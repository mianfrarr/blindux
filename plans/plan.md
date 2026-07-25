# Blindux v0.1.0 Architecture & Redesign Plan

## 1. Overview & Paradigm Shift

The revised Blindux architecture simplifies installation by eliminating live network installation (`pacstrap` on target machine over Wi-Fi). Instead, Phase 1 (Host machine) prepares a fully functional 3-partition USB containing a base root image (`blindux.fs.img`). Phase 2 (Target machine) simply unlocks BitLocker, copies `blindux.fs.img` to the NTFS drive, expands it, and boots into Arch Linux.

---

## 2. USB Drive Partition Layout

The target USB drive is partitioned into three distinct volumes:

| Partition | Type / File System | Mount Point / Role | Description |
|---|---|---|---|
| **P1** | FAT32 | Unmounted in Linux (User Data) | Occupies unallocated space for general Windows storage. Not used by Blindux runtime. |
| **P2** | EXT4 | `/boot` | Holds kernel, initramfs, LUKS key vault (`keys.luks`), and template `blindux.fs.img`. |
| **P3** | FAT32 | `/boot/efi` | EFI System Partition (ESP) containing GRUB2 EFI bootloader. |

---

## 3. Workflow Specifications

### Phase 1: USB Provisioning & Image Generation (Host Machine)
1. User runs `blindux.sh` on host machine with `sudo`.
2. Script partitions target USB into P1 (FAT32), P2 (EXT4), P3 (FAT32).
3. Script formats P2 as EXT4 and P3 as FAT32 (ESP).
4. Script bootstraps a minimal Arch Linux base image (`blindux.fs.img`) locally into a temporary workspace using `pacstrap`.
5. Script configures GRUB bootloader on P3 (ESP) and populates P2 with:
   - Kernel (`vmlinuz-linux`)
   - Custom Initramfs (`initramfs-linux.img`) with `blindux` early boot hooks
   - LUKS key vault (`/boot/keys.luks`) encrypting BitLocker recovery key
   - Base template `blindux.fs.img`
6. Zero-fills and optimizes `blindux.fs.img` to minimize copy footprint.

### Phase 2: In-Situ Deployment & Boot (Target Machine)
1. User boots target computer from the Blindux USB drive via UEFI.
2. GRUB loads kernel and initramfs from USB P2/P3.
3. Initramfs `blindux` hook prompts for Master Passphrase, opens `/boot/keys.luks`, and reads BitLocker recovery key.
4. Unlock target NTFS partition using `dislocker` and mount via `ntfs-3g`.
5. If `blindux.fs.img` is NOT found on NTFS:
   - Copy `/boot/blindux.fs.img` from USB P2 to host NTFS volume (e.g. `C:\blindux\blindux.fs.img`).
   - Expand image file using `truncate -s +XG` and `resize2fs` to user-selected size.
6. Mount `blindux.fs.img` loopback device, pivot root (`switch_root`), and boot natively into Arch Linux.

---

## 4. Architectural Advantages

- **Zero Target Network Dependency:** No target Wi-Fi setup or mirror connection issues.
- **Speed & Reliability:** Copying a ~1.5GB local image from USB to NTFS takes seconds compared to network pacstrapping.
- **Windows Coexistence:** P1 FAT32 partition allows normal USB file transfer usage on Windows.
