# infralab

Three Intel mini PCs (4 cores, 16 GB, 512 GB NVMe, TPM 2.0) running Ubuntu
Server 26.04 minimal. Every node runs all k3s roles.

## Delineation

| Layer | Owns |
|---|---|
| **Network** | Everything per-node. DHCP reservation (MAC -> IP), PTR record in `binddns/` (IP -> hostname). |
| **`autoinstall/`** | Everything OS-level, identical on all nodes: disk layout, LUKS + TPM unlock, user, SSH, sudo, packages, hostname-from-DNS. |
| **`ansible/`** | k3s install and config, plus day-2 ops playbooks. |

Nodes are cattle: rebuilding one is boot the USB, wait, run Ansible.

## Install

1. Write the Ubuntu Server 26.04 ISO to a USB stick.
2. Copy `autoinstall/user-data` and `autoinstall/meta-data` to a second FAT
   stick labelled `CIDATA`. One stick works for every node.
3. Boot the node with both. Answer `yes` at the autoinstall prompt (or add
   `autoinstall` to the kernel line in GRUB to skip it). **This erases the
   NVMe.**
4. When it is back on SSH, save the recovery key and remove it from disk:

   ```
   ssh sysadmin@infraN sudo cat /root/luks-recovery-key   # -> password manager
   ssh sysadmin@infraN sudo shred -u /root/luks-recovery-key
   ```

## How it works

- **Hostname from DNS.** `hostname-from-dns.service` runs on every boot after
  the network is up (and before k3s): it looks up the PTR record for the
  node's address and sets the hostname to its short name. Renaming a node is a
  DNS change and a reboot. cloud-init is told to leave the hostname alone
  (`preserve_hostname`).
- **Disk unlock.** The root volume is LUKS2. The installer formats it with a
  throwaway passphrase (in `user-data`, deliberately public). `late-commands`
  then enroll a TPM2 keyslot bound to PCR 7, add a recovery key, wipe the
  throwaway passphrase, and add the `tpm2-tss` dracut module plus
  `tpm2-device=auto` in crypttab so the initramfs unlocks without a console.
  Any failure aborts the install.
- **No secrets in the repo.** The user has a locked password (SSH key +
  passwordless sudo), and the only key that opens the disk outside the TPM is
  the recovery key generated on the node.

## PCR 7 trade-offs

PCR 7 measures the Secure Boot state and key databases, so kernel, initramfs
and GRUB updates don't affect it and unattended upgrades reboot cleanly.
Toggling Secure Boot, changing its keys, or a firmware/`dbx` update that
changes them will make the node fall back to a passphrase prompt: enter the
recovery key, then re-enroll:

```
sudo systemd-cryptenroll --wipe-slot=tpm2 --tpm2-device=auto --tpm2-pcrs=7 /dev/nvme0n1p3
```

Secure Boot is currently **off** (firmware in Setup Mode), so the TPM will
unseal for anything booted on the same machine. This protects a disk removed
from the box, not a stolen box. To tighten it, restore the factory Secure Boot
keys in the BIOS and enable Secure Boot (Ubuntu's signed shim/GRUB/kernel
boot as-is), before installing.

## Day 2

From `infralab/ansible/` (`source ansible-configure.sh` first):

| Task | Command |
|---|---|
| Update packages, reboot only where required, one node at a time | `ansible-playbook playbooks/ops/update-and-reboot.yml` |
| Rolling reboot | `ansible-playbook playbooks/ops/rolling-reboot.yml` |
