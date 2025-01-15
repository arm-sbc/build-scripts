#!/bin/bash

# Script Name: sunxi-compile.sh

# Ensure the environment is prepared
if [ -z "$BOARD" ] || [ -z "$CHIP" ] || [ -z "$UBOOT_DEFCONFIG" ] || [ -z "$KERNEL_DEFCONFIG" ]; then
  echo -e "\033[1;31m[ERROR] Environment variables not set. Please run set_env.sh first.\033[0m"
  exit 1
fi

# Function to log messages
log() {
  echo -e "\033[1;34m[$(date +'%Y-%m-%d %H:%M:%S')] $1\033[0m"
}

# Function to handle errors
error() {
  echo -e "\033[1;31m[$(date +'%Y-%m-%d %H:%M:%S')] $1\033[0m" >&2
  exit 1
}

# Compile Trusted Firmware (ATF)
compile_atf() {
  log "Compiling Trusted Firmware for $CHIP..."
  cd arm-trusted-firmware || error "Failed to enter ATF directory."
  make CROSS_COMPILE=aarch64-linux-gnu- PLAT=sun50i_a64 DEBUG=1 bl31 || error "Trusted Firmware compilation failed."
  export BL31="$(pwd)/build/sun50i_a64/debug/bl31.bin"
  [ -f "$BL31" ] || error "BL31 file not found after compilation."
  cd - > /dev/null
  log "Trusted Firmware compiled successfully. BL31 is at $BL31."
}

# Compile U-Boot
compile_uboot() {
  log "Compiling U-Boot for $CHIP..."
  cd u-boot || error "Failed to enter U-Boot directory."
  make distclean
  if [[ "$KERNEL_ARCH" == "arm" ]]; then
    export CFLAGS="-mtune=cortex-a7"
  fi
  make CROSS_COMPILE=${CROSS_COMPILE}- "$UBOOT_DEFCONFIG" || error "Failed to configure U-Boot."
  make -j$(nproc) CROSS_COMPILE=${CROSS_COMPILE}- BL31="$BL31" || error "U-Boot compilation failed."

  # Copy U-Boot outputs to OUT
  mkdir -p ../OUT
  if [ -f u-boot-sunxi-with-spl.bin ]; then
    cp u-boot-sunxi-with-spl.bin ../OUT/ || error "Failed to copy u-boot-sunxi-with-spl.bin to OUT."
    log "Copied u-boot-sunxi-with-spl.bin to OUT directory."
  else
    error "u-boot-sunxi-with-spl.bin not found after compilation."
  fi

  cd - > /dev/null
  log "U-Boot compiled and outputs copied to OUT directory."
}

# Function to check cross-compiler
check_cross_compiler() {
  log "Checking cross-compiler for $CHIP..."
  if command -v ${CROSS_COMPILE}-gcc &>/dev/null; then
    CROSS_COMPILER_VERSION=$(${CROSS_COMPILE}-gcc --version | head -n 1)
    log "Using cross-compiler: $CROSS_COMPILER_VERSION"
  else
    error "Cross-compiler '${CROSS_COMPILE}-gcc' not found. Please install it."
  fi
}

