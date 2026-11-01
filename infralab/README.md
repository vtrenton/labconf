# infralab

Three Intel mini PCs (4 cores, 16 GB, 512 GB NVMe, TPM 2.0) running Ubuntu
Server 26.04 minimal, as one HA k3s cluster where every node runs all roles.

infralab is the lab's **deployment and identity gateway**: it runs the only
Argo CD (deploying to itself and to pilab), the Teleport operator that manages
Teleport as code, cert-manager, and the central Prometheus/Grafana for both
labs. Access to everything goes through the self-hosted Teleport cluster
(`teleport.aws.trentonvanderwert.com`); nothing in this repo is a secret.

## At a glance

| What | Where |
|---|---|
| Nodes | `infra1-3` = `10.0.0.161-163` (DHCP reservation; hostname from the PTR record) |
| API server VIP | `10.0.0.160:6443` (`infracluster.labnet.lan`), kube-vip |
| Gateway (Gateway API) | `10.0.0.165`: `*.infra.lab.trentonvanderwert.com`, HTTPS with a Let's Encrypt wildcard; HTTP redirects to HTTPS |
| Legacy Ingress | `10.0.0.166`: Cilium shared Ingress (default IngressClass `cilium`) |
| Pods / Services | `10.40.0.0/16` / `10.41.0.0/16` (distinct from pilab for a future ClusterMesh) |
| Teleport apps | `https://<app>.teleport.aws.trentonvanderwert.com` (see [Teleport](#teleport)) |
| TV dashboard | `https://grafana.infra.lab.trentonvanderwert.com/?kiosk` (anonymous, LAN) |
| Kubeconfig | via Teleport (`tsh kube login infralab`), or `~/.kube/infralab-k3s.yaml` (written by the cluster playbook) |

## Who owns what

| Layer | Owns |
|---|---|
| **Network** | Per-node identity: DHCP reservation (MAC -> IP) and PTR record in `binddns/` (IP -> hostname). Service names in the LAN-only zone `lab.trentonvanderwert.com` on `labns`. |
| **`autoinstall/`** | Everything OS-level, identical on all nodes: disk layout, LUKS + TPM unlock, user, SSH, sudo, packages, hostname-from-DNS, Teleport SSH agent, no unattended upgrades. |
| **`ansible/`** | Bootstrap only: k3s and what must exist before Argo CD (kube-vip, Gateway API CRDs, Cilium, Argo CD), plus day-2 ops playbooks. |
| **`argo-apps/`** | Everything after bootstrap, for **both** clusters (app-of-apps `root`; pilab's apps come from `pilab/argo-apps/apps` via the `pilab` app). |
| **`argo-apps/teleport-resources/`** | Teleport roles, join tokens, bots, workload identities, SAML apps and Managed Updates, reconciled by the Teleport operator. |
| **`aws/`** | The keyless Route 53 access for cert-manager (CloudFormation), in AWS account `321051512565`. |
| **`../teleport/bootstrap/`** | The operator's own identity (applied once with `tctl`; see `teleport/README.md`). |

## Repo layout

```
infralab/
├── autoinstall/            user-data + meta-data (the same for every node)
├── aws/                    cert-manager-dns01.yaml (Roles Anywhere, IAM role, $5 budget)
├── ansible/
│   ├── inventory/          hosts.yml; group_vars/all/{cluster,connection,gitops,versions}.yml
│   ├── playbooks/          cluster.yml; ops/{update-and-reboot,rolling-reboot,reset}.yml
│   └── roles/              kube_vip, gateway_api_crds, cilium, argocd_bootstrap, k3s
└── argo-apps/
    ├── apps/               one Application per app (root syncs this dir)
    ├── cert-manager/ cert-manager-issuers/ tbot/        certificates (keyless DNS-01)
    ├── gateway/            Gateway, wildcard Certificate, HTTP->HTTPS redirect
    ├── kube-vip-cloud-provider/   LoadBalancer IP pool
    ├── monitoring/         kube-prometheus-stack values; manifests/ (routes, dashboards)
    ├── system-upgrade-controller/ k3s upgrade Plan
    ├── teleport-operator/ teleport-kube-agent/ tbot-argocd/ teleport-resources/
    └── (pilab's apps live in pilab/argo-apps/, synced from here)
```

## Installing a node

1. Write the Ubuntu Server 26.04 ISO to a USB stick.
2. Put `autoinstall/user-data` and `autoinstall/meta-data` on a FAT filesystem
   labelled `CIDATA`: a second stick, or a partition in the free space after
   the ISO (`sgdisk -e` the stick first so the GPT covers the whole disk). One
   copy works for every node; re-copy after `user-data` changes.
3. Boot with both and answer `yes` at the autoinstall prompt (or add
   `autoinstall` to the GRUB kernel line). **This erases the NVMe.**
4. Clear the old host keys (`ssh-keygen -R 10.0.0.16N`), then save the LUKS
   recovery key and remove it from the node:

   ```
   ssh sysadmin@10.0.0.16N sudo cat /root/luks-recovery-key   # -> password manager
   ssh sysadmin@10.0.0.16N sudo shred -u /root/luks-recovery-key
   ```

The node joins Teleport on its own (TPM); then bring up k3s (below).

## How a node works

- **Hostname from DNS.** `hostname-from-dns.service` runs every boot once the
  network is up: it resolves the PTR record for the node's address and sets the
  short name. k3s and Teleport both `Require=` it, so a node never registers
  under the installer's default name. Renaming a node is a DNS change and a
  reboot.
- **Disk unlock.** LUKS2 root. The installer formats it with a throwaway
  passphrase (public in `user-data`, wiped before first boot), enrolls a TPM2
  keyslot bound to PCR 7 plus a recovery key, and adds the dracut `tpm2-tss`
  module and `tpm2-device=auto` in crypttab, so boots are unattended.
- **Teleport SSH agent.** First boot runs `install-teleport`: a checksum-pinned
  `teleport-update` enrolls the node in Managed Updates (group `infralab`) and
  `teleport` joins with the TPM (token `infralab-nodes`, one rule per node's EK
  hash). The EK survives reinstalls, so a rebuilt node rejoins by itself.
- **Packages.** Unattended upgrades are off (`apt.conf.d/99-labconf-no-unattended-upgrades`);
  only `playbooks/ops/update-and-reboot.yml` upgrades packages.
- **No secrets.** `sysadmin` has a locked password (SSH key / Teleport +
  passwordless sudo); the only non-TPM key to the disk is the recovery key.

### PCR 7 trade-offs

PCR 7 measures the Secure Boot state and key databases, so kernel, initramfs
and GRUB updates don't affect it. Toggling Secure Boot, changing its keys, or a
firmware/`dbx` update falls back to a passphrase prompt: enter the recovery
key, then re-enroll:

```
sudo systemd-cryptenroll --wipe-slot=tpm2 --tpm2-device=auto --tpm2-pcrs=7 /dev/nvme0n1p3
```

Secure Boot is **off** (firmware in Setup Mode), so the TPM unseals for
anything booted on the box: this protects a removed disk, not a stolen box.
Enable Secure Boot with the factory keys before installing to tighten it.

## Bringing up the cluster

From `infralab/ansible/` (`source ansible-configure.sh` first):

```
ansible-playbook playbooks/cluster.yml
```

One play, `serial: 1`, on all three servers: `kube_vip`, `gateway_api_crds`,
`cilium` and `argocd_bootstrap` only stage manifests in the k3s auto-deploy
dir, then `k3s` installs (the first server initializes etcd; the others join
through the VIP). Ansible installs k3s once and never upgrades it (SUC does).
Re-stage one component with `--tags kube_vip|gateway_api_crds|cilium|argocd`.

Then Argo CD takes over (`root` syncs `argo-apps/apps`). After a **rebuild**,
the cluster's service-account signing keys (JWKS) are new, and every
Kubernetes-JWKS join token has to be refreshed:

1. Operator: `./teleport/bootstrap/render-operator-token.sh > /tmp/t.yaml && tctl create -f /tmp/t.yaml`
2. In git (`kubectl get --raw /openid/v1/jwks`), commit, push:
   `teleport-resources/tokens-kube-agents.yaml` (`infralab-kube-agent`),
   `cert-manager-identity.yaml` (`labconf-cert-manager`),
   `argocd-access.yaml` (`labconf-argocd`).

## Networking and DNS

- **kube-vip** is the only L2 (ARP) speaker: the API VIP, plus LoadBalancer IPs
  that **kube-vip-cloud-provider** allocates from `10.0.0.165-10.0.0.166`.
  Cilium (kube-proxy replacement, Gateway API, Hubble) runs no L2 or LB-IPAM.
- **Gateway `gateway/infra`** on `.165`:
  - `https` listener for `*.infra.lab.trentonvanderwert.com` with the wildcard
    certificate `infra-wildcard-tls`;
  - `http` listener: `http-redirect` sends every `*.infra.lab` name to HTTPS (301).
  - **Rule:** routes for `*.infra.lab` names attach with
    `parentRefs[].sectionName: https`. A route on the `http` listener with an
    exact hostname would win over the wildcard redirect.
- **DNS on `labns`:** zone `lab.trentonvanderwert.com` (`binddns/zones/`) is
  LAN-only: `*.infra` -> `.165`, `ingress.infra` -> `.166`. Public DNS for that
  name is a Route 53 zone holding only cert-manager's `_acme-challenge` TXT
  records. `labnet.lan` only names machines (nodes, VIP, Gateway/Ingress IPs);
  no app uses a `.lan` name.

## Certificates (keyless)

```
tbot (cert-manager ns) --Kubernetes JWKS join--> Teleport (bot labconf-cert-manager)
  --X.509 SVID spiffe://teleport.trentonvanderwert.com/infralab/cert-manager-->
  IAM Roles Anywhere (trust anchor = Teleport SPIFFE CA) --1h creds--> Secret route53-credentials
  --> cert-manager (ambient AWS creds) --DNS-01 TXT--> Route 53 lab.trentonvanderwert.com
  --> Let's Encrypt wildcard *.infra.lab.trentonvanderwert.com
```

- The IAM role (`aws/cert-manager-dns01.yaml`, stack `labconf-cert-manager-dns01`)
  may only change TXT `_acme-challenge.*` in zone `Z06942441FWJASTX1LU8M`, and
  only for that SPIFFE ID. No AWS access key exists anywhere.
- cert-manager checks propagation against public resolvers (`labns` shadows the
  zone on the LAN). If the ISP's handling of `1.1.1.1`/`8.8.8.8` ever breaks it,
  switch `dns01RecursiveNameservers` to `9.9.9.9:53,149.112.112.112:53`.
- Cost: ~$0.50/month (the hosted zone). The stack includes a $5/month budget
  that emails at 80% actual / 100% forecast. Never move the trust anchor to AWS
  Private CA ($400/month).

## Teleport

| What | Joins / authenticates with |
|---|---|
| SSH on infra1-3 (and the Pis) | TPM (`infralab-nodes` / `pilab-nodes`, one EK hash per node) |
| Kube agent (`kube,app,discovery`) | Kubernetes JWKS (`infralab-kube-agent`, roles `Kube, App, Discovery`) |
| Teleport operator (`teleport-iac`) | Kubernetes JWKS, bot `labconf-operator` (bootstrap) |
| tbot for cert-manager / for Argo CD | Kubernetes JWKS, bots `labconf-cert-manager` / `labconf-argocd` |

- **Resources as code:** `argo-apps/teleport-resources/` (roles, tokens, bots,
  workload identity, SAML app, Managed Updates). The operator only manages what
  it created (`teleport.dev/origin: kubernetes`); users stay out of git, and
  your local admin is the break-glass.
- **`lab-admin`** (role): SSH as `sysadmin` (infra) / `admin` (Pis),
  `system:masters` on both clusters, the lab apps, and driving agent update
  rollouts. Assign with `tctl users update <user> --set-roles ...,lab-admin`.
- **A token's roles must cover every role in its agent's values.** After
  widening one, restart the agent so its instance identity picks up the new
  roles (otherwise app heartbeats are refused).

### Apps

| App | Backend | Login inside the app |
|---|---|---|
| `grafana` | Grafana (discovered) | Teleport JWT (`Teleport-Jwt-Assertion`): users created on the fly, `lab-admin` -> Admin, else Viewer |
| `argocd` | Argo CD server (discovered) | Teleport SAML IdP via Argo CD's bundled Dex; `lab-admin` -> `role:admin`; **no local admin** |
| `prometheus-infralab` | Prometheus UI + query API (discovered) | none (Teleport gates it) |
| `hubble-infralab` | Hubble UI (static app) | none |
| `hubble-pilab` | pilab's Hubble UI (static app on pilab's kube agent) | none |

Exposing an app: label the Service `teleport.dev/app: "true"` and annotate
`teleport.dev/name: <name>` (plus `teleport.dev/port` if it has several ports).
Central apps get a bare name; per-cluster apps end in `-<cluster>`. Discovery
**never** looks in `kube-system` or `kube-public`: for those, add a static entry
under `apps:` in the cluster's kube agent values. Apps are labelled
`teleport.dev/kubernetes-cluster: <cluster>`, which is what `lab-admin` matches.

**Argo CD break-glass** (if SSO breaks): with cluster access, set
`admin.enabled: "true"` in `argocd-cm`, set a password (`argocd account bcrypt`
-> `admin.password` / `admin.passwordMtime` in `argocd-secret`), and turn it
off again afterwards. If Keycloak arrives, Argo CD switches to native OIDC
(`dex.enabled: false`, `oidc.config`) with Keycloak federating to Teleport.

## Central Argo CD (deployment gateway)

- `root` syncs `argo-apps/apps`; the `pilab` app syncs `pilab/argo-apps/apps`,
  whose Applications (`pilab-*`) target cluster `pilab`.
- Argo CD reaches pilab **through Teleport**: `tbot-argocd` keeps an Argo CD
  cluster Secret with short-lived certificates (role `labconf-argocd-deployer`,
  `system:masters` on `lab: pilab`). No kubeconfig or token is stored, and
  pilab's API is never exposed. If Teleport is down, syncs to pilab pause;
  nothing running breaks.
- **Adding a cluster:** bootstrap k3s + CNI + a Teleport kube agent labelled
  `lab=<name>` (the agent must be part of the bootstrap, since Argo CD connects
  through it); add `<name>` to `labconf-argocd-deployer`'s `kubernetes_labels`
  and to `tbot-argocd`'s `clusterSelectors`; add a `<name>` app-of-apps here.

## Monitoring (both labs)

```
pilab ─ Prometheus agent (RAM-only WAL, 1Gi) ──HTTPS remote write──▶ prometheus.infra.lab.trentonvanderwert.com/api/v1/write
infralab ─ Prometheus (30d, 40GB, local-path) ◀─┘          ▲ UI/API only via Teleport (prometheus-infralab)
           Grafana ◀── grafana.infra.lab… (TV, anonymous)  /  grafana.teleport.aws… (JWT)
```

- `argo-apps/monitoring/` (kube-prometheus-stack); pilab runs the same chart in
  agent mode (`pilab/argo-apps/monitoring-agent/`). Keep the chart versions in
  step.
- Every series carries `cluster` (scrape-time); node-exporter series carry
  `node`. Bundled dashboards get a cluster picker. Dashboards are code:
  `manifests/dashboards/*.json` + `manifests/kustomization.yaml`; the home
  dashboard is `lab-overview.json`.
- **Cardinality:** k3s exposes the embedded apiserver/etcd/scheduler metrics
  on the kubelet endpoint too, so both clusters drop those families from the
  kubelet job and unused apiserver histograms (~246k -> ~79k series). The agent
  WAL always holds ~2h plus whatever is unsent; if it fills, scrapes fail until
  the agent pod restarts.
- The remote-write route is `POST /api/v1/write` only, unauthenticated, on the
  LAN. Prometheus drops batches on 4xx, so when moving that URL, add the new
  route first, switch the agent, then remove the old one.

## Upgrades

| Component | How |
|---|---|
| k3s | Bump `version` in `argo-apps/system-upgrade-controller/k3s-plans.yaml` **and** `k3s_version` in `versions.yml` (also pilab's), GA only, one minor at a time |
| Cilium, kube-vip, Gateway API CRDs, Argo CD chart | `versions.yml`, then `cluster.yml --tags <role>`. Gateway API CRDs must match what Cilium supports. |
| Teleport | Cluster (EKS) first. Then `teleport-resources/autoupdate.yaml`, the chart versions of `teleport-operator`, `teleport-kube-agent`, `tbot`, `tbot-argocd`, pilab's `teleport_kube_agent_chart_version`, and (for fresh installs) the bootstrap version + SHA-256 in `user-data` and pilab's `node_prep`. Agents never newer than the cluster. |
| SSH agents | Managed Updates: group `infralab`, then `pilab` 24h later, Mon-Thu 16:00 UTC. For an urgent fix: `tctl autoupdate agents start-update infralab`, then `pilab` (`lab-admin` may). |
| cert-manager, kube-prometheus-stack | Chart `targetRevision` in their Applications (kube-prometheus-stack in both clusters) |

## Day 2

From `infralab/ansible/`:

| Task | Command |
|---|---|
| Patch OS packages one node at a time; reboot only if Ubuntu requires it, waiting for the node to be Ready (`--check` lists pending updates) | `ansible-playbook playbooks/ops/update-and-reboot.yml` |
| Rolling reboot | `ansible-playbook playbooks/ops/rolling-reboot.yml` |
| Tear down k3s (destructive) | `ansible-playbook playbooks/ops/reset.yml -e confirm_reset=yes` |
| Agent update status | `tctl autoupdate agents status` |
| Refresh the operator token after a rebuild | see [Bringing up the cluster](#bringing-up-the-cluster) |
