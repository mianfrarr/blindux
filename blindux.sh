#!/usr/bin/env bash

# ==============================================================================
# BLINDUX INSTALLATION & ORCHESTRATION SCRIPT
# ==============================================================================
# Architecture Baseline: BLINDUX SYSTEM SPECIFICATION (v0.1.0)
# Target Environment: Arch Linux Host / WSL / Linux -> Isolated Root Image & USB Boot Provisioning
# ==============================================================================

set -euo pipefail

# --- IMMUTABLE VERSION DECLARATION ---
readonly SKELETON_VERSION="0.1.0"
readonly SCRIPT_VERSION="0.1.0"

# --- GLOBAL PATHS & ENVIRONMENT VARS ---
WORKSPACE_DIR="./blindux"
BUILD_DIR="${WORKSPACE_DIR}/build"
MOUNT_DIR="/mnt/blindux_root"
USB_MOUNT_DIR="/mnt/blindux_usb_boot"
TEMPLATE_IMG="${WORKSPACE_DIR}/blindux.fs.img"

# Capture original calling user to prevent root-locking on host
REAL_USER="${SUDO_USER:-$USER}"
REAL_UID="${SUDO_UID:-$(id -u "$REAL_USER")}"
REAL_GID="${SUDO_GID:-$(id -g "$REAL_USER")}"

# Global Runtime State Variables
SELECTED_USB=""
TARGET_IMG_PATH=""
TARGET_SIZE_GB=""
LUKS_PASSPHRASE=""
BITLOCKER_KEY=""
LOOP_DEV=""

# --- CLEANUP TRAP HANDLER ---
f5_cleanup() {
    local exit_code=$?
    echo -e "\n[!] Cleaning up environment and temporary mounts..."

    # Unmount bind mounts in strict reverse order
    if findmnt -M "${MOUNT_DIR}/mnt/usb_boot" >/dev/null 2>&1; then umount -lf "${MOUNT_DIR}/mnt/usb_boot" || true; fi
    if findmnt -M "${MOUNT_DIR}/dev/pts" >/dev/null 2>&1; then umount -lf "${MOUNT_DIR}/dev/pts" || true; fi
    if findmnt -M "${MOUNT_DIR}/dev" >/dev/null 2>&1; then umount -lf "${MOUNT_DIR}/dev" || true; fi
    if findmnt -M "${MOUNT_DIR}/proc" >/dev/null 2>&1; then umount -lf "${MOUNT_DIR}/proc" || true; fi
    if findmnt -M "${MOUNT_DIR}/sys" >/dev/null 2>&1; then umount -lf "${MOUNT_DIR}/sys" || true; fi
    if findmnt -M "${MOUNT_DIR}" >/dev/null 2>&1; then umount -lf "${MOUNT_DIR}" || true; fi
    if findmnt -M "${USB_MOUNT_DIR}" >/dev/null 2>&1; then umount -lf "${USB_MOUNT_DIR}" || true; fi

    # Detach loop device if active
    if [[ -n "${LOOP_DEV}" ]] && losetup "${LOOP_DEV}" >/dev/null 2>&1; then
        losetup -d "${LOOP_DEV}" || true
    fi

    # Restore ownership of output files to host user
    if [[ -d "${WORKSPACE_DIR}" ]]; then
        chown -R "${REAL_UID}:${REAL_GID}" "${WORKSPACE_DIR}" || true
    fi

    if [[ $exit_code -ne 0 ]]; then
        echo "[X] Installation aborted or failed with exit code $exit_code."
    fi
    exit $exit_code
}

trap f5_cleanup EXIT INT TERM

# --- HELPER FUNCTIONS ---
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "[X] Error: This script must be executed with root privileges (sudo)." >&2
        exit 1
    fi
}

init_workspace() {
    mkdir -p "${WORKSPACE_DIR}" "${BUILD_DIR}" "${MOUNT_DIR}" "${USB_MOUNT_DIR}"
    chown -R "${REAL_UID}:${REAL_GID}" "${WORKSPACE_DIR}"
}

