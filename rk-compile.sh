#!/bin/bash

# Script Name: rk-compile.sh

# Ensure the environment is prepared
if [ -z "$BOARD" ] || [ -z "$CHIP" ] || [ -z "$UBOOT_DEFCONFIG" ] || [ -z "$KERNEL_DEFCONFIG" ] || [ -z "$KERNEL_VERSION" ]; then
  echo -e "\033[1;31m[ERROR] Required environment variables are not set. Please run set_env.sh first.\033[0m"
  exit 1
fi

# Color-coded log messages
log() {
  echo -e "\033[1;34m[$(date +'%Y-%m-%d %H:%M:%S')] $1\033[0m"  # Blue for info
}
warn() {
  echo -e "\033[1;33m[$(date +'%Y-%m-%d %H:%M:%S')] $1\033[0m"  # Yellow for warnings
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

# Function to compile U-Boot
compile_uboot() {
  log "Compiling U-Boot for $CHIP..."

  cd u-boot || error "U-Boot source directory not found."

  # Clean the build directory
  make distclean

  # Configure and compile U-Boot
  if ! make CROSS_COMPILE=aarch64-linux-gnu- "$UBOOT_DEFCONFIG"; then
    error "Failed to configure U-Boot with defconfig: $UBOOT_DEFCONFIG"
  fi

  if ! make -j$(nproc) CROSS_COMPILE=aarch64-linux-gnu-; then
    error "U-Boot compilation failed."
  fi

  # Copy compiled binaries to OUT directory
  mkdir -p ../OUT
  cp u-boot* ../OUT/ || error "Failed to copy U-Boot binaries to OUT directory."
  log "U-Boot compiled and copied to OUT directory successfully."
  cd ..
}

# Function to compile Trusted Firmware (ATF)
compile_atf() {
  log "Compiling Trusted Firmware for $CHIP..."

  cd arm-trusted-firmware || error "ATF source directory not found."
  make CROSS_COMPILE=aarch64-linux-gnu- PLAT=$CHIP DEBUG=1 bl31 || error "Failed to compile Trusted Firmware."
  export BL31=$(pwd)/build/$CHIP/debug/bl31/bl31.elf
  [ -f "$BL31" ] || error "BL31 not found after compilation."
  cd ..
  log "Trusted Firmware compiled successfully. BL31 is at $BL31"
}

# Function to compile OP-TEE
compile_optee() {
  log "Compiling OP-TEE for $CHIP..."

  if [ ! -d "optee_os" ]; then
    warn "OP-TEE source not found. Skipping OP-TEE compilation."
    return
  fi

  cd optee_os || error "Failed to enter OP-TEE source directory."
  make clean
  make PLATFORM=rockchip-$CHIP CFG_ARM64_core=y -j$(nproc) || error "OP-TEE compilation failed."
  export TEE=$(pwd)/out/arm-plat-rockchip/core/tee.bin
  [ -f "$TEE" ] || error "TEE binary not found after OP-TEE compilation."
  cd ..
  log "OP-TEE compiled successfully. TEE binary is at $TEE"
}

# Function to compile the Linux kernel
compile_kernel() {
  log "Compiling Linux kernel for $BOARD ($CHIP)..."

  KERNEL_DIR="linux-${KERNEL_VERSION}"  # Define kernel source directory
  if [ ! -d "$KERNEL_DIR" ]; then
    error "Kernel source directory not found: $KERNEL_DIR. Please download or prepare the kernel source."
  fi

  cd "$KERNEL_DIR" || error "Failed to enter kernel source directory."

  # Clean the build directory
  make distclean || warn "Failed to clean the build directory. Continuing with existing files."

  # Configure and compile the kernel
  if ! make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- "$KERNEL_DEFCONFIG"; then
    error "Failed to configure Linux kernel with defconfig: $KERNEL_DEFCONFIG"
  fi

  if ! make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j$(nproc) Image dtbs modules; then
    error "Kernel compilation failed."
  fi

  # Copy compiled binaries to OUT directory
  mkdir -p ../OUT
  cp arch/arm64/boot/Image ../OUT/ || error "Failed to copy kernel image to OUT directory."
  cp arch/arm64/boot/dts/rockchip/*.dtb ../OUT/ || error "Failed to copy DTS files to OUT directory."
  log "Kernel compiled and copied to OUT directory successfully."
  cd ..
}

# Function to apply patches
apply_patches() {
  log "Applying patches for $BOARD..."
  PATCH_DIRS=("patches/rockchip/kernel" "patches/rockchip/uboot")

  for dir in "${PATCH_DIRS[@]}"; do
    if [ -d "$dir" ]; then
      log "Applying patches from $dir..."
      for patch in "$dir"/*.patch; do
        [ -f "$patch" ] || continue
        log "Applying patch $patch..."
        if ! patch -Np1 --dry-run < "$patch" &>/dev/null; then
          warn "Patch $patch already applied or conflicts detected. Skipping."
          continue
        fi
        patch -Np1 < "$patch" || error "Failed to apply patch $patch."
      done
    else
      warn "Patch directory $dir not found. Skipping."
    fi
  done
  log "Patches applied successfully."
}

# Main script execution based on input argument
case "$1" in
  uboot)
    check_cross_compiler
    apply_patches
    compile_atf
    compile_optee
    compile_uboot
    ;;
  kernel)
    check_cross_compiler
    apply_patches
    compile_kernel
    ;;
  all)
    check_cross_compiler
    apply_patches
    compile_atf
    compile_optee
    compile_uboot
    compile_kernel
    ;;
  *)
    error "Invalid argument. Use 'uboot', 'kernel', or 'all'."
    ;;
esac

log "Script execution completed successfully."

