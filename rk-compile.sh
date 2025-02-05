#!/bin/bash

# Script Name: rk-compile.sh

# Function to log messages with timestamps
log() {
  echo -e "\033[1;34m[$(date +'%Y-%m-%d %H:%M:%S')] $1\033[0m"
}

log "Dumping environment variables..."
env | grep -E 'CROSS_COMPILE|BL31|DEVICE_TREE|CONFIG' > ../script_env_dump.txt


# Check required environment variables based on build option
log "Checking required environment variables for build option: $BUILD_OPTION"

if [ "$BUILD_OPTION" = "uboot" ]; then
  # Check only U-Boot-related variables
  if [ -z "$BOARD" ] || [ -z "$CHIP" ] || [ -z "$UBOOT_DEFCONFIG" ] || [ -z "$OUTPUT_DIR" ]; then
    error "Required environment variables are not set for U-Boot compilation. Please run set_env.sh first."
  fi
elif [ "$BUILD_OPTION" = "kernel" ] || [ "$BUILD_OPTION" = "all" ]; then
  # Check all variables, including kernel-related ones
  if [ -z "$BOARD" ] || [ -z "$CHIP" ] || [ -z "$UBOOT_DEFCONFIG" ] || [ -z "$KERNEL_DEFCONFIG" ] || [ -z "$KERNEL_VERSION" ] || [ -z "$OUTPUT_DIR" ]; then
    error "Required environment variables are not set for kernel compilation. Please run set_env.sh first."
  fi
else
  error "Invalid build option: $BUILD_OPTION"
fi

log "Environment variables set: BOARD=$BOARD, CHIP=$CHIP, UBOOT_DEFCONFIG=$UBOOT_DEFCONFIG, KERNEL_DEFCONFIG=$KERNEL_DEFCONFIG, KERNEL_VERSION=$KERNEL_VERSION, OUTPUT_DIR=$OUTPUT_DIR"

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

ERROR_LOG="$OUTPUT_DIR/error.log"
error() {
  echo -e "\033[1;31m[$(date +'%Y-%m-%d %H:%M:%S')] $1\033[0m"  # Red for errors
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $1" >> "$ERROR_LOG"
  exit 1
}

