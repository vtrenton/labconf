# teleport

Identity for both labs, from the self-hosted Teleport cluster
`teleport.trentonvanderwert.com` (proxy `teleport.aws.trentonvanderwert.com:443`,
Enterprise, v18; deployed from the separate `teleport-master` repo on EKS).
How the labs use it (apps, SSO, access) is in
[infralab/README.md](../infralab/README.md#teleport); this directory holds the
Teleport resources as code.

## Who manages what

| Where | What | Applied by |
|---|---|---|
| `resources/` | Roles, join tokens, bots, workload identities, SAML apps, Managed Updates (table below) | The Teleport cluster's own operator (`teleport-cluster` chart, `operator.enabled`), synced by `teleport-master`'s Argo CD |
| Not in git | Users, including your local admin (break-glass) | Never managed by the operator |

`teleport-master`'s Argo CD syncs `teleport/resources/` from `master` into the
operator's namespace (`teleport-cluster`) as the Application
`labconf-teleport`. Its AppProject, also `labconf-teleport`, allows only these
kinds, in that namespace, nothing cluster-scoped: `TeleportRoleV8`,
`TeleportProvisionToken`, `TeleportBotV1`, `TeleportWorkloadIdentityV1`,
`TeleportSAMLIdPServiceProviderV1`, `TeleportAutoupdateConfigV1`,
`TeleportAutoupdateVersionV1`. A new kind needs adding there first
(`teleport-master`: `argo/addons/templates/labconf-teleport.yaml`).

- Pruning is on: deleting a file here deletes the resource in Teleport.
- The operator only manages what it created (`teleport.dev/origin: kubernetes`),
  so resources made with `tctl` are left alone.
- Nothing here is a secret: every join is delegated (Kubernetes JWKS for
  in-cluster agents, TPM for nodes), so token contents (public signing keys,
  TPM EK hashes) are safe in a public repo.

| Event | Do |
|---|---|
| **infralab or pilab rebuilt** | Refresh that cluster's JWKS in the git-managed tokens (see the infralab README's rebuild steps). |
| **Teleport's EKS cluster rebuilt** | Nothing: the new operator takes over every resource labelled `teleport.dev/origin: kubernetes`. |

## What the operator manages (`resources/`)

| File | Resources |
|---|---|
| `tokens-nodes.yaml` | `infralab-nodes`, `pilab-nodes`, `labns-node`: TPM joins, one rule per node EK |
| `tokens-kube-agents.yaml` | `infralab-kube-agent` (`Kube, App, Discovery`), `pilab-kube-agent` (`Kube, App`): Kubernetes JWKS |
| `roles.yaml` | `lab-admin`: SSH (`sysadmin`/`admin`), `system:masters` and the apps on `infralab`/`pilab`, driving agent update rollouts. `labns-admin`: SSH as `root` on `labns` only |
| `argocd-access.yaml` | Bot `labconf-argocd` + role `labconf-argocd-deployer` (`system:masters` on `lab: pilab`) + its token: Argo CD reaching pilab |
| `argocd-sso.yaml` | SAML service provider `argocd` (Teleport as Argo CD's IdP) |
| `cert-manager-identity.yaml` | Workload identity `infralab-cert-manager` + issuer role + bot `labconf-cert-manager` + token: keyless Route 53 |
| `alertmanager-identity.yaml` | Workload identity `infralab-alertmanager` + issuer role + bot `labconf-alertmanager` + token: keyless SNS |
| `autoupdate.yaml` | Managed Updates: groups `infralab`, then `pilab` 24 h later, then `labns` 24 h after that; target version |

Users stay out of git. Grant the lab role with
`tctl users update <user> --set-roles editor,access,lab-admin,labns-admin`.

## Agents and versions

- SSH: infralab nodes install at first boot (`infralab/autoinstall`), Pis via
  `pilab/ansible` (`prep-nodes.yml --tags teleport`), `labns` by hand
  (`binddns/teleport/install.sh`).
- Kube agents: infralab's from Argo CD (`teleport-kube-agent` app), pilab's
  from its Ansible bootstrap (Argo CD connects through it).
- A Teleport upgrade (the cluster in `teleport-master` first; agents never
  newer) touches `resources/autoupdate.yaml`; the `teleport-kube-agent` and
  `tbot-argocd` chart versions; the tbot sidecar images in
  `infralab/argo-apps/cert-manager/values.yaml` and
  `infralab/argo-apps/monitoring/values.yaml`; pilab's
  `teleport_kube_agent_chart_version`; and, for fresh installs, the bootstrap
  version + SHA-256 in `infralab/autoinstall/user-data`, pilab's `node_prep`
  defaults and `binddns/teleport/install.sh`.
  Bump them all in one commit; `scripts/check-teleport-versions.sh --checksums`
  (also run in CI) fails if any differs from `autoupdate.yaml` or a SHA-256
  doesn't match Teleport's CDN.

## Risk

The operator can write Teleport roles, which means it can grant any access.
Anyone who can merge to `master` of this repo, or who controls Teleport's EKS
cluster (and with it its Argo CD), can therefore become Teleport admin.
Controlling infralab or pilab doesn't. Mitigations: the `protect-master`
ruleset (signed commits only, no force-push or deletion), pre-commit/CI secret
scanning, the `labconf-teleport` AppProject limited to the kinds above, and a
break-glass admin that lives outside git.
