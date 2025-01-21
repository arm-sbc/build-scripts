#!/bin/bash

# Script Name: sunxi-compile.sh

# Global Variables
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="$SCRIPT_DIR/OUT"

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

# Function to check cross-compiler
check_cross_compiler() {
  log "Checking cross-compiler for $CHIP..."
  if command -v "${CROSS_COMPILE}gcc" &>/dev/null; then
    CROSS_COMPILER_VERSION=$(${CROSS_COMPILE}gcc --version | head -n 1)
    log "Using cross-compiler: $CROSS_COMPILER_VERSION"
  else
    error "Cross-compiler '${CROSS_COMPILE}gcc' not found. Please install it."
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
        (
          cd u-boot || error "Failed to enter U-Boot directory."
          patch -Np0 -i "../$patch" || log "Patch $patch already applied or conflicts detected. Skipping."
        )
      done
    else
      log "Patch directory $dir not found. Skipping."
    fi
  done
  log "Patch application process completed."
}

# Function to compile ATF
compile_atf() {
  if [[ "$ARCH" != "arm64" ]]; then
    log "Skipping ATF compilation: Not required for $ARCH."
    return
  fi

  if [[ "$BUILD_OPTION" != "uboot" && "$BUILD_OPTION" != "all" ]]; then
    log "Skipping ATF compilation for build option: $BUILD_OPTION"
    return
  fi

  # Define the expected BL31 path based on the platform
  PLATFORM=$(map_chip_to_platform)
  BL31_PATH="arm-trusted-firmware/build/${PLATFORM}/release/bl31.bin"

  # Check if the BL31 binary already exists
  if [ -f "$BL31_PATH" ]; then
    log "BL31 already exists at $BL31_PATH. Skipping ATF compilation."
    export BL31="$SCRIPT_DIR/$BL31_PATH"
    return
  fi

  log "Compiling Trusted Firmware for $CHIP..."
  cd arm-trusted-firmware || error "Failed to enter ATF directory."

  # Compile ATF with the correct platform and options
  make CROSS_COMPILE="$CROSS_COMPILE" PLAT="$PLATFORM" DEBUG=0 bl31 -j$(nproc) || error "Trusted Firmware compilation failed."

  # Verify the BL31 binary
  export BL31="$SCRIPT_DIR/$BL31_PATH"
  if [ ! -f "$BL31" ]; then
    error "BL31 file not found after compilation. Expected path: $BL31"
  fi

  cd - > /dev/null
  log "Trusted Firmware compiled successfully. BL31 is at $BL31."
}

