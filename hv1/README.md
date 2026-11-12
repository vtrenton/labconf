# hv1

The lab hypervisor: a ThinkStation P520 (Xeon W-2135, 256 GB ECC) running
Proxmox VE 9, at `10.0.0.151` on labnet (`hv1.labnet.lan`; DHCP reservation in
`udm-pro-config`, A/PTR records in `binddns/`). Its VMs use `.152`-`.159`. It
serves storage to the clusters and runs a few VMs and containers.

Rebuilt the same way as everything else: a factory-fresh P520 becomes this
host from git, with one manual step (the recovery passphrase).

| File | What |
|---|---|
| `answer.toml` | Unattended install (declarative): hostname, ZFS mirror on the two P320 NVMes (matched by model, `hdsize` 118), NIC names pinned by MAC, timezone, root's SSH key |
| `first-boot.sh` | Runs once after install and installs itself as `hv1-setup`: key-only SSH, the Teleport agent, rpool onto LUKS (TPM unlock), the encrypted `fast` pool. Its helpers: `add-recovery`, `fast-reattach` |
| `prepare-iso.sh` | Builds the install ISO from a Proxmox VE ISO, with both files and root's password hash |

## Layout

| Pool / device | What |
|---|---|
| `rpool` | 2× 128 GB Patriot P320 NVMe (onboard M.2), each: 1 MB BIOS boot, 512 MB EFI (kernel + initramfs, `proxmox-boot-tool`), the rest **LUKS** → ZFS mirror: the OS |
| `fast` | 2× 2 TB Samsung 980 PRO (PCIe adapter, slot on x4x4x4x4), each one **LUKS** partition → ZFS mirror; Proxmox storage `fast` (VM disks, containers) |
| `bulk` | 5× 1 TB SATA on controller `00:17.0` (alone in its IOMMU group), passed whole to the storage VM: encrypted RAIDZ2 inside it |
| `nic0` | onboard I219-LM, `vmbr0`, management |
| `nic1`-`nic4` | 82580, 4× 1 GbE |
| `nic5`-`nic8` | X710, 4× 10 GbE |

## Encryption

Nothing readable is left on a disk that leaves the machine: root holds
Proxmox's keys (`/etc/pve/priv`), the Teleport agent's identity and root's
password hash; `fast` holds the VMs.

- **rpool**: ZFS on LUKS (LUKS2, AES-256-XTS), one LUKS device per mirror
  disk, unlocked in the initramfs before ZFS imports root
  (`/etc/crypttab`: `luks,discard,initramfs`).
- **Unlock**: clevis with the TPM, bound to PCR 7 (the Secure Boot state, and
  the certificates shim measures). Kernel updates don't change it. If the TPM
  refuses (Secure Boot off, keys changed, TPM cleared), the console asks for
  the **recovery passphrase**.
- **fast**: LUKS under ZFS too (Proxmox calls ZFS native encryption
  experimental, with checksum errors on snapshots and ZVOLs). Its key is
  `/etc/cryptsetup-keys.d/fast.key` on the encrypted root; the recovery
  passphrase is also on each disk.
- **Why the BIOS lockdown matters**: PCR 7 is the same when the machine boots
  another Proxmox installer (same signed shim), which could then unseal the
  key. A supervisor password, USB boot off and a locked boot menu close
  that. Clearing the CMOS doesn't remove a ThinkStation supervisor password,
  and turning Secure Boot off changes PCR 7.
- **Recovery passphrase**: one per host, in your password manager, never in
  git or on the install stick. Same passphrase on all four LUKS devices.

## Rebuild

1. **BIOS**: VT-x and VT-d on; UEFI only; the NVMe adapter's slot on
   x4x4x4x4; **Secure Boot on** (allow the Microsoft third-party UEFI CA);
   supervisor password set. For the install only: allow USB boot.
2. Download the Proxmox VE 9 ISO, then build the unattended one (podman or
   docker; asks for root's password, which is also the web UI login):
   ```bash
   hv1/prepare-iso.sh ~/Downloads/proxmox-ve_9.x.iso
   ```
3. Flash `proxmox-ve_9.x-hv1.iso` to a USB stick and boot the P520 from it.
   The install wipes **only** the two P320 NVMes and reboots. On that first
   boot `hv1-setup` runs (`journalctl -u proxmox-first-boot -f`): it moves
   rpool onto LUKS and creates `fast`. It does not reboot.
4. **Before rebooting**, add the recovery passphrase:
   ```bash
   ssh root@10.0.0.151 hv1-setup add-recovery
   ```
5. Reboot. rpool unlocks with no prompt. Then lock the BIOS down again: USB
   boot off, boot menu behind the supervisor password.
6. Check: `zpool status` (both pools on `/dev/mapper/luks-*`), `tsh ls lab=hv1`
   shows `hv1`, `tsh apps ls` shows `proxmox-hv1`.

The TPM's EK is fixed hardware, so the `hv1-node` token
(`teleport-master/teleport-resources/tokens-nodes.yaml`) still matches after a reinstall.
If the TPM is cleared or the board replaced, run `teleport tpm identify` on
the new host and update the token.

**Reinstalling with `fast` already in use**: `hv1-setup` sees the LUKS headers
on the 980 PROs and leaves them alone (a new install has a new key file).
Bring the pool back with the recovery passphrase:
```bash
ssh root@10.0.0.151 hv1-setup fast-reattach
```

## Operations

| Task | How |
|---|---|
| TPM won't unlock (prompt at the console) | Type the recovery passphrase. Then, if the change was intended (e.g. Secure Boot keys): `clevis luks regen -d <dev> -s <slot>` for each rpool LUKS device (`clevis luks list -d <dev>`) |
| Replace a failed rpool disk | `sgdisk <healthy disk> -R <new disk>; sgdisk -G <new disk>`; LUKS on its partition 3 (`cryptsetup luksFormat`, add the recovery passphrase, `clevis luks bind -d <part> tpm2 '{"pcr_bank":"sha256","pcr_ids":"7"}'`), open it, `zpool replace rpool <old> /dev/mapper/<name>`, add it to `/etc/crypttab` (`luks,discard,initramfs`), `update-initramfs -u -k all`, then `proxmox-boot-tool format <ESP>` and `proxmox-boot-tool init <ESP> grub` |
| Replace a failed fast disk | Partition, `cryptsetup luksFormat --key-file /etc/cryptsetup-keys.d/fast.key`, add the recovery passphrase, open, `zpool replace fast <old> /dev/mapper/<name>`, add to `/etc/crypttab` (`luks,discard`) |
| Back up LUKS headers | `cryptsetup luksHeaderBackup <dev> --header-backup-file <file>`, per device, kept off the host |

## Access

| Path | How |
|---|---|
| SSH (day to day) | `tsh ssh root@hv1` (role `hv1-admin`) |
| Web UI | Teleport app `proxmox-hv1`, or `https://10.0.0.151:8006` from home/wireless; Proxmox's own login (`root`, realm Linux PAM) on top |
| Break-glass | `ssh root@10.0.0.151` from home/wireless with your key (passwords are off for SSH) |
