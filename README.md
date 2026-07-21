# Blindux 🛡️🐧

A lightweight, in-situ deployment tool designed to run Arch Linux natively from a disk image (.img) stored inside an NTFS Windows partition, with optional BitLocker support.

Designed around an **On-Site Provisioning** architecture, Blindux eliminates the need for complex host cross-compilation or permanent disk repartitioning.

>⚠️ **DISCLAIMER & RESPONSIBILITY NOTICE**
>
>**This tool is experimental.**
> 
>Blindux interacts directly with disk images and BitLocker-encrypted partitions at a low level.
>
>The author(s) and contributor(s) take **no responsibility** for any potential data loss, drive corruption, system malfunction, or hardware damage caused by the use or misuse of this software.
>
>Always back up your critical data on Windows before using this tool.

---

## 🎯 Purpose (What & How)

### **What is Blindux?**
Blindux provides a completely isolated, dual-boot-like Linux system on machines with BitLocker-enabled Windows installations. It runs directly on bare-metal hardware (not inside a Virtual Machine) by hosting the Linux root filesystem inside a single file on your existing Windows drive.

### **How Does It Work?**
Blindux operates through a **two-phase workflow**:

1. **Phase 1: Lightweight USB Provisioning (Host Side)**
   * A host script formats a target USB drive using a minimal `pacstrap` footprint.
   * It securely embeds your target Wi-Fi credentials, BitLocker recovery keys, and installation parameters in an encrypted store on the USB drive.

2. **Phase 2: In-Situ Automated Installation (Target Side)**
   * You boot the target machine using the generated Blindux USB.
   * The USB automatically connects to Wi-Fi, unlocks the BitLocker NTFS partition in memory using `dislocker`, and allocates a raw ext4 filesystem image (`blindux.fs.img`) directly on the Windows drive.
   * It performs an *in-situ* `pacstrap` installation directly from official Arch Linux mirrors straight into the `.img` file.
   * Upon reboot, the system leverages an initramfs hook to mount the BitLocker volume, bind the loopback image, and boot natively.

---

## 🔒 Security & Architecture Highlights

* **Total Isolation:** Windows system files remain untouched and completely hidden from the Linux user environment post-boot.
* **Non-Destructive:** No drive repartitioning or modification of Windows partition tables is required.
* **BitLocker Friendly:** Integrates natively with Windows BitLocker encryption via `dislocker`.
* **Native Performance:** Runs directly on hardware with full CPU, GPU, and RAM access.

---

## 🚀 Getting Started

### Prerequisites

* A USB drive (minimum **2 GB** recommended).
* A machine running Windows with BitLocker enabled (or disabled) and an available NTFS partition.
* Your BitLocker recovery key (if encrypted).
* Internet connection (Wi-Fi SSID & Password).

---

## 🛠️ Usage

### **Step 1: Create the Provisioning USB**

1. Clone this repository:
```bash
git clone https://github.com/YOUR_USERNAME/blindux.git
cd blindux
```

3. Run the preparation script on your admin machine:
```bash
sudo ./blindux.sh
```

4. Follow the interactive prompts to provide:
   * Target USB device path (e.g., `/dev/sdX`).
   * Target Wi-Fi SSID and Passphrase.
   * BitLocker Recovery Key (optional/if applicable).
   * Desired size for the Linux root image file (e.g., `20G`).

---

### **Step 2: Install Blindux on the Target Machine**

1. Plug the generated USB drive into the target computer.
2. Boot from the USB via your system's Boot Menu (usually `F12`, `F11`, or `Option`).
3. The automated installer will boot, unlock BitLocker, format the internal `.img` file, download Arch Linux packages, and configure the bootloader automatically.
4. Once completed, remove the USB drive and reboot.

---

## 📜 Versioning

Blindux follows [Semantic Versioning](https://semver.org/). Current active development branch: `v0.1.0`.

---

## 📄 License

Distributed under the MIT License. See `LICENSE` for more information.
