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

# Function to check cross-compiler
check_cross_compiler() {
  log "Checking cross-compiler for $CHIP..."
  if command -v ${CROSS_COMPILE}gcc &>/dev/null; then
    CROSS_COMPILER_VERSION=$(${CROSS_COMPILE}gcc --version | head -n 1)
    log "Using cross-compiler: $CROSS_COMPILER_VERSION"
  else
    error "Cross-compiler '${CROSS_COMPILE}gcc' not found. Please install it."
  fi
}

# Function to apply patches
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
          # Change to the U-Boot directory
          cd u-boot || error "Failed to enter U-Boot directory."

          # Apply the patch using -Np0
          patch -Np0 -i "../$patch" || log "Patch $patch already applied or conflicts detected. Skipping."

          # Return to the original directory
        )
      done
    else
      log "Patch directory $dir not found. Skipping."
    fi
  done
  log "Patch application process completed."
}

# Map CHIP to the correct platform
map_chip_to_platform() {
  case "$CHIP" in
    a64)
      echo "sun50i_a64"
      ;;
    h6)
      echo "sun50i_h6"
      ;;
    h616)
      echo "sun50i_h616"
      ;;
    *)
      error "Unsupported CHIP: $CHIP. Cannot determine platform."
      ;;
  esac
}

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
  BL31_PATH="arm-trusted-firmware/build/sun50i_a64/release/bl31.bin"

  # Check if the BL31 binary already exists
  if [ -f "$BL31_PATH" ]; then
    log "BL31 already exists at $BL31_PATH. Skipping ATF compilation."
    export BL31="$(pwd)/$BL31_PATH"
    return
  fi

  log "Compiling Trusted Firmware for $CHIP..."
  cd arm-trusted-firmware || error "Failed to enter ATF directory."

  # Use release mode (DEBUG=0) to ensure the binary size is within limits
  make CROSS_COMPILE="$CROSS_COMPILE" PLAT=sun50i_a64 DEBUG=0 bl31 -j$(nproc) || error "Trusted Firmware compilation failed."

  # Verify the BL31 binary
  export BL31="$(pwd)/build/sun50i_a64/release/bl31.bin"
  if [ ! -f "$BL31" ]; then
    error "BL31 file not found after compilation. Expected path: $BL31"
  fi

  cd - > /dev/null
  log "Trusted Firmware compiled successfully. BL31 is at $BL31."
}

# Compile U-Boot
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
  make distclean || warn "Failed to clean the build directory. Continuing with existing files."

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
  mkdir -p ../OUT
  log "Copying U-Boot output files to OUT directory..."
  cp u-boot-sunxi-with-spl.bin ../OUT/ || error "Failed to copy u-boot-sunxi-with-spl.bin to OUT."

  log "U-Boot compilation and output copying completed successfully."
  cd - > /dev/null
}