# Function to compile U-Boot
compile_uboot() {
  if [[ "$BUILD_OPTION" != "uboot" && "$BUILD_OPTION" != "all" ]]; then
    log "Skipping U-Boot compilation for build option: $BUILD_OPTION"
    return
  fi

  log "Compiling U-Boot for $CHIP..."
  cd u-boot || error "Failed to enter U-Boot directory."

  # Clean the build directory
  log "Cleaning the build directory..."
  make distclean || log "Failed to clean the build directory. Continuing with existing files."

  # Configure U-Boot
  log "Configuring U-Boot with $UBOOT_DEFCONFIG..."
  make CROSS_COMPILE="$CROSS_COMPILE" "$UBOOT_DEFCONFIG" || error "Failed to configure U-Boot."

  # Ensure DEVICE_TREE is set and strip .dts extension
  if [[ -z "$DEVICE_TREE" ]]; then
    error "DEVICE_TREE is not set. Ensure the correct value is exported from set_env.sh."
  fi
  DEVICE_TREE_NAME="${DEVICE_TREE%.dts}"

  log "Using DEVICE_TREE: $DEVICE_TREE_NAME"

  # Handle BL31 for ARM64
  BL31_ARG=""
  if [[ "$ARCH" == "arm64" ]]; then
    if [ -z "$BL31" ]; then
      error "BL31 is not set. Ensure Trusted Firmware (ATF) is compiled and exported before building U-Boot."
    fi

    if [ ! -f "$BL31" ]; then
      error "BL31 binary not found at $BL31. Check the ATF build process."
    fi

    log "Using BL31 located at: $BL31"
    BL31_ARG="BL31=$BL31"
  fi

  # Handle SCP for A64
  SCP_ARG=""
  if [[ "$CHIP" == "a64" ]]; then
    log "Handling SCP for A64 chip..."
    if [ ! -d "../crust" ]; then
      log "Crust repository not found. Cloning it..."
      git clone https://github.com/arm-sbc/crust.git ../crust || error "Failed to clone Crust repository."
    else
      log "Crust repository already exists. Skipping clone."
    fi

    SCP_FILE="../crust/scp.bin"
    if [ ! -f "$SCP_FILE" ]; then
      error "SCP file not found at $SCP_FILE. Ensure Crust is built correctly."
    fi

    log "Using SCP file located at: $SCP_FILE"
    SCP_ARG="SCP=$SCP_FILE"
  fi

  # Build U-Boot with stripped DEVICE_TREE name, BL31, and SCP for A64
  log "Building U-Boot with DEVICE_TREE=$DEVICE_TREE_NAME..."
  make CROSS_COMPILE="$CROSS_COMPILE" DEVICE_TREE="$DEVICE_TREE_NAME" $BL31_ARG $SCP_ARG -j$(nproc) || error "U-Boot compilation failed."

  # Copy the Sunxi-specific output file
  mkdir -p "$OUT_DIR"
  log "Copying U-Boot output files to OUT directory..."
  cp u-boot-sunxi-with-spl.bin "$OUT_DIR/" || error "Failed to copy u-boot-sunxi-with-spl.bin to $OUT_DIR."

  log "U-Boot compilation and output copying completed successfully."
  cd - >/dev/null
}

# Function to compile the kernel
compile_kernel() {
  log "Compiling Linux kernel for $BOARD ($CHIP)..."

  KERNEL_DIR="linux-${KERNEL_VERSION}"
  if [ ! -d "$KERNEL_DIR" ]; then
    error "Kernel source directory not found: $KERNEL_DIR."
  fi

  cd "$KERNEL_DIR" || error "Failed to enter kernel source directory."

  # Clean and configure the kernel
  make ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" distclean || log "Failed to clean the build directory."
  cp "../custom_configs/defconfig/$KERNEL_DEFCONFIG" .config || error "Failed to copy defconfig."
  make ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" olddefconfig || error "Kernel configuration failed."

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
  CONFIG_OUTPUT="$OUT_DIR/config-$KERNEL_VERSION"
  if [ -f ".config" ]; then
    cp .config "$CONFIG_OUTPUT" || error "Failed to copy updated .config to $CONFIG_OUTPUT"
    log "Copied updated kernel configuration to $CONFIG_OUTPUT"
  else
    error ".config file not found after kernel configuration."
  fi

  # Compile the kernel image and modules
  make ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" -j$(nproc) Image modules || error "Kernel compilation failed."
  make ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" INSTALL_MOD_PATH="$OUT_DIR/modules" modules_install || error "Module installation failed."

  # Rename and copy System.map to OUT directory with version suffix
  SYSTEM_MAP="System.map"
  SYSTEM_MAP_VERSIONED="$OUT_DIR/System.map-$KERNEL_VERSION"
  if [ -f "$SYSTEM_MAP" ]; then
    cp "$SYSTEM_MAP" "$SYSTEM_MAP_VERSIONED" || error "Failed to copy System.map to $OUT_DIR with version suffix."
    log "Copied System.map to $OUT_DIR as System.map-$KERNEL_VERSION"
  else
    warn "System.map file not found."
  fi

  log "Kernel compilation completed successfully."
  cd - >/dev/null
}

