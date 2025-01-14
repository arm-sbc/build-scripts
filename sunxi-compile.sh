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
      fi

      cd "$SOURCE_DIR" || error "Failed to change directory to $SOURCE_DIR"

      for patch in "../$dir"/*.patch; do
        if [ -f "$patch" ]; then
          log "Checking patch: $patch"
          if patch -Np0 --dry-run < "$patch" &>/dev/null; then
            log "Applying patch: $patch"
            patch -Np0 < "$patch" || error "Failed to apply patch: $patch"
          else
            log "Patch already applied or conflicts detected: $patch. Skipping."
          fi
        fi
      done

      cd - > /dev/null
    else
      log "Patch directory $dir not found. Skipping."
    fi
  done

  log "Patch application process completed."
}

# Compile Trusted Firmware (ATF)
compile_atf() {
  log "Compiling Trusted Firmware for $CHIP..."
  cd arm-trusted-firmware || error "Failed to enter ATF directory."
  make CROSS_COMPILE=aarch64-linux-gnu- PLAT=sun50i_a64 DEBUG=1 bl31 || error "Trusted Firmware compilation failed."
  export BL31="$(pwd)/build/sun50i_a64/debug/bl31/bl31.elf"
  [ -f "$BL31" ] || error "BL31 file not found after compilation."
  cd - > /dev/null
  log "Trusted Firmware compiled successfully. BL31 is at $BL31."
}

# Download and prepare Crust firmware
setup_crust_firmware() {
  if [[ "$CHIP" == "a64" ]]; then
    log "Setting up Crust firmware for A64..."

    if [ ! -d "crust" ]; then
      git clone https://github.com/arm-sbc/build-scripts/crust || error "Failed to clone Crust repository."
    fi

    SCP_BIN="crust/build/scp/scp.bin"

    if [ ! -f "$SCP_BIN" ]; then
      log "Crust SCP binary not found. Compiling SCP..."
      cd crust || error "Failed to enter Crust directory."
      export CROSS_COMPILE=or1k-linux-musl-
      make pine64_plus_defconfig || error "Failed to configure Crust firmware."
      make scp || error "Failed to compile Crust firmware."
      [ -f "$SCP_BIN" ] || error "Crust SCP binary not found after compilation."
      cd - > /dev/null
    else
      log "Using existing Crust SCP binary at $SCP_BIN."
    fi

    export SCP_BIN
    log "Crust firmware setup complete. SCP binary is at $SCP_BIN."
  else
    log "Crust firmware is not required for $CHIP."
  fi
}


# Compile U-Boot
compile_uboot() {
  log "Compiling U-Boot for $CHIP..."
  cd u-boot || error "Failed to enter U-Boot directory."
  make distclean
  make CROSS_COMPILE=aarch64-linux-gnu- "$UBOOT_DEFCONFIG" || error "Failed to configure U-Boot."
  make -j$(nproc) CROSS_COMPILE=aarch64-linux-gnu- BL31="$BL31" SCP="$SCP_BIN" || error "U-Boot compilation failed."
  mkdir -p ../OUT
  cp u-boot.bin ../OUT || error "Failed to copy U-Boot binary to OUT."
  log "U-Boot compiled successfully."
  cd - > /dev/null
}

# Compile the kernel
compile_kernel() {
  log "Compiling Linux kernel for $BOARD ($CHIP)..."
  KERNEL_DIR="linux-${KERNEL_VERSION}"
  cd "$KERNEL_DIR" || error "Failed to enter kernel directory: $KERNEL_DIR"
  make distclean
  make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- "$KERNEL_DEFCONFIG" || error "Failed to configure Linux kernel."
  make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j$(nproc) Image dtbs modules || error "Kernel compilation failed."
  mkdir -p ../OUT
  cp arch/arm64/boot/Image ../OUT || error "Failed to copy kernel image to OUT."
  cp arch/arm64/boot/dts/allwinner/*.dtb ../OUT || error "Failed to copy DTS files to OUT."
  make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- INSTALL_MOD_PATH=../OUT modules_install || error "Failed to install kernel modules."
  cd - > /dev/null
  log "Linux kernel compiled successfully."
}

# Main script execution
log "Starting the compilation process for Allwinner board $BOARD with chip $CHIP..."
check_cross_compiler
apply_patches
compile_atf
setup_crust_firmware
compile_uboot
compile_kernel
log "Compilation process completed successfully. All files are in the OUT directory."
