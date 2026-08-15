# Changelog

All notable changes to the **Blindux** project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [0.1.0] - 2026-08-15

### 🚀 Added
- **Pure Arch Linux Deployment Pipeline:** Automated, isolated `pacstrap` environment referencing upstream mirrors (`geo.mirror.pkgbuild.com`) with non-root ownership preservation.
- **In-Chroot Dislocker Compilation:** Automated CMake build and installation of `dislocker` from upstream source directly into the target root image.
- **2-Partition GPT USB Layout:** Unified FAT32 Data partition (`BLNDX_DATA`) for Windows file storage and FAT32 ESP partition (`BLNDX_BOOT`) for bootloader, kernel, initramfs, template image, and encrypted LUKS key containers.
- **Smart Storage & BitLocker Initramfs Hooks:** Custom `/etc/initcpio/hooks/blindux` with automatic BitLocker partition detection, LUKS passphrase prompting, `dislocker` unlocking, and in-situ image provisioning.
- **Initramfs Binary & Module Bundling:** Configured `/etc/initcpio/install/blindux` to package `dislocker`, `ntfs-3g`, `cryptsetup`, `resize2fs`, `truncate`, `blkid`, `losetup`, and required kernel modules (`fuse`, `loop`, `ext4`, `vfat`).
- **Phase 4 Runtime Automation:**
  - `blindux-persist.service`: Consolidates transient `root=auto` parameter to persistent UUID on first boot.
  - `blindux-space-monitor.service` / `.timer`: Background service monitoring available root container space every 10 minutes.
  - `99-blindux-sync.hook`: Pacman transaction hook to keep USB kernel and initramfs synchronized on system updates.

### ⚡ Optimized
- **Post-Build Footprint Optimization:** Automated removal of build-only tools (`cmake`, `git`) and complete purge of Pacman package cache (`/var/cache/pacman/pkg/`) and temporary build files, freeing ~600MB of usable disk space inside the deployed root filesystem.
- **Repository Hygiene:** Added `.gitignore` to prevent tracking large raw image files (`blindux.fs.img`), temporary files, and sensitive recovery keys.

### 📚 Documentation & Governance
- **Architecture Specification (v0.1.0):** Comprehensive baseline specification covering host isolation, storage layouts, initramfs hooks, and runtime automation.
- **Automated Git Governance:** Established policy for automated Git commits, milestone tracking, rollback management, and release changelog generation.
