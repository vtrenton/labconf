# labconf

Configuration for a homelab: every cluster, the lab DNS, and the Teleport
resources that give access to all of it. Everything is declarative and kept
in git; this repo is public, so **nothing in it is a secret** (identity is
keyless: TPM, Kubernetes service-account and SPIFFE joins through Teleport).

## Layout

| Path | What |
|---|---|
| [`infralab/`](infralab/README.md) | 3 Intel mini PCs (Ubuntu, unattended install + TPM disk unlock). The **gateway**: the only Argo CD (deploys to every cluster), the Teleport operator, cert-manager, central Prometheus/Grafana. |
| [`pilab/`](pilab/README.md) | 7 Raspberry Pi 4s (Debian kernel, k3s, Cilium). Bootstrapped by Ansible; everything else deployed from infralab's Argo CD through Teleport. |
| [`teleport/`](teleport/README.md) | The Teleport operator's own bootstrap identity (`tctl`). All other Teleport resources live in `infralab/argo-apps/teleport-resources/`. |
| `binddns/` | BIND config and zones for the LAN resolver `labns` (`10.0.0.5`): `labnet.lan` (machines), `lab.trentonvanderwert.com` (LAN-only service names), reverse zone. |
| `kiosk/` | systemd unit for the rack TV (cage + Chromium on the Grafana dashboard). |
| `.githooks/`, `.github/` | Secret scanning: a fail-closed gitleaks pre-commit hook and a gitleaks CI workflow. |

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
