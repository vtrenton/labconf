# infralab

Three Intel mini PCs (4 cores, 16 GB, 512 GB NVMe, TPM 2.0) running Ubuntu
Server 26.04 minimal. Every node runs all k3s roles.

## Delineation

| Layer | Owns |
|---|---|
| **Network** | Everything per-node. DHCP reservation (MAC -> IP), PTR record in `binddns/` (IP -> hostname). |
| **`autoinstall/`** | Everything OS-level, identical on all nodes: disk layout, LUKS + TPM unlock, user, SSH, sudo, packages, hostname-from-DNS. |
| **`ansible/`** | Bootstrap of k3s and what must exist before Argo CD can run: kube-vip, Gateway API CRDs, Cilium, Argo CD. Plus day-2 ops playbooks. |
| **`argo-apps/`** | Everything after bootstrap (Argo CD app-of-apps): system-upgrade-controller, kube-vip-cloud-provider, the shared Gateway, monitoring. |

Nodes are cattle: rebuilding one is boot the USB, wait, run Ansible.

## Install

1. Write the Ubuntu Server 26.04 ISO to a USB stick.
2. Copy `autoinstall/user-data` and `autoinstall/meta-data` to a second FAT
   stick labelled `CIDATA`. One stick works for every node.
3. Boot the node with both. Answer `yes` at the autoinstall prompt (or add
   `autoinstall` to the kernel line in GRUB to skip it). **This erases the
   NVMe.**
4. When it is back on SSH, save the recovery key and remove it from disk:

   ```
   ssh sysadmin@infraN sudo cat /root/luks-recovery-key   # -> password manager
   ssh sysadmin@infraN sudo shred -u /root/luks-recovery-key
   ```

## How it works

- **Hostname from DNS.** `hostname-from-dns.service` runs on every boot after
  the network is up (and before k3s): it looks up the PTR record for the
  node's address and sets the hostname to its short name. Renaming a node is a
  DNS change and a reboot. cloud-init is told to leave the hostname alone
  (`preserve_hostname`).
- **Disk unlock.** The root volume is LUKS2. The installer formats it with a
  throwaway passphrase (in `user-data`, deliberately public). `late-commands`
  then enroll a TPM2 keyslot bound to PCR 7, add a recovery key, wipe the
  throwaway passphrase, and add the `tpm2-tss` dracut module plus
  `tpm2-device=auto` in crypttab so the initramfs unlocks without a console.
  Any failure aborts the install.
- **Teleport agent (SSH).** First boot runs `install-teleport`: a
  checksum-pinned `teleport-update` enrolls the node in Managed Updates (group
  `infralab`), then `teleport` starts after `hostname-from-dns` and joins with
  the TPM (token `infralab-nodes`, which allows each node's EK hash; managed by
  the Teleport operator). A reinstall keeps the same TPM, so the node rejoins on
  its own. Until the token exists, the agent keeps retrying.
- **No secrets in the repo.** The user has a locked password (SSH key +
  passwordless sudo), and the only key that opens the disk outside the TPM is
  the recovery key generated on the node.

## PCR 7 trade-offs

PCR 7 measures the Secure Boot state and key databases, so kernel, initramfs
and GRUB updates don't affect it and unattended upgrades reboot cleanly.
Toggling Secure Boot, changing its keys, or a firmware/`dbx` update that
changes them will make the node fall back to a passphrase prompt: enter the
recovery key, then re-enroll:

```
sudo systemd-cryptenroll --wipe-slot=tpm2 --tpm2-device=auto --tpm2-pcrs=7 /dev/nvme0n1p3
```

Secure Boot is currently **off** (firmware in Setup Mode), so the TPM will
unseal for anything booted on the same machine. This protects a disk removed
from the box, not a stolen box. To tighten it, restore the factory Secure Boot
keys in the BIOS and enable Secure Boot (Ubuntu's signed shim/GRUB/kernel
boot as-is), before installing.

## Cluster

All three nodes are k3s servers (embedded etcd, no taint, all run workloads).

| | |
|---|---|
| API server VIP | `10.0.0.160:6443` (`infracluster`), kube-vip ARP, up with the first server |
| LoadBalancer pool | `10.0.0.165-10.0.0.166`: kube-vip-cloud-provider allocates, kube-vip announces |
| Ingress | Gateway API first: Cilium Gateway `gateway/infra` on `10.0.0.165` (`parentRefs: [{name: infra, namespace: gateway}]`). Legacy `Ingress` resources: Cilium shared ingress (default IngressClass `cilium`) on `10.0.0.166`. |
| CNI | Cilium: kube-proxy replacement, Gateway API (Envoy), Hubble. No Cilium L2 / LB-IPAM pools. |
| Pods / Services | `10.40.0.0/16` / `10.41.0.0/16` (distinct from pilab for a future ClusterMesh) |
| Kubeconfig | `~/.kube/infralab-k3s.yaml` (fetched by the playbook, points at the VIP) |

Bring it up (from `infralab/ansible/`):

```
ansible-playbook playbooks/cluster.yml
```

Upgrades: k3s via the SUC Plan in `argo-apps/system-upgrade-controller`; Cilium,
kube-vip, Gateway API CRDs and Argo CD via `inventory/group_vars/all/versions.yml`
and a re-stage with `--tags <role>`.

## Monitoring (both labs)

```
pilab  ── Prometheus agent (RAM-only WAL) ──remote write──▶ prometheus.infra.labnet.lan/api/v1/write
                                                              │ (Gateway .165, write path only)
infralab ─ Prometheus (30d, local-path PVC) ◀─────────────────┘
              ▲
           Grafana (anonymous Viewer) ◀── grafana.infra.labnet.lan ◀── TV
```

- `argo-apps/monitoring/`: kube-prometheus-stack (Prometheus, node-exporter,
  kube-state-metrics, Grafana) with the values in `values.yaml`, plus
  `manifests/` (HTTPRoutes, dashboards). pilab runs the same chart in agent
  mode from `pilab/argo-apps/monitoring-agent/`; keep the chart versions in
  step.
- Every series carries `cluster` (`infralab` / `pilab`, set at scrape time)
  and node-exporter series carry `node`. The bundled dashboards get a cluster
  picker.
- Grafana has no admin user and no login form: anonymous Viewer only, no
  persistence. Dashboards are code: add a JSON file under
  `manifests/dashboards/` and list it in `manifests/kustomization.yaml`.
- The TV: `chromium --kiosk http://grafana.infra.labnet.lan/?kiosk` opens the
  home dashboard, `dashboards/lab-overview.json`.
- Both endpoints are unauthenticated and LAN-only. Anything on the LAN can
  view Grafana and push samples to Prometheus.

## Day 2

From `infralab/ansible/` (`source ansible-configure.sh` first):

| Task | Command |
|---|---|
| Patch OS packages, one node at a time; reboot only where Ubuntu requires it, waiting for each node to be Ready (`--check` to only list pending updates). The only thing that upgrades packages: unattended upgrades are off. | `ansible-playbook playbooks/ops/update-and-reboot.yml` |
| Rolling reboot | `ansible-playbook playbooks/ops/rolling-reboot.yml` |
| Tear down k3s on every node (destructive) | `ansible-playbook playbooks/ops/reset.yml -e confirm_reset=yes` |
