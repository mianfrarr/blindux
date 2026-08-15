# BLINDUX: SYSTEM ARCHITECTURE & SKELETON SPECIFICATION (v0.1.0)

## PREREQUISITES & RENDERED OUTPUT GOVERNANCE
1. **Language Compliance Constraints:** All architecture specifications, skeletons, logs, prompts, error handling, and code comments within this document and the derived installer scripts MUST be written strictly in English (US).
2. **Host Privilege Requirements:** Must be executed with root privileges (`sudo`) under WSL or any standard Linux distribution.
3. **Environment Assets:** Host environment must feature standard raw image utilities, loop device management tools, `cryptsetup`, `dislocker`, `ntfs-3g`, and `arch-install-scripts` (or native `pacstrap` / `pacman-key`).
4. **Markdown Code Block Enforcement:** As an absolute structural constraint, this entire architecture document, its technical specifications, and any derived deployment scripts MUST ALWAYS be shared with the Creator inside a clean Markdown code block to guarantee direct, unpolluted portability and seamless downloading.
5. **Automated Git Version Control & Rollback Governance:** The project workspace must maintain an active Git version control repository. All architectural updates, script refactors, and milestones must be systematically committed with clear, descriptive commit messages. Rollbacks and checkpoints must be managed automatically to guarantee seamless state preservation and version recovery.
6. **Release Changelog Maintenance:** A dedicated `CHANGELOG.md` adhering to the Keep a Changelog standard and Semantic Versioning must be maintained at the root of the workspace. Milestones, new features, optimizations, bug fixes, and architectural adjustments must be compiled from the Git commit history and recorded in `CHANGELOG.md` upon each version release.

### Project Governance & Semantic Versioning (SemVer)
* All architecture specifications, skeletons, and derived installer scripts must strictly follow the standard Semantic Versioning (SemVer) scheme (`MAJOR.MINOR.PATCH`).

### Version Alignment and Synchronization
* **Dual-Tracking Coordination:** Every generated deployment script must embed and match the exact version of the Project Skeleton it was built from. 
* **Version Header Requirement:** The target installation script (`blindux.sh`) must declare two immutable variables at the very top of its execution scope: `SKELETON_VERSION` and `SCRIPT_VERSION`.

### Execution Environment
* The setup/installation script can run under **WSL (Windows Subsystem for Linux)** or any standard **Linux distribution** with raw image and loop device management tools.
* **Privilege & Ownership Enforcement:** The script must be executed with root privileges (`sudo`). However, to prevent root-ownership pollution of the host workspace, the script must capture the non-root calling user via `$SUDO_USER`, `$SUDO_UID`, and `$SUDO_GID`. Every file or folder created directly on the host workspace must explicitly have its ownership restored to this calling user.

---

## FASE 0: PRE-INSTALLATION, CONTEXT & RESUME MECHANISM

### Workspace
* All generated output files, build files, and final images will be stored inside the relative folder `./blindux/`.
* **Dynamic Permission Fix:** If the `./blindux/` directory is created by the script, it must instantly be chowned to `$SUDO_USER:$SUDO_USER` (or utilizing `$SUDO_UID:$SUDO_GID`) to ensure the normal user can read, modify, or delete the workspace without permission errors.

### Robustness & Safety Standards
* **Global Cleanup Trap:** The script must register an exit/error trap handler (`trap f5_cleanup EXIT INT TERM`) immediately upon launch to ensure loop devices, chroot binds, and mount points are decoupled under any failure or manual interruption condition.

### Interactive Input Gathering
1. **Welcome Title:** Display a clean, single-line text title: `--- Blindux Installer ---`.
2. **Target USB Selector (Bash Syntax Enforcement):** Scan and list available USB block devices (displaying size, label, and filesystem). Provide an option to select a device **OR select `Refresh` (`r`)** in case the USB was not yet connected.
3. **Target Image Path Selector:** Select destination path for `blindux.fs.img` on host NTFS volume (Default: `/blindux/blindux.fs.img`, `/Users/Public/blindux/blindux.fs.img`, or custom).
4. **Target Distribution:** Standardized on **Arch Linux** base system for minimal footprint, native package management, and custom early-boot initramfs hooks.
5. **Image Size Picker (Validation Logic):** 
    * Prompt the user to indicate the initial target size in GB for the `blindux.fs.img` once deployed to the host NTFS partition.
    * Default value is **20**.
    * **Validation constraints:** Loop and re-prompt the user if the input is `0`, if it is not a valid integer number, or if the available free space in the host directory `./` is less than the specified size in GB.
