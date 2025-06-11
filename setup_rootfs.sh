#!/bin/bash

# Color Scheme
yellow="\033[1;33m"
blue="\033[1;34m"
red="\033[1;31m"
green="\033[1;32m"
reset="\033[0m"

# Function to print messages with colors
function info() {
    echo -e "${blue}[INFO] $1${reset}"
}

function warning() {
    echo -e "${yellow}[WARNING] $1${reset}"
}

function error() {
    echo -e "${red}[ERROR] $1${reset}"
}

function prompt() {
    echo -e "${green}[PROMPT] $1${reset}"
}

# Check if required variables are set
if [ -z "$BOARD" ] || [ -z "$ARCH" ] || [ -z "$VERSION" ]; then
    error "Required variables BOARD, ARCH, or VERSION are missing. Exiting."
    exit 1
fi

info "Starting root filesystem creation for Board: $BOARD, Architecture: $ARCH, Version: $VERSION"

# Check for sudo access
info "Checking for sudo access..."
if ! sudo -v; then
    error "This script requires sudo privileges. Please run as a user with sudo access."
    exit 1
fi
info "Sudo access verified."

prepare_rootfs() {
  ROOTFS_DIR="$OUTPUT_DIR/rootfs"
  IMAGES_DIR="$OUTPUT_DIR/images"

  # Base URL for Linux Containers
  BASE_URL="https://images.linuxcontainers.org/images"

  # Determine architecture-specific URL format
  case "$ARCH" in
    "arm")
      ARCH_URL="armhf"
      ;;
    "arm64")
      ARCH_URL="arm64"
      ;;
    *)
      error "Unsupported architecture: $ARCH"
      exit 1
      ;;
  esac

  # Determine distribution
  case "$DIST" in
    1)
      DISTRO="ubuntu"
      ;;
    2)
      DISTRO="debian"
      ;;
    *)
      error "Invalid distribution selection. Exiting."
      exit 1
      ;;
  esac

  # Construct the URL for the rootfs directory
  ROOTFS_URL="$BASE_URL/$DISTRO/$FLAVOR/$ARCH_URL/default/"

  info "Fetching rootfs directory listing from $ROOTFS_URL..."
  if ! wget -q -O /tmp/rootfs_listing.html "$ROOTFS_URL"; then
    error "Failed to fetch directory listing from $ROOTFS_URL. Please check your internet connection or the URL."
    exit 1
  fi

  # Parse the latest date directory (assumes date format like 20241230_07:42)
  LATEST_DATE=$(grep -oP '\d{8}_\d{2}:\d{2}' /tmp/rootfs_listing.html | sort | tail -n 1)
  if [ -z "$LATEST_DATE" ]; then
    error "Failed to determine the latest rootfs date. Directory listing might be empty or incorrectly formatted."
    exit 1
  fi

  IMAGE_URL="${ROOTFS_URL}${LATEST_DATE}/rootfs.tar.xz"

  info "Downloading prebuilt image from $IMAGE_URL..."
  mkdir -p "$IMAGES_DIR"
  if ! wget -q -O "$IMAGES_DIR/rootfs.tar.xz" "$IMAGE_URL"; then
    error "Failed to download rootfs.tar.xz."
    exit 1
  fi

  info "Extracting image: $IMAGES_DIR/rootfs.tar.xz..."
  rm -rf "$ROOTFS_DIR"
  mkdir -p "$ROOTFS_DIR"
  if ! tar -xf "$IMAGES_DIR/rootfs.tar.xz" -C "$ROOTFS_DIR"; then
    error "Failed to extract the rootfs image."
    exit 1
  fi

  info "Root filesystem extracted to $ROOTFS_DIR."

  # Chroot into the rootfs directory and update passwords
  info "Changing root to $ROOTFS_DIR to update passwords..."
  sudo chroot "$ROOTFS_DIR" /bin/bash -c "
    echo 'Updating root password...' &&
    passwd &&
    echo 'Checking for user directories in /home...' &&
    for user_dir in /home/*; do
      if [ -d \"\$user_dir\" ]; then
        user=\$(basename \"\$user_dir\")
        echo \"Updating password for user: \$user\" &&
        echo \"Please set the password for user: \$user\" &&
        passwd \"\$user\"
      fi
    done
  "
}

create_fresh_rootfs() {
    FRESH_DIR="$OUTPUT_DIR/fresh_$VERSION"
    info "Preparing fresh rootfs in $FRESH_DIR for $BOARD ($ARCH)..."

    # Check if the directory already exists
    if [ -d "$FRESH_DIR" ]; then
        warning "Directory $FRESH_DIR already exists. Removing it to avoid conflicts..."
        sudo rm -rf "$FRESH_DIR" || { error "Failed to remove existing directory $FRESH_DIR."; exit 1; }
        info "Existing directory $FRESH_DIR removed."
    fi

    info "Creating directory $FRESH_DIR for fresh rootfs..."
    mkdir -p "$FRESH_DIR" || { error "Failed to create directory $FRESH_DIR."; exit 1; }

    info "Checking and installing dependencies..."
    if ! dpkg -l | grep -qw debootstrap; then
        info "Installing debootstrap..."
        sudo apt-get install -y debootstrap
    fi

    if ! dpkg -l | grep -qw qemu-user-static; then
        info "Installing qemu-user-static..."
        sudo apt-get install -y qemu-user-static
    fi

    # Use a temporary directory for mounting
    TEMP_MOUNT_DIR=$(mktemp -d)
    info "Mounting $FRESH_DIR to $TEMP_MOUNT_DIR..."
    sudo mount --bind "$FRESH_DIR" "$TEMP_MOUNT_DIR" || { error "Failed to mount $FRESH_DIR to $TEMP_MOUNT_DIR."; exit 1; }

    # Run debootstrap based on architecture
    case $ARCH in
        arm32)
            info "Running debootstrap for armhf architecture..."
            sudo debootstrap --arch=armhf --foreign "$VERSION" "$FRESH_DIR" || { error "Debootstrap failed."; exit 1; }
            info "Copying qemu-arm-static binary..."
            sudo mkdir -p "$FRESH_DIR/usr/bin"
            sudo cp /usr/bin/qemu-arm-static "$FRESH_DIR/usr/bin/"
            ;;
        arm64)
            info "Running debootstrap for arm64 architecture..."
            sudo debootstrap --arch=arm64 --foreign "$VERSION" "$FRESH_DIR" || { error "Debootstrap failed."; exit 1; }
            info "Copying qemu-aarch64-static binary..."
            sudo mkdir -p "$FRESH_DIR/usr/bin"
            sudo cp /usr/bin/qemu-aarch64-static "$FRESH_DIR/usr/bin/"
            ;;
        *)
            error "Unsupported architecture: $ARCH"
            sudo umount "$TEMP_MOUNT_DIR"
            rm -rf "$TEMP_MOUNT_DIR"
            exit 1
            ;;
    esac

    info "Chrooting into the fresh rootfs for second-stage debootstrap..."
    sudo chroot "$TEMP_MOUNT_DIR" /bin/bash -c "
        /debootstrap/debootstrap --second-stage && \
        echo 'Updating root password...' && \
        passwd && \
        echo 'Checking for user directories in /home...' && \
        for user_dir in /home/*; do \
            if [ -d \"\$user_dir\" ]; then \
                user=\$(basename \"\$user_dir\") && \
                echo \"Updating password for user: \$user\" && \
                passwd \"\$user\"; \
            fi; \
        done" || { error "Chroot failed."; exit 1; }

    info "Fresh rootfs created successfully in $FRESH_DIR."
    sudo umount "$TEMP_MOUNT_DIR"
    rm -rf "$TEMP_MOUNT_DIR"
}

# Rootfs creation options
info "Select an option for rootfs creation:"
echo -e "1. Download prebuilt rootfs from Linux Containers"
echo -e "2. Create a fresh rootfs"

prompt "Enter your choice (1/2):"
read -r OPTION

case $OPTION in
    1)
        info "Downloading prebuilt rootfs from Linux Containers..."
        echo -e "Select a distribution:"
        echo -e "1. Ubuntu"
        echo -e "2. Debian"
        
        prompt "Enter your choice (1/2):"
        read -r DIST
        
        case $DIST in
            1)
                info "Selected Ubuntu. Choose a version:"
                echo -e "1. Noble (24.04)"
                echo -e "2. Jammy (22.04)"
                echo -e "3. Focal (20.04)"
                echo -e "4. Oracular (24.10)"
                
                prompt "Enter your choice (1/2/3/4):"
                read -r UBUNTU_VERSION
                case $UBUNTU_VERSION in
                    1) FLAVOR="noble";;
                    2) FLAVOR="jammy";;
                    3) FLAVOR="focal";;
                    4) FLAVOR="oracular";;
                    *) error "Invalid Ubuntu version selected. Exiting."; exit 1;;
                esac
                ;;
            2)
                info "Selected Debian. Choose a version:"
                echo -e "1. Bookworm"
                echo -e "2. Bullseye"
                echo -e "3. Trixie"
                
                prompt "Enter your choice (1/2/3):"
                read -r DEBIAN_VERSION
                case $DEBIAN_VERSION in
                    1) FLAVOR="bookworm";;
                    2) FLAVOR="bullseye";;
                    3) FLAVOR="trixie";;
                    *) error "Invalid Debian version selected. Exiting."; exit 1;;
                esac
                ;;
            *)
                error "Invalid distribution selected. Exiting."
                exit 1
                ;;
        esac
        DISTRO="linux"
        prepare_rootfs
        ;;
    2)
        info "Creating a fresh rootfs..."
        echo -e "Select a distribution:"
        echo -e "1. Ubuntu"
        echo -e "2. Debian"
        
        prompt "Enter your choice (1/2):"
        read -r DIST
        
        case $DIST in
            1)
                info "Selected Ubuntu. Choose a version:"
                echo -e "1. Noble (24.04)"
                echo -e "2. Jammy (22.04)"
                echo -e "3. Focal (20.04)"
                echo -e "4. Oracular (24.10)"
                
                prompt "Enter your choice (1/2/3/4):"
                read -r UBUNTU_VERSION
                case $UBUNTU_VERSION in
                    1) VERSION="noble";;
                    2) VERSION="jammy";;
                    3) VERSION="focal";;
                    4) VERSION="oracular";;
                    *) error "Invalid Ubuntu version selected. Exiting."; exit 1;;
                esac
                ;;
            2)
                info "Selected Debian. Choose a version:"
                echo -e "1. Bookworm"
                echo -e "2. Bullseye"
                echo -e "3. Trixie"
                
                prompt "Enter your choice (1/2/3):"
                read -r DEBIAN_VERSION
                case $DEBIAN_VERSION in
                    1) VERSION="bookworm";;
                    2) VERSION="bullseye";;
                    3) VERSION="trixie";;
                    *) error "Invalid Debian version selected. Exiting."; exit 1;;
                esac
                ;;
            *)
                error "Invalid distribution selected. Exiting."
                exit 1
                ;;
        esac
        create_fresh_rootfs
        ;;
    *)
        error "Invalid option selected. Exiting."
        exit 1
        ;;
esac

#--- Create rootfs.img for firmware packaging ---#
info "Packing rootfs.img from prepared root filesystem..."

ROOTFS_SRC="$OUTPUT_DIR/rootfs"
ROOTFS_IMG="$OUTPUT_DIR/rootfs.img"
TMP_MNT="mnt_rootfs"
SIZE_MB=2048

info "Allocating $SIZE_MB MB for rootfs.img..."
rm -f "$ROOTFS_IMG"
dd if=/dev/zero of="$ROOTFS_IMG" bs=1M count=$SIZE_MB
mkfs.ext4 -F "$ROOTFS_IMG"

mkdir -p "$TMP_MNT"
sudo mount "$ROOTFS_IMG" "$TMP_MNT"
sudo cp -a "$ROOTFS_SRC"/* "$TMP_MNT/"

if [ -d "$OUTPUT_DIR/lib/modules" ]; then
    info "Copying kernel modules..."
    sudo mkdir -p "$TMP_MNT/lib/modules"
    sudo cp -a "$OUTPUT_DIR/lib/modules/"* "$TMP_MNT/lib/modules/"
fi

echo "[INFO] Cloning Armbian firmware repository..."
git clone --depth=1 https://github.com/armbian/firmware.git /tmp/armbian-firmware || {
    warning "Failed to clone Armbian firmware repository. Skipping firmware copy."
    FIRMWARE_CLONED=0
}

if [ -d "/tmp/armbian-firmware" ]; then
    echo "[INFO] Copying firmware into rootfs..."
    sudo mkdir -p "$ROOTFS_TMP_MNT/lib/firmware"
    sudo rsync -a --delete /tmp/armbian-firmware/ "$TMP_MNT/lib/firmware/"
    rm -rf /tmp/armbian-firmware
fi

sudo umount "$TMP_MNT"
rm -rf "$TMP_MNT"

info "rootfs.img created at $ROOTFS_IMG"

#--- Prompt to create Rockchip images ---#
echo
prompt "Do you want to create Rockchip images now?"
echo "1. Create SD card image"
echo "2. Create eMMC image"
echo "3. Create both"
echo "4. Skip"
prompt "Enter your choice (1/2/3/4):"
read -r IMAGE_OPTION

case $IMAGE_OPTION in
    1)
        ./make-sdcard.sh || error "Failed to create SD card image."
        ;;
    2)
        ./make-eMMC.sh || error "Failed to create eMMC image."
        ;;
    3)
        ./make-sdcard.sh || error "Failed to create SD card image."
        ./make-eMMC.sh || error "Failed to create eMMC image."
        ;;
    4)
        info "Skipping image creation."
        ;;
    *)
        warning "Invalid choice. Skipping image creation."
        ;;
esac

info "Rootfs creation and image options completed."

