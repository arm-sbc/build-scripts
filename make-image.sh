#!/bin/bash

SCRIPT_NAME="make-image.sh"

# Function to log messages with colors
log() {
  local MSG_TYPE=$1
  local MESSAGE=$2

  case $MSG_TYPE in
    INFO) echo -e "\033[1;34m[$(date +"%Y-%m-%d %H:%M:%S")][INFO][$SCRIPT_NAME]\033[0m $MESSAGE" ;;
    WARN) echo -e "\033[1;33m[$(date +"%Y-%m-%d %H:%M:%S")][WARN][$SCRIPT_NAME]\033[0m $MESSAGE" ;;
    ERROR) echo -e "\033[1;31m[$(date +"%Y-%m-%d %H:%M:%S")][ERROR][$SCRIPT_NAME]\033[0m $MESSAGE" ;;
    *) echo "[$(date +"%Y-%m-%d %H:%M:%S")][$MSG_TYPE][$SCRIPT_NAME] $MESSAGE" ;;
  esac
}

# Verify sudo access
if [ "$EUID" -ne 0 ]; then
  log "ERROR" "This script requires sudo privileges. Please run with sudo."
  exit 1
fi

# Detect available board directories
BOARD_DIRS=(OUT-ARM-SBC-*)
if [ ${#BOARD_DIRS[@]} -eq 0 ]; then
  log "ERROR" "No valid board directories found. Ensure your output directories are correctly named as OUT-ARM-SBC-<BOARD>."
  exit 1
fi

log "INFO" "Available boards:"
select BOARD_DIR in "${BOARD_DIRS[@]}"; do
  if [ -n "$BOARD_DIR" ]; then
    log "INFO" "Selected board: $BOARD_DIR"
    break
  else
    log "ERROR" "Invalid selection. Please try again."
  fi
done

# Set working directory
OUT_DIR="$BOARD_DIR"

# Determine architecture
ARCH=""
if [ -f "$OUT_DIR/Image" ]; then
  ARCH="arm64"
elif [ -f "$OUT_DIR/zImage" ]; then
  ARCH="arm32"
else
  log "ERROR" "Neither Image nor zImage found in $OUT_DIR. Cannot determine architecture."
  exit 1
fi
log "INFO" "Detected architecture: $ARCH"

# Extract chip name from device tree file
dtb_file=$(ls "$OUT_DIR"/*.dtb 2>/dev/null | head -n 1)
if [ -n "$dtb_file" ]; then
  CHIP=$(basename "$dtb_file" | cut -d'-' -f1)
  log "INFO" "Detected chip name: $CHIP"
else
  log "ERROR" "No device tree (*.dtb) file found in $OUT_DIR."
  exit 1
fi

# Determine platform type
if [[ "$CHIP" == sun* || "$CHIP" == a* ]]; then
  PLATFORM="Allwinner"
  PARTITION_START=2M
elif [[ "$CHIP" == rk* ]]; then
  PLATFORM="Rockchip"
  PARTITION_START=64M
else
  log "ERROR" "Unknown platform type. Unable to determine bootloader procedure."
  exit 1
fi
log "INFO" "Platform detected: $PLATFORM"

# Set correct serial console for extlinux
if [ "$PLATFORM" == "Allwinner" ]; then
  SERIAL_CONSOLE="ttyS0"
elif [ "$PLATFORM" == "Rockchip" ]; then
  SERIAL_CONSOLE="ttyS2"
else
  SERIAL_CONSOLE="ttyS1"  # Default fallback
fi
log "INFO" "Using serial console: $SERIAL_CONSOLE"

# Cleanup existing images
log "INFO" "Cleaning up existing images in $OUT_DIR..."
rm -f "$OUT_DIR"/*.img || log "WARN" "No existing images to remove."

# Create SD card image
IMAGE_NAME="$OUT_DIR/${CHIP}_SD.img"
log "INFO" "Creating SD card image: $IMAGE_NAME..."
dd if=/dev/zero of="$IMAGE_NAME" bs=1M count=2048 || { log "ERROR" "Failed to create image file."; exit 1; }

# Write bootloader
log "INFO" "Writing bootloader..."
write_bootloader() {
  if [ "$PLATFORM" == "Rockchip" ]; then
    if [ -f "$OUT_DIR/idbloader.img" ] && [ -f "$OUT_DIR/u-boot.itb" ]; then
      log "INFO" "Writing idbloader and u-boot.itb to $IMAGE_NAME..."
      dd if="$OUT_DIR/idbloader.img" of="$IMAGE_NAME" bs=512 seek=64 conv=notrunc || { log "ERROR" "Failed to write idbloader.img."; exit 1; }
      dd if="$OUT_DIR/u-boot.itb" of="$IMAGE_NAME" bs=512 seek=16384 conv=notrunc || { log "ERROR" "Failed to write u-boot.itb."; exit 1; }
    elif [ -f "$OUT_DIR/u-boot-rockchip.bin" ]; then
      log "INFO" "Writing u-boot-rockchip.bin to $IMAGE_NAME..."
      dd if="$OUT_DIR/u-boot-rockchip.bin" of="$IMAGE_NAME" bs=512 seek=64 conv=notrunc || { log "ERROR" "Failed to write u-boot-rockchip.bin."; exit 1; }
    else
      log "ERROR" "No valid Rockchip bootloader found in $OUT_DIR."
      exit 1
    fi
  elif [ "$PLATFORM" == "Allwinner" ]; then
    if [ -f "$OUT_DIR/u-boot-sunxi-with-spl.bin" ]; then
      log "INFO" "Writing u-boot-sunxi-with-spl.bin to $IMAGE_NAME..."
      dd if="$OUT_DIR/u-boot-sunxi-with-spl.bin" of="$IMAGE_NAME" bs=1024 seek=8 conv=notrunc || { log "ERROR" "Failed to write u-boot-sunxi-with-spl.bin."; exit 1; }
    else
      log "ERROR" "No valid Allwinner bootloader found in $OUT_DIR."
      exit 1
    fi
  else
    log "ERROR" "Unsupported platform: $PLATFORM"
    exit 1
  fi
  sync
}

write_bootloader

# Create partition
log "INFO" "Creating partition starting at $PARTITION_START..."
echo "$PARTITION_START,,L" | sfdisk "$IMAGE_NAME" || { log "ERROR" "Failed to partition the image."; exit 1; }

# Set up loop device
LOOP_DEVICE=$(losetup -f --show "$IMAGE_NAME" --partscan) || { log "ERROR" "Failed to set up loop device."; exit 1; }
log "INFO" "Loop device created: $LOOP_DEVICE"

# Ensure partition exists
if [ ! -e "${LOOP_DEVICE}p1" ]; then
  log "ERROR" "Partition not recognized after creation. Exiting."
  losetup -d "$LOOP_DEVICE"
  exit 1
fi

# Format partition
log "INFO" "Formatting partition with ext4..."
mkfs.ext4 "${LOOP_DEVICE}p1" || { log "ERROR" "Failed to format partition."; losetup -d "$LOOP_DEVICE"; exit 1; }

# Mount partition
MOUNT_POINT="/mnt/${CHIP}_img"
mkdir -p "$MOUNT_POINT"
mount "${LOOP_DEVICE}p1" "$MOUNT_POINT" || { log "ERROR" "Failed to mount partition."; losetup -d "$LOOP_DEVICE"; exit 1; }

# Detect kernel version dynamically
KERNEL_VERSION=$(basename "$OUT_DIR/config-"* 2>/dev/null | cut -d'-' -f2-)
if [ -n "$KERNEL_VERSION" ]; then
  log "INFO" "Detected kernel version: $KERNEL_VERSION"
else
  log "WARN" "Kernel version not found, skipping config and System.map copy."
fi

# Copy essential files
log "INFO" "Copying essential files..."
mkdir -p "$MOUNT_POINT/boot"
cp -a "$OUT_DIR/rootfs/"* "$MOUNT_POINT/"

# Ensure kernel and dtb files exist before copying
[ -f "$OUT_DIR/zImage" ] && cp "$OUT_DIR/zImage" "$MOUNT_POINT/boot/"
[ -n "$(ls $OUT_DIR/*.dtb 2>/dev/null)" ] && cp "$OUT_DIR"/*.dtb "$MOUNT_POINT/boot/"

# Copy config and System.map files if kernel version is detected
[ -f "$OUT_DIR/config-$KERNEL_VERSION" ] && cp "$OUT_DIR/config-$KERNEL_VERSION" "$MOUNT_POINT/boot/" || log "WARN" "No config file found, skipping."
[ -f "$OUT_DIR/System.map-$KERNEL_VERSION" ] && cp "$OUT_DIR/System.map-$KERNEL_VERSION" "$MOUNT_POINT/boot/" || log "WARN" "No System.map file found, skipping."

# Configure extlinux
log "INFO" "Configuring extlinux..."
mkdir -p "$MOUNT_POINT/boot/extlinux"
cat <<EOF > "$MOUNT_POINT/boot/extlinux/extlinux.conf"
LABEL Linux
    KERNEL /boot/zImage
    FDT /boot/$(basename "$dtb_file")
    APPEND console=${SERIAL_CONSOLE},115200 root=/dev/mmcblk0p1 rootwait rw
EOF

# Check if firmware is already downloaded
if [ ! -d "$OUT_DIR" ]; then
  log "INFO" "Firmware not found, downloading..."
  log "INFO" "Downloading firmware from Armbian..."
  FIRMWARE_URL="https://github.com/armbian/firmware/archive/refs/heads/master.zip"
  wget -q -O "$OUT_DIR/firmware.zip" "$FIRMWARE_URL" || { log "ERROR" "Failed to download firmware."; exit 1; }
  unzip -qo "$OUT_DIR/firmware.zip" -d "$OUT_DIR/firmware/"
  rsync -a --ignore-existing "$OUT_DIR/firmware/" "$MOUNT_POINT/lib/firmware/"
  else
  log "INFO" "Firmware already exists, skipping download."
  
fi


# Copy modules and firmware
log "INFO" "Copying kernel modules and firmware..."
[ -d "$OUT_DIR/lib/modules" ] && cp -a "$OUT_DIR/lib/modules" "$MOUNT_POINT/lib/"


# Unmount and finalize
umount "$MOUNT_POINT"
losetup -d "$LOOP_DEVICE"
log "INFO" "SD card image creation completed successfully."

