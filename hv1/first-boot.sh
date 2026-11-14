#!/bin/sh
# hv1 setup. prepare-iso.sh embeds this script in the install ISO; Proxmox
# runs it once on first boot (log: journalctl -u proxmox-first-boot). It
# installs itself as /usr/local/sbin/hv1-setup, so the helpers below stay
# available.
#
#   hv1-setup                  first-boot setup (also safe to re-run)
#   hv1-setup add-recovery     add your recovery passphrase to every LUKS
#                              device (rpool + fast). Run once after install,
#                              BEFORE the first reboot.
#   hv1-setup fast-reattach    after a reinstall: unlock the existing `fast`
#                              disks with the recovery passphrase and bring
#                              the pool back (a new install has a new key)
#
# First-boot setup, in this order (the risky disk work last, so the host is
# reachable through Teleport even if it stops):
#   1. apt: the no-subscription repository; cryptsetup, clevis, mokutil, and
#      systemd-cryptsetup (Debian 13 ships the /etc/crypttab reader for after
#      the initramfs separately; without it `fast` never unlocks at boot)
#   2. SSH: keys only (root's key comes from answer.toml)
#   3. Teleport agent (SSH + the Proxmox UI as app proxmox-hv1), joined with
#      the TPM (token hv1-node), installed by the proxy's own install script
#      (the cluster decides the version; Managed Updates group hv1)
#   4. rpool onto LUKS, one mirror disk at a time, each TPM-bound (PCR 7:
#      Secure Boot state) before it holds data, so every boot can unlock it
#   5. fast: LUKS on the 980 PROs, ZFS mirror, Proxmox storage `fast`; its
#      key is a file on the (encrypted) root
#
# Nothing is wiped that isn't declared here or by answer.toml: rpool is
# whatever the installer built, fast is the serials below, and a fast disk
# that already has a LUKS header is never formatted (see fast-reattach).
set -eu

# --- Declared here ---------------------------------------------------------
proxy=teleport.aws.trentonvanderwert.com
group=hv1
fast_serials="S6B0NU0W818132J S6B0NU0W716003H" # 2x Samsung 980 PRO 2TB
fast_key=/etc/cryptsetup-keys.d/fast.key
tpm_policy='{"pcr_bank":"sha256","pcr_ids":"7"}'
# ---------------------------------------------------------------------------

