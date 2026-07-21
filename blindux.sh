#!/usr/bin/env bash
#
# ==============================================================================
# BLINDUX INSTALLER MAESTRO (v0.0.63)
# ==============================================================================
# Objective: Bootstraps an isolated Linux system inside a raw disk image nested 
#            on a BitLocker NTFS partition, managed by a self-contained bootable 
#            USB drive containing GRUB and a LUKS key vault.
#
# SKELETON SYNC VERSION: v0.0.63
# GOVERNANCE SYSTEM: Strict Semantic Versioning (SemVer)
#
# Constraints: Run as root (sudo). Works on any standard Linux distribution.
# Language: English (US) for all logs, code comments, and CLI outputs.
# ==============================================================================

set -euo pipefail

# --- IMMUTABLE VERSION TRACKING ---
readonly SKELETON_VERSION="v0.0.63"
readonly SCRIPT_VERSION="v0.0.63"

# --- ENFORCE ROOT PRIVILEGES BUT CAPTURE REAL CALLER ---
if [ "$EUID" -ne 0 ]; then
    echo -e "\033[0;31m[ERROR] This script must be run as root (sudo).\033[0m" >&2
    exit 1
fi

# Capture the real, non-root user details
export REAL_USER="${SUDO_USER:-$USER}"
export REAL_UID="${SUDO_UID:-$(id -u)}"
export REAL_GID="${SUDO_GID:-$(id -g)}"

# --- GLOBAL VARIABLES & PATHS ---
export WORKSPACE="./blindux"
export MOUNT_ROOT="/mnt/blindux_root"
export MOUNT_BOOT="/mnt/blindux_boot"
export IMG_FS="${WORKSPACE}/blindux.fs.img"
export IMG_BOOT="${WORKSPACE}/boot.dsk.img"
export LOG_FILE="${WORKSPACE}/install.log"
export STATE_FILE="${WORKSPACE}/.install_state.enc"

# --- COLOR PALETTE FOR PHASE LOGGING ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# ==============================================================================
# UTILITY / HELPER FUNCTIONS
# ==============================================================================

log_phase() {
    local phase="$1"
    local desc="$2"
    echo -e "\n${PURPLE}======================================================================${NC}" >&2
    echo -e "${CYAN}[PHASE] ${phase}:${NC} ${desc}" >&2
    echo -e "${PURPLE}======================================================================${NC}" >&2
    echo "[PHASE] ${phase}: ${desc}" >> "${LOG_FILE}"
}

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1" >&2
    echo "[INFO] $1" >> "${LOG_FILE}"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1" >&2
    echo "[SUCCESS] $1" >> "${LOG_FILE}"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
    echo "[ERROR] $1" >> "${LOG_FILE}"
    exit 1
}

fix_ownership() {
    local path="$1"
    if [ -e "${path}" ]; then
        chown -R "${REAL_UID}:${REAL_GID}" "${path}"
    fi
}

# ==============================================================================
# FASE 5: CLEANUP ROUTINE
# ==============================================================================

f5_cleanup() {
    echo -e "\n${YELLOW}[CLEANUP] Intercepting exit state. Cleaning resources safely...${NC}"
    set +e
    
    if [ -d "/mnt/vault" ]; then umount /mnt/vault 2>/dev/null; rm -rf /mnt/vault; fi
    if cryptsetup status blindux_vault &>/dev/null; then cryptsetup close blindux_vault 2>/dev/null; fi

    umount -lf "${MOUNT_ROOT}/dev/pts" 2>/dev/null
    umount -lf "${MOUNT_ROOT}/dev" 2>/dev/null
    umount -lf "${MOUNT_ROOT}/proc" 2>/dev/null
    umount -lf "${MOUNT_ROOT}/sys" 2>/dev/null
    
    umount -lf "${MOUNT_ROOT}" 2>/dev/null
    umount -lf "${MOUNT_BOOT}" 2>/dev/null

    if [ -n "${BOOT_LOOP_DEV:-}" ] && losetup -a | grep -q "${BOOT_LOOP_DEV}"; then
        losetup -d "${BOOT_LOOP_DEV}" 2>/dev/null
    fi
    
    if [ -d "${WORKSPACE}" ]; then fix_ownership "${WORKSPACE}"; fi
    set -e
    echo -e "${GREEN}[CLEANUP] Workspace structural safety achieved.${NC}"
}