6. **LUKS Container Passphrase (Master Passphrase):** Securely prompt the user to define a master passphrase. This passphrase will encrypt both the local state session cache file and the final file containing the BitLocker key on the `/boot` USB storage.
7. **BitLocker Key Input:** Securely prompt the user for their Windows BitLocker Recovery Key (masking input on-screen). If left empty, proceed assuming the host Windows partition is unencrypted.

---

## FASE 1: TEMPLATE IMAGE PROVISIONING & STRAPPED INSTALLATION (COMPRESSION OPTIMIZED)

### Virtual Disk Template Creation
* Create a minimal RAW image file named `./blindux/blindux.fs.img` (~3GB sparse template) using `truncate`.
* **Host Filesystem Ownership:** Immediately after the raw `.img` allocation, ownership must be fixed to match the original user (`$SUDO_USER`), avoiding root-locked files in the host directory tree.
* Format `./blindux/blindux.fs.img` with `ext4` directly as a loopback device, without partition tables.

### Base Bootstrap (Isolated Matrix & Non-Interactive Constraint)
* Mount `./blindux/blindux.fs.img` to a temporary mount point (`/mnt/blindux_root`).
* **Distribution Agnosticism Isolation:** To avoid polluting or picking up mirror configurations from the host, the bootstrap sequence is isolated:
    * Generate a standalone temporary `pacman.conf` referencing an isolated temporary `mirrorlist` pointing strictly to upstream official Arch Linux CDN/mirrors (`geo.mirror.pkgbuild.com`).
    * Pass this configuration to `pacstrap` via `-C` flag with `--noconfirm` (`base linux linux-firmware base-devel grub efibootmgr archlinux-keyring ntfs-3g cryptsetup git cmake mbedtls fuse2 patch util-linux e2fsprogs coreutils which parted`).

### Initial Configuration & Native CLI Provisioning inside Chroot
* Configure system locales (`en_US.UTF-8`), timezone, network defaults, and user accounts.
* **Dynamic Mount Mapping:** Bind-mount host system descriptors (`/dev`, `/proc`, `/sys`) and `/dev/pts` into the chroot workspace.
* **Dislocker Compilation & Post-Build Cleanup:** Inside the chroot environment, clone upstream `dislocker` from source, compile with CMake (`-DCMAKE_INSTALL_PREFIX=/usr`), and install to provide `dislocker`, `dislocker-fuse`, and `dislocker-file` utilities. Immediately following installation, remove build-only packages (`cmake`, `git`), purge the Pacman package download cache (`pacman -Scc`), and clear temporary directories to reclaim ~600MB of usable root drive space for the user.
* **Host Co-existence Clock Sync:** Explicitly run hardware clock adjustments mapping the hardware real-time clock to local time (`hwclock --systohc --localtime`).
* **Strict Chroot Dismantling Order:** Prior to unmounting root, decouple all dynamic system mounts (`/dev/pts`, `/dev`, `/proc`, `/sys`) in strict reverse-nested order utilizing lazy unmounting (`umount -lf`).

---

## FASE 2: BOOT USB & 2-PARTITION LAYOUT GENERATION

### Partitioning Scheme (2-Partition GPT Layout)
When a physical USB device is targeted, the disk is formatted with a GPT partition table containing two distinct partitions:
1. **P1 (FAT32 - Windows Data Volume):** Sized to occupy all capacity up to the last 4GB. Label: `BLNDX_DATA`. Formatted as FAT32 so that Windows can natively read/write data to the USB drive without error prompts.
2. **P2 (FAT32 - Unified EFI/Boot Volume):** Formatted as FAT32 with the ESP flag, sized ~4 GB at the end of the disk. Label: `BLNDX_BOOT`. Holds the Linux kernel (`vmlinuz-linux`), custom initramfs (`initramfs-linux.img`), encrypted BitLocker LUKS container (`keys.luks`), template root filesystem image (`blindux.fs.img`), and portable GRUB binaries.

### Securing the BitLocker Key (LUKS2 Container)
* If a BitLocker key was provided in Phase 0:
    * Create a **32MB** container file `/keys.luks` inside partition P2 (`BLNDX_BOOT`).
    * Format and encrypt it using `cryptsetup luksFormat --type luks2` with the master passphrase defined by the user.
    * Format the container with `ext4`, mount it temporarily, write the BitLocker recovery key to `bitlocker.key`, unmount, and close the LUKS mapping.
* If no BitLocker key was provided, omit the creation of `/keys.luks` entirely.

### Populating USB Partition P2
* Copy the kernel (`vmlinuz-linux`), custom initramfs (`initramfs-linux.img`), template `blindux.fs.img`, and `/keys.luks` (if generated) into partition P2.

---

## FASE 3: BOOTLOADER & ISOLATED CHROOT INITRAMFS CONFIGURATION