log() { printf '\n== %s\n' "$*"; }
die() { printf 'hv1-setup: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run as root"

# --- 1. apt ----------------------------------------------------------------
apt_setup() {
  log "apt: no-subscription repository, encryption packages"
  # Enterprise repositories off (no subscription): "Enabled: no" in each
  # stanza of the installer's deb822 files.
  for f in /etc/apt/sources.list.d/pve-enterprise.sources /etc/apt/sources.list.d/ceph.sources; do
    if [ -f "$f" ] && ! grep -q '^Enabled: no' "$f"; then
      sed -i '/^Types:/a Enabled: no' "$f"
    fi
  done
  cat > /etc/apt/sources.list.d/pve-no-subscription.sources <<'CONF'
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
CONF
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -q
  apt-get install -y -q cryptsetup cryptsetup-initramfs systemd-cryptsetup clevis clevis-luks clevis-tpm2 clevis-initramfs mokutil gdisk parted
}

# --- 2. SSH ----------------------------------------------------------------
ssh_key_only() {
  log "SSH: keys only"
  # Break-glass when Teleport is down; reachable from home and wireless
  # only (udm-pro-config).
  cat > /etc/ssh/sshd_config.d/10-key-only.conf <<'CONF'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
CONF
  sshd -t
  systemctl reload ssh
}

# --- 3. Teleport -----------------------------------------------------------
teleport_agent() {
  log "Teleport agent"
  [ -e /dev/tpmrm0 ] || die "no /dev/tpmrm0: the TPM isn't available"
  new=$(mktemp)
  cat > "$new" <<'CONF'
# Teleport agent on hv1 (written by hv1-setup). Joins with the TPM (token
# hv1-node allows this P520's EK). SSH as root only (role hv1-admin); the
# Proxmox UI is the app proxmox-hv1 (Proxmox's own login still applies).
version: v3
teleport:
  nodename: hv1
  proxy_server: teleport.aws.trentonvanderwert.com:443
  join_params:
    method: tpm
    token_name: hv1-node
  log:
    output: stderr
    severity: INFO
auth_service:
  enabled: false
proxy_service:
  enabled: false
ssh_service:
  enabled: true
  labels:
    lab: hv1
app_service:
  enabled: true
  apps:
    - name: proxmox-hv1
      description: Proxmox VE on hv1
      uri: https://localhost:8006
      # Proxmox's certificate is self-signed
      insecure_skip_verify: true
      labels:
        lab: hv1
CONF
  changed=false
  if ! cmp -s "$new" /etc/teleport.yaml; then
    install -m 0644 -o root -g root "$new" /etc/teleport.yaml
    changed=true
  fi
  rm -f "$new"

  if [ ! -x /usr/local/bin/teleport ]; then
    curl -fsSL "https://$proxy/scripts/install.sh?group=$group" | sh
    changed=false # freshly installed: started below with the new config
  fi

  systemctl enable teleport
  if $changed; then systemctl restart teleport; else systemctl start teleport; fi
}

# --- helpers for 4 and 5 -----------------------------------------------------
setup_key=/run/hv1-setup.key
new_setup_key() {
  umask 077
  [ -s "$setup_key" ] || head -c 64 /dev/urandom > "$setup_key"
}

# luks_format <partition> <name>: LUKS2, TPM-bound (with the setup key as
# the only other slot, removed later), opened as /dev/mapper/<name>.
luks_format() {
  cryptsetup luksFormat --batch-mode --type luks2 --cipher aes-xts-plain64 \
    --key-size 512 --hash sha256 --key-file "$setup_key" "$1"
  cryptsetup open --allow-discards --key-file "$setup_key" "$1" "$2"
}

tpm_bind() {
  clevis luks bind -y -k "$setup_key" -d "$1" tpm2 "$tpm_policy"
}

uuid_of() { blkid -s UUID -o value "$1"; }

crypttab_add() { # <name> <device> <keyfile|none> <options>
  grep -q "^$1 " /etc/crypttab 2>/dev/null && return 0
  printf '%s UUID=%s %s %s\n' "$1" "$(uuid_of "$2")" "$3" "$4" >> /etc/crypttab
}

settle() { udevadm settle; sleep 1; }

# --- 4. rpool onto LUKS ----------------------------------------------------
rpool_members() { zpool status -P rpool | awk '$1 ~ "^/dev/" {print $1}'; }

encrypt_rpool() {
  log "rpool onto LUKS"
  mokutil --sb-state 2>/dev/null | grep -q 'SecureBoot enabled' ||
    die "Secure Boot is off: the TPM binding (PCR 7) would protect nothing. Turn it on in the BIOS, reinstall."

  plain=$(rpool_members | grep -v '^/dev/mapper/' || true)
  [ -z "$plain" ] && { echo "already on LUKS"; return 0; }
  [ "$(rpool_members | wc -l)" -eq 2 ] || die "rpool must be a two-disk mirror: $(rpool_members | tr '\n' ' ')"

  new_setup_key
  for member in $plain; do
    case "$member" in *-part3) ;; *) die "unexpected rpool member $member" ;; esac
    disk=${member%-part3}
    other=$(rpool_members | grep -vx "$member")
    i=0; while [ -e "/dev/mapper/luks-rpool$i" ]; do i=$((i + 1)); done
    name=luks-rpool$i
    echo "-- $member -> /dev/mapper/$name (mirror runs on $other meanwhile)"

    zpool detach rpool "$member"
    zpool labelclear -f "$member"
    # Same start, to the end of the disk: larger than the plain partition
    # (answer.toml hdsize), so the LUKS device fits back into the mirror.
    start=$(sgdisk -i 3 "$disk" | awk '/^First sector/ {print $3}')
    sgdisk -d 3 -n "3:$start:0" -t 3:8309 -c 3:"$name" "$disk"
    partprobe "$disk"; settle
    wipefs -a "$disk-part3"

    luks_format "$disk-part3" "$name"
    tpm_bind "$disk-part3"
    zpool attach -w rpool "$other" "/dev/mapper/$name"

    # Unlocked in the initramfs (before ZFS imports root), by clevis/TPM;
    # the recovery passphrase is the fallback prompt.
    crypttab_add "$name" "$disk-part3" none luks,discard,initramfs
    update-initramfs -u -k all
  done

  # Only the TPM slots stay; add-recovery adds the passphrase.
  for dev in $(rpool_devices); do
    cryptsetup luksRemoveKey "$dev" "$setup_key" 2>/dev/null || true
  done
  # shellcheck disable=SC2046 # one argument per member
  zpool online -e rpool $(rpool_members)
  proxmox-boot-tool refresh
  zpool status rpool
}

# Raw LUKS partitions behind rpool / fast, from crypttab
crypt_devices() {
  awk -v p="$1" '$1 ~ "^"p {sub(/^UUID=/, "", $2); print "/dev/disk/by-uuid/" $2}' /etc/crypttab
}
rpool_devices() { crypt_devices luks-rpool; }
fast_devices() { crypt_devices luks-fast; }

# --- 5. fast ---------------------------------------------------------------
fast_disk() { # <serial> -> /dev/disk/by-id/... (whole disk)
  for d in /dev/disk/by-id/nvme-*_"$1"; do [ -e "$d" ] && { echo "$d"; return 0; }; done
  die "no NVMe disk with serial $1"
}

