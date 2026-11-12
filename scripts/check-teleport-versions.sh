#!/usr/bin/env bash
# Every Teleport version in this repo must match the Managed Updates target,
# which lives in the teleport-master repo (teleport-resources/autoupdate.yaml,
# fetched from GitHub; branch: $TELEPORT_MASTER_REF, default internal_lab):
# chart versions, images, the pilab kube agent and the node bootstrap
# installers. Bump them together in one commit (teleport/README.md, "Agents
# and versions").
#
#   scripts/check-teleport-versions.sh              versions only
#   scripts/check-teleport-versions.sh --checksums  also verify the bootstrap
#                                                   SHA-256s against cdn.teleport.dev
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

checksums=false
[ "${1:-}" = --checksums ] && checksums=true

autoupdate_src="teleport-master:${TELEPORT_MASTER_REF:-internal_lab}:teleport-resources/autoupdate.yaml"
autoupdate=$(mktemp)
trap 'rm -f "$autoupdate"' EXIT
curl -fsS -o "$autoupdate" \
  "https://raw.githubusercontent.com/vtrenton/teleport-master/${TELEPORT_MASTER_REF:-internal_lab}/teleport-resources/autoupdate.yaml" ||
  { echo "could not fetch $autoupdate_src" >&2; exit 1; }
userdata=infralab/autoinstall/user-data
pilab_versions=pilab/ansible/inventory/group_vars/all/versions.yml
pilab_bootstrap=pilab/ansible/roles/node_prep/defaults/main.yml
labns_install=binddns/teleport/install.sh

target=$(sed -n 's/^ *target_version: *\([0-9.]*\).*/\1/p' "$autoupdate" | head -n1)
[ -n "$target" ] || { echo "no target_version in $autoupdate_src" >&2; exit 1; }
echo "target: $target ($autoupdate_src)"

fail=0
# found <what> <file:line> <version>
found() {
  if [ "$3" = "$target" ]; then
    printf '  ok        %-28s %s\n' "$1" "$2"
  else
    printf '  MISMATCH  %-28s %s: %s\n' "$1" "$2" "$3"
    fail=1
  fi
}
# require <what> <count>: a location that matches nothing means this script
# no longer sees it (moved or renamed); fail instead of passing silently.
require() {
  if [ "$2" -eq 0 ]; then
    printf '  MISSING   %-28s (nothing found; update this script)\n' "$1"
    fail=1
  fi
}

n=0
while IFS=: read -r file line text; do
  found autoupdate_version "$file:$line" "${text##*: }"; n=$((n+1))
done < <(grep -nE '^ *(start|target)_version:' "$autoupdate" | sed "s|^|$autoupdate_src:|")
require autoupdate_version "$n"

# Argo CD Applications using Teleport's chart repo: the targetRevision that
# follows that repoURL
n=0
while IFS=: read -r file line ver; do
  found "chart $(basename "$file" .yaml)" "$file:$line" "$ver"; n=$((n+1))
done < <(awk '
  /repoURL: *https:\/\/charts\.releases\.teleport\.dev/ { want = 1 }
  want && /targetRevision:/ {
    v = $2; gsub(/"/, "", v); f = FILENAME; sub(/^\.\//, "", f)
    print f ":" FNR ":" v; want = 0
  }
' ./*/argo-apps/apps/*.yaml)
require "Teleport charts" "$n"

# Teleport images (e.g. the tbot sidecar)
n=0
while IFS=: read -r file line text; do
  ref=${text#*gravitational/}   # e.g. tbot-distroless:18.11.8
  tag=${ref#*:}
  found "image ${ref%%:*}" "$file:$line" "${tag%%[\" ]*}"; n=$((n+1))
done < <(grep -rnE --include='*.yaml' --include='*.yml' --include='*.j2' \
  'gravitational/[a-z-]+:' infralab pilab)
require "Teleport images" "$n"

v=$(sed -n 's/^teleport_kube_agent_chart_version: *"\{0,1\}\([0-9.]*\)"\{0,1\}.*/\1/p' "$pilab_versions")
require "pilab kube agent" "${#v}"
[ -z "$v" ] || found "pilab kube agent" "$pilab_versions" "$v"

v_pi=$(sed -n 's/^node_prep_teleport_bootstrap_version: *\([0-9.]*\).*/\1/p' "$pilab_bootstrap")
sha_pi=$(sed -n 's/^node_prep_teleport_bootstrap_sha256: *\([0-9a-f]*\).*/\1/p' "$pilab_bootstrap")
require "pilab bootstrap" "${#v_pi}"
[ -z "$v_pi" ] || found "pilab bootstrap" "$pilab_bootstrap" "$v_pi"

v_infra=$(sed -n 's/^ *v=\([0-9.]*\)$/\1/p' "$userdata")
sha_infra=$(sed -n 's/^ *sha=\([0-9a-f]*\)$/\1/p' "$userdata")
require "infralab bootstrap" "${#v_infra}"
[ -z "$v_infra" ] || found "infralab bootstrap" "$userdata" "$v_infra"

v_labns=$(sed -n 's/^version=\([0-9.]*\)$/\1/p' "$labns_install")
sha_labns=$(sed -n 's/^sha256=\([0-9a-f]*\)$/\1/p' "$labns_install")
require "labns bootstrap" "${#v_labns}"
[ -z "$v_labns" ] || found "labns bootstrap" "$labns_install" "$v_labns"

if $checksums; then
  echo "checksums (cdn.teleport.dev):"
  # verify <what> <version> <arch> <sha>
  verify() {
    local f="teleport-update-v$2-linux-$3-bin.tar.gz" want
    [ -n "$2" ] || return 0   # already reported MISSING
    if ! want=$(curl -fsS "https://cdn.teleport.dev/$f.sha256" | cut -d' ' -f1); then
      printf '  ERROR     %-28s could not fetch %s.sha256\n' "$1" "$f"; fail=1; return
    fi
    if [ "$want" = "$4" ]; then
      printf '  ok        %-28s %s\n' "$1" "$f"
    else
      printf '  MISMATCH  %-28s %s: repo %s, cdn %s\n' "$1" "$f" "$4" "$want"; fail=1
    fi
  }
  verify "infralab bootstrap" "$v_infra" amd64 "$sha_infra"
  verify "pilab bootstrap" "$v_pi" arm64 "$sha_pi"
  verify "labns bootstrap" "$v_labns" arm64 "$sha_labns"
fi

if [ "$fail" -ne 0 ]; then
  echo "Teleport versions are out of step with $autoupdate_src" >&2
  exit 1
fi