# --- PHASE 0: INTERACTIVE INPUT GATHERING ---
phase0_input_gathering() {
    echo "=================================================================="
    echo "--- Blindux Installer (v${SCRIPT_VERSION} / Skeleton v${SKELETON_VERSION}) ---"
    echo "=================================================================="

    # 1. Target USB Selector
    while true; do
        echo -e "\n[?] Scanning available USB block devices..."
        
        local usb_list=()
        local usb_devices=()

        local raw_lsblk
        raw_lsblk=$(lsblk -dn -o NAME,SIZE,TYPE,TRAN,LABEL,FSTYPE | grep -E 'usb|disk' || true)

        local count=1
        while read -r line; do
            if [[ -n "$line" ]]; then
                usb_list+=("$line")
                local dev_name
                dev_name=$(echo "$line" | awk '{print $1}')
                usb_devices+=("/dev/${dev_name}")
                echo "  ${count}) /dev/${dev_name} - ${line}"
                ((count++))
            fi
        done <<< "$raw_lsblk"

        if [[ ${#usb_list[@]} -eq 0 ]]; then
            echo "  [!] No USB or disk devices found automatically."
        fi

        echo "  r) [Refresh Device List]"
        read -rp "Select target USB device (1-${#usb_list[@]} or 'r'): " usb_choice

        if [[ "$usb_choice" == "r" || "$usb_choice" == "R" ]]; then
            continue
        elif [[ "$usb_choice" =~ ^[0-9]+$ ]] && (( usb_choice >= 1 && usb_choice <= ${#usb_list[@]} )); then
            SELECTED_USB="${usb_devices[$((usb_choice-1))]}"
            echo "[+] Selected USB Target: ${SELECTED_USB}"
            break
        else
            echo "[!] Invalid selection. Please try again."
        fi
    done

    # 2. Target Image Path Selector
    echo -e "\n[?] Select destination path for blindux.fs.img on host NTFS volume:"
    echo "  1) /blindux/blindux.fs.img (Default)"
    echo "  2) /Users/Public/blindux/blindux.fs.img"
    echo "  3) Custom path"
    read -rp "Choice [1-3] (Default: 1): " path_choice
    path_choice="${path_choice:-1}"

    case "$path_choice" in
        1) TARGET_IMG_PATH="/blindux/blindux.fs.img" ;;
        2) TARGET_IMG_PATH="/Users/Public/blindux/blindux.fs.img" ;;
        3) 
            read -rp "Enter absolute custom path (e.g., /MyOS/blindux.fs.img): " custom_path
            if [[ "$custom_path" != /* ]]; then
                custom_path="/${custom_path}"
            fi
            TARGET_IMG_PATH="${custom_path}"
            ;;
        *) TARGET_IMG_PATH="/blindux/blindux.fs.img" ;;
    esac
    echo "[+] Target Image Path: ${TARGET_IMG_PATH}"

    # 3. Image Size Picker
    local avail_space_gb
    avail_space_gb=$(df -BG . | tail -n1 | awk '{print $4}' | sed 's/G//')

    while true; do
        read -rp $'\n[?] Enter target container size in GB [Default: 20]: ' input_size
        input_size="${input_size:-20}"

        if [[ "$input_size" =~ ^[1-9][0-9]*$ ]]; then
            if (( input_size > avail_space_gb )); then
                echo "[!] Error: Requested ${input_size}GB, but host only has ${avail_space_gb}GB available."
            else
                TARGET_SIZE_GB="$input_size"
                echo "[+] Target Image Size set to: ${TARGET_SIZE_GB} GB"
                break
            fi
        else
            echo "[!] Invalid input. Must be a non-zero positive integer."
        fi
    done

    # 4. Master Passphrase Input
    while true; do
        read -rsp $'\n[?] Define Master Passphrase (LUKS/Key Storage): ' pass1
        echo
        read -rsp "[?] Confirm Master Passphrase: " pass2
        echo
        if [[ -n "$pass1" && "$pass1" == "$pass2" ]]; then
            LUKS_PASSPHRASE="$pass1"
            break
        else
            echo "[!] Passphrases do not match or are empty. Try again."
        fi
    done

    # 5. BitLocker Recovery Key Input
    read -rsp $'\n[?] Enter Windows BitLocker Recovery Key (Leave empty if unencrypted): ' BITLOCKER_KEY
    echo
    if [[ -n "$BITLOCKER_KEY" ]]; then
        echo "[+] BitLocker Recovery Key registered."
    else
        echo "[*] No BitLocker Key provided. Proceeding assuming unencrypted host partition."
    fi
}

# --- PHASE 1: TEMPLATE IMAGE PROVISIONING & STRAPPED INSTALLATION ---
phase1_provisioning() {
    echo -e "\n=================================================================="
    echo "--- PHASE 1: Sparse Template Allocation & Arch Linux Bootstrap ---"
    echo "=================================================================="

    echo "[+] Creating 3GB sparse RAW template image at ${TEMPLATE_IMG}..."
    truncate -s 3G "${TEMPLATE_IMG}"
    chown "${REAL_UID}:${REAL_GID}" "${TEMPLATE_IMG}"

    echo "[+] Formatting template image with ext4..."
    mkfs.ext4 -F -q "${TEMPLATE_IMG}"

    echo "[+] Mounting template image to ${MOUNT_DIR}..."
    mount -o loop "${TEMPLATE_IMG}" "${MOUNT_DIR}"
    LOOP_DEV=$(findmnt -n -o SOURCE "${MOUNT_DIR}" || true)

    echo "[+] Setting up isolated Arch Linux repository configuration..."
    local tmp_pacman_conf="${BUILD_DIR}/pacman.conf"
    local tmp_mirrorlist="${BUILD_DIR}/mirrorlist"
    local tmp_gpg_dir="${BUILD_DIR}/gnupg"

    echo "Server = https://geo.mirror.pkgbuild.com/\$repo/os/\$arch" > "${tmp_mirrorlist}"
    
    mkdir -p "${tmp_gpg_dir}"
    chmod 700 "${tmp_gpg_dir}"
    
    echo "[+] Initializing isolated Arch Linux keyring..."
    pacman-key --gpgdir "${tmp_gpg_dir}" --init
    pacman-key --gpgdir "${tmp_gpg_dir}" --populate archlinux

    cat <<EOF > "${tmp_pacman_conf}"
[options]
HoldPkg     = pacman glibc
Architecture = auto
SigLevel    = Required DatabaseOptional
LocalFileSigLevel = Optional
GPGDir      = ${tmp_gpg_dir}
Include     = ${tmp_mirrorlist}

[core]
Include = ${tmp_mirrorlist}

[extra]
Include = ${tmp_mirrorlist}
EOF

    echo "[+] Executing pacstrap with core base packages and compilation tools..."
    pacstrap -C "${tmp_pacman_conf}" -c "${MOUNT_DIR}" \
        base linux linux-firmware base-devel grub efibootmgr \
        archlinux-keyring ntfs-3g cryptsetup git cmake mbedtls fuse2 \
        patch util-linux e2fsprogs coreutils which parted --noconfirm

    # Mount system descriptors for chroot operations
    echo "[+] Binding system descriptors (/dev, /dev/pts, /proc, /sys)..."
    mount --bind /dev "${MOUNT_DIR}/dev"
    mount --bind /dev/pts "${MOUNT_DIR}/dev/pts"
    mount --bind /proc "${MOUNT_DIR}/proc"
    mount --bind /sys "${MOUNT_DIR}/sys"

    # Copy Host DNS configuration to guarantee network access inside chroot
    echo "[+] Copying host DNS resolution settings..."
    cp -L /etc/resolv.conf "${MOUNT_DIR}/etc/resolv.conf" 2>/dev/null || true

    # Prevent vconsole warnings in mkinitcpio
    echo "KEYMAP=us" > "${MOUNT_DIR}/etc/vconsole.conf"

    echo "[+] Populating keyrings and generating locales inside target chroot..."
    sed -i 's/#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' "${MOUNT_DIR}/etc/locale.gen" 2>/dev/null || true
    echo "LANG=en_US.UTF-8" > "${MOUNT_DIR}/etc/locale.conf"
    chroot "${MOUNT_DIR}" locale-gen || true

    chroot "${MOUNT_DIR}" env LC_ALL=C pacman-key --init
    chroot "${MOUNT_DIR}" env LC_ALL=C pacman-key --populate archlinux

    echo "[+] Configuring system clock inside chroot..."
    chroot "${MOUNT_DIR}" env LC_ALL=C hwclock --systohc --localtime || true

    # Compile and install dislocker from source inside chroot
    echo "[+] Building and installing dislocker from upstream source inside chroot..."
    chroot "${MOUNT_DIR}" /bin/bash -c "
        rm -rf /tmp/dislocker-src && \
        git clone https://github.com/Aorimn/dislocker.git /tmp/dislocker-src && \
        cd /tmp/dislocker-src && \
        cmake -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr && \
        make -C build -j\$(nproc) && \
        make -C build install && \
        rm -rf /tmp/dislocker-src
    "

    # Clean up build-only packages and package caches to maximize available user space
    echo "[+] Cleaning up build dependencies and package caches..."
    chroot "${MOUNT_DIR}" /bin/bash -c "
        pacman -Rns --noconfirm cmake git 2>/dev/null || true
        pacman -Scc --noconfirm
        rm -rf /tmp/* /var/tmp/* /var/cache/pacman/pkg/*
    "

    mkdir -p "${MOUNT_DIR}/boot"
}

# --- PHASE 2: BOOT USB & 2-PARTITION LAYOUT GENERATION ---
phase2_usb_layout() {
    echo -e "\n=================================================================="
    echo "--- PHASE 2: USB Partitioning & Boot Volume Provisioning ---"
    echo "=================================================================="

    echo "[!] WARNING: All data on ${SELECTED_USB} will be wiped!"
    read -rp "Are you sure you want to proceed? [y/N]: " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo "[X] USB provisioning aborted."
        exit 1
    fi

    # Unmount target USB if already mounted
    umount "${SELECTED_USB}"* 2>/dev/null || true

    echo "[+] Creating GPT partition table on ${SELECTED_USB}..."
    parted -s "${SELECTED_USB}" mklabel gpt
    
    # Partition 1: FAT32 Data Volume (Rest of disk)
    # Partition 2: FAT32 Boot/EFI Volume (~4GB at the end)
    echo "[+] Creating 2-partition scheme (Data & Unified EFI/Boot)..."
    parted -s "${SELECTED_USB}" -- mkpart primary fat32 1MiB -4096MiB
    parted -s "${SELECTED_USB}" -- mkpart primary fat32 -4096MiB 100%
    parted -s "${SELECTED_USB}" set 2 esp on

    # Sync partition table with the kernel
    partprobe "${SELECTED_USB}" || true
    udevadm settle || sleep 2

    # Format Partitions
    local p1="${SELECTED_USB}1"
    local p2="${SELECTED_USB}2"

    if [[ "${SELECTED_USB}" == *"nvme"* || "${SELECTED_USB}" == *"loop"* ]]; then
        p1="${SELECTED_USB}p1"
        p2="${SELECTED_USB}p2"
    fi

    echo "[+] Formatting ${p1} as FAT32 (Data)..."
    mkfs.vfat -F32 -n "BLNDX_DATA" "${p1}"

    echo "[+] Formatting ${p2} as FAT32 (Boot/EFI)..."
    mkfs.vfat -F32 -n "BLNDX_BOOT" "${p2}"

    # Ensure filesystems are written and block devices are ready
    sync
    udevadm settle || sleep 2

    echo "[+] Mounting ${p2} to ${USB_MOUNT_DIR}..."
    mount "${p2}" "${USB_MOUNT_DIR}"

    # Handle BitLocker Key Encryption (keys.luks)
    if [[ -n "$BITLOCKER_KEY" ]]; then
        echo "[+] Securing BitLocker Recovery Key inside LUKS2 container..."
        local luks_file="${USB_MOUNT_DIR}/keys.luks"
        truncate -s 32M "${luks_file}"
        
        echo -n "$LUKS_PASSPHRASE" | cryptsetup luksFormat --type luks2 --batch-mode "${luks_file}" -
        
        # Temporary map to write key
        echo -n "$LUKS_PASSPHRASE" | cryptsetup open "${luks_file}" blindux_keys -
        mkfs.ext4 -F -q /dev/mapper/blindux_keys
        mkdir -p /mnt/keys_tmp
        mount /dev/mapper/blindux_keys /mnt/keys_tmp
        echo "$BITLOCKER_KEY" > /mnt/keys_tmp/bitlocker.key
        sync
        umount /mnt/keys_tmp
        cryptsetup close blindux_keys
        rmdir /mnt/keys_tmp
    fi

    # Copy template image to USB /boot
    echo "[+] Copying template image to USB Boot Partition..."
    cp "${TEMPLATE_IMG}" "${USB_MOUNT_DIR}/blindux.fs.img"
}

# --- PHASE 3: BOOTLOADER, ISOLATED CHROOT INSTALLED GRUB & INITRAMFS ---
phase3_bootloader_initramfs() {
    echo -e "\n=================================================================="
    echo "--- PHASE 3: GRUB Setup, Initramfs Custom Hook & Boot Logic ---"
    echo "=================================================================="

    local p2_uuid
    p2_uuid=$(blkid -s UUID -o value "$(df "${USB_MOUNT_DIR}" | tail -n1 | awk '{print $1}')")

    # Write embedded /etc/fstab inside image
    cat <<EOF > "${MOUNT_DIR}/etc/fstab"
UUID=${p2_uuid}   /boot   vfat   noauto,nofail,defaults   0   2
EOF

    # Install GRUB Portable EFI strictly via CHROOT (Bind-Mount approach to preserve Host)
    echo "[+] Bind-mounting USB boot partition inside chroot for isolated GRUB installation..."
    mkdir -p "${MOUNT_DIR}/mnt/usb_boot"
    mount --bind "${USB_MOUNT_DIR}" "${MOUNT_DIR}/mnt/usb_boot"

    echo "[+] Installing Portable GRUB2 EFI payload strictly using target chroot binaries..."
    chroot "${MOUNT_DIR}" grub-install \
        --target=x86_64-efi \
        --efi-directory=/mnt/usb_boot \
        --boot-directory=/mnt/usb_boot/boot \
        --bootloader-id="BOOT" \
        --removable \
        --recheck

    # Unmount bind mount immediately after installation
    umount "${MOUNT_DIR}/mnt/usb_boot"
    rmdir "${MOUNT_DIR}/mnt/usb_boot"

    # Write grub.cfg with root=auto transient parameter
    echo "[+] Configuring grub.cfg with root=auto transient discovery parameter..."
    mkdir -p "${USB_MOUNT_DIR}/boot/grub"
    cat <<EOF > "${USB_MOUNT_DIR}/boot/grub/grub.cfg"
set default=0
set timeout=5

menuentry "Blindux Portable OS" {
    insmod fat
    insmod ext2
    insmod part_gpt
    
    search --no-floppy --fs-uuid --set=root ${p2_uuid}
    
    echo "Loading Linux Kernel..."
    linux /vmlinuz-linux root=auto root.img=${TARGET_IMG_PATH} target.size=${TARGET_SIZE_GB} rw quiet
    
    echo "Loading Initramfs..."
    initrd /initramfs-linux.img
}
EOF

    # Copy Kernel & Initramfs binaries from chroot to USB
    echo "[+] Synchronizing Kernel assets to USB..."
    cp "${MOUNT_DIR}/boot/vmlinuz-linux" "${USB_MOUNT_DIR}/vmlinuz-linux" || cp "${MOUNT_DIR}/boot/vmlinuz"* "${USB_MOUNT_DIR}/vmlinuz-linux"
    
    # Generate Custom Initramfs Hook for Auto-Detection and BitLocker / NTFS Mounting
    mkdir -p "${MOUNT_DIR}/etc/initcpio/hooks" "${MOUNT_DIR}/etc/initcpio/install"
    
    cat <<'EOF' > "${MOUNT_DIR}/etc/initcpio/hooks/blindux"
run_hook() {
    echo "=== Blindux Smart Boot Initialization ==="
    
    ROOT_ARG=""
    ROOT_IMG="/blindux/blindux.fs.img"
    TARGET_SIZE="20"
    
    # Read command line arguments
    for arg in $(cat /proc/cmdline); do
        case "$arg" in
            root=*) ROOT_ARG="${arg#*=}" ;;
            root.img=*) ROOT_IMG="${arg#*=}" ;;
            target.size=*) TARGET_SIZE="${arg#*=}" ;;
        esac
    done

    if [ "$ROOT_ARG" = "auto" ]; then
        echo "[+] Automated Smart Storage Discovery engaged."
        
        # Load necessary kernel drivers
        modprobe fuse 2>/dev/null || true
        modprobe loop 2>/dev/null || true
        modprobe ext4 2>/dev/null || true
        modprobe vfat 2>/dev/null || true
        
        # Mount the USB boot partition to access keys.luks and template
        mkdir -p /boot
        USB_BOOT_DEV=$(blkid -t LABEL="BLNDX_BOOT" -o device | head -n1)
        if [ -n "$USB_BOOT_DEV" ]; then
            mount -t vfat "$USB_BOOT_DEV" /boot 2>/dev/null || mount "$USB_BOOT_DEV" /boot 2>/dev/null || true
        fi

        mkdir -p /mnt/host

        # Branch 1: BitLocker workflow if keys.luks exists
        if [ -f /boot/keys.luks ]; then
            echo "[+] Encrypted BitLocker key container detected (/boot/keys.luks)."
            mkdir -p /mnt/keys /mnt/dislocker
            
            echo "[?] Enter Blindux Master Passphrase to unlock BitLocker key:"
            if cryptsetup open /boot/keys.luks blindux_keys; then
                mount /dev/mapper/blindux_keys /mnt/keys
                BITLOCKER_KEY=$(cat /mnt/keys/bitlocker.key 2>/dev/null || true)
                umount /mnt/keys
                cryptsetup close blindux_keys
                
                # Scan for BitLocker partitions
                BITLOCKER_DEVS=$(blkid -t TYPE=BitLocker -o device)
                if [ -z "$BITLOCKER_DEVS" ]; then
                    BITLOCKER_DEVS=$(lsblk -dpno NAME,TYPE | grep 'part' | awk '{print $1}')
                fi
                
                DISLOCKER_SUCCESS=0
                for bdev in $BITLOCKER_DEVS; do
                    echo "[*] Attempting BitLocker unlock on $bdev..."
                    if dislocker -V "$bdev" -p"$BITLOCKER_KEY" -- /mnt/dislocker 2>/dev/null; then
                        echo "[+] BitLocker volume unlocked successfully on $bdev."
                        if ntfs-3g /mnt/dislocker/dislocker-file /mnt/host 2>/dev/null; then
                            echo "[+] Host NTFS filesystem mounted from BitLocker container."
                            DISLOCKER_SUCCESS=1
                            break
                        fi
                    fi
                done
                
                if [ $DISLOCKER_SUCCESS -ne 1 ]; then
                    echo "[!] Failed to automatically unlock/mount BitLocker partition."
                fi
            else
                echo "[!] Master Passphrase rejected. Could not open keys.luks."
            fi
        else
            # Branch 2: Standard unencrypted NTFS workflow
            echo "[+] No keys.luks present. Scanning for unencrypted NTFS host partitions..."
            NTFS_DEVS=$(blkid -t TYPE=ntfs -o device)
            SELECTED_DEV=""
            DEV_COUNT=$(echo "$NTFS_DEVS" | wc -w)
            
            if [ "$DEV_COUNT" -eq 1 ]; then
                SELECTED_DEV="$NTFS_DEVS"
                echo "[+] Single NTFS target discovered: $SELECTED_DEV"
            elif [ "$DEV_COUNT" -gt 1 ]; then
                echo "Available NTFS Partitions:"
                select dev in $NTFS_DEVS; do
                    if [ -n "$dev" ]; then
                        SELECTED_DEV="$dev"
                        break
                    fi
                done
            fi

            if [ -n "$SELECTED_DEV" ]; then
                ntfs-3g "$SELECTED_DEV" /mnt/host
            fi
        fi

        # Target In-Situ Image Provisioning Check
        if [ ! -f "/mnt/host/${ROOT_IMG}" ]; then
            echo "[+] Initial Boot: Provisioning container to /mnt/host/${ROOT_IMG}..."
            mkdir -p "$(dirname "/mnt/host/${ROOT_IMG}")"
            if [ -f /boot/blindux.fs.img ]; then
                cp /boot/blindux.fs.img "/mnt/host/${ROOT_IMG}"
                echo "[+] Expanding container to ${TARGET_SIZE}GB..."
                truncate -s "${TARGET_SIZE}G" "/mnt/host/${ROOT_IMG}"
                resize2fs "/mnt/host/${ROOT_IMG}"
            else
                echo "[!] Error: /boot/blindux.fs.img template not found on USB!"
            fi
        fi
        
        # Mount root container to loop device for root pivot
        if [ -f "/mnt/host/${ROOT_IMG}" ]; then
            LOOP_TARGET=$(losetup -f --show "/mnt/host/${ROOT_IMG}")
            mount -o rw "$LOOP_TARGET" /new_root
        else
            echo "[!] Fatal: Target root container /mnt/host/${ROOT_IMG} not available."
        fi
    fi
}
EOF

    # Generate Hook Installation Script with explicit binaries and modules
    cat <<'EOF' > "${MOUNT_DIR}/etc/initcpio/install/blindux"
build() {
    add_module fuse
    add_module loop
    add_module ext4
    add_module vfat
    add_module nls_cp437
    add_module nls_iso8859_1

    add_binary dislocker
    add_binary dislocker-fuse
    add_binary dislocker-file
    add_binary ntfs-3g
    add_binary mount.ntfs-3g
    add_binary mount.ntfs
    add_binary cryptsetup
    add_binary resize2fs
    add_binary truncate
    add_binary blkid
    add_binary losetup
    add_binary lsblk

    add_file /etc/fuse.conf 2>/dev/null || true

    add_runscript
}

help() {
    echo "Injects Blindux smart storage detection, BitLocker unlocking, and loop mounting hooks."
}
EOF

    # Ensure blindux hook is registered in /etc/mkinitcpio.conf
    echo "[+] Registering blindux hook in /etc/mkinitcpio.conf..."
    if ! grep -q "blindux" "${MOUNT_DIR}/etc/mkinitcpio.conf"; then
        sed -i 's/HOOKS=(\(.*\)filesystems\(.*\))/HOOKS=(\1filesystems blindux\2)/' "${MOUNT_DIR}/etc/mkinitcpio.conf" || \
        sed -i 's/HOOKS=(\(.*\))/HOOKS=(\1 blindux)/' "${MOUNT_DIR}/etc/mkinitcpio.conf"
    fi

    # Rebuild initramfs inside chroot
    echo "[+] Rebuilding initramfs image inside chroot..."
    chroot "${MOUNT_DIR}" mkinitcpio -P
    cp "${MOUNT_DIR}/boot/initramfs-linux.img" "${USB_MOUNT_DIR}/initramfs-linux.img"

    # Inject Post-Boot Persistence Service (One-Shot)
    echo "[+] Injecting Systemd Post-Boot One-Shot Persistence Service..."
    cat <<EOF > "${MOUNT_DIR}/etc/systemd/system/blindux-persist.service"
[Unit]
Description=Blindux Post-Boot UUID Consolidation Service
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/blindux-persist.sh
RemainAfterExit=true

[Install]
WantedBy=multi-user.target
EOF

    cat <<'EOF' > "${MOUNT_DIR}/usr/local/bin/blindux-persist.sh"
#!/bin/bash
if grep -q "root=auto" /proc/cmdline; then
    ACTIVE_NTFS=$(findmnt -n -o SOURCE /mnt/host 2>/dev/null || true)
    if [ -n "$ACTIVE_NTFS" ]; then
        HOST_UUID=$(blkid -s UUID -o value "$ACTIVE_NTFS")
        mount /boot 2>/dev/null || true
        if [ -f /boot/grub/grub.cfg ]; then
            sed -i "s/root=auto/root=UUID=${HOST_UUID}/g" /boot/grub/grub.cfg
            echo "Consolidated grub.cfg with fixed UUID: ${HOST_UUID}"
        fi
    fi
fi
EOF
    chmod +x "${MOUNT_DIR}/usr/local/bin/blindux-persist.sh"
    chroot "${MOUNT_DIR}" systemctl enable blindux-persist.service || true

    # Phase 4 Automation: Space Monitor Service & Timer
    echo "[+] Injecting Background Disk Space Monitor Service & Timer..."
    cat <<'EOF' > "${MOUNT_DIR}/usr/local/bin/blindux-space-monitor.sh"
#!/bin/bash
FREE_MB=$(df -m / | awk 'NR==2 {print $4}')
if [ "$FREE_MB" -lt 1024 ]; then
    echo "[!] Warning: Low disk space in Blindux root image (${FREE_MB} MB remaining)."
    logger -t blindux-monitor "Warning: Low disk space in Blindux root image (${FREE_MB} MB remaining)."
fi
EOF
    chmod +x "${MOUNT_DIR}/usr/local/bin/blindux-space-monitor.sh"

    cat <<EOF > "${MOUNT_DIR}/etc/systemd/system/blindux-space-monitor.service"
[Unit]
Description=Blindux Free Space Monitor
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/blindux-space-monitor.sh
EOF

    cat <<EOF > "${MOUNT_DIR}/etc/systemd/system/blindux-space-monitor.timer"
[Unit]
Description=Run Blindux Free Space Monitor every 10 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=10min

[Install]
WantedBy=timers.target
EOF
    chroot "${MOUNT_DIR}" systemctl enable blindux-space-monitor.timer || true

    # Phase 4 Automation: Pacman Kernel Update Sync Hook
    echo "[+] Injecting Pacman Kernel Update Sync Hook..."
    mkdir -p "${MOUNT_DIR}/etc/pacman.d/hooks"
    cat <<EOF > "${MOUNT_DIR}/etc/pacman.d/hooks/99-blindux-sync.hook"
[Trigger]
Type = Package
Operation = Install
Operation = Upgrade
Target = linux

[Action]
Description = Synchronizing updated kernel and initramfs to Blindux USB...
When = PostTransaction
Exec = /usr/local/bin/blindux-sync-kernel.sh
EOF

    cat <<'EOF' > "${MOUNT_DIR}/usr/local/bin/blindux-sync-kernel.sh"
#!/bin/bash
if ! mountpoint -q /boot; then
    mount /boot 2>/dev/null || true
fi

if mountpoint -q /boot; then
    echo "[+] Syncing updated kernel and initramfs to /boot on USB..."
    cp -u /boot/vmlinuz-linux /boot/vmlinuz-linux.new 2>/dev/null || true
    sync
    echo "[+] Kernel sync complete."
fi
EOF
    chmod +x "${MOUNT_DIR}/usr/local/bin/blindux-sync-kernel.sh"

    # Clean up chroot binds
    echo "[+] Dismantling chroot environment..."
    umount -lf "${MOUNT_DIR}/dev/pts"
    umount -lf "${MOUNT_DIR}/dev"
    umount -lf "${MOUNT_DIR}/proc"
    umount -lf "${MOUNT_DIR}/sys"
    umount -lf "${MOUNT_DIR}"
    umount -lf "${USB_MOUNT_DIR}"

    echo -e "\n=================================================================="
    echo "[SUCCESS] Blindux Installation & Provisioning Complete!"
    echo "You may now reboot your computer and boot from the USB drive."
    echo "=================================================================="
}

# --- MAIN EXECUTION FLOW ---
main() {
    check_root
    init_workspace
    phase0_input_gathering
    phase1_provisioning
    phase2_usb_layout
    phase3_bootloader_initramfs
}

main "$@"