# Compile Kernel Function
compile_kernel() {
  log "Compiling Linux kernel for $BOARD ($CHIP)..."

  KERNEL_DIR="linux-${KERNEL_VERSION}"
  BOARD_DTS="../custom_configs/dts/$DEVICE_TREE"

  if [ ! -d "$KERNEL_DIR" ]; then
    error "Kernel source directory not found: $KERNEL_DIR. Please download or prepare the kernel source."
  fi

  # Debugging exported values
  log "Debug: ARCH=$ARCH, CROSS_COMPILE=$CROSS_COMPILE"

  # Set kernel image type dynamically
  if [ "$ARCH" = "arm64" ]; then
    KERNEL_IMAGE_TYPE="Image"
  elif [ "$ARCH" = "arm" ]; then
    KERNEL_IMAGE_TYPE="zImage"
  else
    error "Unsupported architecture: $ARCH. Cannot determine kernel image type."
  fi
  log "Kernel image type set to: $KERNEL_IMAGE_TYPE"

  cd "$KERNEL_DIR" || error "Failed to enter kernel source directory."

  # Clean the build directory
  make ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" distclean || warn "Failed to clean the build directory. Continuing with existing files."

  # Configure the kernel
  CUSTOM_DEFCONFIG_DIR="../custom_configs/defconfig"
  if [ ! -f "$CUSTOM_DEFCONFIG_DIR/$KERNEL_DEFCONFIG" ]; then
    error "Defconfig file not found: $CUSTOM_DEFCONFIG_DIR/$KERNEL_DEFCONFIG"
  fi

  log "Copying defconfig to .config: $KERNEL_DEFCONFIG"
  cp "$CUSTOM_DEFCONFIG_DIR/$KERNEL_DEFCONFIG" .config || error "Failed to copy defconfig to .config"

  log "Generating kernel configuration from defconfig..."
  make ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" olddefconfig || error "Failed to configure kernel."

  # Verify and copy the .config file
  if [ -f ".config" ]; then
    CONFIG_OUTPUT="../OUT/config-$KERNEL_VERSION"
    cp .config "$CONFIG_OUTPUT" || error "Failed to copy .config to $CONFIG_OUTPUT"
    log "Copied kernel configuration to $CONFIG_OUTPUT"
  else
    error ".config file not found after kernel configuration."
  fi

  # Compile the kernel image and modules
  make ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" -j$(nproc) "$KERNEL_IMAGE_TYPE" modules || error "Kernel compilation failed."

  MODULES_OUT_DIR="../OUT/modules"
  mkdir -p "$MODULES_OUT_DIR"
  make ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" INSTALL_MOD_PATH="$MODULES_OUT_DIR" modules_install || error "Failed to install modules."
  log "Kernel modules installed to $MODULES_OUT_DIR."

  log "Kernel compilation completed successfully. Proceeding to DTS compilation..."
  compile_dts
}

# DTS Compilation
compile_dts() {
  if [ -f "$BOARD_DTS" ]; then
    # Dynamically set the DTS_PATH based on architecture
    if [ "$ARCH" = "arm64" ]; then
      DTS_PATH="arch/arm64/boot/dts/allwinner"
    elif [ "$ARCH" = "arm" ]; then
      DTS_PATH="arch/arm/boot/dts/allwinner"
    else
      error "Unsupported architecture: $ARCH. Cannot determine DTS path."
    fi

    log "Assigned DTS_PATH: $DTS_PATH"

    # Copy the DTS file to the correct location
    cp "$BOARD_DTS" "$DTS_PATH/" || error "Failed to copy DTS file to kernel directory."
    log "Copied DTS file to: $DTS_PATH/$(basename "$BOARD_DTS")"

    # Verify the DTS file is in the correct location
    if [ ! -f "$DTS_PATH/$(basename "$BOARD_DTS")" ]; then
      error "DTS file not found in the expected directory: $DTS_PATH. Check the copy operation."
    fi
    log "Verified DTS file is in the correct directory: $DTS_PATH/$(basename "$BOARD_DTS")"

    # Add entry to the Makefile for the DTS
    DTS_MAKEFILE="$DTS_PATH/Makefile"
    FAMILY_PREFIX=$(basename "$BOARD_DTS" | cut -d '-' -f 1)
    CONFIG_MACH="CONFIG_MACH_${FAMILY_PREFIX^^}"  # Convert family prefix to uppercase
    DTS_ENTRY="dtb-\$($CONFIG_MACH) += $(basename "${BOARD_DTS%.dts}.dtb")"

    if ! grep -q "$(basename "${BOARD_DTS%.dts}.dtb")" "$DTS_MAKEFILE"; then
      echo "$DTS_ENTRY" >> "$DTS_MAKEFILE"
      log "Added entry to DTS Makefile: $DTS_ENTRY"
    fi

    # Compile the DTB using the kernel build system
    log "Compiling DTS file using kernel build system..."
    make ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" dtbs || error "Failed to compile DTBs."

    log "DTB files compiled successfully."
  else
    warn "DTS file for selected board not found: $BOARD_DTS. Skipping DTS compilation."
  fi
}

# Main script execution
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
