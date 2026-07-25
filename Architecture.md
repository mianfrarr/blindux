# BLINDUX: SYSTEM ARCHITECTURE & SKELETON SPECIFICATION (v0.1.0)

## PREREQUISITES & RENDERED OUTPUT GOVERNANCE
1. **Language Compliance Constraints:** All architecture specifications, skeletons, logs, prompts, error handling and code comments within this document and the derived installer scripts MUST be written strictly in English (US).
2. **Host Privilege Requirements:** Must be executed with root privileges (`sudo`) under WSL or any standard Linux distribution.
3. **Environment Assets:** Host environment must feature standard raw image utilities, loop device management tools, `cryptsetup`, `dislocker`, and `ntfs-3g`.
4. **Markdown Code Block Enforcement:** As an absolute structural constraint, this entire architecture document, its technical specifications, and any derived deployment scripts MUST ALWAYS be shared with the Creator inside a clean Markdown code block to guarantee direct, unpolluted portability and seamless downloading.

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

### Interactive Input Gathering (If no previous state found)
1. **Welcome Title:** Display a clean, single-line text title: `--- Blindux Installer ---`.
2. **Target USB Selector (Bash Syntax Enforcement):** Scan and list available USB block devices (displaying size, label, and filesystem). **Strict constraint:** Ensure the `local` declaration of variables and array definitions/assignments (such as `mapfile`) are treated as separate identifiers and executed in isolated sequential commands to prevent syntax initialization rejections. Provide an option to select a device **OR select `Refresh`** in case the USB was not yet connected to the computer.
3. **Distro Selector:** Choose the target base system (Arch Linux / Debian / Fedora).
4. **Image Size Picker (Validation Logic):** 
    * Prompt the user to indicate the initial target size in GB for the `blindux.fs.img` once deployed to the host NTFS partition.
    * Default value is **20**.
    * **Validation constraints:** Loop and re-prompt the user if the input is `0`, if it is not a valid integer number, or if the available free space in the host directory `./` is less than the specified size in GB.
5. **LUKS Container Passphrase (Master Passphrase):** Securely prompt the user to define a master passphrase. This passphrase will encrypt both the local state session cache file and the final file containing the BitLocker key on the `/boot` USB storage.
6. **BitLocker Key Input:** Securely prompt the user for their Windows BitLocker Recovery Key (masking input on-screen). If left empty, proceed assuming the host Windows partition is unencrypted.

---

## FASE 1: TEMPLATE IMAGE PROVISIONING & STRAPPED INSTALLATION (COMPRESSION OPTIMIZED)

### Virtual Disk Template Creation
* Create a minimal RAW image file named `./blindux/blindux.fs.img` (~2GB sparse template) using `truncate`.
* **Host Filesystem Ownership:** Immediately after the raw `.img` allocation (and any host-side compressed outputs), ownership must be structural-fixed to match the original user (`$SUDO_USER`), avoiding root-locked files in the host directory tree.
* Format `./blindux/blindux.fs.img` with the filesystem selected by the user (e.g., `ext4`, `btrfs`, `xfs`) directly as a loopback device, without partition tables.

### Base Bootstrap (Isolated Matrix & Non-Interactive Constraint)
* Mount `./blindux/blindux.fs.img` to a temporary mount point (`/mnt/blindux_root`).
* **Distribution Agnosticism Isolation:** To avoid polluting or picking up mirror configurations, repository branches, or ambiguous packages from a modified host distribution, the bootstrap execution sequence must be heavily isolated:
    * **Arch Linux:** Generate a clean standalone temporary `pacman.conf` file referencing an isolated temporary `mirrorlist` file pointing strictly to upstream official Arch Linux CDN/mirrors (`geo.mirror.pkgbuild.com`), pass this architecture mapping manually to `pacstrap` via the configuration overriding flag (`-C`), and append the non-interactive indicator (`--noconfirm`) to guarantee a fully automated, uninterrupted kernel bootstrap (`base linux linux-firmware base-devel`).
    * **Debian / Fedora:** Utilize their respective explicit, agnostic isolated flags (such as `--releasever` for DNF or strict direct HTTP mirrors targets for debootstrap) to completely decouple dependency resolving trees from the host runtime scope.