apply_uboot_patches() {
  log "Starting U-Boot patch application process..."
  PATCH_DIR="patches/rockchip/uboot"

  if [[ ! -d "$PATCH_DIR" ]]; then
    log "Patch directory $PATCH_DIR not found. Skipping U-Boot patch application."
    return
  fi

  log "Applying U-Boot patches from $PATCH_DIR..."
  for patch in "$PATCH_DIR"/*.patch; do
    [ -f "$patch" ] || continue
    log "Applying patch $patch..."
    (
      cd u-boot || error "Failed to enter U-Boot directory."
      patch -Np0 -i "../$patch" || log "Patch $patch already applied or conflicts detected. Skipping."
    )
  done

  log "U-Boot patch application process completed."
}

apply_kernel_patches() {
  log "Starting kernel patch application process..."
  PATCH_DIR="patches/rockchip/kernel"

  if [[ ! -d "$PATCH_DIR" ]]; then
    log "Patch directory $PATCH_DIR not found. Skipping kernel patch application."
    return
  fi

  log "Applying kernel patches from $PATCH_DIR..."
  for patch in "$PATCH_DIR"/*.patch; do
    [ -f "$patch" ] || continue
    log "Applying patch $patch..."
    (
      cd "linux-$KERNEL_VERSION" || error "Failed to enter kernel directory."
      patch -Np0 -i "../$patch" || log "Patch $patch already applied or conflicts detected. Skipping."
    )
  done

  log "Kernel patch application process completed."
}

# Function to compile U-Boot
compile_uboot() {
  log "Compiling U-Boot for $CHIP ($ARCH)..."

  cd u-boot || error "U-Boot source directory not found."

  log "Cleaning U-Boot build directory..."
  make distclean || warn "Failed to clean U-Boot build directory. Continuing."

  log "Configuring U-Boot with defconfig: $UBOOT_DEFCONFIG"
  make CROSS_COMPILE="$CROSS_COMPILE" "$UBOOT_DEFCONFIG" || error "Failed to configure U-Boot with defconfig."

  # Extract DEVICE_TREE from .config
  DEVICE_TREE_NAME=$(grep -oP 'CONFIG_DEFAULT_DEVICE_TREE="\K[^"]+' .config)
  if [[ -z "$DEVICE_TREE_NAME" ]]; then
    error "CONFIG_DEFAULT_DEVICE_TREE is not set. Check the defconfig or .config file."
  fi
  log "DEVICE_TREE_NAME resolved from .config: $DEVICE_TREE_NAME"

  # Check and export BL31 for ARM64
  if [[ "$ARCH" == "arm64" ]]; then
    if [[ -z "$BL31" || ! -f "$BL31" ]]; then
      error "BL31 binary not found. Ensure Trusted Firmware is compiled and BL31 is set."
    fi
    log "Using BL31 binary located at: $BL31"
  fi

  # Compile U-Boot with DEVICE_TREE and BL31
  log "Building U-Boot with DEVICE_TREE=$DEVICE_TREE_NAME"
  make CROSS_COMPILE="$CROSS_COMPILE" DEVICE_TREE="$DEVICE_TREE_NAME" BL31="$BL31" -j$(nproc) || error "U-Boot compilation failed."

  # Prepare output directory
  mkdir -p "$OUTPUT_DIR"

  # Copy output files based on board and configuration
  log "Copying U-Boot output files to $OUTPUT_DIR"
  cp idbloader.img u-boot-rockchip.bin "$OUTPUT_DIR/" 2>/dev/null || warn "idbloader.img or u-boot-rockchip.bin not found, skipping."
  cp u-boot.itb "$OUTPUT_DIR/" 2>/dev/null || warn "u-boot.itb not found, skipping."
  
  log "U-Boot compiled and copied to $OUTPUT_DIR successfully."
  cd - >/dev/null
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

compile_optee() {
  log "Compiling OP-TEE for $CHIP..."

  # Compile OP-TEE only for rk3399
  if [ "$CHIP" != "rk3399" ]; then
    log "OP-TEE is not required for CHIP=$CHIP. Skipping OP-TEE compilation."
    return
  fi

  # Clone OP-TEE repository if it doesn't exist
  if [ ! -d "optee_os" ]; then
    log "Cloning OP-TEE source repository..."
    git clone https://github.com/OP-TEE/optee_os.git || error "Failed to clone OP-TEE repository."
  fi

  # Enter the OP-TEE directory
  cd optee_os || error "Failed to enter OP-TEE source directory."

  # Clean and compile OP-TEE
  #log "Cleaning previous OP-TEE build..."
  #make clean || warn "Failed to clean OP-TEE build. Continuing with compilation..."

  log "Compiling OP-TEE for platform rockchip-rk3399..."
  make PLATFORM=rockchip-rk3399 CFG_ARM64_core=y -j$(nproc) V=2 || error "OP-TEE compilation failed."
  
  # Verify and export the path to the compiled TEE binary
  export TEE="$(pwd)/out/arm-plat-rockchip/core/tee.bin"
  if [ ! -f "$TEE" ]; then
    error "TEE binary not found after OP-TEE compilation. Expected path: $TEE"
  fi

  log "OP-TEE compiled successfully. TEE binary is located at: $TEE"
  cd - >/dev/null
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
  CONFIG_OUTPUT="$OUTPUT_DIR/config-$KERNEL_VERSION"
  if [ -f ".config" ]; then
    cp .config "$OUTPUT_DIR/" || error "Failed to copy updated .config to $CONFIG_OUTPUT"
    log "Copied updated kernel configuration to $OUTPUT_DIR/"
  else
    error ".config file not found after kernel configuration."
  fi

  # Build kernel Image and modules
  make ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" -j$(nproc) "$KERNEL_IMAGE_TYPE" modules || error "Kernel compilation failed."

  MODULES_OUT_DIR="$OUTPUT_DIR/"
  mkdir -p "$OUTPUT_DIR/"
  make ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" INSTALL_MOD_PATH="$MODULES_OUT_DIR" modules_install || error "Failed to install modules."
  log "Kernel modules installed to $OUTPUT_DIR/."

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
    mv "$GENERATED_DTB" "$OUTPUT_DIR/" || error "Failed to move DTB file to OUT directory."
    log "DTB file moved to OUT directory: $SCRIPT_DIR/OUT/$(basename "$GENERATED_DTB")"
  else
    error "DTB file not created: $GENERATED_DTB"
  fi

  log "DTS compilation completed successfully for Rockchip boards."
}

  # Copy the kernel image, .config, and System.map to OUT directory
  KERNEL_IMAGE_PATH="arch/$ARCH/boot/$KERNEL_IMAGE_TYPE"
  SYSTEM_MAP_OUTPUT="$OUTPUT_DIR/System.map-$KERNEL_VERSION"

  # Copy kernel image
  if [ -f "$KERNEL_IMAGE_PATH" ]; then
    cp "$KERNEL_IMAGE_PATH" $OUTPUT_DIR/ || error "Failed to copy kernel image to OUT directory."
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

# Main script execution
case "$1" in
  uboot)
    BUILD_OPTION="uboot"
    #check_cross_compiler
    compile_atf
    apply_uboot_patches
    compile_uboot
    ;;
  kernel)
    BUILD_OPTION="kernel"
    #check_cross_compiler
    apply_kernel_patches
    compile_kernel
    compile_dts
    ;;
  all)
    BUILD_OPTION="all"
    #check_cross_compiler
    compile_atf
    apply_uboot_patches
    compile_uboot
    apply_kernel_patches
    compile_kernel
    compile_dts
    ;;
  *)
    error "Invalid argument. Use 'uboot', 'kernel', or 'all'."
    ;;
esac

log "Script execution completed successfully."