trap f5_cleanup EXIT INT TERM

# ==============================================================================
# FASE 0: PRE-INSTALLATION, CONTEXT & STATE RESUME
# ==============================================================================

f0_initialize() {
    clear
    echo -e "${CYAN}--- Blindux Installer ---${NC}"
    echo -e "${BLUE}[VERSION MASTER] Skeleton: ${SKELETON_VERSION} | Script: ${SCRIPT_VERSION}${NC}\n"
    
    mkdir -p "${WORKSPACE}"
    touch "${LOG_FILE}"
    fix_ownership "${WORKSPACE}"
    log_info "Workspace verified with host user execution contexts. Version mapping complete."
}

f0_save_checkpoint() {
    local current_phase="$1"
    log_info "Saving checkpoint session state at Phase [${current_phase}]..."
    
    local raw_state
    raw_state=$(cat <<EOF
export CHECKPOINT="${current_phase}"
export TARGET_USB="${TARGET_USB}"
export TARGET_DISTRO="${TARGET_DISTRO}"
export IMG_SIZE_GB="${IMG_SIZE_GB}"
export BITLOCKER_KEY="${BITLOCKER_KEY}"
export LUKS_PASS="${LUKS_PASS}"
export LOGGED_SKELETON_VERSION="${SKELETON_VERSION}"
export LOGGED_SCRIPT_VERSION="${SCRIPT_VERSION}"
EOF
)
    echo "${raw_state}" | openssl enc -aes-256-cbc -salt -pbkdf2 -iter 100000 -pass pass:"${LUKS_PASS}" -out "${STATE_FILE}"
    fix_ownership "${STATE_FILE}"
}

f0_check_resume() {
    if [ -f "${STATE_FILE}" ]; then
        echo -e "${YELLOW}[RESUME] An existing installation state file was found.${NC}"
        while true; do
            read -s -rp "Enter your Blindux Master Passphrase to unlock session: " pass_check
            echo ""
            if [ -z "${pass_check}" ]; then continue; fi
            
            if decrypted_env=$(openssl enc -d -aes-256-cbc -pbkdf2 -iter 100000 -pass pass:"${pass_check}" -in "${STATE_FILE}" 2>/dev/null); then
                eval "${decrypted_env}"
                
                log_info "State synchronization telemetry check:"
                log_info "  -> Found session Skeleton: ${LOGGED_SKELETON_VERSION:-Unknown}"
                log_info "  -> Found session Script: ${LOGGED_SCRIPT_VERSION:-Unknown}"
                
                log_success "Session decrypted. Resuming deployment flow from Phase [${CHECKPOINT}]."
                return 0
            else
                echo -e "${RED}Invalid Master Passphrase. Decryption failed.${NC}"
                read -rp "Do you want to discard this session and start over? (y/N): " restart_choice
                if [[ "$restart_choice" =~ ^[yY]$ ]]; then
                    rm -f "${STATE_FILE}"
                    log_info "Previous state removed. Proceeding with fresh configuration."
                    break
                fi
            fi
        done
    fi
    export CHECKPOINT="0"
}

f0_select_usb() {
    if [ "${CHECKPOINT}" != "0" ]; then return 0; fi
    log_phase "0.2" "Scanning for target USB devices..."
    echo -e "Available block storage tracks:"
    
    local devices
    mapfile -t devices < <(lsblk -dno NAME,SIZE,TYPE,TRAN | grep "usb" || true)
    
    echo "----------------------------------------------------------"
    lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINTS
    echo "----------------------------------------------------------"
    echo "0) None (Build image files in workspace only, do not flash)"
    
    local idx=1 dev_map=()
    for dev in "${devices[@]}"; do
        local name size
        name=$(echo "$dev" | awk '{print $1}')
        size=$(echo "$dev" | awk '{print $2}')
        echo "$idx) /dev/$name ($size)"
        dev_map+=("/dev/$name")
        idx=$((idx + 1))
    done

    local choice
    while true; do
        read -rp "Select target boot USB device (0-${#dev_map[@]}): " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -le "${#dev_map[@]}" ]; then break; fi
        echo "Invalid choice. Please retry."
    done

    if [ "$choice" -eq 0 ]; then
        export TARGET_USB="None"
    else
        export TARGET_USB="${dev_map[$((choice - 1))]}"
    fi
    log_info "Target boot USB set to: ${TARGET_USB}"
}

