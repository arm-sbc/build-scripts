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

apply_uboot_patches() {
  log "Starting U-Boot patch application process..."
  PATCH_DIR="patches/sunxi/uboot"

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
  PATCH_DIR="patches/sunxi/kernel"

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
      patch -Np1 -i "../$patch" || log "Patch $patch already applied or conflicts detected. Skipping."
    )
  done

  log "Kernel patch application process completed."
}

# Function to dynamically add DTB entry to Makefile
add_dtb_entry() {
  MAKEFILE_PATH="path/to/Makefile"  # Adjust this path as needed
  NEW_DTB_ENTRY="$DEVICE_TREE_NAME.dtb"

  # Detect the correct family section in the Makefile
  FAMILY_SECTION=$(grep -i "dtb-\$(CONFIG_MACH_$PROCESSOR_FAMILY)" "$MAKEFILE_PATH" | head -n 1)

  if [[ -z "$FAMILY_SECTION" ]]; then
    error "Family section for $PROCESSOR_FAMILY not found in the Makefile."
  fi

  # Construct the line to add to the Makefile
  NEW_LINE="    $NEW_DTB_ENTRY"

  # Append the new DTB entry under the existing family section
  if grep -q "$NEW_LINE" "$MAKEFILE_PATH"; then
    log "DTB entry $NEW_DTB_ENTRY already exists in Makefile. Skipping addition."
  else
    sed -i "/$FAMILY_SECTION/a $NEW_LINE" "$MAKEFILE_PATH"
    log "Added $NEW_DTB_ENTRY to the Makefile under $FAMILY_SECTION."
  fi
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

  log "Compiling U-Boot for $CHIP ($PROCESSOR_FAMILY family)..."
  cd u-boot || error "Failed to enter U-Boot directory."

  # Apply patches based on processor family if necessary
  if [ -d "patches/$PROCESSOR_FAMILY" ]; then
    log "Applying patches for $PROCESSOR_FAMILY..."
    for patch in patches/$PROCESSOR_FAMILY/*.patch; do
      git apply "$patch" || log "Failed to apply patch: $patch"
    done
  fi

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
  if [[ "$ARCH" == "arm64" ]]; then
    KERNEL_IMAGE="Image"
  else
    KERNEL_IMAGE="zImage"
  fi

  make ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" -j$(nproc) "$KERNEL_IMAGE" modules || error "Kernel compilation failed."
  make ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" INSTALL_MOD_PATH="$OUT_DIR/tmp_modules" modules_install || error "Module installation failed."

  # Copy only the kernel modules directory to the final OUT/modules location
  MODULES_DIR="$OUT_DIR/modules"
  mkdir -p "$MODULES_DIR"
  KERNEL_MODULES_SRC="$OUT_DIR/tmp_modules/lib/modules/$KERNEL_VERSION"
  KERNEL_MODULES_DEST="$MODULES_DIR/$KERNEL_VERSION"

  if [ -d "$KERNEL_MODULES_SRC" ]; then
    cp -r "$KERNEL_MODULES_SRC" "$MODULES_DIR/" || error "Failed to copy kernel modules to $MODULES_DIR."
    log "Copied kernel modules to $MODULES_DIR."
  else
    error "Kernel modules directory not found: $KERNEL_MODULES_SRC"
  fi

  # Clean up temporary modules directory
  rm -rf "$OUT_DIR/tmp_modules"

  # Copy the kernel image to the OUT directory without version suffix
  KERNEL_OUTPUT="$OUT_DIR/$KERNEL_IMAGE"
  cp "arch/$ARCH/boot/$KERNEL_IMAGE" "$KERNEL_OUTPUT" || error "Failed to copy $KERNEL_IMAGE to $OUT_DIR."
  log "Copied $KERNEL_IMAGE to $OUT_DIR."

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

# Function to compile DTS files for Sunxi/Allwinner boards
compile_dts() {
  log "Starting DTS compilation for Allwinner boards..."

  # Resolve the absolute script directory
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  # Ensure DEVICE_TREE and ARCH are set
  if [ -z "$DEVICE_TREE" ] || [ -z "$ARCH" ]; then
    error "DEVICE_TREE or ARCH is not set. Ensure both variables are properly configured."
  fi

  # Determine DTS source directory based on architecture
  if [ "$ARCH" = "arm64" ]; then
    DTS_SOURCE_DIR="$SCRIPT_DIR/custom_configs/dts/sunxi/arm64"
    DTS_PATH="$SCRIPT_DIR/linux-${KERNEL_VERSION}/arch/arm64/boot/dts/armsbc"
    DTS_MAIN_MAKEFILE="$SCRIPT_DIR/linux-${KERNEL_VERSION}/arch/arm64/boot/dts/Makefile"
  elif [ "$ARCH" = "arm" ]; then
    DTS_SOURCE_DIR="$SCRIPT_DIR/custom_configs/dts/sunxi/arm32"
    DTS_PATH="$SCRIPT_DIR/linux-${KERNEL_VERSION}/arch/arm/boot/dts/armsbc"
    DTS_MAIN_MAKEFILE="$SCRIPT_DIR/linux-${KERNEL_VERSION}/arch/arm/boot/dts/Makefile"
  else
    error "Unsupported architecture: $ARCH for Allwinner boards."
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

  log "DTS compilation completed successfully for Allwinner boards."
}

# Main script execution
case "$1" in
  uboot)
    BUILD_OPTION="uboot"
    check_cross_compiler
    compile_atf
    apply_uboot_patches
    add_dtb_entry
    compile_uboot
    ;;
  kernel)
    BUILD_OPTION="kernel"
    check_cross_compiler
    apply_kernel_patches
    compile_kernel
    compile_dts
    ;;
  all)
    BUILD_OPTION="all"
    check_cross_compiler
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

log "Compilation process completed successfully."

