# teleport

Identity for both labs, from the self-hosted Teleport cluster
`teleport.trentonvanderwert.com` (proxy `teleport.aws.trentonvanderwert.com:443`,
Enterprise, v18), deployed from the separate `teleport-master` repo on EKS.
How the labs use it (apps, SSO, access) is in
[infralab/README.md](../infralab/README.md#teleport).

**The Teleport resources the labs depend on** (roles, join tokens, bots,
workload identities, SAML apps, Managed Updates) are in the `teleport-master`
repo, `teleport-resources/`: reconciled by the cluster's own operator, synced
by its Argo CD from its deployed branch (`internal_lab`). Its README lists
each resource and what to do when a lab cluster is rebuilt (new JWKS) or a
node's TPM changes. Users stay out of git.

This directory covers the labs' side: their agents and the Teleport versions
pinned here.

## Agents and versions

- SSH: infralab nodes install at first boot (`infralab/autoinstall`), Pis via
  `pilab/ansible` (`prep-nodes.yml --tags teleport`), `labns` by hand
  (`binddns/teleport/install.sh`), `hv1` at first boot (`hv1/first-boot.sh`).
- Kube agents: infralab's from Argo CD (`teleport-kube-agent` app), pilab's
  from its Ansible bootstrap (Argo CD connects through it).
- A Teleport upgrade (the cluster in `teleport-master` first, then its
  `teleport-resources/autoupdate.yaml`; agents never newer) touches here: the
  `teleport-kube-agent` and `tbot-argocd` chart versions; the tbot sidecar
  images in `infralab/argo-apps/cert-manager/values.yaml` and
  `infralab/argo-apps/monitoring/values.yaml`; pilab's
  `teleport_kube_agent_chart_version`; and, for fresh installs, the bootstrap
  version + SHA-256 in `infralab/autoinstall/user-data`, pilab's `node_prep`
  defaults and `binddns/teleport/install.sh`. (`hv1/first-boot.sh` pins
  nothing: it uses the install script the proxy serves, which installs the
  cluster's version.)
  Bump them all in one commit; `scripts/check-teleport-versions.sh --checksums`
  (also run in CI) fetches the target from `teleport-master` and fails if any
  differs, or if a SHA-256 doesn't match Teleport's CDN.