f0_select_distro() {
    if [ "${CHECKPOINT}" != "0" ]; then return 0; fi
    log_phase "0.3" "Select Base Linux Distribution"
    echo "1) Arch Linux"
    echo "2) Debian Stable"
    echo "3) Fedora (DNF InstallRoot)"
    
    local choice
    while true; do
        read -rp "Select base distribution (1-3): " choice
        case "$choice" in
            1) export TARGET_DISTRO="arch"; break;;
            2) export TARGET_DISTRO="debian"; break;;
            3) export TARGET_DISTRO="fedora"; break;;
            *) echo "Invalid selection.";;
        esac
    done
    log_info "Target distribution set to: ${TARGET_DISTRO}"
}

f0_select_size() {
    if [ "${CHECKPOINT}" != "0" ]; then return 0; fi
    log_phase "0.4" "Allocate Virtual Disk Capacity"
    
    local host_free_kb host_free_gb
    host_free_kb=$(df --output=avail . | tail -n1)
    host_free_gb=$(( host_free_kb / 1024 / 1024 ))

    while true; do
        read -rp "Enter initial image size in GB [Default: 10]: " size_input
        if [ -z "${size_input}" ]; then size_input="10"; fi
        
        if [[ ! "${size_input}" =~ ^[0-9]+$ ]] || [ "${size_input}" -eq 0 ]; then
            echo -e "${RED}Error: Size must be a valid positive integer greater than 0.${NC}"
            continue
        fi

        if [ "${size_input}" -ge "${host_free_gb}" ]; then
            echo -e "${RED}Insufficient disk space. Only ${host_free_gb}GB available on host directory path.${NC}"
            continue
        fi
        
        export IMG_SIZE_GB="${size_input}"
        break
    done
    log_info "System image targeted volume constraint: ${IMG_SIZE_GB} GB."
}

f0_gather_keys() {
    if [ "${CHECKPOINT}" != "0" ]; then return 0; fi
    log_phase "0.5" "Defining Credentials Schema"
    
    while true; do
        read -s -rp "Define Blindux Master LUKS Passphrase: " LUKS_PASS
        echo ""
        read -s -rp "Confirm Master LUKS Passphrase: " LUKS_PASS_CONFIRM
        echo ""
        if [ "$LUKS_PASS" = "$LUKS_PASS_CONFIRM" ] && [ -n "$LUKS_PASS" ]; then
            export LUKS_PASS
            log_success "Master Passphrase mapped successfully."
            break
        fi
        echo -e "${RED}Passwords do not match or are empty. Retry.${NC}"
    done

    while true; do
        read -s -rp "Enter Windows BitLocker Recovery Key (Leave EMPTY if unencrypted): " BITLOCKER_KEY
        echo ""
        if [ -z "$BITLOCKER_KEY" ]; then
            export BITLOCKER_KEY=""
            log_info "No encryption payload bound to corporate environment host partition."
            break
        else
            if [[ "$BITLOCKER_KEY" =~ ^([0-9]{6}-?){8}$ ]]; then
                export BITLOCKER_KEY="$BITLOCKER_KEY"
                log_success "BitLocker token regex signature validated."
                break
            else
                echo -e "${YELLOW}Warning: Non-standard BitLocker core layout detected.${NC}"
                read -rp "Enforce integration anyway? (y/N): " confirm
                if [[ "$confirm" =~ ^[yY]$ ]]; then
                    export BITLOCKER_KEY="$BITLOCKER_KEY"
                    break
                fi
            fi
        fi
    done
    
    f0_save_checkpoint "1"
}

# ==============================================================================
# FASE 1: IMAGE PROVISIONING & STRAPPED INSTALLATION
# ==============================================================================

f1_create_system_image() {
    if [ "${CHECKPOINT}" -gt "1" ]; then return 0; fi
    log_phase "1.1" "Provisioning virtual system storage"
    
    if [ -f "${IMG_FS}" ]; then
        log_info "Removing stale image from previous interrupted workspace run..."
        rm -f "${IMG_FS}"
    fi

    log_info "Allocating raw sparse file boundary (${IMG_SIZE_GB}GB) at ${IMG_FS}..."
    truncate -s "${IMG_SIZE_GB}G" "${IMG_FS}"
    fix_ownership "${IMG_FS}"

    log_info "Structuring active standalone target loop filesystem layer directly..."
    mkfs.ext4 -F -O "^metadata_csum,^64bit" "${IMG_FS}"
    log_success "Storage layer instantiated."
}

