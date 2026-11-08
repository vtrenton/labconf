# binddns

BIND for the lab's LAN resolver, `labns` (`10.0.0.5`), shared by every cluster.
It runs in a podman container (`bindcmd`) with the config and zones mounted
from the host's `/bind/`.

## Zones

| Zone | File | Holds |
|---|---|---|
| `labnet.lan` | `zones/db.labnet.lan` | Machines only: gateway, `labns`, every node, cluster VIPs, the infralab Gateway/Ingress IPs. No app uses a `.lan` name. |
| `0.0.10.in-addr.arpa` | `zones/10.0.0.rev` | PTR records. **infralab nodes take their hostname from these** (`hostname-from-dns`), so a node's PTR must exist before it boots. |
| `lab.trentonvanderwert.com` | `zones/db.lab.trentonvanderwert.com` | **LAN-only** service names with real certificates: `*.infra` -> Gateway `.165`, `ingress.infra` -> `.166`. Public DNS for this name is a Route 53 zone that is empty (NS/SOA only) except for a minute or two during certificate issuance, when cert-manager adds and then removes an `_acme-challenge` TXT record; these names don't resolve off the LAN. |

Everything else is forwarded to Quad9 (`9.9.9.9`, `149.112.112.112`); the ISP
interferes with `1.1.1.1`/`8.8.8.8`. Only clients in the `trusted` ACL
(`10.0.0.0/24`, `192.168.0.0/24`, localhost, the podman bridge) may query.
`named.conf` serves only the `lab.` subdomain of `trentonvanderwert.com`, so
the rest of the domain (e.g. `teleport.aws.`) still resolves publicly.

## Changing a zone

1. Edit the zone and **bump its serial** (`YYYYMMDDNN`; must increase).
2. Check it:

   ```
   named-checkzone labnet.lan zones/db.labnet.lan
   named-checkzone lab.trentonvanderwert.com zones/db.lab.trentonvanderwert.com
   named-checkzone 0.0.10.in-addr.arpa zones/10.0.0.rev
   ```

   (`named-checkconf config/named.conf` fails off-host on the missing
   `/var/cache/bind`; check a copy with `directory` pointed at a temp dir.)
3. Commit, then copy the file(s) to the host's `/bind/zones/` (and
   `config/named.conf` to `/bind/config/`) and reload:

   ```
   podman exec bind9 rndc reload
   ```

4. Confirm the served serial matches the repo:

   ```
   dig +short SOA labnet.lan @10.0.0.5
   ```

## Teleport (SSH)

`labns` runs a Teleport SSH agent (`teleport/`), managed by hand like the rest
of this host, not by Ansible. It joins with the Pi's TPM 2.0 (token
`labns-node`, one EK rule) and has label `lab: labns`. The only login is
`root` (role `labns-admin`, granted on its own so `lab-admin` never gets root
anywhere else). Managed Updates group `labns`, a day after `pilab`.

Install, or re-apply `teleport.yaml` after changing it (as root on `labns`):

```
scp -r binddns/teleport root@10.0.0.5:/root/
ssh root@10.0.0.5 sh /root/teleport/install.sh
```

The script prints `teleport tpm identify`. Put the EK hash and serial in the
`labns-node` token (`infralab/argo-apps/teleport-resources/tokens-nodes.yaml`)
and push; the agent retries until the operator has applied it. The EK is in
the chip, so a reflash rejoins without touching the token.

Then: `tsh ssh root@labns`.

**The agent doesn't depend on this host's BIND.** systemd-resolved is
disabled so `bind9` can bind `:53`, and `/etc/resolv.conf` is hand-written:

```
nameserver 127.0.0.1
nameserver 9.9.9.9
```

With BIND up, Quad9 is never used. With BIND down, queries to `127.0.0.1` are
refused and glibc moves on to Quad9, so the agent still reaches
`teleport.aws.trentonvanderwert.com` and `tsh ssh root@labns` works to fix
BIND (the host itself just can't resolve `.lan` names meanwhile). Keep the
second line if this file is ever rewritten. OpenSSH by IP stays the
break-glass path (`BREAK-GLASS.md`).

## Conventions

- A new machine gets an `A` record in `labnet.lan` **and** a `PTR` in
  `10.0.0.rev` (plus a DHCP reservation).
- A new infralab service needs no DNS: `*.infra.lab.trentonvanderwert.com`
  already points at the Gateway, and the wildcard certificate covers it.
- An explicit name under a wildcard hides the wildcard for everything beneath
  it (e.g. adding `foo.infra` makes `*.infra` stop matching `x.foo.infra`).
