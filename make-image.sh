#!/bin/bash

SCRIPT_NAME="make-image.sh"

# Function to log messages with colors
log() {
  local MSG_TYPE=$1
  local MESSAGE=$2

  case $MSG_TYPE in
    INFO)
      echo -e "\033[1;34m[$(date +"%Y-%m-%d %H:%M:%S")][INFO][$SCRIPT_NAME]\033[0m $MESSAGE"
      ;;
    WARN)
      echo -e "\033[1;33m[$(date +"%Y-%m-%d %H:%M:%S")][WARN][$SCRIPT_NAME]\033[0m $MESSAGE"
      ;;
    PROMPT)
      echo -e "\033[1;32m[$(date +"%Y-%m-%d %H:%M:%S")][PROMPT][$SCRIPT_NAME]\033[0m $MESSAGE"
      ;;
    ERROR)
      echo -e "\033[1;31m[$(date +"%Y-%m-%d %H:%M:%S")][ERROR][$SCRIPT_NAME]\033[0m $MESSAGE"
      ;;
    *)
      echo "[$(date +"%Y-%m-%d %H:%M:%S")][$MSG_TYPE][$SCRIPT_NAME] $MESSAGE"
      ;;
  esac
}

# Verify sudo access
if [ "$EUID" -ne 0 ]; then
  log "ERROR" "This script requires sudo privileges. Please run with sudo."
  exit 1
fi

# Check architecture
ARCH=""
if [ -f "OUT/Image" ]; then
  ARCH="arm64"
elif [ -f "OUT/zImage" ]; then
  ARCH="arm32"
else
  log "ERROR" "Neither Image nor zImage found in OUT folder. Cannot determine architecture."
  exit 1
fi
log "INFO" "Detected architecture: $ARCH"

