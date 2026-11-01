# Break-glass

What to do when the normal path (Teleport, SSO, GitOps) isn't available.
Nothing here needs a secret from this repo; the credentials it relies on live
on your workstation or in your password manager.

## Paths that don't depend on Teleport

| Need | Use |
|---|---|
| `kubectl` to infralab | `KUBECONFIG=~/.kube/infralab-k3s.yaml` (straight to the VIP `10.0.0.160:6443`) |
| `kubectl` to pilab | `KUBECONFIG=~/.kube/pilab-k3s.yaml` (VIP `10.0.0.10:6443`) |
| SSH to infra nodes | `ssh -i ~/.ssh/github_rsa sysadmin@10.0.0.16{1,2,3}` (OpenSSH, passwordless sudo) |
| SSH to Pis | `ssh -i ~/.ssh/id_rsa admin@10.0.0.1{1..7}` |
| A lost kubeconfig | On any server: `sudo cat /etc/rancher/k3s/k3s.yaml`, then replace `127.0.0.1` with the VIP |
| Teleport itself | Your local Teleport admin user (outside git, never operator-managed) |

## Teleport is down

- **Running workloads are unaffected.**
- **Lost:** SSH, `kubectl` and app access through Teleport. Use the paths above.
  Grafana's LAN URL (the TV) keeps working.
- **Paused:** infralab's Argo CD can't reach pilab (syncs to pilab wait; infralab
  syncs continue).
- **Certificates:** tbot can't refresh cert-manager's AWS credentials, so a
  renewal would fail. The wildcard renews 30 days before expiry (currently due
  2026-12-30, expires 2027-01-29), so there is about a month of slack.
- **Operator:** Teleport resources stay as they are; changes in git apply once
  it's back.

## Argo CD SSO is broken

The admin account is disabled. With cluster access (kubeconfig above):

```sh
kubectl -n argocd patch cm argocd-cm --type merge -p '{"data":{"admin.enabled":"true"}}'
HASH=$(htpasswd -nbBC 10 "" 'NEW-PASSWORD' | tr -d ':\n' | sed 's/$2y/$2a/')   # or: argocd account bcrypt
kubectl -n argocd patch secret argocd-secret -p \
  "{\"stringData\":{\"admin.password\":\"$HASH\",\"admin.passwordMtime\":\"$(date -u +%FT%TZ)\"}}"
kubectl -n argocd port-forward svc/argocd-server 8080:80    # if Teleport is down too
```

Log in as `admin`. Afterwards set `admin.enabled` back to `"false"` (or re-stage:
`infralab/ansible` `cluster.yml --tags argocd`, which also resets it).
Debug SSO with `kubectl -n argocd logs deploy/argocd-dex-server`.

## A node asks for a disk passphrase (infralab)

The TPM didn't release the key: Secure Boot changed, a firmware/`dbx` update,
or a motherboard swap. At the console, type the node's **LUKS recovery key**
(password manager), then re-enroll once booted:

```sh
sudo systemd-cryptenroll --wipe-slot=tpm2 --tpm2-device=auto --tpm2-pcrs=7 /dev/nvme0n1p3
```

## A node won't start k3s or Teleport (infralab)

Both require `hostname-from-dns`, which needs `labns` and the node's PTR
record. Check `systemctl status hostname-from-dns`. Fix DNS rather than
bypassing it: on the `labns` host, `podman start bind9` (or `podman ps -a` /
`podman logs bind9`); see `binddns/README.md`.

## A cluster was rebuilt

Its service-account signing keys are new, so every Kubernetes-JWKS join is
refused until refreshed.

- **infralab:**
  1. Operator token first (bootstrap):
     `./teleport/bootstrap/render-operator-token.sh > /tmp/t.yaml && tctl create -f /tmp/t.yaml`
  2. Then in git, from `kubectl get --raw /openid/v1/jwks`:
     `tokens-kube-agents.yaml` (`infralab-kube-agent`),
     `cert-manager-identity.yaml`, `argocd-access.yaml`
     (all in `infralab/argo-apps/teleport-resources/`). Push.
- **pilab:** update `pilab-kube-agent` in `tokens-kube-agents.yaml`. Push.
  Argo CD reconnects once the agent joins.

TPM node tokens don't change on a rebuild (the EK is in the chip).

## A Teleport agent update went wrong

```sh
tctl autoupdate agents status
tctl autoupdate agents rollback infralab      # or pilab
```

The kube agents aren't updated this way; revert their chart version in git
(infralab) or `versions.yml` + `--tags teleport_kube_agent` (pilab).

## The AWS budget alert fired

Only the Route 53 zone (~$0.50/month) is expected. Check Cost Explorer for the
service; the most likely accident would be an AWS Private CA ($400/month),
which nothing here should ever use. Account `321051512565`.
