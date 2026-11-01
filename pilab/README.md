# pilab

A 7-node Raspberry Pi 4 Kubernetes lab: HA k3s with embedded etcd, Cilium
for networking, Traefik for Gateway API/Ingress. Everything after bootstrap
is deployed by the central Argo CD in infralab, through Teleport.

This directory is one cluster in the
[labconf](https://github.com/vtrenton/labconf) repo. Paths below are relative
to `pilab/` unless they start with `pilab/`, which is how Argo CD sees them
(relative to the repo root).

| Piece | Role |
|---|---|
| k3s (embedded etcd) | 3 masters (`10.0.0.11-13`), etcd on a USB SSD; 4 workers (`10.0.0.14-17`), SD card only |
| kube-vip | API server VIP `10.0.0.10:6443`, ARP from the masters |
| Cilium | CNI + kube-proxy replacement, LB-IPAM pool `10.0.0.20-25`, L2 (ARP) announcements from workers only |
| Traefik (bundled with k3s) | Gateway API + Ingress on `10.0.0.20` (`kube-system/traefik-gateway`) |
| Argo CD (in infralab) | App-of-apps `pilab` syncs `pilab/argo-apps/apps`; reaches this cluster through Teleport (`tbot-argocd`) |
| Teleport kube agent (`kube,app`) | Registers the cluster as `pilab` (`lab=pilab`) and serves the Teleport app `hubble-pilab` (Hubble UI). Staged by Ansible because Argo CD connects through it |
| Teleport SSH agents | On all 7 nodes (`node_prep`), joined with each Pi's TPM (token `pilab-nodes`); Managed Updates group `pilab` |
| Prometheus agent | Scrapes the cluster and remote-writes to infralab over HTTPS; no storage, rules or Grafana here |
| system-upgrade-controller | k3s upgrades via Plans in git |

## Why the nodes run Debian's kernel and a custom device tree overlay

The nodes run Debian trixie with Raspberry Pi OS packages. **The Pi OS
kernel (`*+rpt-rpi-v8`) can't run this stack**, so `node_prep` switches every
node to Debian's stock generic arm64 kernel (`linux-image-arm64`). It is not
a custom-compiled kernel; what's custom is how the Pi firmware boots it and
one device tree overlay.

### The two kernel problems

| Problem | Pi OS kernel | Debian `linux-image-arm64` | Symptom |
|---|---|---|---|
| BTF type info | `CONFIG_DEBUG_INFO_NONE=y`, no `/sys/kernel/btf/vmlinux` | `CONFIG_DEBUG_INFO_BTF=y` | Cilium 1.20 datapath never loads: `apply CO-RE relocations: load kernel spec: no BTF found`. Every non-hostNetwork pod sticks in `ContainerCreating` (CNI returns `429 putEndpointIdTooManyRequests`) |
| Virtual address bits | `CONFIG_ARM64_VA_BITS=39` | `52` | `cilium-envoy` crashes at start: tcmalloc assumes a 48-bit address space |

- Cilium lists `CONFIG_DEBUG_INFO_BTF=y` as a requirement from 1.19.x on:
  [system_requirements.rst (v1.20.4)](https://github.com/cilium/cilium/blob/v1.20.4/Documentation/operations/system_requirements.rst).
  1.18 doesn't list it, but pinning an old Cilium only delays the problem.
- The Envoy crash is the still-open
  [cilium/proxy#1027 "cilium-envoy failing on RPi4 + RaspbianOS"](https://github.com/cilium/proxy/issues/1027).
  The workarounds there are rebuilding Envoy without tcmalloc or rebuilding
  the Pi kernel with `CONFIG_ARM64_VA_BITS_48`; both need redoing on every
  upgrade.

Debian's kernel fixes both, still supports the Pi 4 (`ARCH_BCM2835`,
`BCMGENET`, `PCIE_BRCMSTB`, `MMC_SDHCI_IPROC`), and updates through normal
`apt`.

> Traefik, not Cilium, serves Gateway API/Ingress because of the Envoy crash.
> With the 52-bit kernel Cilium's Envoy should now work; switching back is a
> possible follow-up, not a requirement.

### How the Pi firmware boots it (`roles/node_prep/tasks/boot_kernel.yml`)

The Pi OS `raspi-firmware` kernel hooks only handle `*-rpi-*` kernels and
skip anything else, so the role wires Debian's kernel in itself:

1. **initramfs modules**: `sdhci_iproc` and `mmc_block` are added to
   `/etc/initramfs-tools/modules`. On Debian's kernel the SD controller is a
   module (built in on the Pi kernel), and `MODULES=dep` resolves against the
   *running* Pi kernel, so without this the initrd can't find the root fs.
2. **Kernel hook** `debian-kernel-to-firmware` (in `postinst.d`, `postrm.d`
   and `initramfs/post-update.d`): copies the newest `vmlinuz-*-arm64`, its
   initrd and the upstream `bcm2711-rpi-4-b.dtb` to `/boot/firmware/debian/`.
   Kernel updates through `apt` then just work.
3. **`config.txt`** (template; the original is kept as `config.txt.rpi`)
   uses the Pi firmware's `kernel=`, `initramfs`, `device_tree=` and
   `overlay_prefix=` options
   ([config.txt docs](https://www.raspberrypi.com/documentation/computers/config_txt.html))
   to boot `debian/vmlinuz` with the **upstream** device tree.

### Device tree overlays (`roles/node_prep/files/*.dts`)

The upstream device tree uses different node labels than the Pi OS one, so
**Pi OS overlays (`dtoverlay=...` from `/boot/firmware/overlays`) don't
apply**. Ours are listed in `node_prep_dt_overlays`, compiled on the node with
`dtc -@` into `/boot/firmware/debian/overlays/`, and applied by the firmware
via `config.txt` (`overlay_prefix=debian/overlays/`).

| Pi OS overlay | Replacement |
|---|---|
| `tpm-slb9670` (Infineon SLB9670 TPM 2.0 on SPI0 CE1) | `tpm-slb9670-upstream`. The Pi overlay targets the Pi-only labels `spi0`/`spidev1`; ours targets upstream's `spi` and `gpio`, declares the SPI0 pin groups and uses `cs-gpios` for chip select. The kernel's `tpm_tis_spi` matches `infineon,slb9670` → `/dev/tpm0`, `/dev/tpmrm0` |
| `disable-wifi` | `disable-wifi-upstream` plus two more layers, below |

The vc4 display overlay is simply dropped (headless).

### Wi-Fi is off in three independent layers

| Layer | Mechanism | Effect |
|---|---|---|
| 1. Device tree | `disable-wifi-upstream` sets the SDIO controller `mmc@7e300000` (label `sdhci`) to `disabled` | The radio's power sequence never runs and the chip is never enumerated. The SD card is on a different controller (`emmc2`, `mmc@7e340000`) |
| 2. Kernel module | `/etc/modprobe.d/disable-wifi.conf`: `blacklist` **and** `install brcmfmac /bin/false` | Blocks autoloading, explicit `modprobe`, and loading as a dependency |
| 3. NetworkManager | `/etc/NetworkManager/conf.d/99-disable-wifi.conf` (`match-device=type:wifi`, `managed=0`) | A Wi-Fi device that somehow appeared would never be brought up |

After every reboot the rollout asserts `ifaces=0 driver=0 sdio=0` (no wireless
interface, no `brcmfmac`, nothing on SDIO) and stops if Wi-Fi is present.

**Bluetooth is deliberately left alone** (driver loaded, soft-blocked by
rfkill) for possible future use. It shares the CYW43455 chip but is on the
UART (`serial@7e201000`) with its own enable line, so the Wi-Fi overlay
doesn't affect it. Disabling it later would be the same pattern: an overlay
for the UART's Bluetooth node plus blocking `hci_uart`/`btbcm`.

### Trade-offs to know

- **Rescue path**: `cp /boot/firmware/config.txt.rpi /boot/firmware/config.txt`
  and reboot boots the Pi OS kernel (still installed). If the node won't
  boot, do the same with the SD card in another machine. `reboot "0 tryboot"`
  does **not** work from Debian's kernel: the mainline firmware driver doesn't
  pass the tryboot flag.
- **SD card device name isn't stable**: it's `mmcblk0` or `mmcblk1` depending
  on boot. Everything uses PARTUUIDs; never hardcode `/dev/mmcblkN`.
- **Pi-specific tools** that need downstream drivers (`vcgencmd`, `/dev/vcio`)
  don't work.
- The TPM runs SPI without DMA (`no tx-dma configuration found`), which is
  fine at TPM data rates.
- **kubemaster1's SLB9670 was a TPM 1.2 part**, converted to TPM 2.0 with
  Infineon's firmware tool (same chip, `rev-id 16`; the others are native 2.0,
  `rev-id 22`). After a 1.2 -> 2.0 conversion the chip needs a **power cycle**
  (a warm `reboot` leaves it in `TPM_RC_REBOOT`). Its boot log always shows
  `A TPM error (256) ... starting up the TPM manually`: harmless, the Pi
  firmware doesn't send `TPM2_Startup`, so the kernel does.

## Teleport

- **SSH:** `node_prep` (`--tags teleport`) writes `/etc/teleport.yaml` (SSH
  only, label `lab=pilab`, `join_params.method: tpm`, token `pilab-nodes`) and
  installs Teleport with a checksum-pinned `teleport-update` (group `pilab`).
  The token (in `infralab/argo-apps/teleport-resources/tokens-nodes.yaml`)
  allows each node's TPM Endorsement Key hash; nothing secret is on the node,
  and the EK survives a reflash, so a rebuilt node rejoins by itself. A new or
  replaced TPM needs its `teleport tpm identify` output added there.
- **Kubernetes and apps:** the kube agent (`roles/teleport_kube_agent`) joins
  with the Kubernetes JWKS method (token `pilab-kube-agent`, roles
  `Kube, App`). `hubble-pilab` is a static app because Teleport's app
  discovery never looks in `kube-system`, where Cilium puts the Hubble UI.
- **Access:** role `lab-admin` (managed in infralab) gives SSH as `admin`,
  `system:masters`, and the apps. OpenSSH stays for Ansible.
- Agent state lives in `/var/lib/teleport` on the SD card (small writes, plus
  session recordings while a session is open).

## Other design decisions

- **kube-vip, not Cilium, owns the API VIP.** kube-vip runs as a static
  manifest in the k3s auto-deploy dir, so `10.0.0.10` comes up with the first
  server, before any CNI exists. Its lease timings are 15/10/2s: the original
  5/3/1s made kube-vip exit (dropping the VIP) when a busy Pi missed a renew.
- **Cilium reaches the apiserver at `127.0.0.1:6444`.** That's k3s's local
  apiserver (servers) or client load balancer (agents), so Cilium doesn't
  depend on the VIP.
- **Everything bootstrap-critical is staged before k3s starts.** kube-vip,
  Cilium, the Traefik `HelmChartConfig` and the Teleport kube agent go into
  `/var/lib/k3s/server/manifests` first; k3s applies them in name order and
  retries failures every 15s
  ([k3s auto-deploying manifests](https://docs.k3s.io/installation/packaged-components),
  [HelmChart](https://docs.k3s.io/helm)).
- **Ansible installs k3s once; SUC owns upgrades.** The k3s role never
  reinstalls an existing node, so a stale `k3s_version` can't downgrade the
  cluster ([automated upgrades](https://docs.k3s.io/upgrades/automated)).
- **The repo is public: no secrets.** The k3s join token is read from the
  first server at runtime (`no_log`); never commit a plain `Secret` to
  `argo-apps/`.

## Repo layout

```
pilab/
├── README.md
├── ansible/                    # bootstrap: nodes, k3s, and what infralab's Argo CD needs to reach the cluster
│   ├── ansible.cfg             # inventory + roles path (no -i needed)
│   ├── requirements.yml        # ansible.posix, community.general
│   ├── inventory/
│   │   ├── hosts.yml           # hosts + groups only (first master inits etcd)
│   │   └── group_vars/
│   │       ├── all/
│   │       │   ├── cluster.yml     # VIP, CIDRs, data dir, interface
│   │       │   ├── network.yml     # LB-IPAM pool, Traefik IP
│   │       │   ├── versions.yml    # every pinned version
│   │       │   ├── teleport.yml    # Teleport proxy + cluster name (kube agent; SSH agent vars are node_prep defaults)
│   │       │   └── connection.yml  # SSH user/key
│   │       ├── masters.yml     # k3s_role: server
│   │       └── workers.yml     # k3s_role: agent
│   ├── playbooks/
│   │   ├── site.yml            # prep-nodes + cluster
│   │   ├── prep-nodes.yml      # node_prep, serial: 1
│   │   ├── cluster.yml         # masters: kube_vip, cilium, traefik, teleport_kube_agent, k3s; workers: k3s
│   │   └── ops/                # reset, rolling-reboot, update-and-reboot
│   └── roles/
│       ├── node_prep/          # cmdline cgroups, Debian kernel, DT overlays (TPM, Wi-Fi off), sysctls, SSD mount, Teleport SSH agent
│       ├── k3s/                # config, install-once, first-server setup
│       ├── kube_vip/           # API VIP manifests
│       ├── cilium/             # HelmChart + LB pool / L2 policy
│       ├── traefik/            # HelmChartConfig for bundled Traefik
│       └── teleport_kube_agent/  # Teleport kube agent HelmChart (kube + static app hubble-pilab)
└── argo-apps/                  # everything after bootstrap (synced by infralab's Argo CD)
    ├── apps/                   # Application manifests (destination: pilab), synced by infralab app "pilab"
    ├── monitoring-agent/       # Prometheus agent values (remote-writes to infralab)
    └── system-upgrade-controller/  # SUC + k3s upgrade Plans
```

Lab DNS (BIND config and zones, including the node records) is shared by all
clusters and lives at the repo root in `binddns/`.

Argo CD Applications reference paths from the **repo root**, so they use the
`pilab/` prefix: `path: pilab/argo-apps/<name>`.

### Who owns what

| Concern | Owner | Change it in |
|---|---|---|
| Node OS, kernel, boot config, TPM, Wi-Fi off, Teleport SSH agent | Ansible `node_prep` | `roles/node_prep/` |
| Teleport tokens, roles, Managed Updates | infralab's Teleport operator | `infralab/argo-apps/teleport-resources/` |
| k3s install + config | Ansible `k3s` (first install only) | `group_vars`, `roles/k3s/` |
| k3s version after install | SUC | `argo-apps/system-upgrade-controller/k3s-plans.yaml` |
| API VIP | kube-vip, staged by Ansible | `roles/kube_vip/` |
| CNI, LB IPs, L2 | Cilium, staged by Ansible | `roles/cilium/`, `network.yml` |
| Gateway API / Ingress | k3s's Traefik, configured by Ansible | `roles/traefik/` |
| Teleport kube agent | Ansible (`teleport_kube_agent`) | `roles/teleport_kube_agent/`, `versions.yml` |
| Everything else | infralab's Argo CD | `argo-apps/` |

## Rolling out

From `pilab/ansible/`:

```sh
source ansible-configure.sh                   # ssh-agent + key; must be sourced, not executed
ansible-galaxy collection install -r requirements.yml
ansible-playbook playbooks/site.yml           # full build
```

Or in stages: `playbooks/prep-nodes.yml`, then `playbooks/cluster.yml`.
`pilab/argo-apps/` must be pushed to `master` on GitHub before infralab's Argo CD can sync it. After a rebuild, update pilab's JWKS in `infralab/argo-apps/teleport-resources/tokens-kube-agents.yaml` so the kube agent (and with it Argo CD) can connect.

### What to expect

1. **Node prep** (`prep-nodes.yml`, one node at a time, about 4-6 min each
   on first run, about 2 min when only `config.txt` changes): it fixes
   `cmdline.txt`, installs Debian's kernel, builds the device tree overlays,
   disables Wi-Fi, writes `config.txt`, mounts the SSD on masters, installs
   the Teleport SSH agent (it joins with the TPM), then **reboots once** if
   needed. A node must pass verification (Debian
   `*-arm64` kernel, memory cgroup, BTF, no Wi-Fi) before the next one starts;
   any failure stops the rollout.
2. **First master** (`cluster.yml`): manifests are staged, k3s is installed
   and started, then the play waits for the join token and for kube-vip to
   bring up `10.0.0.10:6443` (up to 10 min while the image pulls). The admin
   kubeconfig lands in `~/.kube/pilab-k3s.yaml`, pointing at the VIP.
3. **Other masters** join through the VIP one at a time. k3s is started
   without blocking and polled until active (up to 5 min), so a brief VIP
   blip just costs a systemd retry.
4. **Workers** join in parallel.
5. **Final check**: all nodes Ready (up to 15 min while Cilium images pull on
   the Pis).
6. **In-cluster, on its own**: Cilium → Traefik (`10.0.0.20` returns 404 with
   no routes) → the Teleport kube agent joins → infralab's Argo CD sees `pilab`
   and syncs `pilab/argo-apps/apps` → SUC applies its Plans as a no-op on each node (each node is briefly cordoned).

Every playbook is idempotent; re-running after a timeout is safe.

### Day 2

| Task | How |
|---|---|
| Re-stage one bootstrap component | `ansible-playbook playbooks/cluster.yml --tags kube_vip\|cilium\|traefik\|teleport_kube_agent` |
| Upgrade k3s (incl. bundled Traefik) | Bump `version` in both SUC Plans **and** `k3s_version` in `versions.yml`, one minor at a time; push |
| Upgrade Cilium | Bump `cilium_version` (one minor at a time), then `--tags cilium` |
| Upgrade Teleport | After the Teleport cluster: `teleport_kube_agent_chart_version` in `versions.yml` then `--tags teleport_kube_agent`; SSH agents follow infralab's `autoupdate.yaml` (group `pilab`, 24h after `infralab`, Mon-Thu 16:00 UTC; start early with `tctl autoupdate agents start-update pilab`). `node_prep_teleport_bootstrap_version` + SHA-256 only matter for fresh installs. |
| Kernel / package updates | `ansible-playbook playbooks/ops/update-and-reboot.yml`: one node at a time, reboots only into a newer Debian `-arm64` kernel and waits for the node to be Ready (`--check` only lists pending updates). It's the only thing that upgrades packages. The hook syncs a new kernel to `/boot/firmware/debian/`. |
| Add an app | Application YAML in `argo-apps/apps/` (`name: pilab-<app>`, `destination.name: pilab`, `path: pilab/argo-apps/<name>`), manifests in `argo-apps/<name>/` |
| Wipe and rebuild | `ansible-playbook playbooks/ops/reset.yml -e confirm_reset=yes`, then `site.yml` |

### Notes

- Workers keep k3s data (images, `local-path` volumes, logs) on the SD card.
  Steady-state writes are small, but don't schedule write-heavy PVCs on
  workers until they have SSDs.
- **Monitoring:** the Prometheus agent (`argo-apps/monitoring-agent/`) writes
  to `https://prometheus.infra.lab.trentonvanderwert.com/api/v1/write`. Its
  WAL is a RAM-only `emptyDir` (1Gi; no SD writes): it holds ~2h plus anything
  unsent, and if it fills, scrapes fail until the pod restarts. k3s exposes the
  embedded control-plane metrics on the kubelet endpoint too, so those are
  dropped from the kubelet job (~200k -> ~73k series). Data, rules and Grafana
  are in infralab.
- **Traefik** comes with k3s (currently 3.7.13). The Traefik and containerd
  CVE fixes arrive with the next GA k3s patch (`v1.36.6+k3s1`); upgrade via SUC.
- `kubemaster1` has `cluster-init: true`. Rebuilding only kubemaster1 would
  start a new cluster; rebuild the whole cluster, or rejoin it as a normal
  server.