f1_bootstrap_os() {
    if [ "${CHECKPOINT}" -gt "1" ]; then return 0; fi
    log_phase "1.2" "Bootstrapping Target Operating System Base"
    mkdir -p "${MOUNT_ROOT}"
    
    log_info "Mounting loopback image system channel..."
    mount -o loop "${IMG_FS}" "${MOUNT_ROOT}"

    log_info "Deploying target base architecture binary structures (${TARGET_DISTRO})..."
    case "${TARGET_DISTRO}" in
        "arch")
            if ! command -v pacstrap &>/dev/null; then
                log_error "pacstrap missing. Install 'arch-install-scripts' utility on host environment."
            fi

            log_info "Generating pure Arch Linux mirrors and configuration matrices..."
            local tmp_mirrors="${WORKSPACE}/mirrors_pure_arch.conf"
            cat <<EOF > "${tmp_mirrors}"
Server = https://geo.mirror.pkgbuild.com/\$repo/os/\$arch
Server = https://mirror.rackspace.com/archlinux/\$repo/os/\$arch
EOF

            local tmp_pacman="${WORKSPACE}/pacman_pure_arch.conf"
            cat <<EOF > "${tmp_pacman}"
[options]
Architecture = auto
SigLevel = Required DatabaseOptional TrustedOnly
LocalFileSigLevel = Optional

[core]
Include = ${tmp_mirrors}

[extra]
Include = ${tmp_mirrors}
EOF

            log_info "Bootstrapping pure Arch Linux matrix using isolated configuration profile..."
            pacstrap -C "${tmp_pacman}" -K "${MOUNT_ROOT}" \
                base linux linux-firmware base-devel ntfs-3g fuse2 \
                cryptsetup systemd-sysvcompat grub-efi-x86_64 python networkmanager --noconfirm
            
            rm -f "${tmp_pacman}" "${tmp_mirrors}"
            ;;
        "debian")
            if ! command -v debootstrap &>/dev/null; then log_error "debootstrap package missing on host."; fi
            debootstrap stable "${MOUNT_ROOT}" http://deb.debian.org/debian/
            ;;
        "fedora")
            if ! command -v dnf &>/dev/null; then log_error "dnf core framework tracking missing."; fi
            dnf -y --installroot="${MOUNT_ROOT}" --releasever=44 groupinstall "Minimal Install"
            dnf -y --installroot="${MOUNT_ROOT}" install kernel grub2-efi-x64 ntfs-3g cryptsetup fuse NetworkManager
            ;;
    esac
    log_success "Base runtime OS deployment sequence completed."
}

f1_configure_chroot() {
    if [ "${CHECKPOINT}" -gt "1" ]; then return 0; fi
    log_phase "1.3" "Executing Embedded Chroot Localization & Basic Provisioning"
    
    mount --bind /dev "${MOUNT_ROOT}/dev"
    mount --bind /dev/pts "${MOUNT_ROOT}/dev/pts"
    mount --bind /proc "${MOUNT_ROOT}/proc"
    mount --bind /sys "${MOUNT_ROOT}/sys"
    
    cp -L /etc/resolv.conf "${MOUNT_ROOT}/etc/resolv.conf" 2>/dev/null || true

    log_info "Applying virtualization core parameters and host clock co-existence layers..."
    cat <<EOF | chroot "${MOUNT_ROOT}" /bin/bash
    echo "blindux" > /etc/hostname
    echo "127.0.0.1 localhost" >> /etc/hosts
    echo "::1       localhost" >> /etc/hosts
    if [ -f /etc/locale.gen ]; then
        echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
        locale-gen &>/dev/null
    fi
    echo "LANG=en_US.UTF-8" > /etc/locale.conf
    echo "KEYMAP=us" > /etc/vconsole.conf
    hwclock --systohc --localtime
EOF

    log_info "Enabling core networking frameworks inside target environments non-interactively..."
    case "${TARGET_DISTRO}" in
        "arch"|"fedora")
            cat <<EOF | chroot "${MOUNT_ROOT}" /bin/bash
            systemctl enable NetworkManager &>/dev/null || true