# Function to compile DTS files
compile_dts() {
  log "Compiling DTS for $DEVICE_TREE..."

  # Ensure DEVICE_TREE is set
  if [ -z "$DEVICE_TREE" ]; then
    error "DEVICE_TREE is not set. Ensure it is exported before running the script."
  fi

  # Define DTS path based on architecture
  if [ "$ARCH" = "arm64" ]; then
    DTS_PATH="arch/arm64/boot/dts/allwinner"
  elif [ "$ARCH" = "arm" ]; then
    DTS_PATH="arch/arm/boot/dts/allwinner"
  else
    error "Unsupported architecture: $ARCH. Cannot determine DTS path."
  fi

  # Ensure the DTS file exists in the custom configs
  BOARD_DTS="$SCRIPT_DIR/custom_configs/dts/$DEVICE_TREE"
  if [ ! -f "$BOARD_DTS" ]; then
    error "DTS file not found: $BOARD_DTS. Ensure the correct DTS file is present."
  fi

  # Copy the DTS file to the kernel DTS directory
  log "Copying DTS file to kernel DTS directory..."
  cp "$BOARD_DTS" "linux-${KERNEL_VERSION}/$DTS_PATH/" || error "Failed to copy DTS file to $DTS_PATH."
  log "Copied DTS file to: linux-${KERNEL_VERSION}/$DTS_PATH/$(basename "$BOARD_DTS")"

  # Add entry to the DTS Makefile
  DTS_MAKEFILE="linux-${KERNEL_VERSION}/$DTS_PATH/Makefile"
  BOARD_NAME=$(basename "${BOARD_DTS%.dts}")

  if [ "$ARCH" = "arm64" ]; then
    # Use CONFIG_ARCH_SUNXI for arm64
    if ! grep -q "dtb-\$(CONFIG_ARCH_SUNXI) += $BOARD_NAME.dtb" "$DTS_MAKEFILE"; then
      echo "dtb-\$(CONFIG_ARCH_SUNXI) += $BOARD_NAME.dtb" >> "$DTS_MAKEFILE"
      log "Added DTS entry to Makefile: dtb-\$(CONFIG_ARCH_SUNXI) += $BOARD_NAME.dtb"
    else
      log "DTS entry already exists in Makefile: dtb-\$(CONFIG_ARCH_SUNXI) += $BOARD_NAME.dtb"
    fi
  else
    # Use CONFIG_MACH_* format for arm
    FAMILY_PREFIX=$(basename "$BOARD_DTS" | cut -d '-' -f 1)
    CONFIG_MACH="CONFIG_MACH_${FAMILY_PREFIX^^}" # Convert family prefix to uppercase
    DTS_ENTRY="dtb-\$($CONFIG_MACH) += $BOARD_NAME.dtb"
    if ! grep -q "$BOARD_NAME.dtb" "$DTS_MAKEFILE"; then
      echo "$DTS_ENTRY" >> "$DTS_MAKEFILE"
      log "Added DTS entry to Makefile: $DTS_ENTRY"
    else
      log "DTS entry already exists in Makefile: $DTS_ENTRY"
    fi
  fi

  # Compile all DTBs
  log "Compiling all DTBs using 'make dtbs'..."
  cd "linux-${KERNEL_VERSION}" || error "Failed to enter kernel directory."
  make ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" dtbs || error "Failed to compile DTBs."

  # Copy compiled DTB to OUT directory
  log "Copying compiled DTB to OUT directory..."
  mkdir -p "$OUT_DIR"
  DTB_FILE="$DTS_PATH/$BOARD_NAME.dtb"
  cp "$DTB_FILE" "$OUT_DIR/" || error "Failed to copy $DTB_FILE to $OUT_DIR."
  log "Copied compiled DTB to OUT directory: $OUT_DIR/$(basename "$DTB_FILE")"

  log "DTB compilation and copying completed successfully."
  cd - >/dev/null
}

# Main script execution
case "$1" in
  uboot)
    BUILD_OPTION="uboot"
    check_cross_compiler
    compile_atf
    compile_uboot
    ;;
  kernel)
    BUILD_OPTION="kernel"
    check_cross_compiler
    compile_kernel
    compile_dts
    ;;
  all)
    BUILD_OPTION="all"
    check_cross_compiler
    compile_atf
    compile_uboot
    compile_kernel
    compile_dts
    ;;
  *)
    error "Invalid argument. Use 'uboot', 'kernel', or 'all'."
    ;;
esac

log "Compilation process completed successfully."

