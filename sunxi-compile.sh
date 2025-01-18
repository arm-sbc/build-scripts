#!/bin/bash

# Script Name: sunxi-compile.sh

# Ensure the environment is prepared
if [ -z "$BOARD" ] || [ -z "$CHIP" ] || [ -z "$UBOOT_DEFCONFIG" ]; then
  echo -e "\033[1;31m[ERROR] Required environment variables not set. Please run set_env.sh first.\033[0m"
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

# Determine architecture and cross-compiler based on CHIP
if [[ "$CHIP" =~ ^(A64|T527)$ ]]; then
  KERNEL_ARCH="arm64"
  CROSS_COMPILE="aarch64-linux-gnu"
else
  KERNEL_ARCH="arm"
  CROSS_COMPILE="arm-linux-gnueabihf"
fi

log "Detected architecture: $KERNEL_ARCH, Cross-compiler: $CROSS_COMPILE"

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

# Function to apply patches
apply_patches() {
  log "Starting patch application process..."
  PATCH_DIRS=()

  if [[ "$BUILD_OPTION" == "uboot" || "$BUILD_OPTION" == "all" ]]; then
    PATCH_DIRS+=("patches/sunxi/uboot")
  fi

  if [[ "$BUILD_OPTION" == "kernel" || "$BUILD_OPTION" == "all" ]]; then
    PATCH_DIRS+=("patches/sunxi/kernel")
  fi

  for dir in "${PATCH_DIRS[@]}"; do
    if [ -d "$dir" ]; then
      log "Applying patches from $dir..."
      for patch in "$dir"/*.patch; do
        [ -f "$patch" ] || continue
        log "Applying patch $patch..."
        patch -Np0 < "$patch" || log "Patch $patch already applied or conflicts detected. Skipping."
      done
    else
      log "Patch directory $dir not found. Skipping."
    fi
  done
  log "Patch application process completed."
}

# Compile Trusted Firmware (ATF)
compile_atf() {
  if [[ "$BUILD_OPTION" != "uboot" && "$BUILD_OPTION" != "all" ]]; then
    log "Skipping ATF compilation for build option: $BUILD_OPTION"
    return
  fi

  log "Compiling Trusted Firmware for $CHIP..."
  cd arm-trusted-firmware || error "Failed to enter ATF directory."
  make CROSS_COMPILE="$CROSS_COMPILE"- PLAT=sun50i_a64 DEBUG=1 bl31 || error "Trusted Firmware compilation failed."
  export BL31="$(pwd)/build/sun50i_a64/debug/bl31.bin"
  [ -f "$BL31" ] || error "BL31 file not found after compilation."
  cd - > /dev/null
  log "Trusted Firmware compiled successfully. BL31 is at $BL31."
}

# Compile U-Boot
compile_uboot() {
  if [[ "$BUILD_OPTION" != "uboot" && "$BUILD_OPTION" != "all" ]]; then
    log "Skipping U-Boot compilation for build option: $BUILD_OPTION"
    return
  fi

  log "Compiling U-Boot for $CHIP..."
  cd u-boot || error "Failed to enter U-Boot directory."
  make distclean
  make CROSS_COMPILE="$CROSS_COMPILE"- "$UBOOT_DEFCONFIG" || error "Failed to configure U-Boot."
  make -j$(nproc) CROSS_COMPILE="$CROSS_COMPILE"- BL31="$BL31" || error "U-Boot compilation failed."
  mkdir -p ../OUT
  cp u-boot-sunxi-with-spl.bin ../OUT/ || error "Failed to copy u-boot-sunxi-with-spl.bin to OUT."
  log "U-Boot compiled and outputs copied to OUT directory."
  cd - > /dev/null
}

# Compile the Linux kernel
compile_kernel() {
  if [[ "$BUILD_OPTION" != "kernel" && "$BUILD_OPTION" != "all" ]]; then
    log "Skipping kernel compilation for build option: $BUILD_OPTION"
    return
  fi

  log "Compiling Linux kernel for $BOARD ($CHIP)..."
  KERNEL_DIR="linux-${KERNEL_VERSION}"
  cd "$KERNEL_DIR" || error "Failed to enter kernel directory: $KERNEL_DIR"
  make distclean
  make ARCH="$KERNEL_ARCH" CROSS_COMPILE="$CROSS_COMPILE"- "$KERNEL_DEFCONFIG" || error "Failed to configure Linux kernel."
  make ARCH="$KERNEL_ARCH" CROSS_COMPILE="$CROSS_COMPILE"- -j$(nproc) Image dtbs modules || error "Kernel compilation failed."
  mkdir -p ../OUT
  cp arch/"$KERNEL_ARCH"/boot/Image ../OUT/ || error "Failed to copy kernel Image to OUT."
  cp arch/"$KERNEL_ARCH"/boot/dts/allwinner/*.dtb ../OUT/ || error "Failed to copy DTS files to OUT."
  cd - > /dev/null
  log "Linux kernel compiled and outputs copied to OUT directory."
}

# Main script execution based on input argument
case "$1" in
  uboot)
    BUILD_OPTION="uboot"
    check_cross_compiler
    apply_patches
    compile_atf
    compile_uboot
    ;;
  kernel)
    BUILD_OPTION="kernel"
    check_cross_compiler
    apply_patches
    compile_kernel
    ;;
  all)
    BUILD_OPTION="all"
    check_cross_compiler
    apply_patches
    compile_atf
    compile_uboot
    compile_kernel
    ;;
  *)
    error "Invalid argument. Use 'uboot', 'kernel', or 'all'."
    ;;
esac

log "Compilation process completed successfully."