### Initial Configuration & Native CLI Provisioning inside Chroot
* Configure system locales, timezone, network defaults, and user accounts.
* **Dynamic Mount Mapping (Crucial Pseudo-TTY Support):** Bind-mount host system descriptors (`/dev`, `/proc`, `/sys`) into the chroot workspace. Crucially, the virtual pseudo-terminal subsystem **`/dev/pts`** must be explicitly bind-mounted to prevent terminal allocation errors.
* **Dual Boot Directories:** Ensure a local `/boot` directory is fully populated with the kernel and standard configuration files *inside* `blindux.fs.img` so that the local package manager functions correctly during future updates.
* Install necessary target system packages: `dislocker`, `ntfs-3g`, `cryptsetup`, and basic recovery packages.
* **Host Co-existence Clock Sync:** To ensure dual-boot operations do not corrupt or offset the host Windows system clock, explicitly run hardware clock adjustments mapping the hardware real-time clock to local time (`hwclock --systohc --localtime`).
* **Zero-Maintenance Post-Installation Logic (Minimal TUI / CLI Native Setup):** To bypass dependencies on D-Bus/Systemd PID 1 inside the chroot, all references to upstream automated wizards (`archinstall`, `tasksel`) are stripped. The installer provisions a predictable, clean command-line base environment using native package management commands (`pacman`, `apt-get`, `dnf`) to configure hostname, basic network management frameworks, and system language parameters non-interactively.
* **Strict Chroot Dismantling Order:** Prior to invoking the final root unmount sequence, all dynamic system mounts (`/dev/pts`, `/dev`, `/proc`, `/sys`) must be decoupled in a strict, explicit reverse-nested order utilizing lazy/forced unmounting (`umount -lf`) to prevent silent directory locks that block subsequent image operations.

---

## FASE 2: BOOT USB & 3-PARTITION LAYOUT GENERATION

### Partitioning Scheme (3-Partition GPT Layout)
When a physical USB device is targeted, the disk is formatted with a GPT partition table containing three distinct partitions:
1. **P1 (FAT32 - Windows Data Volume):** Occupies all remaining USB capacity not used by the Blindux boot and image partitions. Formatted as FAT32 so that Windows can natively read/write data to the USB drive without error prompts.
2. **P2 (EXT4 - Blindux `/boot` Volume):** Formatted as EXT4, probably 4 GB size. Holds the Linux kernel (`vmlinuz-linux`), custom initramfs (`initramfs-linux.img`), encrypted BitLocker LUKS container (`/boot/keys.luks`), and the template root filesystem image (`blindux.fs.img`).
3. **P3 (FAT32 - EFI System Partition `/boot/efi`):** Formatted as FAT32 with the ESP flag. Hosts the portable GRUB2 EFI bootloader payload (`grub-install --target=x86_64-efi --removable`).

### Securing the BitLocker Key (LUKS2 Alignment Fix)
* If a BitLocker key was provided in Phase 0:
    * Create a **32MB** container file `/boot/keys.luks` inside partition P2 (`/boot`) (32MB handles the high metadata payload size overhead of modern LUKS2/Argon2id headers without data starvation or activation errors).
    * Format and encrypt it using `cryptsetup luksFormat --type luks2` with the master passphrase defined by the user.
    * Store the host Windows BitLocker recovery key securely *inside* this encrypted LUKS container.
* If no BitLocker key was provided, omit the creation of `/boot/keys.luks` entirely.

### Populating USB Partition P2
* Copy the kernel (`vmlinuz`), custom initramfs, template `blindux.fs.img`, and `/boot/keys.luks` into partition P2 (`/boot`).

---

## FASE 3: BOOTLOADER & CUSTOM INITRAMFS CONFIGURATION

### Image Mount Protection & Validation
* Before modifying core assets within the virtual system structure, the installation script must query active mount points (`findmnt`). If the target system image descriptor path is already mapped onto the local mount point, it must automatically reuse the active mount structure instead of re-triggering a failing concurrent loop constraint.

### GRUB Configuration (`grub.cfg`)
* Configure GRUB inside USB partition P3 (`/boot/efi`) to pass the custom parameters to the kernel:
    * `root=`: Indicates the parent host partition containing the target Windows NTFS filesystem (e.g., `/dev/sda2`, `UUID=xxxx-xxxx`, `LABEL=WHATEVER`).
    * `root.img=`: Indicates the absolute path to the `.img` file within that host partition (e.g., `/blindux/blindux.fs.img`).
    * `target.size=`: Target size in GB for image auto-expansion during initial boot setup.

### Embedded `/etc/fstab` inside Initramfs (Self-Contained Mounting)
* During installation, write the USB partition P2 UUID to a minimal `/etc/fstab` file inside the target environment:
  `UUID=USB_BOOT_P2_UUID   /boot   ext4   noauto,nofail,defaults   0   2`
