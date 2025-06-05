#!/bin/bash

set -e

# Define SD card and eMMC
SD_CARD="/dev/mmcblk0"
EMMC="/dev/mmcblk1"

# Ensure both devices exist
if [ ! -b "$SD_CARD" ]; then
    echo "Error: SD card ($SD_CARD) not found!"
    exit 1
fi

if [ ! -b "$EMMC" ]; then
    echo "Error: eMMC ($EMMC) not found!"
    exit 1
fi

echo "Detected SD Card: $SD_CARD"
echo "Detected eMMC: $EMMC"

# Install fdisk if missing
if ! command -v fdisk &>/dev/null; then
    echo "fdisk not found, installing..."
    apt update && apt install -y fdisk
fi

# Show partition layouts
echo "SD Card Partition Layout:"
fdisk -l $SD_CARD || echo "Warning: Unable to read SD card partition layout."

echo "eMMC Partition Layout:"
fdisk -l $EMMC || echo "Warning: Unable to read eMMC partition layout."

echo "WARNING: This will overwrite all data on $EMMC with the contents of $SD_CARD!"
read -p "Are you sure you want to continue? (yes/no): " confirm

if [ "$confirm" != "yes" ]; then
    echo "Operation aborted."
    exit 1
fi

echo "Unmounting all partitions on $EMMC..."
umount ${EMMC}p* || true

echo "Extracting bootloader from SD card..."
dd if=$SD_CARD of=/tmp/u-boot-sunxi-with-spl.bin bs=1024 skip=8 count=1024 status=progress

echo "Wiping existing bootloader on eMMC..."
dd if=/dev/zero of=$EMMC bs=1M count=1 status=progress

echo "Writing extracted bootloader to eMMC..."
dd if=/tmp/u-boot-sunxi-with-spl.bin of=$EMMC bs=1024 seek=8 status=progress

echo "Recreating partition table on eMMC..."
echo -e "o\nn\np\n1\n4096\n\nw" | fdisk $EMMC  # Uses full available space

echo "Waiting for partition table update..."
sleep 2

echo "Forcing kernel to reread partition table..."
blockdev --rereadpt $EMMC || true

echo "Verifying new partition structure on eMMC:"
fdisk -l $EMMC || echo "Warning: If partitions do not appear, try rebooting."

# Copy each partition from SD card to eMMC
for part in $(fdisk -l $SD_CARD | awk '/^\/dev/ {print $1}'); do
    part_num=$(echo $part | grep -o '[0-9]*$')
    emmc_part="${EMMC}p${part_num}"

    if [ -b "$emmc_part" ]; then
        echo "Copying partition $part to $emmc_part..."
        dd if=$part of=$emmc_part bs=4M status=progress
    else
        echo "Skipping partition $part - no matching partition found on eMMC."
    fi
done

# Run e2fsck before resizing
echo "Checking filesystem integrity before resizing..."
e2fsck -f -y ${EMMC}p1 || true

echo "Resizing root filesystem on eMMC..."
ROOT_PART="${EMMC}p1"
if [ -b "$ROOT_PART" ]; then
    echo "Forcing kernel to reread partition table again..."
    blockdev --rereadpt $EMMC || true
    sleep 2

    echo "Resizing $ROOT_PART..."
    resize2fs $ROOT_PART
else
    echo "Warning: No root filesystem found. Resize skipped."
fi

# Modify extlinux.conf to set correct root device
echo "Modifying extlinux.conf to set correct root device..."

MOUNT_POINT="/mnt/emmc"
EXTLINUX_PATH="$MOUNT_POINT/boot/extlinux/extlinux.conf"

# Mount eMMC root filesystem
mkdir -p $MOUNT_POINT
mount ${EMMC}p1 $MOUNT_POINT

# Ensure extlinux.conf exists before modifying
if [ -f "$EXTLINUX_PATH" ]; then
    echo "Updating root device in extlinux.conf..."
    sed -i 's/root=\/dev\/mmcblk0p1/root=\/dev\/mmcblk1p1/g' "$EXTLINUX_PATH"
    echo "extlinux.conf updated successfully."
else
    echo "Warning: extlinux.conf not found in $EXTLINUX_PATH"
fi

# Unmount eMMC root filesystem
umount $MOUNT_POINT

echo "Syncing data..."
sync

echo "eMMC Flashing Completed Successfully!"

