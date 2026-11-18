# binddns

DNS for every network in the house, on two Raspberry Pi 4s in the DNS
network (VLAN 853), both in every network's DHCP DNS:

| Host | Address | Switch port | OS | BIND | Teleport |
|---|---|---|---|---|---|
| **dns1** (`labns` in DNS and Teleport until the `dc` rename) | `10.0.53.11` | home-access 48 | Ubuntu Server, root only | primary: the zone files live here | agent (TPM) |
| **dns2** | `10.0.53.12` | lab-access 48 | Raspberry Pi OS, `admin` + sudo | secondary of dns1, transfers every zone | none (no TPM): break-glass SSH only |

Unbound is identical on both. The network side (VLANs, DHCP, firewall,
reservations) is in the `udm-pro-config` repo; this directory is the hosts.

Two containers, both `--network host`, config mounted from the host's
`/bind/`:

```
clients (every network) :53 ─▶ Unbound ─┬─ local zones ──▶ BIND 127.0.0.1:5300 (authoritative only)
                                        └─ everything else ─▶ Quad9 over DNS-over-TLS (853)
```

| Container | Start | Config | Job |
|---|---|---|---|
| `unbound` | `unboundcmd` | `unbound/unbound.conf` → `/bind/unbound/` | The resolver: access per network, the IoT allowlist view, ad blocking (RPZ) for home/wireless/guest, DNSSEC validation, DoT upstream, stub zones to BIND |
| `bind9` | `bindcmd` | dns1: `config/named.conf` → `/bind/config/`, `zones/` → `/bind/zones/`. dns2: `config/named.dns2.conf` → `/bind/config/named.conf`, no zone files (transferred into `/bind/cache/`) | Authoritative for the local zones only: no recursion, port 5300 (not 5353: that's mDNS). Localhost for Unbound; dns1 also on `10.0.53.11` for dns2 only (SOA, transfers), dns2 also on `10.0.53.12` for dns1's NOTIFYs |

Host networking matters: with port publishing (`-p 53:53`) Unbound would see
the container gateway instead of the client, and the per-network rules below
wouldn't work.

## Zones (BIND)

| Zone | File | Holds |
|---|---|---|
| `labnet.lan` | `zones/db.labnet.lan` | Machines on labnet (VLAN 800): gateway, `labns`/`dns1`, every node, cluster VIPs, the infralab Gateway/Ingress IPs. No app uses a `.lan` name. |
| `wired.lan` | `zones/db.wired.lan` | The wired LAN (home): `gateway`, plus any home machine that needs a name. |
| `0.0.10.in-addr.arpa` | `zones/10.0.0.rev` | labnet PTRs. **infralab nodes take their hostname from these** (`hostname-from-dns`), so a node's PTR must exist before it boots. |
| `53.0.10.in-addr.arpa` | `zones/10.0.53.rev` | DNS network PTRs (dns1). |
| `lab.trentonvanderwert.com` | `zones/db.lab.trentonvanderwert.com` | **LAN-only** service names with real certificates: `*.infra` -> Gateway `.165`, `ingress.infra` -> `.166`. Public DNS for this name is a Route 53 zone that is empty (NS/SOA only) except for a minute or two during certificate issuance, when cert-manager adds and then removes an `_acme-challenge` TXT record; these names don't resolve off the LAN. |

Unbound sends exactly these zones to BIND (`stub-zone`), marks them unsigned
(`domain-insecure`) and allows their private answers (`private-domain`).
Everything else goes to Quad9 (`9.9.9.9`, `149.112.112.112`, filtered,
DNSSEC) over TLS; the ISP interferes with `1.1.1.1`/`8.8.8.8`.

A new zone needs three things: the zone file, a `zone` block in
`named.conf`, and a `stub-zone` (plus `domain-insecure`, and `private-domain`
if it answers private addresses) in `unbound.conf`.

## Who may ask what (Unbound)

`access-control` in `unbound.conf` lists every network: home, wireless,
guest, Default (management), labnet, camera, dns. Anything else is refused.
The UDM firewall separately allows every network to reach this host on 53
only (and break-glass SSH from Wired), and only the DNS network may send DNS
or DoT to the internet.

**IoT (`10.0.2.0/24`) only gets the allowlist** (`unbound/iot-allowlist.conf`,
the `iot` view): every other name, local ones included, is `REFUSED` and
logged. One `local-zone: "<name>." transparent` line per allowed name, each
with a comment saying which device needs it and why. Refusals in the log:

```
podman logs unbound 2>&1 | grep ' refuse 10.0.2.23@' \
  | awk '{print $(NF-2), $(NF-1)}' | sort | uniq -c | sort -rn
```

(`... info: . refuse 10.0.2.23@51234 api.vendor.example. A IN`: name and type
are the 3rd and 2nd fields from the end.) The full workflow, together with
the firewall side, is the IoT runbook in `udm-pro-config` (IMPLEMENTATION.md).

## Ad blocking (Unbound RPZ)

For **home, wireless and guest** only (`access-control-tag … "adblock"`); labnet,
camera, dns, management and IoT are unfiltered (IoT has its allowlist
instead).

- **List:** HaGeZi Multi NORMAL in RPZ format (ads, trackers, telemetry,
  phishing, malware; ~400k entries; "mostly won't cause restrictions").
  Unbound downloads it itself over HTTPS, refreshes it per the list's SOA
  (8h), and keeps the last copy in `/var/lib/unbound/adblock.rpz`, so a
  restart without internet still blocks. Unbound uses ~270 MB with it loaded.
- **Exceptions:** `unbound/adblock-allow.rpz`, checked before the list. One
  `name CNAME rpz-passthru.` line per name (plus `*.name` for subdomains),
  with a comment saying why.
- **What was blocked, by which rule:**

  ```
  podman logs --since 1h unbound 2>&1 | grep 'rpz: applied \[adblock\]' \
    | awk '{print $(NF-2)}' | sort | uniq -c | sort -rn | head
  ```

Blocked names answer `NXDOMAIN`. To switch a network on or off, edit its
`access-control-tag` line.

**Firefox DoH canary:** `use-application-dns.net` answers `NXDOMAIN` for
every client (`local-zone … always_nxdomain`), which tells Firefox not to
switch to DNS-over-HTTPS by itself and bypass this resolver.

## Ansible (`ansible/`)

Both hosts are managed from `binddns/ansible/`, separate from the clusters'
Ansible. It connects over plain SSH from home (dns1 as `root`, dns2 as
`admin` with sudo, both your `id_rsa`), never through Teleport, so it works
when DNS is down. Load the key first (`ansible-configure.sh`).

```
cd binddns/ansible
ansible-playbook playbooks/site.yml --check --diff   # what would change
ansible-playbook playbooks/site.yml                  # apply (both hosts)
ansible-playbook playbooks/site.yml -l dns2          # one host
ansible-playbook playbooks/ops/update-and-reboot.yml # patch (only path for upgrades)
```

- **`site.yml`**: the whole host from this directory: packages, `resolv.conf`
  (below), `podman-restart`, `/bind`, the config files (zones on dns1 only),
  and the containers (created from `bindcmd`/`unboundcmd` when missing or
  when the script changed). It checks the config with `named-checkconf -z`
  and `unbound-checkconf` before anything reloads, then reloads only what
  changed (`rndc reconfig`/`reload`, or an Unbound restart). One host at a
  time, dns2 first, each must answer before the next; at the end, dns2 must
  serve dns1's serial for every zone.
- **`ops/update-and-reboot.yml`**: `apt full-upgrade`, reboot only for a
  newer kernel (of the running flavour), one host at a time and only while
  the other one answers. Unattended upgrades are off.
- Not in Ansible: the OS install, the account and key (below), dns1's
  Teleport agent (`teleport/install.sh`).

Host settings live in `inventory/host_vars/` (which `named.conf`, primary or
secondary); the zone list in `inventory/group_vars/all/dns.yml` must match
`named.conf`, `named.dns2.conf` and the stub-zones in `unbound.conf`.

## Changing a zone or the allowlist

Zones change on **dns1 only**: dns1 sends dns2 a NOTIFY on every serial bump
and dns2 transfers the zone within seconds. Unbound files
(`unbound.conf`, the allowlist, the adblock exceptions) go to **both** hosts;
`site.yml` does both.

1. Edit the zone and **bump its serial** (`YYYYMMDDNN`; must increase: the
   playbook stops if a changed zone's serial isn't above the served one), or
   edit `unbound/iot-allowlist.conf` / `unbound/adblock-allow.rpz`.
2. Optionally check it off-host first (`nix shell nixpkgs#bind`):

   ```
   named-checkzone labnet.lan zones/db.labnet.lan
   ```

3. Commit, then `ansible-playbook playbooks/site.yml --diff`.
4. dns2 behind anyway? `sudo podman logs bind9 | grep -i transfer` on dns2,
   or force it: `sudo podman exec bind9 rndc retransfer labnet.lan`.

## Install on a fresh Pi

Until dns1 answers, no network has DNS except the bypasses home and wireless
keep (UDM resolver, public DNS). dns2 needs dns1 up: it transfers its zones
from it.

1. **OS**, by hand:
   - **dns1:** Ubuntu Server (arm64), DHCP on `eth0` (reservation
     `10.0.53.11`, home-access port 48), root login by SSH key only; root is
     the only account.
   - **dns2:** Raspberry Pi OS (64-bit), DHCP on `eth0` (reservation
     `10.0.53.12`, lab-access port 48), user `admin` with your key and
     passwordless sudo. The rule goes in `/etc/sudoers.d/`, not
     `/etc/sudoers`: sudo applies the last match, and `%sudo ... ALL` comes
     after anything added above it.

     ```
     echo 'admin ALL=(ALL) NOPASSWD: ALL' | sudo tee /etc/sudoers.d/010_admin-nopasswd
     sudo chmod 440 /etc/sudoers.d/010_admin-nopasswd
     ```

2. **Everything else:** `ansible-playbook playbooks/site.yml -l <host>`.
3. **dns1's Teleport agent:** see Teleport (SSH) below.
4. **Check** from a home machine (`site.yml` checks the first three):

   ```
   dig @10.0.53.11 gateway.wired.lan
   dig @10.0.53.11 kubemaster1.labnet.lan
   dig @10.0.53.11 x.infra.lab.trentonvanderwert.com
   dig @10.0.53.11 -x 10.0.0.161
   dig @10.0.53.11 example.com
   dig @10.0.53.11 dnssec-failed.org             # SERVFAIL: validation works
   dig @10.0.53.11 smetrics.abbott               # NXDOMAIN from home (ad blocking);
                                                 # resolves from labnet (not filtered)
   ```

   The same against `10.0.53.12`. Reboot once and check again: both
   containers must come back on their own.

What the playbook sets up, and why:

- **`resolv.conf`** is hand-written: `127.0.0.1`, then `9.9.9.9`. Unbound
  needs `:53` (dns1: systemd-resolved off; dns2: NetworkManager `dns=none`),
  and the host (and dns1's Teleport agent) keeps resolving when Unbound is
  down; see Teleport below.
- **`/bind/cache`** (BIND: managed keys; dns2's transferred zones) and
  **`/var/lib/unbound`** (the cached blocklist) belong to the images' users,
  uid 100, gid 101.
- The Unbound image's entrypoint does the rest at every start:
  `unbound-anchor` on `/etc/unbound/root.key` (DNSSEC trust anchor), the
  `unbound-control` keys, and `chown -R unbound /etc/unbound`. The generated
  `*.key`/`*.pem` stay on the host, never in git.
- Containers start from `/` (`chdir`): conmon fails if the working directory
  is gone.

## Teleport (SSH)

`labns` (dns1) runs a Teleport SSH agent (`teleport/`), installed by its own
script, not by Ansible; dns2 has no TPM and no agent. It joins with the Pi's TPM 2.0 (token
`labns-node`, one EK rule) and has label `lab: labns`. The only login is
`root` (role `labns-admin`, granted on its own so `lab-admin` never gets root
anywhere else). Managed Updates group `labns`, a day after `pilab`.

Install, or re-apply `teleport.yaml` after changing it (as root on `labns`):

```
scp -r binddns/teleport root@10.0.53.11:/root/
ssh root@10.0.53.11 sh /root/teleport/install.sh
```

The script prints `teleport tpm identify`. Put the EK hash and serial in the
`labns-node` token (`teleport-master/teleport-resources/tokens-nodes.yaml`)
and push; the agent retries until the operator has applied it. The EK is in
the chip, so a reflash rejoins without touching the token.

Then: `tsh ssh root@labns`.

**The agent doesn't depend on this host's DNS.** systemd-resolved is
disabled so Unbound can bind `:53`, and `/etc/resolv.conf` is hand-written:

```
nameserver 127.0.0.1
nameserver 9.9.9.9
```

With Unbound up, Quad9 is only reached over DoT. With Unbound down, queries to
`127.0.0.1` are refused and glibc moves on to Quad9 (plain 53, which the DNS
network may still use), so the agent still reaches
`teleport.aws.trentonvanderwert.com` and `tsh ssh root@labns` works to fix
DNS (the host itself just can't resolve `.lan` names meanwhile). Keep the
second line if this file is ever rewritten. OpenSSH by IP from the wired LAN
(`ssh root@10.0.53.11`, the only other way in: the network allows Wired → DNS
on 22 for exactly this) stays the break-glass path (`BREAK-GLASS.md`).

## Conventions

- A new labnet machine gets an `A` record in `labnet.lan` **and** a `PTR` in
  `10.0.0.rev` (plus a DHCP reservation in `udm-pro-config`).
- A new infralab service needs no DNS: `*.infra.lab.trentonvanderwert.com`
  already points at the Gateway, and the wildcard certificate covers it.
- An explicit name under a wildcard hides the wildcard for everything beneath
  it (e.g. adding `foo.infra` makes `*.infra` stop matching `x.foo.infra`).
- ExternalDNS (with the `dc` rename, not before): dns1's BIND already
  listens on `10.0.53.11:5300` (for dns2); add RFC2136 updates with a TSIG
  key, `allow-update` only on the zone ExternalDNS owns. dns2 gets the
  updates by NOTIFY. Unbound can't take updates, so they go to BIND
  directly; the UDM needs labnet → dns on 5300 (`udm-pro-config`).