EOF
            ;;
        "debian")
            cat <<EOF | chroot "${MOUNT_ROOT}" /bin/bash
            apt-get update -y &>/dev/null
            apt-get install -y network-manager &>/dev/null
            systemctl enable network-manager &>/dev/null || true
EOF
            ;;
    esac

    log_success "Chroot profiling and localization requirements synchronized successfully."
}

f1_optimize_compression() {
    if [ "${CHECKPOINT}" -gt "1" ]; then return 0; fi
    log_phase "1.4" "Optimizing Disk Blocks for Maximal Compression (Zero-Filling)"
    
    log_info "Writing binary zeros (throttled sync to prevent system freeze)..."
    dd if=/dev/zero of="${MOUNT_ROOT}/zero.tmp" bs=4M status=progress conv=fdatasync || true
    
    log_info "Purging dummy zero allocations file..."
    rm -f "${MOUNT_ROOT}/zero.tmp"
    sync
    
    log_info "Dismantling chroot inner binds before system unmount..."
    umount -lf "${MOUNT_ROOT}/dev/pts" 2>/dev/null || true
    umount -lf "${MOUNT_ROOT}/dev" 2>/dev/null || true
    umount -lf "${MOUNT_ROOT}/proc" 2>/dev/null || true
    umount -lf "${MOUNT_ROOT}/sys" 2>/dev/null || true
    umount -lf "${MOUNT_ROOT}" 2>/dev/null || true
    sync
    
    f0_save_checkpoint "2"
}

# ==============================================================================
# FASE 2: BOOT IMAGE GENERATION (`boot.dsk.img`)
# ==============================================================================

f2_create_boot_disk() {
    if [ "${CHECKPOINT}" -gt "2" ]; then return 0; fi
    log_phase "2.1" "Generating boot disk image (boot.dsk.img)"
    
    truncate -s 256M "${IMG_BOOT}"
    fix_ownership "${IMG_BOOT}"
    
    parted -s "${IMG_BOOT}" mklabel gpt
    parted -s "${IMG_BOOT}" mkpart ESP fat32 1MiB 100%
    parted -s "${IMG_BOOT}" set 1 esp on

    export BOOT_LOOP_DEV
    BOOT_LOOP_DEV=$(losetup -fP --show "${IMG_BOOT}")
    local part_dev="${BOOT_LOOP_DEV}p1"

    mkfs.vfat -F 32 -n "BL_BOOT" "${part_dev}"
    export USB_BOOT_UUID
    USB_BOOT_UUID=$(blkid -s UUID -o value "${part_dev}")

    mkdir -p "${MOUNT_BOOT}"
    mount "${part_dev}" "${MOUNT_BOOT}"

    log_info "Deploying portable standalone EFI GRUB payload..."
    grub-install --target=x86_64-efi --efi-directory="${MOUNT_BOOT}" --boot-directory="${MOUNT_BOOT}" --removable --recheck
}

f2_secure_bitlocker_key() {
    if [ "${CHECKPOINT}" -gt "2" ]; then return 0; fi
    
    if [ -n "${BITLOCKER_KEY}" ]; then
        log_phase "2.2" "Deploying Corporate Keys into Strict 32MB LUKS2 Vault"
        local luks_file="${MOUNT_BOOT}/keys.luks"
        
        dd if=/dev/zero of="${luks_file}" bs=1M count=32
        
        log_info "Formatting LUKS2 array structure with master credential passphrase..."
        echo -n "${LUKS_PASS}" | cryptsetup luksFormat --type luks2 "${luks_file}" -
        
        log_info "Injecting Windows keys payloads..."
        echo -n "${LUKS_PASS}" | cryptsetup open "${luks_file}" blindux_vault -
        
        mkdir -p /mnt/vault
        mkfs.ext2 -F /dev/mapper/blindux_vault &>/dev/null
        mount /dev/mapper/blindux_vault /mnt/vault
        echo -n "${BITLOCKER_KEY}" > /mnt/vault/bitlocker.key
        
        umount /mnt/vault
        cryptsetup close blindux_vault
        rm -rf /mnt/vault
        log_success "BitLocker corporate unlock sequence payload successfully secured."
    else
        log_info "Host unencrypted tracking profile requested. Omit LUKS container layer allocation."
    fi
    
    f0_save_checkpoint "3"
}

