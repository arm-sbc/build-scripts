#!/bin/bash
set -e
#--- Paths and Tools ---#
OUT_DIR="OUT-$BOARD"
IMAGE_DIR="$OUT_DIR"
OUT_UPDATE_IMG="$OUT_DIR/update-$BOARD.img"
RAW_IMG="$OUT_DIR/update.raw.img"
PARAMETER_FILE="rk-tools/${CHIP}-parameter.txt"
PACKAGE_FILE="rk-tools/${CHIP}-package-file"
AFPTOOL="rk-tools/afptool"
RKIMAGEMAKER="rk-tools/rkImageMaker"
RKBOOT_INI="rkbin/RKBOOT/${CHIP^^}MINIALL.ini"
BOOT_MERGER="rkbin/tools/boot_merger"

pause() {
  echo "[ERROR] Press any key to quit."
  read -n1 -s
  exit 1
}

#--- Generate Loader if not found ---#
LOADER_BIN="$OUT_DIR/${CHIP}_spl_loader_v1.09.107.bin"
if [ ! -f "$LOADER_BIN" ]; then
  echo "[INFO] Loader not found. Attempting to generate using boot_merger..."
  [ -x "$BOOT_MERGER" ] || chmod +x "$BOOT_MERGER"
  [ -f "$RKBOOT_INI" ] || { echo "[ERROR] Missing RKBOOT ini file: $RKBOOT_INI"; pause; }
  pushd rkbin > /dev/null
  ./tools/boot_merger "RKBOOT/${CHIP^^}MINIALL.ini" || pause
  popd > /dev/null
  GENERATED_LOADER=$(find rkbin -maxdepth 1 -name "${CHIP}_spl_loader_*.bin" | sort | tail -n1)
  [ -f "$GENERATED_LOADER" ] || { echo "[ERROR] Failed to generate loader."; pause; }
  cp "$GENERATED_LOADER" "$LOADER_BIN"
  echo "[INFO] Loader generated and copied to: $LOADER_BIN"
fi

#--- Validate Inputs ---#
echo "[INFO] Validating required files..."
[ -f "$PARAMETER_FILE" ] || { echo "[ERROR] parameter.txt not found at $PARAMETER_FILE"; pause; }
[ -f "$PACKAGE_FILE" ] || { echo "[ERROR] $PACKAGE_FILE not found at $PACKAGE_FILE"; pause; }
[ -f "$LOADER_BIN" ] || { echo "[ERROR] Loader binary not found at $LOADER_BIN"; pause; }

#--- Prepare boot directory with kernel, dtb, config, System.map, extlinux.conf ---#
echo "[INFO] Preparing boot directory..."
BOOT_DIR="$OUT_DIR/boot"
mkdir -p "$BOOT_DIR"

cp "$OUT_DIR/Image" "$BOOT_DIR/" || pause
DTB_FILE=$(find "$OUT_DIR" -name "*.dtb" | grep -i "$CHIP" | head -n1)
[ "$DTB_FILE" != "$BOOT_DIR/$(basename "$DTB_FILE")" ] && cp "$DTB_FILE" "$BOOT_DIR/" || echo "[INFO] Skipping DTB copy to avoid duplication."
cp "$OUT_DIR"/config-* "$BOOT_DIR/" || true
cp "$OUT_DIR"/System.map-* "$BOOT_DIR/" || true

# Generate extlinux.conf
EXTLINUX_DIR="$BOOT_DIR/extlinux"
mkdir -p "$EXTLINUX_DIR"

case "$CHIP" in
  rk3588|rk3568|rk3399)
    CONSOLE="ttyS2"
    BAUD="1500000"
    ;;
  rk3576)
    CONSOLE="ttyS0"
    BAUD="1500000"
    ;;
  rk3288|rk3128)
    CONSOLE="ttyS2"
    BAUD="115200"
    ;;
  *)
    CONSOLE="ttyS2"
    BAUD="1500000"
    ;;
esac

cat > "$EXTLINUX_DIR/extlinux.conf" <<EOF
LABEL Linux ARB-SBC
    KERNEL /Image
    FDT /$(basename "$DTB_FILE")
    APPEND console=$CONSOLE,$BAUD root=/dev/mmcblk0p4 rw rootwait init=/sbin/init
EOF

#--- Generate ext2-based boot.img ---#
echo "[INFO] Creating ext2-based boot.img..."
BOOT_IMG="$OUT_DIR/boot_${CHIP}.img"

BLOCK_SIZE=4096
INODES=8192

# Calculate used size in KB and apply 25% safety margin
USED_KB=$(du -s --block-size=1024 "$BOOT_DIR" | cut -f1)
PADDING_KB=$(( USED_KB / 4 ))
TOTAL_KB=$(( USED_KB + PADDING_KB ))

# Enforce a minimum size of 32MB
MIN_KB=$(( 32 * 1024 ))
[ "$TOTAL_KB" -lt "$MIN_KB" ] && TOTAL_KB="$MIN_KB"

BLOCKS=$(( TOTAL_KB * 1024 / BLOCK_SIZE ))

genext2fs -b "$BLOCKS" -B "$BLOCK_SIZE" -d "$BOOT_DIR" -i "$INODES" -U "$BOOT_IMG" || pause

#--- Generate raw image with afptool ---#
echo "[INFO] Copying parameter.txt into OUT_DIR..."
cp "$PARAMETER_FILE" "$OUT_DIR/" || { echo "[ERROR] Failed to copy parameter.txt to $OUT_DIR"; pause; }

echo "[INFO] Packing raw image using afptool..."
$AFPTOOL -pack "$OUT_DIR" "$RAW_IMG" "$PACKAGE_FILE" || pause

#--- Extract RK Tag from MiniLoader for proper RKFW header ---#
TAG="RK$(hexdump -s 21 -n 4 -e '4 "%c"' "$LOADER_BIN" | rev)"
echo "[INFO] Using RK Tag: $TAG"

#--- Generate final update.img using rkImageMaker ---#
echo "[INFO] Creating final update.img using rkImageMaker..."
$RKIMAGEMAKER -$TAG "$LOADER_BIN" "$RAW_IMG" "$OUT_UPDATE_IMG" -os_type:linux || pause

#--- Final Check ---#
[ -f "$OUT_UPDATE_IMG" ] && echo "[SUCCESS] update.img created successfully: $OUT_UPDATE_IMG" || pause

exit 0