setup_fast() {
  log "fast: LUKS + ZFS mirror"
  if zpool list fast >/dev/null 2>&1; then echo "pool fast exists"; return 0; fi
  for s in $fast_serials; do
    d=$(fast_disk "$s")
    if cryptsetup isLuks "$d-part1" 2>/dev/null; then
      echo "$d already holds a LUKS volume: an existing fast pool from before"
      echo "this install. Not touching it; run: hv1-setup fast-reattach"
      return 0
    fi
  done

  umask 077
  mkdir -p "$(dirname "$fast_key")"
  [ -s "$fast_key" ] || head -c 64 /dev/urandom > "$fast_key"
  i=0; mappers=""
  for s in $fast_serials; do
    d=$(fast_disk "$s"); name=luks-fast$i
    sgdisk --zap-all "$d"
    sgdisk -n 1:0:0 -t 1:8309 -c 1:"$name" "$d"
    partprobe "$d"; settle
    cryptsetup luksFormat --batch-mode --type luks2 --cipher aes-xts-plain64 \
      --key-size 512 --hash sha256 --key-file "$fast_key" "$d-part1"
    cryptsetup open --allow-discards --key-file "$fast_key" "$d-part1" "$name"
    # Unlocked after root, with the key file on the encrypted root
    crypttab_add "$name" "$d-part1" "$fast_key" luks,discard
    mappers="$mappers /dev/mapper/$name"; i=$((i + 1))
  done
  # shellcheck disable=SC2086 # one argument per device
  zpool create -o ashift=12 -o autotrim=on -O compression=lz4 -O atime=off \
    -O acltype=posixacl -O xattr=sa fast mirror $mappers
  pvesm add zfspool fast --pool fast --content images,rootdir --sparse 1
  zpool status fast
}

# --- helpers -----------------------------------------------------------------
read_passphrase() { # -> $pass
  printf '%s: ' "$1"; stty -echo; read -r pass; stty echo; echo
  printf 'Again: '; stty -echo; read -r again; stty echo; echo
  [ "$pass" = "$again" ] || die "passphrases differ"
  [ -n "$pass" ] || die "empty passphrase"
}

add_recovery() {
  # Against a disk taken out of the machine this passphrase is the whole
  # protection (the TPM stays behind): use a random one from your password
  # manager, not a word or phrase.
  read_passphrase "Recovery passphrase (random, from your password manager)"
  umask 077
  newkey=$(mktemp -p /run); cur=$(mktemp -p /run)
  trap 'rm -f "$newkey" "$cur"' EXIT
  printf '%s' "$pass" > "$newkey"
  for dev in $(rpool_devices); do
    if cryptsetup open --test-passphrase --key-file "$newkey" "$dev" 2>/dev/null; then echo "$dev: already set"; continue; fi
    slot=$(clevis luks list -d "$dev" | awk -F: '/tpm2/ {print $1; exit}')
    clevis luks pass -d "$dev" -s "$slot" > "$cur"
    cryptsetup luksAddKey --key-file "$cur" "$dev" "$newkey" && echo "$dev: added"
  done
  for dev in $(fast_devices); do
    if cryptsetup open --test-passphrase --key-file "$newkey" "$dev" 2>/dev/null; then echo "$dev: already set"; continue; fi
    cryptsetup luksAddKey --key-file "$fast_key" "$dev" "$newkey" && echo "$dev: added"
  done
}

fast_reattach() {
  read_passphrase "Recovery passphrase of the existing fast disks"
  umask 077
  newkey=$(mktemp -p /run); trap 'rm -f "$newkey"' EXIT
  printf '%s' "$pass" > "$newkey"
  mkdir -p "$(dirname "$fast_key")"
  [ -s "$fast_key" ] || head -c 64 /dev/urandom > "$fast_key"
  i=0
  for s in $fast_serials; do
    d=$(fast_disk "$s"); name=luks-fast$i
    cryptsetup isLuks "$d-part1" || die "$d-part1 isn't LUKS"
    # This install's key file joins the recovery passphrase in a new slot
    cryptsetup open --test-passphrase --key-file "$fast_key" "$d-part1" 2>/dev/null ||
      cryptsetup luksAddKey --key-file "$newkey" "$d-part1" "$fast_key"
    [ -e "/dev/mapper/$name" ] || cryptsetup open --allow-discards --key-file "$fast_key" "$d-part1" "$name"
    crypttab_add "$name" "$d-part1" "$fast_key" luks,discard
    i=$((i + 1))
  done
  zpool list fast >/dev/null 2>&1 || zpool import -d /dev/mapper fast
  pvesm status --storage fast >/dev/null 2>&1 || pvesm add zfspool fast --pool fast --content images,rootdir --sparse 1
  echo "Old key slots from the previous install stay until removed: cryptsetup luksDump <dev>"
  zpool status fast
}

first_boot() {
  cmp -s "$0" /usr/local/sbin/hv1-setup || install -m 0755 "$0" /usr/local/sbin/hv1-setup
  apt_setup
  ssh_key_only
  teleport_agent
  encrypt_rpool
  setup_fast
  log "done"
  cat <<'MSG'
Next, BEFORE the first reboot:
  ssh root@10.0.0.151 hv1-setup add-recovery
Then reboot: rpool unlocks from the TPM with no prompt.
MSG
  echo "TPM identity (the hv1-node token allows this EK):"
  /usr/local/bin/teleport tpm identify
}

# Anything but a helper name runs the first-boot setup: Proxmox's first-boot
# service passes its own argument, and every step checks whether it's done.
case "${1:-}" in
  add-recovery) add_recovery ;;
  fast-reattach) fast_reattach ;;
  *) first_boot ;;
esac
