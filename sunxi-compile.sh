#!/bin/bash

# Script Name: sunxi-compile.sh


# Ensure the environment is prepared
if [ -z "$BOARD" ] || [ -z "$CHIP" ] || [ -z "$UBOOT_DEFCONFIG" ] || [ -z "$KERNEL_DEFCONFIG" ]; then
  echo -e "\033[1;31m[ERROR] Environment variables not set. Please run set_env.sh first.\033[0m"
  exit 1
fi

# Color-coded log messages
log() {
  echo -e "\033[1;34m[$(date +'%Y-%m-%d %H:%M:%S')] $1\033[0m"  # Blue for info
}
error() {
  echo -e "\033[1;31m[$(date +'%Y-%m-%d %H:%M:%S')] $1\033[0m"  # Red for errors
  exit 1
}

# Function to check cross-compiler
check_cross_compiler() {
  log "Checking cross-compiler for $CHIP..."
  if command -v aarch64-linux-gnu-gcc &>/dev/null; then
    CROSS_COMPILER_VERSION=$(aarch64-linux-gnu-gcc --version | head -n 1)
    log "Using cross-compiler: $CROSS_COMPILER_VERSION"
  else
    error "Cross-compiler 'aarch64-linux-gnu-gcc' not found. Please install it."
  fi
}

# Function to apply patches
apply_patches() {
  log "Starting patch application process..."

  # Define patch directories
  PATCH_DIRS=("patches/sunxi/kernel" "patches/sunxi/uboot")
  log "Using patches from patches/sunxi/kernel and patches/sunxi/uboot."

  log "Debugging patch directories and files..."
  for dir in "${PATCH_DIRS[@]}"; do
    if [ -d "$dir" ]; then
      log "Contents of $dir:"
      ls -l "$dir"
    else
      warn "Patch directory $dir does not exist."
    fi
  done
  log "End of debug output."

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
          log "Checking patch: $patch"
          if patch -Np0 --dry-run < "$patch" &>/dev/null; then
            log "Applying patch: $patch"
            if patch -Np0 < "$patch"; then
              log "Successfully applied patch: $patch"
            else
              error "Failed to apply patch: $patch"
            fi
          else
            warn "Patch already applied or conflicts detected: $patch. Skipping."
          fi
        else
          warn "No patch files found in $dir."
        fi
      done

      cd - > /dev/null
    else
      warn "Patch directory $dir not found. Skipping."
    fi
  done

  log "Patch application process completed."
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
  make CROSS_COMPILE=aarch64-linux-gnu- "$UBOOT_DEFCONFIG" || error "Failed to configure U-Boot."
  make -j$(nproc) CROSS_COMPILE=aarch64-linux-gnu- BL31="$BL31" || error "U-Boot compilation failed."

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

# Copy DTS files
copy_dts_files() {
  log "Copying DTS files for $BOARD..."

  # Define DTS mappings
  case $BOARD in
    ARM-SBC-RWA-A64) DTS_FILE="sun50i-a64-armsbc-rwa" ;;
    ARM-SBC-RP-A40i) DTS_FILE="sun50i-a40i-armsbc-rp" ;;
    ARM-SBC-RP-T527) DTS_FILE="sun50i-t527-armsbc-rp" ;;
    ARM-SBC-XZ-A64) DTS_FILE="sun50i-a64-armsbc-xz" ;;
    ARM-SBC-XZ-A20) DTS_FILE="sun7i-a20-armsbc-xz" ;;
    *) error "No DTS mapping found for $BOARD." ;;
  esac

  DTS_PATH="linux-${KERNEL_VERSION}/arch/arm64/boot/dts/allwinner/$DTS_FILE.dtb"

  if [ -f "$DTS_PATH" ]; then
    mkdir -p OUT
    cp "$DTS_PATH" OUT/ || error "Failed to copy DTS file $DTS_FILE to OUT directory."
    log "Copied $DTS_FILE.dtb to OUT directory."
  else
    error "DTS file $DTS_PATH not found. Ensure kernel compilation generated the required DTS files."
  fi
}

# Compile the kernel
compile_kernel() {
  log "Compiling Linux kernel for $BOARD ($CHIP)..."
  KERNEL_DIR="linux-${KERNEL_VERSION}"
  cd "$KERNEL_DIR" || error "Failed to enter kernel directory: $KERNEL_DIR"
  make distclean
  make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- "$KERNEL_DEFCONFIG" || error "Failed to configure Linux kernel."
  make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j$(nproc) Image dtbs modules || error "Kernel compilation failed."

  # Copy kernel outputs to OUT
  mkdir -p ../OUT
  if [ -f arch/arm64/boot/Image ]; then
    cp arch/arm64/boot/Image ../OUT/ || error "Failed to copy Image to OUT."
    log "Copied Image to OUT directory."
  fi
  make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- INSTALL_MOD_PATH=../OUT modules_install || error "Failed to install kernel modules."

  cd - > /dev/null
  log "Linux kernel compiled and outputs copied to OUT directory."
}

# Main script execution
log "Starting the compilation process for Allwinner board $BOARD with chip $CHIP..."
check_cross_compiler
apply_patches
compile_atf
#setup_crust_firmware
compile_uboot
compile_kernel
copy_dts_files
log "Compilation process completed successfully. All files are in the OUT directory."
