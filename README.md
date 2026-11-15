# labconf

Configuration for a homelab: every cluster, the lab DNS, and the Teleport
resources that give access to all of it. Everything is declarative and kept
in git; this repo is public, so **nothing in it is a secret** (identity is
keyless: TPM, Kubernetes service-account and SPIFFE joins through Teleport).

## Layout

| Path | What |
|---|---|
| [`infralab/`](infralab/README.md) | 3 Intel mini PCs (Ubuntu, unattended install + TPM disk unlock). The **gateway**: the only Argo CD (deploys to every cluster), cert-manager, central Prometheus/Grafana. |
| [`pilab/`](pilab/README.md) | 7 Raspberry Pi 4s (Debian kernel, k3s, Cilium). Bootstrapped by Ansible; everything else deployed from infralab's Argo CD through Teleport. |
| [`hv1/`](hv1/README.md) | The Proxmox VE hypervisor (ThinkStation P520): unattended install (`answer.toml`), first-boot setup (key-only SSH, Teleport agent, root and VM storage on LUKS with TPM unlock), ISO builder. Storage for the clusters and a few VMs. |
| [`teleport/`](teleport/README.md) | How the labs use Teleport: agents and versions. The Teleport resources themselves (roles, join tokens, bots, Managed Updates) are in the `teleport-master` repo, `teleport-resources/`. |
| `binddns/` | DNS for every network, on `labns` / dns1 (`10.0.53.11`): Unbound (resolver, IoT allowlist view, DoT to Quad9) in front of BIND (authoritative: `labnet.lan` machines, `wired.lan`, `lab.trentonvanderwert.com` LAN-only service names, reverse zones). Plus its Teleport SSH agent (`binddns/teleport/`). |
| `kiosk/` | systemd unit for the rack TV (cage + Chromium on the Grafana dashboard). |
| `scripts/` | `check-teleport-versions.sh`: every Teleport version in the repo matches `autoupdate.yaml` (run in CI). |
| `.githooks/`, `.github/` | Secret scanning (a fail-closed gitleaks pre-commit hook and a gitleaks CI workflow) and the Teleport version check in CI. |

Each cluster directory follows the same split: `ansible/` (or
`autoinstall/` + `ansible/`) bootstraps the nodes and k3s, and `argo-apps/`
holds everything after bootstrap. Argo CD paths are relative to the repo
root (`<cluster>/argo-apps/...`).

## How it fits together

```
           Teleport (self-hosted, teleport.aws.trentonvanderwert.com)
           SSH, kubectl, web apps, SSO for Grafana/Argo CD, AWS via Roles Anywhere
                      ▲                                ▲
 infralab ── Argo CD ─┼── deploys ──▶ pilab            │
   (gateway)          └── kube agent        kube agent ┘
 Prometheus ◀──────────── remote write ─── Prometheus agent
 cert-manager ── Let's Encrypt wildcard *.infra.lab.trentonvanderwert.com (DNS-01, Route 53)
```

When Teleport, SSO or GitOps isn't available: [BREAK-GLASS.md](BREAK-GLASS.md).

## Working in this repo

- Enable the hook once per clone: `git config core.hooksPath .githooks`.
- `master` requires signed commits (no force-push or deletion).
- Argo CD syncs from `master` on GitHub: changes take effect after a push.

## Open items

Decided, not built yet. The network side has its own list (`udm-pro-config`,
OPERATIONS.md, "Open items").

- **Teleport SSH agent installs without version pins.** Managed Updates
  already update the SSH agents, but fresh installs still pin a version and
  SHA-256 (`infralab/autoinstall/user-data`, pilab's `node_prep` defaults,
  `binddns/teleport/install.sh`). Move them to the proxy's install script
  (`https://teleport.aws.trentonvanderwert.com/scripts/install.sh?group=<group>`),
  as `hv1/first-boot.sh` does, so no installer or Ansible role picks a
  version; then drop those pins from `scripts/check-teleport-versions.sh`.
- **hv1 on the TV.** The lab overview's network graph leaves hv1 out. Its
  panel waits for VM traffic and shows the dataplane (`bond0`/`vmbr1`, later
  the X710), not management (`nic0`).
- **hv1's `bulk` storage VM:** the five SATA SSDs (controller `00:17.0`
  passed through) as RAIDZ2 in a Debian VM, serving NFS/iSCSI to the
  clusters over labnet.
- **VLANs for VMs:** services (`804`) and a non-routed storage VLAN (`805`)
  are reserved in `udm-pro-config`. Tag them on lab-access's LAG (ports
  33-36), then per VM NIC on `vmbr1`.
- **10 GbE dataplane:** with a 10 GbE server switch, the X710 becomes a
  second bond for east-west and storage traffic; `bond0` stays the VMs'
  front end. DPDK after that.
- **DNS:** the `dc` rename (with ExternalDNS) and a dns2, in
  [binddns/README.md](binddns/README.md#conventions).
