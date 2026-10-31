$TTL 3600       ; Default TTL
; LAN-only answers for lab.trentonvanderwert.com. Public DNS for this name is
; a Route 53 zone that only ever holds cert-manager's _acme-challenge TXT
; records; cert-manager checks those against public resolvers, never here.
@       IN      SOA     labns.labnet.lan. admin.labnet.lan. (
                        2026103101  ; Serial
                        3600        ; Refresh
                        1800        ; Retry
                        604800      ; Expire
                        3600 )      ; Minimum TTL

@               IN      NS      labns.labnet.lan.

                ; infralab: Gateway API (.165) and legacy Ingress (.166).
                ; One wildcard certificate (*.infra.lab...) covers the Gateway.
*.infra         IN      A       10.0.0.165
gateway.infra   IN      A       10.0.0.165
ingress.infra   IN      A       10.0.0.166

; end of zone file