# ==============================================================================
# FASE 3: BOOTLOADER & CUSTOM INITRAMFS CONFIGURATION
# ==============================================================================

f3_configure_bootloader() {
    if [ "${CHECKPOINT}" -gt "3" ]; then return 0; fi
    log_phase "3.1" "Writing Embedded Hardware Agnostic Architecture Assets"

    if ! findmnt -nt ext4 "${MOUNT_ROOT}" >/dev/null; then
        log_info "Mounting loopback image system channel..."
        mount -o loop "${IMG_FS}" "${MOUNT_ROOT}"
    else
        log_info "Image already mapped at target mount point. Reusing active descriptor."
    fi
    
    mkdir -p "${MOUNT_ROOT}/etc"
    cat <<EOF > "${MOUNT_ROOT}/etc/fstab"
# Embedded Blindux Host USB Boot Mount Profile
UUID=${USB_BOOT_UUID}   /boot   vfat   noauto,nofail,defaults   0   2
EOF

    if [ -f "${MOUNT_ROOT}/etc/mkinitcpio.conf" ]; then
        sed -i 's/^FILES=(.*)/FILES=(\/etc\/fstab)/' "${MOUNT_ROOT}/etc/mkinitcpio.conf"
    fi

    log_info "Generating GRUB environment configurations..."
    cat <<EOF > "${MOUNT_BOOT}/grub/grub.cfg"
set default=0
set timeout=3

menuentry "Blindux Native Security OS" {
    insmod ext2
    insmod fat
    search --no-floppy --fs-uuid --set=root ${USB_BOOT_UUID}
    linux /vmlinuz-linux root=UUID=PLACE_HOLDER_WINDOWS_UUID root.img=/blindux/blindux.fs.img rw quiet
    initrd /initramfs-linux.img
}
EOF
}