### Host-Isolated Bootloader Installation (Chroot Bind-Mount Pattern)
* To guarantee 100% host isolation and prevent contamination of host GRUB modules or host NVRAM:
  * Bind-mount the USB boot partition (`${USB_MOUNT_DIR}`) into the target chroot environment at `${MOUNT_DIR}/mnt/usb_boot`.
  * Execute `grub-install` strictly via `chroot "${MOUNT_DIR}"` using target binaries (`--target=x86_64-efi --efi-directory=/mnt/usb_boot --boot-directory=/mnt/usb_boot/boot --bootloader-id="BOOT" --removable --recheck`).
  * Unmount `${MOUNT_DIR}/mnt/usb_boot` immediately after installation.

### GRUB Configuration (`grub.cfg`)
* Configure GRUB inside USB partition P2 (`BLNDX_BOOT`) to pass custom parameters to the kernel:
    * `root=auto`: Transient search parameter triggering smart storage discovery during early boot.
    * `root.img=`: Absolute path to the container file on the host target volume (e.g., `/blindux/blindux.fs.img`).
    * `target.size=`: Initial expansion size in GB.

### Custom Initramfs Hooks & Dynamic Compilation
* **Initramfs Packaging (`/etc/initcpio/install/blindux`):**
  * Explicitly bundles kernel modules (`fuse`, `loop`, `ext4`, `vfat`, `nls_cp437`, `nls_iso8859_1`).
  * Explicitly bundles binaries and their runtime dependencies (`dislocker`, `dislocker-fuse`, `dislocker-file`, `ntfs-3g`, `mount.ntfs-3g`, `mount.ntfs`, `cryptsetup`, `resize2fs`, `truncate`, `blkid`, `losetup`, `lsblk`).
* **Hook Registration:** Register `blindux` inside the `HOOKS=(...)` array in `/etc/mkinitcpio.conf`.
* **Early Boot Runtime Logic (`/etc/initcpio/hooks/blindux`):**
  1. Parse `root`, `root.img`, and `target.size` from `/proc/cmdline`.
  2. Locate and mount the USB boot partition (`BLNDX_BOOT`) to `/boot`.
  3. **Check for `keys.luks` presence:**
      * **If `/keys.luks` exists:** Prompt the user for the master passphrase, open `/boot/keys.luks`, read `bitlocker.key`, scan block devices for BitLocker signatures (`TYPE="BitLocker"`), unlock via `dislocker`, and mount the resulting `dislocker-file` via `ntfs-3g /mnt/dislocker/dislocker-file /mnt/host`.
      * **If `/keys.luks` does NOT exist:** Scan for unencrypted NTFS partitions (`blkid -t TYPE=ntfs`) and mount directly via `ntfs-3g`.
  4. **Target In-Situ Image Provisioning Check:**
      * Check if target image `/mnt/host/${root.img}` exists on the host drive.
      * **If NOT present (First Target Boot):**
          * Copy `/boot/blindux.fs.img` from USB to `/mnt/host/${root.img}`.
          * Expand image file to target size using `truncate -s "${target.size}G"`.
          * Expand filesystem using `resize2fs`.
  5. Mount target image (`root.img`) as a loop device (`/dev/loopX`).
  6. Pivot root into loop device (`mount "$LOOP_TARGET" /new_root`) to complete OS boot.

---

## FASE 4: RUNTIME AUTOMATION & SYSTEM LIFE CYCLE

### Post-Boot UUID Consolidation (`blindux-persist.service`)
* One-shot systemd service running after boot: Detects the active host partition UUID, mounts `/boot` on USB, and updates `root=auto` in `/boot/grub/grub.cfg` to `root=UUID=<HOST_UUID>` for faster subsequent boots.

### Background Disk Monitor (`blindux-space-monitor.service` & `.timer`)
* Systemd service and timer checking available root container space every 10 minutes.
* Logs warnings if available space inside `blindux.fs.img` falls below 1GB.

### Kernel Update Sync Hook (`99-blindux-sync.hook`)
* Pacman PostTransaction hook triggering on `linux` kernel updates.
* Mounts USB `/boot` if present and syncs the newly installed kernel and initramfs to the USB drive.

---

## FASE 5: TESTING & VALIDATION WORKFLOW

* **Initial Boot Test:** Verify boot sequence: GRUB load -> Detect encryption context -> Mount Host -> Image Copy/Expand (if initial boot) -> Loopback mounting -> Active OS.
* **Hot-Expansion Test:** Artificially fill the filesystem to verify disk space monitor alerts.
* **Kernel Upgrade Simulation:** Run `pacman -S linux`, verify USB kernel binary synchronization.