# Extract chip name from device tree file
extract_chip_name() {
  local dtb_file
  dtb_file=$(ls OUT/*.dtb 2>/dev/null | head -n 1)
  if [ -n "$dtb_file" ]; then
    CHIP=$(basename "$dtb_file" | cut -d'-' -f1)
    log "INFO" "Detected chip name: $CHIP"
  else
    log "ERROR" "No device tree (*.dtb) file found in OUT directory."
    exit 1
  fi
}

# Prompt for SD card or eMMC image creation
prompt_image_type() {
  log "PROMPT" "Select the type of image to create:"
  echo "1- SD card"
  echo "2- eMMC"
  echo "3- Both"
  read -p "Enter the number corresponding to your choice: " IMAGE_TYPE_SELECTION

  case $IMAGE_TYPE_SELECTION in
    1) IMAGE_TYPES=("SD") ;;
    2) IMAGE_TYPES=("eMMC") ;;
    3) IMAGE_TYPES=("SD" "eMMC") ;;
    *) log "ERROR" "Invalid selection. Please enter 1, 2, or 3."; exit 1 ;;
  esac
}

# Download firmware to OUT directory
download_firmware() {
  if [ ! -d "OUT/firmware" ]; then
    FIRMWARE_URL="https://github.com/armbian/firmware/archive/refs/heads/master.zip"
    log "INFO" "Downloading firmware from $FIRMWARE_URL..."
    wget -q -O OUT/firmware.zip "$FIRMWARE_URL" || { log "ERROR" "Failed to download firmware."; exit 1; }
    log "INFO" "Extracting firmware to OUT/firmware..."
    unzip -qo OUT/firmware.zip -d OUT/ || { log "ERROR" "Failed to extract firmware."; exit 1; }
    mv OUT/firmware-master OUT/firmware
    log "INFO" "Firmware downloaded and extracted successfully."
  else
    log "INFO" "Firmware directory already exists in OUT. Skipping download."
  fi
}

# Remove existing images
cleanup_existing_images() {
  log "INFO" "Cleaning up existing images in OUT directory..."
  rm -f OUT/*.img || log "WARN" "No existing images to remove."
  log "INFO" "Existing images cleaned up."
}

# Write bootloader
write_bootloader() {
  local IMAGE_NAME=$1
  if [ -f "OUT/idbloader.img" ] && [ -f "OUT/u-boot.itb" ]; then
    log "INFO" "Writing idbloader and u-boot.itb to $IMAGE_NAME..."
    dd if=OUT/idbloader.img of="$IMAGE_NAME" bs=512 seek=64 conv=notrunc || { log "ERROR" "Failed to write idbloader."; exit 1; }
    sync
    dd if=OUT/u-boot.itb of="$IMAGE_NAME" bs=512 seek=16384 conv=notrunc || { log "ERROR" "Failed to write u-boot.itb."; exit 1; }
    sync
    log "INFO" "Bootloader written successfully."
  elif [ -f "OUT/u-boot-rockchip.bin" ]; then
    log "INFO" "Writing u-boot-rockchip.bin to $IMAGE_NAME..."
    dd if=OUT/u-boot-rockchip.bin of="$IMAGE_NAME" bs=512 seek=64 conv=notrunc || { log "ERROR" "Failed to write u-boot-rockchip.bin."; exit 1; }
    sync
    log "INFO" "Bootloader written successfully."
  else
    log "ERROR" "No valid bootloader files found in OUT. Ensure idbloader.img, u-boot.itb, or u-boot-rockchip.bin are available."
    exit 1
  fi
}


# Create and configure image
create_image() {
  local TYPE=$1
  IMAGE_NAME="OUT/${CHIP}_${TYPE}.img"
  log "INFO" "Creating $TYPE image: $IMAGE_NAME..."
  dd if=/dev/zero of="$IMAGE_NAME" bs=1M count=2048 || { log "ERROR" "Failed to create image file."; exit 1; }

  # Write bootloader
  write_bootloader "$IMAGE_NAME"

  # Set up loop device
  LOOP_DEVICE=$(losetup -f --show "$IMAGE_NAME")
  if [ -z "$LOOP_DEVICE" ]; then
    log "ERROR" "Failed to set up loop device."
    exit 1
  fi

  # Partition the image using sfdisk
  log "INFO" "Partitioning $IMAGE_NAME using sfdisk..."
  echo "64M,,L" | sfdisk "$LOOP_DEVICE" || {
    log "ERROR" "Failed to partition the image using sfdisk."
    losetup -d "$LOOP_DEVICE"
    exit 1
  }

  # Detach and reattach loop device to refresh
  log "INFO" "Detaching and reattaching loop device to refresh partition table..."
  losetup -d "$LOOP_DEVICE"
  LOOP_DEVICE=$(losetup -f --show "$IMAGE_NAME" --partscan) || {
    log "ERROR" "Failed to reattach loop device."
    exit 1
  }

  # Validate partition recognition
  if [ ! -e "${LOOP_DEVICE}p1" ]; then
    log "ERROR" "Partition not recognized after reattaching. Exiting."
    losetup -d "$LOOP_DEVICE"
    exit 1
  fi
  log "INFO" "Partition table successfully updated and recognized."

  # Format the partition
  mkfs.ext4 "${LOOP_DEVICE}p1" || {
    log "ERROR" "Failed to format partition."
    losetup -d "$LOOP_DEVICE"
    exit 1
  }

  # Mount the image
  MOUNT_POINT="/mnt/${TYPE}_img"
  mkdir -p "$MOUNT_POINT"
  mount "${LOOP_DEVICE}p1" "$MOUNT_POINT" || { log "ERROR" "Failed to mount image."; losetup -d "$LOOP_DEVICE"; exit 1; }

  # Populate the filesystem
  log "INFO" "Copying rootfs to $MOUNT_POINT..."
  if [ -d "OUT/rootfs_fresh" ]; then
    cp -a OUT/rootfs_fresh/* "$MOUNT_POINT/" || { log "ERROR" "Failed to copy rootfs from OUT/rootfs_fresh."; umount "$MOUNT_POINT"; losetup -d "$LOOP_DEVICE"; exit 1; }
  elif [ -d "OUT/rootfs" ]; then
    cp -a OUT/rootfs/* "$MOUNT_POINT/" || { log "ERROR" "Failed to copy rootfs from OUT/rootfs."; umount "$MOUNT_POINT"; losetup -d "$LOOP_DEVICE"; exit 1; }
  elif [ -d "OUT/fresh_noble" ]; then
    cp -a OUT/fresh_noble/* "$MOUNT_POINT/" || { log "ERROR" "Failed to copy rootfs from OUT/fresh_noble."; umount "$MOUNT_POINT"; losetup -d "$LOOP_DEVICE"; exit 1; }
  else
    log "ERROR" "No valid rootfs directory found in OUT (rootfs, rootfs_fresh, or fresh_noble)."
    umount "$MOUNT_POINT"
    losetup -d "$LOOP_DEVICE"
    exit 1
  fi
  log "INFO" "Rootfs copied successfully."

  # Copy boot files
  mkdir -p "$MOUNT_POINT/boot"
  cp OUT/{Image,zImage,*.dtb} "$MOUNT_POINT/boot/" 2>/dev/null
  cp OUT/config-* "$MOUNT_POINT/boot/" 2>/dev/null
  cp OUT/System.map-* "$MOUNT_POINT/boot/" 2>/dev/null
  log "INFO" "Boot files copied."

  # Copy kernel modules
  if [ -d "OUT/lib" ]; then
    mkdir -p "$MOUNT_POINT/lib/"
    cp -a OUT/lib/* "$MOUNT_POINT/lib/" || { log "ERROR" "Failed to copy kernel modules."; umount "$MOUNT_POINT"; losetup -d "$LOOP_DEVICE"; exit 1; }
    log "INFO" "Kernel modules copied."
  fi

  # Copy kernel headers
  if [ -d "OUT/include" ]; then
    mkdir -p "$MOUNT_POINT/usr/include"
    cp -a OUT/include/* "$MOUNT_POINT/usr/include/" || { log "ERROR" "Failed to copy kernel headers."; umount "$MOUNT_POINT"; losetup -d "$LOOP_DEVICE"; exit 1; }
    log "INFO" "Kernel headers copied."
  fi

  # Copy firmware
  if [ -d "OUT/firmware" ]; then
    mkdir -p "$MOUNT_POINT/lib/firmware"
    cp -a OUT/firmware/* "$MOUNT_POINT/lib/firmware/" || { log "ERROR" "Failed to copy firmware."; umount "$MOUNT_POINT"; losetup -d "$LOOP_DEVICE"; exit 1; }
    log "INFO" "Firmware copied."
  fi

# Install extlinux
mkdir -p "$MOUNT_POINT/boot/extlinux"
DTB_FILE=$(ls OUT/*.dtb | head -n 1 | xargs basename)  # Extract the DTB file name

# Set baud rate based on architecture
if [ "$ARCH" == "arm64" ]; then
  BAUD_RATE=1500000
elif [ "$ARCH" == "arm32" ]; then
  BAUD_RATE=115200
else
  log "ERROR" "Unknown architecture: $ARCH. Cannot determine baud rate."
  exit 1
fi

cat <<EOF > "$MOUNT_POINT/boot/extlinux/extlinux.conf"
LABEL Linux
    KERNEL /boot/Image
    FDT /boot/$DTB_FILE
    APPEND earlyprintk console=ttyS2,$BAUD_RATE root=/dev/mmcblk1p1 rootwait rw init=/sbin/init
EOF
log "INFO" "extlinux configured."

  # Unmount and clean up
  umount "$MOUNT_POINT"
  losetup -d "$LOOP_DEVICE"
  log "INFO" "$TYPE image creation completed."
}

# Main script execution
log "INFO" "Starting image creation script."
download_firmware
cleanup_existing_images
extract_chip_name
prompt_image_type

for TYPE in "${IMAGE_TYPES[@]}"; do
  create_image "$TYPE"
done

log "INFO" "All tasks completed successfully."

