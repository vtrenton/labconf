# teleport

Identity for both labs, from the self-hosted Teleport cluster
`teleport.trentonvanderwert.com` (proxy `teleport.aws.trentonvanderwert.com:443`,
Enterprise, v18).

## Who manages what

| Where | What | Applied by |
|---|---|---|
| `bootstrap/` | The Teleport Kubernetes Operator's own role, bot and join token: everything the operator needs before it can manage anything | You, with `tctl` (your user + MFA) |
| `infralab/argo-apps/teleport*` | Everything else: roles, kube-agent and node join tokens, bots, workload identities, managed updates | The operator in infralab, synced by Argo CD |
| Not in git | Your local admin user (break-glass) | Never managed by the operator |

Nothing here is a secret. The join tokens use delegated methods (Kubernetes
JWKS for in-cluster agents, TPM for nodes), so token names and their contents
(public signing keys, TPM EK hashes) are safe in a public repo.

## Bootstrap (once, and after rebuilds)

```
tsh login --proxy=teleport.aws.trentonvanderwert.com:443

tctl create teleport/bootstrap/operator-role.yaml
tctl create teleport/bootstrap/operator-bot.yaml

./teleport/bootstrap/render-operator-token.sh > /tmp/operator-token.yaml
tctl create /tmp/operator-token.yaml
```

`tctl create -f` means `--force` (overwrite), not "file". Use it only to
update roles and tokens. Bots are created once; `tctl create` (with or
without `-f`) on an existing bot fails with `unable to determine existing
generation for bot due to missing label`. That error means the bot is
already there: check with `tctl bots ls`, and change it with
`tctl bots update`.

Then Argo CD deploys the operator (`infralab/argo-apps/teleport-operator`),
which joins as the `operator` bot from service account
`teleport-iac:teleport-operator`.

| Event | Do |
|---|---|
| **infralab rebuilt** (new service-account signing keys) | Re-render the token and overwrite it: `./teleport/bootstrap/render-operator-token.sh > /tmp/operator-token.yaml && tctl create -f /tmp/operator-token.yaml`. Until then the operator can't join, and Teleport resources it manages stay as they are. |
| **Operator gains a resource kind we want** | Add it to `operator-role.yaml` and re-apply before adding the CRs. |
| **Role edited** | `tctl create -f teleport/bootstrap/operator-role.yaml` (overwrite). |
| **Bot edited** | `tctl bots update operator --set-roles operator` (forcing the bot resource can fail). |

## Risk

The operator can write Teleport roles, which means it can grant any access.
Anyone who can merge to `master` of this repo, or who controls infralab, can
therefore become Teleport admin. Mitigations: the `protect-master` ruleset
(signed commits only, no force-push or deletion), the pre-commit/CI secret
scanning, the operator role limited to the kinds above, and a break-glass
admin that lives outside git.