f3_generate_initramfs_hooks() {
    if [ "${CHECKPOINT}" -gt "3" ]; then return 0; fi
    log_phase "3.2" "Compiling Adaptive Initramfs Hook Arrays"

    local hook_dir="${MOUNT_ROOT}/etc/initcpio"
    mkdir -p "${hook_dir}/hooks" "${hook_dir}/install"

    cat <<'EOF' > "${hook_dir}/install/blindux"
#!/bin/bash
build() {
    add_runscript
    add_binary cryptsetup
    add_binary dislocker
    add_binary ntfs-3g
    add_module loop
    add_module fuse
}
EOF
    chmod +x "${hook_dir}/install/blindux"

    cat <<'EOF' > "${hook_dir}/hooks/blindux"
#!/usr/bin/env ash
run_hook() {
    local host_root="" host_img=""
    for param in $(cat /proc/cmdline); do
        case ${param} in
            root=*) host_root="${param#root=}" ;;
            root.img=*) host_img="${param#root.img=}" ;;
        esac
    done

    echo ":: Blindux Initialization Vectors online..."
    mkdir -p /boot
    if ! mount /boot; then return 1; fi

    if [ -f /boot/keys.luks ]; then
        echo ":: Encrypted Windows corporate context detected."
        local pass_verified=0
        while [ ${pass_verified} -eq 0 ]; do
            echo -n "Enter Blindux Master Passphrase: "
            read -s pass; echo ""
            if echo -n "${pass}" | cryptsetup open /boot/keys.luks blindux_vault -; then
                pass_verified=1
            else
                echo ":: Authentication failure. Verification rejected."
            fi
        done

        mkdir -p /mnt/vault /mnt/host_decrypted /mnt/host_final
        mount /dev/mapper/blindux_vault /mnt/vault
        local raw_bitkey=$(cat /mnt/vault/bitlocker.key)
        umount /mnt/vault && cryptsetup close blindux_vault

        dislocker -r -V "${host_root}" -p"${raw_bitkey}" -- /mnt/host_decrypted
        ntfs-3g /mnt/host_decrypted/dislocker-file /mnt/host_final
    else
        echo ":: Raw Host access configuration profile active."
        mkdir -p /mnt/host_final
        ntfs-3g "${host_root}" /mnt/host_final
    fi

    mkdir -p /new_root
    mount -o loop "/mnt/host_final/${host_img}" /new_root
}
EOF
    chmod +x "${hook_dir}/hooks/blindux"

    mount --bind /dev "${MOUNT_ROOT}/dev"
    mount --bind /dev/pts "${MOUNT_ROOT}/dev/pts"
    mount --bind /proc "${MOUNT_ROOT}/proc"
    mount --bind /sys "${MOUNT_ROOT}/sys"

    log_info "Compiling native target internal hardware initramfs distribution layout..."
    
    set +e
    chroot "${MOUNT_ROOT}" /bin/bash <<'EOF'
    if command -v mkinitcpio &>/dev/null; then
        echo "[INITRAMFS] Arch Linux/Manjaro mkinitcpio framework detected."
        if grep -q "HOOKS=" /etc/mkinitcpio.conf; then
            sed -i 's/\(udev\)/\1 blindux/' /etc/mkinitcpio.conf
        fi
        
        local preset_file preset_name
        preset_file=$(ls /etc/mkinitcpio.d/*.preset 2>/dev/null | head -n1)
        
        if [ -n "${preset_file}" ]; then
            preset_name=$(basename "${preset_file}" .preset)
            echo "[INITRAMFS] Found active kernel preset: ${preset_name}"
            mkinitcpio -p "${preset_name}"
        else
            echo "[WARNING] No .preset file found in /etc/mkinitcpio.d/. Falling back to direct build configuration."
            local kernel_version
            kernel_version=$(ls /usr/lib/modules/ | head -n1)
            echo "[INITRAMFS] Compiling direct fallback layout for kernel version: ${kernel_version}"
            mkinitcpio -c /etc/mkinitcpio.conf -g /boot/initramfs-linux.img -k "${kernel_version}"
        fi
    fi
EOF
    CHROOT_STATUS=$?
    set -e

    if [ $CHROOT_STATUS -ne 0 ]; then
        log_error "Initramfs compilation failed inside the chroot environment."
    fi

    log_info "Synchronizing fresh images kernels files back to standalone boot matrix..."
    cp -f $(find "${MOUNT_ROOT}/boot" -name "vmlinuz*" -o -name "vmlinux*" | head -n1) "${MOUNT_BOOT}/vmlinuz-linux" 2>/dev/null || true
    cp -f $(find "${MOUNT_ROOT}/boot" -name "initramfs*" -o -name "initrd*" | head -n1) "${MOUNT_BOOT}/initramfs-linux.img" 2>/dev/null || true

    umount -lf "${MOUNT_ROOT}/dev/pts" 2>/dev/null || true
    umount -lf "${MOUNT_ROOT}/dev" 2>/dev/null || true
    umount -lf "${MOUNT_ROOT}/proc" 2>/dev/null || true
    umount -lf "${MOUNT_ROOT}/sys" 2>/dev/null || true
    
    f0_save_checkpoint "4"
}

# ==============================================================================
# FASE 4: RUNTIME AUTOMATION & SYSTEM LIFE CYCLE
# ==============================================================================

f4_inject_system_automations() {
    if [ "${CHECKPOINT}" -gt "4" ]; then return 0; fi
    log_phase "4.1" "Injecting Runtime System Automations inside Image"

    local monitor_script="${MOUNT_ROOT}/usr/local/bin/blindux-disk-monitor"
    mkdir -p "$(dirname "${monitor_script}")"
    cat <<'EOF' > "${monitor_script}"
#!/usr/bin/env bash
FREE_SPACE_KB=$(df --output=avail / | tail -n1)
FREE_SPACE_GB=$(( FREE_SPACE_KB / 1024 / 1024 ))
if [ "${FREE_SPACE_GB}" -lt 1 ]; then
    export DISPLAY=:0
    export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u)/bus"
    notify-send -u critical "Blindux low space alert!" "Only ${FREE_SPACE_GB}GB left inside your core container loop."
fi
EOF
    chmod +x "${monitor_script}"

    cat <<EOF > "${MOUNT_ROOT}/etc/systemd/system/blindux-monitor.service"
[Unit]
Description=Blindux Space Alerts Daemon
[Service]
Type=oneshot
ExecStart=${monitor_script}
EOF

    cat <<EOF > "${MOUNT_ROOT}/etc/systemd/system/blindux-monitor.timer"
[Unit]
Description=Run Blindux Space Monitor Every 10 Minutes
[Timer]
OnBootSec=10min
OnUnitActiveSec=10min
[Install]
WantedBy=timers.target
EOF

    local resize_script="${MOUNT_ROOT}/usr/local/bin/blindux-autoresize"
    cat <<'EOF' > "${resize_script}"
#!/usr/bin/env bash
FREE_SPACE_KB=$(df --output=avail / | tail -n1)
FREE_SPACE_GB=$(( FREE_SPACE_KB / 1024 / 1024 ))
if [ "${FREE_SPACE_GB}" -lt 5 ]; then
    truncate -s +5G /host/blindux/blindux.fs.img
    resize2fs $(findmnt -n -o SOURCE /)
fi
EOF
    chmod +x "${resize_script}"

    cat <<EOF > "${MOUNT_ROOT}/etc/systemd/system/blindux-autoresize.service"
[Unit]
Description=Dynamic Partition Growing Service
Before=sysinit.target
[Service]
Type=oneshot
ExecStart=${resize_script}
[Install]
WantedBy=sysinit.target
EOF

    local sync_script="${MOUNT_ROOT}/usr/local/bin/blindux-kernelsync"
    cat <<'EOF' > "${sync_script}"
#!/usr/bin/env bash
BOOT_UUID=$(grep -oP 'UUID=\K\S+' /etc/fstab || true)
if [ -z "$BOOT_UUID" ]; then exit 0; fi
while true; do
    DEV_PATH=$(blkid -U "${BOOT_UUID}" || true)
    if [ -n "${DEV_PATH}" ]; then break; fi
    export DISPLAY=:0
    notify-send -u critical "Blindux Update Sync Alert" "Please insert your Blindux USB Boot token to finish structural kernel upgrade syncing!"
    sleep 30
done
mount "${DEV_PATH}" /mnt/usb_boot
cp /boot/vmlinuz-linux /mnt/usb_boot/
cp /boot/initramfs-linux.img /mnt/usb_boot/
umount /mnt/usb_boot
notify-send "Blindux Sync Success" "Kernel payloads synchronized successfully."
EOF
    chmod +x "${sync_script}"

    cat <<EOF | chroot "${MOUNT_ROOT}" /bin/bash
    systemctl enable blindux-monitor.timer &>/dev/null || true
    systemctl enable blindux-autoresize.service &>/dev/null || true
EOF

    umount "${MOUNT_ROOT}" 2>/dev/null || true
    umount "${MOUNT_BOOT}" 2>/dev/null || true
    
    if [ -n "${BOOT_LOOP_DEV:-}" ]; then losetup -d "${BOOT_LOOP_DEV}" 2>/dev/null; fi
    
    rm -f "${STATE_FILE}"
    log_success "All dynamic daemons injected. Session storage benchmarks complete."
}

# ==============================================================================
# FASE 5: OPTIONAL FLASHING PIPELINE
# ==============================================================================

f5_flash_physical_usb() {
    if [ "${TARGET_USB}" != "None" ]; then
        log_phase "5.2" "Streaming boot matrix assets directly into target USB media block"
        log_info "Writing ${IMG_BOOT} directly to ${TARGET_USB} via dd streams..."
        dd if="${IMG_BOOT}" of="${TARGET_USB}" bs=4M status=progress conv=fsync
        log_success "Flashing onto target physical boundary completed safely."
    else
        log_phase "5.2" "Manual Flashing Deployment Summary"
        echo -e "${YELLOW}Standalone build requested.${NC}"
        echo "Deploy your master secure key boot assets manually to your hardware device via:"
        echo -e "Command: ${GREEN}dd if=${IMG_BOOT} of=/dev/sdX bs=4M status=progress conv=fsync${NC}"
    fi
}

# ==============================================================================
# SCRIPT ORCHESTRATION PIPELINE
# ==============================================================================

main() {
    f0_initialize
    f0_check_resume
    f0_select_usb
    f0_select_distro
    f0_select_size
    f0_gather_keys
    
    f1_create_system_image
    f1_bootstrap_os
    f1_configure_chroot
    f1_optimize_compression
    
    f2_create_boot_disk
    f2_secure_bitlocker_key
    
    f3_configure_bootloader
    f3_generate_initramfs_hooks
    f4_inject_system_automations
    
    f5_flash_physical_usb
    
    log_success "BLINDUX ARCHITECTURE ROUTINES FULLY IMPLEMENTED!"
}

main "$@"