# Apply patches
apply_patches() {
  log "Starting patch application process..."
  PATCH_DIRS=("patches/sunxi/kernel" "patches/sunxi/uboot")

  for dir in "${PATCH_DIRS[@]}"; do
    if [ -d "$dir" ]; then
      log "Applying patches from $dir..."
      if [[ "$dir" == *kernel* ]]; then
        SOURCE_DIR="linux-${KERNEL_VERSION}"
      elif [[ "$dir" == *uboot* ]]; then
        SOURCE_DIR="u-boot"
      fi

      if [ ! -d "$SOURCE_DIR" ]; then
        error "Source directory $SOURCE_DIR not found. Ensure the sources are downloaded."
        continue
      fi

      cd "$SOURCE_DIR" || { error "Failed to change directory to $SOURCE_DIR"; continue; }

      for patch in "../$dir"/*.patch; do
        if [ -f "$patch" ]; then
          if patch -Np0 --dry-run < "$patch" &>/dev/null; then
            log "Applying patch: $patch"
            patch -Np0 < "$patch" || error "Failed to apply patch: $patch"
          else
            log "Patch already applied or conflicts detected: $patch"
          fi
        fi
      done

      cd - > /dev/null
    fi
  done
  log "Patch application process completed."
}

# Compile the kernel
compile_kernel() {
  log "Compiling Linux kernel for $BOARD ($CHIP)..."
  KERNEL_DIR="linux-${KERNEL_VERSION}"
  cd "$KERNEL_DIR" || error "Failed to enter kernel directory: $KERNEL_DIR"
  make distclean
  if [[ "$KERNEL_ARCH" == "arm" ]]; then
    export CFLAGS="-mtune=cortex-a7"
  fi
  make ARCH=${KERNEL_ARCH} CROSS_COMPILE=${CROSS_COMPILE}- "$KERNEL_DEFCONFIG" || error "Failed to configure Linux kernel."
  if [[ "$KERNEL_ARCH" == "arm64" ]]; then
    make ARCH=${KERNEL_ARCH} CROSS_COMPILE=${CROSS_COMPILE}- -j$(nproc) Image dtbs modules || error "Kernel compilation failed."
    cp arch/${KERNEL_ARCH}/boot/Image ../OUT/ || error "Failed to copy Image to OUT."
  else
    make ARCH=${KERNEL_ARCH} CROSS_COMPILE=${CROSS_COMPILE}- -j$(nproc) zImage dtbs modules || error "Kernel compilation failed."
    cp arch/${KERNEL_ARCH}/boot/zImage ../OUT/ || error "Failed to copy zImage to OUT."
  fi
  cp .config ../OUT/config-${KERNEL_VERSION} || error "Failed to copy .config to OUT as config-${KERNEL_VERSION}."
  cp System.map ../OUT/ || error "Failed to copy System.map to OUT."
  make ARCH=${KERNEL_ARCH} CROSS_COMPILE=${CROSS_COMPILE}- INSTALL_MOD_PATH=../OUT modules_install || error "Failed to install kernel modules."
  cd - > /dev/null
  log "Linux kernel compiled and outputs copied to OUT directory."
}

# Copy DTS files
copy_dts_files() {
  log "Copying DTS files for $BOARD..."

  case $BOARD in
    ARM-SBC-RWA-A64) DTS_FILE="sun50i-a64-armsbc-rwa" ;;
    ARM-SBC-RP-A40i) DTS_FILE="sun50i-a40i-armsbc-rp" ;;
    ARM-SBC-RP-T527) DTS_FILE="sun50i-t527-armsbc-rp" ;;
    ARM-SBC-XZ-A64) DTS_FILE="sun50i-a64-armsbc-xz" ;;
    ARM-SBC-XZ-A20) DTS_FILE="sun7i-a20-armsbc-xz" ;;
    ARM-SBC-XZ-A83T) DTS_FILE="sun8i-a83t-armsbc-xz" ;;
    *) error "No DTS mapping found for $BOARD." ;;
  esac

  DTS_PATH="linux-${KERNEL_VERSION}/arch/${KERNEL_ARCH}/boot/dts/allwinner/$DTS_FILE.dtb"

  if [ -f "$DTS_PATH" ]; then
    mkdir -p OUT
    cp "$DTS_PATH" OUT/ || error "Failed to copy DTS file $DTS_FILE to OUT directory."
    log "Copied $DTS_FILE.dtb to OUT directory."
  else
    error "DTS file $DTS_PATH not found. Ensure kernel compilation generated the required DTS files."
  fi
}

# Main script execution
log "Starting the compilation process for Allwinner board $BOARD with chip $CHIP..."

if [[ "$CHIP" =~ ^(A64|T527)$ ]]; then
  KERNEL_ARCH="arm64"
  CROSS_COMPILE="aarch64-linux-gnu"
else
  KERNEL_ARCH="arm"
  CROSS_COMPILE="arm-linux-gnueabihf"
fi

check_cross_compiler
apply_patches

processors_with_atf=("A64" "T527")
if [[ " ${processors_with_atf[@]} " =~ " $CHIP " ]]; then
  compile_atf
else
  log "$CHIP is a 32-bit processor. Skipping ATF compilation."
fi

compile_uboot
compile_kernel
copy_dts_files
log "Compilation process completed successfully. All files are in the OUT directory."

