# binddns

DNS for every network in the house, on **dns1** (`10.0.53.11`, the DNS
network, VLAN 853, USW port 48), a Raspberry Pi 4 named `labns` in DNS and
Teleport (until the `dc` rename). The network side (VLANs, DHCP, firewall,
its reservation) is in the `udm-pro-config` repo; this directory is the host.

Two containers, both `--network host`, config mounted from the host's
`/bind/`:

```
clients (every network) :53 ─▶ Unbound ─┬─ local zones ──▶ BIND 127.0.0.1:5300 (authoritative only)
                                        └─ everything else ─▶ Quad9 over DNS-over-TLS (853)
```

| Container | Start | Config | Job |
|---|---|---|---|
| `unbound` | `unboundcmd` | `unbound/unbound.conf` → `/bind/unbound/` | The resolver: access per network, the IoT allowlist view, ad blocking (RPZ) for home/wireless/guest, DNSSEC validation, DoT upstream, stub zones to BIND |
| `bind9` | `bindcmd` | `config/named.conf` → `/bind/config/`, `zones/` → `/bind/zones/` | Authoritative for the local zones only: no recursion, localhost only (port 5300, not 5353: that's mDNS) |

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

## Changing a zone or the allowlist

1. Edit the zone and **bump its serial** (`YYYYMMDDNN`; must increase), or
   edit `unbound/iot-allowlist.conf` / `unbound/adblock-allow.rpz`.
2. Check it (off-host via `nix shell nixpkgs#bind nixpkgs#unbound`, or on the
   host):

   ```
   named-checkzone labnet.lan zones/db.labnet.lan
   named-checkzone wired.lan zones/db.wired.lan
   named-checkzone lab.trentonvanderwert.com zones/db.lab.trentonvanderwert.com
   named-checkzone 0.0.10.in-addr.arpa zones/10.0.0.rev
   named-checkzone 53.0.10.in-addr.arpa zones/10.0.53.rev
   ```

   `named-checkconf` / `unbound-checkconf` fail off-host on missing
   directories (`/var/cache/bind`, `/etc/unbound`, the anchor); check a copy
   with those paths pointed at a temp dir, or on dns1 with the image:
   `podman run --rm -v /bind/unbound:/etc/unbound --entrypoint unbound-checkconf docker.io/alpinelinux/unbound:latest-aarch64`.
3. Commit, copy the changed file(s) to the host's `/bind/zones/`,
   `/bind/config/` or `/bind/unbound/`, and apply:

   ```
   podman exec bind9 rndc reload        # zones / named.conf
   podman restart unbound               # unbound.conf / iot-allowlist.conf / adblock-allow.rpz
   ```

4. Confirm the served serial matches the repo:

   ```
   dig +short SOA labnet.lan @10.0.53.11
   ```

## Install on a fresh Pi

The Pi gets `10.0.53.11` from its DHCP reservation (udm-pro-config) on USW
port 48. Until this is done no network has DNS except the bypasses home and
wireless keep (UDM resolver, public DNS).

1. **OS:** Ubuntu Server (arm64), DHCP on `eth0`, root login by SSH key only
   (root is the only account). Then, as root:

   ```
   apt install podman
   systemctl enable podman-restart.service           # starts --restart=always containers at boot
   systemctl disable --now systemd-resolved          # frees :53 for Unbound
   rm /etc/resolv.conf
   printf 'nameserver 127.0.0.1\nnameserver 9.9.9.9\n' > /etc/resolv.conf
   mkdir -p /bind/cache /var/lib/unbound && chown 100:101 /var/lib/unbound
   ```

   `/var/lib/unbound` holds the cached blocklist and belongs to the image's
   `unbound` user (uid 100, gid 101). The `resolv.conf` keeps the host (and
   its Teleport agent) resolving when Unbound is down; see Teleport below.

2. **Config** (from a checkout of this repo):

   ```
   scp -r binddns/config binddns/zones binddns/unbound binddns/bindcmd binddns/unboundcmd root@10.0.53.11:/bind/
   ```

3. **Start** (both `--restart=always`):

   ```
   sh /bind/bindcmd
   sh /bind/unboundcmd
   podman logs unbound      # no errors; "start of service"
   ```

   The Unbound image's entrypoint does the rest at every start:
   `unbound-anchor` on `/etc/unbound/root.key` (DNSSEC trust anchor), the
   `unbound-control` keys, and `chown -R unbound /etc/unbound` (so
   `/bind/unbound` ends up owned by uid 100; the generated `*.key`/`*.pem`
   stay on the host, never in git). After changing `bindcmd`/`unboundcmd`,
   recreate: `podman rm -f bind9 unbound`, then step 3.

4. **Teleport agent:** see Teleport (SSH) below.

5. **Check** on the host, then from a home machine:

   ```
   dig +short SOA labnet.lan @127.0.0.1 -p 5300   # BIND directly
   dig @10.0.53.11 gateway.wired.lan
   dig @10.0.53.11 kubemaster1.labnet.lan
   dig @10.0.53.11 x.infra.lab.trentonvanderwert.com
   dig @10.0.53.11 -x 10.0.0.161
   dig @10.0.53.11 example.com
   dig @10.0.53.11 dnssec-failed.org             # SERVFAIL: validation works
   dig @10.0.53.11 metrics.abbott                # NXDOMAIN from home (ad blocking);
                                                 # resolves from labnet (not filtered)
   ```

   Reboot once and check again: both containers must come back on their own.

## Teleport (SSH)

`labns` runs a Teleport SSH agent (`teleport/`), managed by hand like the rest
of this host, not by Ansible. It joins with the Pi's TPM 2.0 (token
`labns-node`, one EK rule) and has label `lab: labns`. The only login is
`root` (role `labns-admin`, granted on its own so `lab-admin` never gets root
anywhere else). Managed Updates group `labns`, a day after `pilab`.

Install, or re-apply `teleport.yaml` after changing it (as root on `labns`):

```
scp -r binddns/teleport root@10.0.53.11:/root/
ssh root@10.0.53.11 sh /root/teleport/install.sh
```

The script prints `teleport tpm identify`. Put the EK hash and serial in the
`labns-node` token (`infralab/argo-apps/teleport-resources/tokens-nodes.yaml`)
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
- ExternalDNS (with the `dc` rename, not before): BIND also listens on
  `10.0.53.11:5300` for RFC2136 updates with a TSIG key, `allow-update` /
  `allow-transfer` only on the zone ExternalDNS owns. Unbound can't take
  updates, so they go to BIND directly; the UDM needs labnet → dns on 5300
  (`udm-pro-config`).
- A future dns2: its own `access-control`-identical Unbound, BIND as a
  secondary (`allow-transfer` / `also-notify` here), and `10.0.53.12` in the
  networks' DHCP DNS (`udm-pro-config`).
