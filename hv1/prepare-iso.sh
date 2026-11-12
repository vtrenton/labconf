#!/bin/sh
# Builds hv1's unattended install ISO from a Proxmox VE ISO: embeds
# answer.toml and first-boot.sh, plus root's password hash.
#
#   hv1/prepare-iso.sh /path/to/proxmox-ve_9.x.iso
#
# Asks for root's password (also the Proxmox web UI login: keep it in your
# password manager); only its hash goes into the new ISO, never into git.
# Writes <iso basename>-hv1.iso next to the source ISO. Flash it to a USB
# stick and boot the P520 from it: the install wipes the two P320 NVMes only.
#
# proxmox-auto-install-assistant is Debian/Proxmox-only, so this runs it in a
# throwaway Debian 13 container (podman or docker).
set -eu

[ $# -eq 1 ] && [ -r "$1" ] || { echo "usage: $0 /path/to/proxmox-ve.iso" >&2; exit 2; }
here=$(cd "$(dirname "$0")" && pwd)
dir=$(cd "$(dirname "$1")" && pwd)
src=$(basename "$1")
out="${src%.iso}-hv1.iso"
engine=$(command -v podman || command -v docker) || { echo "needs podman or docker" >&2; exit 1; }

# The script below runs inside the container (its $ expand there).
# shellcheck disable=SC2016
"$engine" run --rm -it \
  -v "$here:/hv1:ro" -v "$dir:/iso" \
  -e SRC="$src" -e OUT="$out" -e ROOT_PASSWORD_HASH="${ROOT_PASSWORD_HASH:-}" \
  docker.io/library/debian:trixie sh -euc '
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends ca-certificates curl whois xorriso >/dev/null
    curl -fsSL -o /usr/share/keyrings/proxmox-archive-keyring.gpg \
      https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg
    printf "%s\n" "Types: deb" "URIs: http://download.proxmox.com/debian/pve" "Suites: trixie" \
      "Components: pve-no-subscription" "Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg" \
      > /etc/apt/sources.list.d/pve.sources
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends proxmox-auto-install-assistant >/dev/null

    hash=${ROOT_PASSWORD_HASH:-}
    if [ -z "$hash" ]; then
      echo "root password for hv1 (also the web UI login):"
      hash=$(mkpasswd -m yescrypt)
    fi
    awk -v h="$hash" "{print} /^\[global\]\$/ {print \"root-password-hashed = \\\"\" h \"\\\"\"}" \
      /hv1/answer.toml > /tmp/answer.toml
    proxmox-auto-install-assistant validate-answer /tmp/answer.toml
    proxmox-auto-install-assistant prepare-iso "/iso/$SRC" \
      --fetch-from iso --answer-file /tmp/answer.toml \
      --on-first-boot /hv1/first-boot.sh --output "/iso/$OUT"
    echo "written: $OUT"
  '
