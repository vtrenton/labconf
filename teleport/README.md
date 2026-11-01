# teleport

Identity for both labs, from the self-hosted Teleport cluster
`teleport.trentonvanderwert.com` (proxy `teleport.aws.trentonvanderwert.com:443`,
Enterprise, v18; deployed from the separate `teleport-master` repo on EKS).
How the labs use it (apps, SSO, access) is in
[infralab/README.md](../infralab/README.md#teleport); this directory is only
the operator's bootstrap.

## Who manages what

| Where | What | Applied by |
|---|---|---|
| `bootstrap/` | The Teleport Kubernetes Operator's own role, bot and join token: everything it needs before it can manage anything | You, with `tctl` (your user + MFA) |
| `infralab/argo-apps/teleport-resources/` | Everything else (table below) | The operator in infralab, synced by Argo CD |
| Not in git | Users, including your local admin (break-glass) | Never managed by the operator |

Nothing here is a secret: every join is delegated (Kubernetes JWKS for
in-cluster agents, TPM for nodes), so token contents (public signing keys, TPM
EK hashes) are safe in a public repo.

## Bootstrap (once, and after rebuilds)

```
tsh login --proxy=teleport.aws.trentonvanderwert.com:443

tctl create teleport/bootstrap/operator-role.yaml
tctl create teleport/bootstrap/operator-bot.yaml

./teleport/bootstrap/render-operator-token.sh > /tmp/operator-token.yaml
tctl create /tmp/operator-token.yaml
```

Argo CD then deploys the operator (`infralab/argo-apps/teleport-operator`),
which joins as bot `labconf-operator` from service account
`teleport-iac:teleport-operator`.

- `tctl create -f` means `--force` (overwrite), not "file": use it to update
  roles and tokens. Bots are created once; `tctl create` on an existing bot
  fails with `unable to determine existing generation for bot due to missing
  label` (the bot is already there; change it with `tctl bots update`).
- Everything here is named `labconf-*`. The `teleport-cluster` deployment in
  AWS runs its own operator as bot/role `operator`; never reuse those names.
- The operator role allows only: `role`, `token`, `bot`, `workload_identity`,
  `saml_idp_service_provider`, `autoupdate_config`, `autoupdate_version`. Add
  a kind there (and re-apply) before adding its CRs.

| Event | Do |
|---|---|
| **infralab rebuilt** | Re-render and overwrite the operator token (`render-operator-token.sh`, then `tctl create -f`); until then the operator can't join, and what it manages stays as it is. Then refresh the JWKS in the git-managed tokens (see the infralab README's rebuild steps). |
| **Role edited** | `tctl create -f teleport/bootstrap/operator-role.yaml` |
| **Bot edited** | `tctl bots update labconf-operator --set-roles labconf-operator` |

## What the operator manages (`infralab/argo-apps/teleport-resources/`)

| File | Resources |
|---|---|
| `tokens-nodes.yaml` | `infralab-nodes`, `pilab-nodes`: TPM joins, one rule per node EK |
| `tokens-kube-agents.yaml` | `infralab-kube-agent` (`Kube, App, Discovery`), `pilab-kube-agent` (`Kube, App`): Kubernetes JWKS |
| `roles.yaml` | `lab-admin`: SSH (`sysadmin`/`admin`), `system:masters` and the apps on `infralab`/`pilab`, driving agent update rollouts |
| `argocd-access.yaml` | Bot `labconf-argocd` + role `labconf-argocd-deployer` (`system:masters` on `lab: pilab`) + its token: Argo CD reaching pilab |
| `argocd-sso.yaml` | SAML service provider `argocd` (Teleport as Argo CD's IdP) |
| `cert-manager-identity.yaml` | Workload identity `infralab-cert-manager` + issuer role + bot `labconf-cert-manager` + token: keyless Route 53 |
| `autoupdate.yaml` | Managed Updates: groups `infralab`, then `pilab` 24 h later; target version |

Users stay out of git. Grant the lab role with
`tctl users update <user> --set-roles editor,access,lab-admin`.

## Agents and versions

- SSH: infralab nodes install at first boot (`infralab/autoinstall`), Pis via
  `pilab/ansible` (`prep-nodes.yml --tags teleport`).
- Kube agents: infralab's from Argo CD (`teleport-kube-agent` app), pilab's
  from its Ansible bootstrap (Argo CD connects through it).
- A Teleport upgrade (cluster first; agents never newer) touches
  `autoupdate.yaml`; the `teleport-operator`, `teleport-kube-agent`, `tbot`
  and `tbot-argocd` chart versions; pilab's `teleport_kube_agent_chart_version`;
  and, for fresh installs, the bootstrap version + SHA-256 in
  `infralab/autoinstall/user-data` and pilab's `node_prep` defaults.

## Risk

The operator can write Teleport roles, which means it can grant any access.
Anyone who can merge to `master` of this repo, or who controls infralab, can
therefore become Teleport admin. Mitigations: the `protect-master` ruleset
(signed commits only, no force-push or deletion), pre-commit/CI secret
scanning, the operator role limited to the kinds above, and a break-glass
admin that lives outside git.
