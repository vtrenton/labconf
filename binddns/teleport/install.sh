#!/bin/sh
# Install (or re-apply the config of) the Teleport SSH agent on labns.
# Run as root on labns from a copy of this directory:
#   sh install.sh
# Idempotent. Prints the TPM identity at the end: its EK hash and serial go
# into the labns-node token (infralab/argo-apps/teleport-resources/tokens-nodes.yaml).
# Until that token allows this EK the agent just retries.
#
# The version below only bootstraps teleport-update; after that Managed
# Updates (group labns) follow the cluster's autoupdate_version. Bump it with
# the others (scripts/check-teleport-versions.sh).
set -eu
version=18.11.8
sha256=9bf88f2726c481d37aeec2710e96af2b26803ad209ce68bc6fe35940641dae9f
proxy=teleport.aws.trentonvanderwert.com:443
group=labns
here=$(cd "$(dirname "$0")" && pwd)

[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }
[ -e /dev/tpmrm0 ] || { echo "no /dev/tpmrm0: the TPM isn't available" >&2; exit 1; }

changed=false
if ! cmp -s "$here/teleport.yaml" /etc/teleport.yaml; then
  install -m 0644 -o root -g root "$here/teleport.yaml" /etc/teleport.yaml
  changed=true
fi

if [ ! -x /usr/local/bin/teleport ]; then
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  f="teleport-update-v$version-linux-arm64-bin.tar.gz"
  curl -fsSL -o "$tmp/$f" "https://cdn.teleport.dev/$f"
  echo "$sha256  $tmp/$f" | sha256sum -c -
  tar -xzf "$tmp/$f" -C "$tmp"
  "$tmp/teleport/teleport-update" enable --proxy "$proxy" --group "$group"
  changed=false   # freshly installed: started below with the new config
fi

systemctl enable teleport
if $changed; then systemctl restart teleport; else systemctl start teleport; fi

echo
echo "TPM identity (add to the labns-node token):"
/usr/local/bin/teleport tpm identify