* Configure `mkinitcpio` (or the corresponding initramfs builder) to include `/etc/fstab` inside the generated initramfs image (`FILES=(/etc/fstab)` in `/etc/mkinitcpio.conf`).

### Custom Initramfs Hooks & Dynamic Compilation (Adaptive Environment Setup)
* **Dynamic Kernel Preset Parsing (Arch/Manjaro Host Fix):** When compiling the initramfs using `mkinitcpio`, the script must avoid hardcoded `-p linux` flags. Instead, it must dynamically scan `/etc/mkinitcpio.d/*.preset` inside the chroot to detect the exact active kernel preset installed (e.g., `linux61.preset`, `linux-lts.preset`). If multiple exist, pick the first match. If none are found, fall back to compiling directly via explicit output path parameters and module tree folder lookups.
* **Hook Injection Framework:** Ensure `blindux` is injected cleanly into the `HOOKS=(...)` array within `/etc/mkinitcpio.conf` immediately following the `udev` instruction.
* **Early Boot Runtime Logic (Target In-Situ Copy & Expansion):** Inject an early boot hook executing this sequence:
    1. Parse `root`, `root.img`, and `target.size` from `/proc/cmdline`.
    2. Mount the USB `/boot` partition (P2) by running: `mount /boot` (which reads the embedded `/etc/fstab` in memory).
    3. **Check for `keys.luks` presence:**
        * **If `/boot/keys.luks` exists:** Prompt the user for the master passphrase to open the LUKS container, read the decrypted BitLocker key, and mount the host partition via `dislocker` followed by `ntfs-3g`.
        * **If `/boot/keys.luks` does NOT exist:** Assume the host partition is unencrypted. Mount the NTFS host partition directly via `ntfs-3g`.
    4. **Target In-Situ Image Provisioning Check:**
        * Check if the target image `/mnt/host_final/${host_img}` exists on the NTFS drive.
        * **If NOT present (First Target Boot):**
            * Copy `/boot/blindux.fs.img` from USB P2 to `/mnt/host_final/${host_img}`.
            * Expand the image file to the configured target size using `truncate -s "${target_size}G" "/mnt/host_final/${host_img}"`.
            * Expand the filesystem using `resize2fs "/mnt/host_final/${host_img}"`.
    5. Mount the target image (`root.img`) as a loop device (`/dev/loopX`).
    6. Pivot root (`switch_root`) into the loop device to complete the OS boot.

---

## FASE 4: RUNTIME AUTOMATION & SYSTEM LIFE CYCLE

### USB Auto-Unmount
* Configure the initramfs/systemd to unmount the physical USB storage once the pivot root is complete, allowing safe physical removal during runtime.

### Background Disk Monitor
* Install a background service (`systemd` + `.timer`) inside the system running every 10 minutes.
* Check available space within `blindux.fs.img`. If free space falls below 1GB, trigger a desktop notification (`notify-send`) alerting the user.

### Automated Image Resizing (Safe Expansion)
* Create a systemd service that monitors free space. If the system has less than 5GB of free space left inside the loop root (and the underlying NTFS volume has enough space), the script will expand the `blindux.fs.img` file dynamically during the boot or shutdown sequences (via `truncate` + `resize2fs`/`btrfs resize`).

### Kernel Update Sync Hook (Agnostic fstab)
* Deploy a package manager hook (e.g., a Pacman hook) that triggers whenever a kernel/initramfs update occurs.
* **No local /etc/fstab dependency:** The hook reads `/proc/cmdline` to find the current active boot USB's UUID (via the embedded `/etc/fstab` inside the loaded initramfs) or scans `blkid` for the unique Blindux USB partition.
* **Notification & Loop fallback:** If the USB is missing, prompt the user with a desktop notification (`notify-send`) requesting its connection. Re-check every 30 seconds. Once detected, automatically mount the USB, copy the updated kernel/initramfs, update the embedded `/etc/fstab` if UUID changed, unmount the USB, and display a confirmation notification.

---

## FASE 5: TESTING & VALIDATION WORKFLOW

* **Initial Boot Test:** Verify boot sequence: GRUB load -> Detect encryption context -> Mount Host -> Image Copy/Expand (if initial boot) -> Loopback mounting -> Active Desktop.
* **Hot-Expansion Test:** Artificially fill the filesystem to trigger the safe boot/shutdown auto-growth and test the 10-minute warning notifications.
* **Kernel Upgrade Simulation:** Run a mock or real kernel update, disconnect the USB to verify the reconnection prompt, connect it back, and verify the files on the USB are updated flawlessly.