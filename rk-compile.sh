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

# Function to apply patches
apply_patches() {
  log "Starting patch application process..."
  PATCH_DIRS=()

  if [[ "$BUILD_OPTION" == "uboot" || "$BUILD_OPTION" == "all" ]]; then
    PATCH_DIRS+=("patches/sunxi/uboot")
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

  KERNEL_DIR="linux-${KERNEL_VERSION}"
  DTS_MAKEFILE="arch/$ARCH/boot/dts/rockchip/Makefile"
  DTS_PATH="arch/$ARCH/boot/dts/rockchip"
  BOARD_DTS="../custom_configs/dts/$DEVICE_TREE"
  COMPILED_DTB_PATH="../OUT/$(basename "${BOARD_DTS%.dts}.dtb")"

  if [ ! -d "$KERNEL_DIR" ]; then
    error "Kernel source directory not found: $KERNEL_DIR. Please download or prepare the kernel source."
  fi

  # Dynamically set the cross-compiler based on architecture
  if [ "$ARCH" = "arm64" ]; then
    CROSS_COMPILE="aarch64-linux-gnu-"
    KERNEL_IMAGE_TYPE="Image"
  elif [ "$ARCH" = "arm" ]; then
    CROSS_COMPILE="arm-linux-gnueabihf-"
    KERNEL_IMAGE_TYPE="zImage"
  else
    error "Unsupported architecture: $ARCH. Exiting."
  fi

  log "Using cross-compiler: $CROSS_COMPILE"
  log "Kernel image type: $KERNEL_IMAGE_TYPE"

  cd "$KERNEL_DIR" || error "Failed to enter kernel source directory."

  # Clean the build directory
  make ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" distclean || warn "Failed to clean the build directory. Continuing with existing files."

  # Configure kernel using the defconfig file from custom_configs/defconfig
  CUSTOM_DEFCONFIG_DIR="../custom_configs/defconfig"
  if [ ! -f "$CUSTOM_DEFCONFIG_DIR/$KERNEL_DEFCONFIG" ]; then
    error "Defconfig file not found: $CUSTOM_DEFCONFIG_DIR/$KERNEL_DEFCONFIG"
  fi

  # Copy the defconfig file to .config
  log "Copying defconfig to .config: $KERNEL_DEFCONFIG"
  cp "$CUSTOM_DEFCONFIG_DIR/$KERNEL_DEFCONFIG" .config || error "Failed to copy defconfig to .config"

  # Generate the final configuration
  log "Generating kernel configuration from defconfig..."
  make ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" olddefconfig || error "Failed to configure kernel."

  # Prompt for running menuconfig
  echo -e "\033[1;33mDo you want to modify the kernel configuration using menuconfig? [y/N]:\033[0m"
  read -r RUN_MENUCONFIG
  if [[ "$RUN_MENUCONFIG" =~ ^[Yy]$ ]]; then
    log "Launching menuconfig..."
    make ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" menuconfig || error "menuconfig failed."
    log "menuconfig completed. Continuing with kernel compilation..."
  else
    log "Skipping menuconfig."
  fi

  # Copy the updated .config to the OUT directory
  CONFIG_OUTPUT="../OUT/config-$KERNEL_VERSION"
  if [ -f ".config" ]; then
    cp .config "$CONFIG_OUTPUT" || error "Failed to copy updated .config to $CONFIG_OUTPUT"
    log "Copied updated kernel configuration to $CONFIG_OUTPUT"
  else
    error ".config file not found after kernel configuration."
  fi

  # Build kernel Image and modules
  make ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" -j$(nproc) "$KERNEL_IMAGE_TYPE" modules || error "Kernel compilation failed."

  MODULES_OUT_DIR="../OUT/modules"
  mkdir -p "$MODULES_OUT_DIR"
  make ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" INSTALL_MOD_PATH="$MODULES_OUT_DIR" modules_install || error "Failed to install modules."
  log "Kernel modules installed to $MODULES_OUT_DIR."

# Function to compile DTS files for Rockchip boards
compile_dts() {
  log "Starting DTS compilation for Rockchip boards..."

  # Resolve the absolute script directory
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  # Ensure DEVICE_TREE and ARCH are set
  if [ -z "$DEVICE_TREE" ] || [ -z "$ARCH" ]; then
    error "DEVICE_TREE or ARCH is not set. Ensure both variables are properly configured."
  fi

  # Determine DTS source directory based on architecture
  if [ "$ARCH" = "arm64" ]; then
    DTS_SOURCE_DIR="$SCRIPT_DIR/custom_configs/dts/rockchip/arm64"
    DTS_PATH="$SCRIPT_DIR/linux-${KERNEL_VERSION}/arch/arm64/boot/dts/armsbc"
    DTS_MAIN_MAKEFILE="$SCRIPT_DIR/linux-${KERNEL_VERSION}/arch/arm64/boot/dts/Makefile"
  elif [ "$ARCH" = "arm" ]; then
    DTS_SOURCE_DIR="$SCRIPT_DIR/custom_configs/dts/rockchip/arm32"
    DTS_PATH="$SCRIPT_DIR/linux-${KERNEL_VERSION}/arch/arm/boot/dts/armsbc"
    DTS_MAIN_MAKEFILE="$SCRIPT_DIR/linux-${KERNEL_VERSION}/arch/arm/boot/dts/Makefile"
  else
    error "Unsupported architecture: $ARCH for Rockchip boards."
  fi

  # Verify the DTS source directory
  if [ ! -d "$DTS_SOURCE_DIR" ]; then
    error "DTS source directory not found: $DTS_SOURCE_DIR. Ensure the directory exists."
  fi

  # Create the armsbc directory if it doesn't exist
  if [ ! -d "$DTS_PATH" ]; then
    log "Creating DTS directory: $DTS_PATH"
    mkdir -p "$DTS_PATH" || error "Failed to create DTS directory: $DTS_PATH"
  fi

  # Copy all files from the source directory to the kernel DTS directory
  log "Copying all DTS files to kernel DTS directory: $DTS_PATH"
  cp -r "$DTS_SOURCE_DIR/"* "$DTS_PATH/" || error "Failed to copy DTS files to $DTS_PATH."
  log "All DTS files copied from $DTS_SOURCE_DIR to $DTS_PATH"

  # Add the 'armsbc' entry to the main DTS Makefile
  if ! grep -q "subdir-y += armsbc" "$DTS_MAIN_MAKEFILE"; then
    echo "subdir-y += armsbc" >> "$DTS_MAIN_MAKEFILE"
    log "Added 'subdir-y += armsbc' to $DTS_MAIN_MAKEFILE"
  fi

  # Compile the DTB using the kernel build system
  log "Compiling DTS files using kernel build system..."
  cd "$SCRIPT_DIR/linux-${KERNEL_VERSION}" || error "Failed to enter kernel source directory."
  make ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" dtbs || error "Failed to compile DTBs."

  # Verify and move the generated DTB file
  GENERATED_DTB="$DTS_PATH/$(basename "${DEVICE_TREE%.dts}.dtb")"
  if [ -f "$GENERATED_DTB" ]; then
    log "Generated DTB file: $GENERATED_DTB"
    mv "$GENERATED_DTB" "$SCRIPT_DIR/OUT/" || error "Failed to move DTB file to OUT directory."
    log "DTB file moved to OUT directory: $SCRIPT_DIR/OUT/$(basename "$GENERATED_DTB")"
  else
    error "DTB file not created: $GENERATED_DTB"
  fi

  log "DTS compilation completed successfully for Rockchip boards."
}

  # Copy the kernel image, .config, and System.map to OUT directory
  KERNEL_IMAGE_PATH="arch/$ARCH/boot/$KERNEL_IMAGE_TYPE"
  SYSTEM_MAP_OUTPUT="../OUT/System.map-$KERNEL_VERSION"

  # Copy kernel image
  if [ -f "$KERNEL_IMAGE_PATH" ]; then
    cp "$KERNEL_IMAGE_PATH" ../OUT/ || error "Failed to copy kernel image to OUT directory."
    log "Copied kernel image ($KERNEL_IMAGE_PATH) to OUT directory."
  else
    error "Kernel image not found: $KERNEL_IMAGE_PATH"
  fi

  # Copy System.map as System.map-$KERNEL_VERSION
  if [ -f "System.map" ]; then
    cp System.map "$SYSTEM_MAP_OUTPUT" || error "Failed to copy System.map to $SYSTEM_MAP_OUTPUT"
    log "Copied System.map to $SYSTEM_MAP_OUTPUT"
  else
    warn "System.map file not found. Skipping System.map copy."
  fi

  log "Kernel, modules, configuration, compiled and copied successfully."
  cd ..
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
    compile_kernel
    compile_dts
    ;;
  all)
    check_cross_compiler
    apply_patches
    compile_atf
    compile_optee
    compile_uboot
    compile_kernel
    compile_dts
    ;;
  *)
    error "Invalid argument. Use 'uboot', 'kernel', or 'all'."
    ;;
esac

log "Script execution completed successfully."

