#!/bin/bash

# Script Name: postinstall-desktop.sh

# --- Color Logging ---
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[1;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; }

# --- Input Variables ---
ROOTFS_DIR="$1"
ARCH="$2"
QEMU_BIN="$3"

# --- Validation ---
if [ -z "$ROOTFS_DIR" ] || [ -z "$ARCH" ] || [ -z "$QEMU_BIN" ]; then
    error "Usage: $0 <rootfs_dir> <arch> <qemu_bin>"
    exit 1
fi

if [ ! -f "$QEMU_BIN" ]; then
    error "QEMU binary not found at $QEMU_BIN"
    exit 1
fi

# --- Setup ---
info "Copying QEMU binary..."
sudo cp "$QEMU_BIN" "$ROOTFS_DIR/usr/bin/"

info "Ensuring /tmp exists with correct permissions..."
sudo mkdir -p "$ROOTFS_DIR/tmp"
sudo chmod 1777 "$ROOTFS_DIR/tmp"

info "Binding /dev, /proc, /sys..."
sudo mount --bind /dev "$ROOTFS_DIR/dev"
sudo mount --bind /proc "$ROOTFS_DIR/proc"
sudo mount --bind /sys "$ROOTFS_DIR/sys"

info "Setting static DNS (8.8.8.8) inside rootfs..."
sudo rm -f "$ROOTFS_DIR/etc/resolv.conf"
cat <<EOF | sudo tee "$ROOTFS_DIR/etc/resolv.conf" > /dev/null
nameserver 8.8.8.8
nameserver 8.8.4.4
EOF

sudo chown -R root:root "$ROOTFS_DIR/etc"
sudo chown -R root:root "$ROOTFS_DIR/var"

# --- Chroot and Configure ---
info "Starting chroot setup..."
cat << 'EOF' | sudo chroot "$ROOTFS_DIR"

set -e

echo "[INFO] Updating package lists..."
apt update

echo "[INFO] Installing essentials..."
apt install -y openssh-server gpiod alsa-utils fdisk nano i2c-tools util-linux-extra
echo "[INFO] Installing LXQt desktop and LightDM..."

DEBIAN_FRONTEND=noninteractive apt install -y \
    lxqt lightdm xinit 

echo "[INFO] Installing Bluetooth stack..."
apt install -y blueman

echo "[INFO] Enabling autologin for user 'ubuntu'..."
mkdir -p /etc/lightdm/lightdm.conf.d
cat <<AUTOLOGIN > /etc/lightdm/lightdm.conf.d/50-autologin.conf
[Seat:*]
autologin-user=ubuntu
autologin-user-timeout=0
user-session=lxqt
AUTOLOGIN

echo "[INFO] Removing any LXC-style netplan config..."
rm -f /etc/netplan/10-lxc.yaml /etc/netplan/lxc.yaml

echo "[INFO] Writing NetworkManager netplan config..."
mkdir -p /etc/netplan
cat <<NETPLAN > /etc/netplan/01-network-manager.yaml
network:
  version: 2
  renderer: NetworkManager
  ethernets:
    default:
      match:
        name: "e*"
      dhcp4: true
NETPLAN

echo "[INFO] Setting hostname based on chip ID..."
CHIPID=\$(grep -m1 Serial /proc/cpuinfo | awk '{print \$3}' | tail -c 9)
HOSTNAME="armsbc-\${CHIPID:-default}"
echo "\$HOSTNAME" > /etc/hostname
if grep -q "127.0.1.1" /etc/hosts; then
    sed -i "s/127.0.1.1.*/127.0.1.1\t\$HOSTNAME/" /etc/hosts
else
    echo "127.0.1.1 \$HOSTNAME" >> /etc/hosts
fi

echo "[INFO] Removing unwanted services (nftables, accounts-daemon)..."
apt purge -y nftables accountsservice
apt autoremove -y --purge

echo "[INFO] Cleaning apt cache..."
apt clean
rm -rf /var/lib/apt/lists/*

EOF

echo "[INFO] Fixing sudo binary permissions..."
sudo chown root:root "$MNT_ROOTFS/usr/bin/sudo" 2>/dev/null || true
sudo chmod 4755 "$MNT_ROOTFS/usr/bin/sudo" 2>/dev/null || true

echo "[INFO] Fixing sudoers ownership and mode..."
sudo chown root:root "$MNT_ROOTFS/etc/sudoers" 2>/dev/null || true
sudo chmod 440 "$MNT_ROOTFS/etc/sudoers" 2>/dev/null || true
sudo chown -R root:root "$MNT_ROOTFS/etc/sudoers.d" 2>/dev/null || true
sudo find "$MNT_ROOTFS/etc/sudoers.d" -type f -exec chmod 440 {} + 2>/dev/null

# --- Cleanup ---
info "Unmounting /dev, /proc, /sys..."
sudo umount "$ROOTFS_DIR/dev"
sudo umount "$ROOTFS_DIR/proc"
sudo umount "$ROOTFS_DIR/sys"

success "✅ Post-installation complete: Desktop, utilities, and services are set up."

