
#!/bin/bash

# Script Name: rk-compile.sh

# Ensure the environment is prepared
if [ -z "$BOARD" ] || [ -z "$CHIP" ] || [ -z "$UBOOT_DEFCONFIG" ] || [ -z "$KERNEL_DEFCONFIG" ]; then
  echo -e "\033[1;31m[ERROR] Environment variables not set. Please run set_env.sh first.\033[0m"
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

  # Define patch directories
  PATCH_DIRS=("patches/rockchip/kernel" "patches/kernel/uboot")
  log "Using patches from patches/rockchip/kernel and patches/rockchip/uboot."

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

# Main script execution
log "Starting the compilation process for $BOARD with chip $CHIP..."
check_cross_compiler
apply_patches

log "Compilation process complete. Proceed with building the kernel and U-Boot as needed."

# Compile Trusted Firmware (ATF)
compile_atf() {
  log "Compiling Trusted Firmware for $CHIP..."
  cd arm-trusted-firmware || { log "Failed to enter ATF directory."; exit 1; }
  make CROSS_COMPILE=aarch64-linux-gnu- PLAT=$CHIP DEBUG=1 bl31
  if [ $? -ne 0 ]; then
    log "Trusted Firmware compilation failed."
    exit 1
  fi
  export BL31="$(pwd)/build/$CHIP/debug/bl31/bl31.elf"
  if [ ! -f "$BL31" ]; then
    log "Error: BL31 file not found at $BL31 after compilation."
    exit 1
  fi
  cd ..
  log "Trusted Firmware compiled successfully. BL31 is at $BL31"
}

# Compile OP-TEE
compile_optee() {
  log "Checking OP-TEE support for $BOARD with chip $CHIP..."
  
  # Check if OP-TEE source directory exists
  if [ ! -d "optee_os/core/arch/arm/plat-rockchip" ]; then
    log "OP-TEE source directory for Rockchip not found. Skipping OP-TEE compilation."
    return
  fi

  # Dynamically check for board-specific OP-TEE files
  OPTEE_FILE="optee_os/core/arch/arm/plat-rockchip/platform_$CHIP.c"
  if [ ! -f "$OPTEE_FILE" ]; then
    warn "OP-TEE support for $CHIP is not defined in $OPTEE_FILE."
    read -p "Continue without OP-TEE? [y/N]: " choice
    if [[ "$choice" != "y" && "$choice" != "Y" ]]; then
      log "Exiting as OP-TEE is not supported for $CHIP."
      exit 1
    fi
    log "Continuing without OP-TEE compilation for $CHIP."
    return
  fi

  # Proceed with OP-TEE compilation
  log "Compiling OP-TEE for $BOARD..."
  cd optee_os || { error "Failed to change directory to optee_os."; exit 1; }
  make clean
  make PLATFORM=rockchip-$CHIP CFG_ARM64_core=y -j$(nproc)
  if [ $? -ne 0 ]; then
    error "OP-TEE compilation failed."
  fi
  if [ ! -f "out/arm-plat-rockchip/core/tee.bin" ]; then
    error "OP-TEE compilation succeeded but tee.bin not found!"
  fi
  export TEE="$(pwd)/out/arm-plat-rockchip/core/tee.bin"
  cd ..
  log "OP-TEE compiled successfully. Output: $TEE"
}

# Compile U-Boot
compile_uboot() {
  echo "Compiling U-Boot for $CHIP..."

  cd u-boot || { echo "Failed to enter U-Boot directory."; exit 1; }

  # Clean the build directory
  make distclean

  # Ensure defconfig file exists
  if [ ! -f "configs/$UBOOT_DEFCONFIG" ]; then
    echo "Error: Defconfig file 'configs/$UBOOT_DEFCONFIG' not found. Ensure the patches are applied correctly."
    exit 1
  fi

  # Use dynamically selected U-Boot defconfig
  if ! make CROSS_COMPILE=aarch64-linux-gnu- "$UBOOT_DEFCONFIG"; then
    echo "Failed to configure U-Boot for $BOARD."
    exit 1
  fi

  # Compile U-Boot
  if ! make -j$(nproc) CROSS_COMPILE=aarch64-linux-gnu- BL31="$BL31" TEE="$TEE"; then
    echo "U-Boot compilation failed."
    exit 1
  fi

  # Ensure the OUT directory exists
  mkdir -p ../OUT

# Move compiled U-Boot binaries to OUT directory
if [ -f u-boot-rockchip.bin ]; then
  cp u-boot-rockchip.bin ../OUT/ || { error "Failed to copy u-boot-rockchip.bin to OUT."; exit 1; }
  log "Copied u-boot-rockchip.bin to OUT."
elif [ -f u-boot ]; then
  cp u-boot ../OUT/u-boot || { error "Failed to copy u-boot to OUT."; exit 1; }
  log "Copied u-boot to OUT."
else
  error "No U-Boot binary found after compilation."
fi

# Copy idbloader.img if available
if [ -f idbloader.img ]; then
  cp idbloader.img ../OUT/ || { error "Failed to copy idbloader.img to OUT."; exit 1; }
  log "Copied idbloader.img to OUT."
fi

# Copy u-boot.itb if available
if [ -f u-boot.itb ]; then
  cp u-boot.itb ../OUT/ || { error "Failed to copy u-boot.itb to OUT."; exit 1; }
  log "Copied u-boot.itb to OUT."
fi

cd ..

  # Generate preloader for the chip
  log "Generating preloader for $CHIP..."
  cd rkbin || { echo "Failed to enter rkbin directory."; exit 1; }

  # Select appropriate .ini file based on the chip
  case $CHIP in
    rk3399) INI_FILE="RKBOOT/RK3399MINIALL.ini" ;;
    rk3588) INI_FILE="RKBOOT/RK3588MINIALL.ini" ;;
    rk3568) INI_FILE="RKBOOT/RK3568MINIALL.ini" ;;
    rk3288) INI_FILE="RKBOOT/RK3288MINIALL.ini" ;;
    *) warn "No preloader generation needed for $CHIP." cd ..; return 0 ;;
  esac

  # Check if the .ini file exists
  if [ ! -f "$INI_FILE" ]; then
    error "INI file '$INI_FILE' not found in rkbin directory."
    exit 1
  fi

  # Run the boot_merger tool
  if ! ./tools/boot_merger "$INI_FILE"; then
    error "Preloader generation failed."
    exit 1
  fi

  # Locate and copy the generated preloader binary
  PRELOADER_FILE=$(ls ${CHIP}_loader_v*.bin 2>/dev/null | head -n 1)
  if [ -n "$PRELOADER_FILE" ]; then
    cp "$PRELOADER_FILE" ../OUT/ || { echo "Failed to copy preloader to OUT."; exit 1; }
log "Preloader $(basename "$PRELOADER_FILE") copied to OUT directory."
else
  error "Preloader file not found after boot_merger. Please verify the process."
fi

  cd ..
  log "U-Boot compilation and preloader generation completed successfully for $CHIP."
}

# Function to compile the kernel
compile_kernel() {
  log "Compiling Linux kernel for $BOARD ($CHIP)..."

  # Determine the kernel directory based on the selected kernel
  if [[ "$KERNEL_SELECTION" -eq 1 ]]; then
    KERNEL_DIR="linux-${KERNEL_VERSION}" # Legacy kernel
  else
    KERNEL_DIR="linux-${KERNEL_VERSION}" # Latest kernel dynamically downloaded
  fi

  cd "$KERNEL_DIR" || { error "Failed to enter kernel directory: $KERNEL_DIR"; exit 1; }

  # Determine architecture and kernel image based on chip
  if [[ "$CHIP" == "rk3288" ]]; then
    ARCH="arm"
    KERNEL_IMAGE="zImage"
  else
    ARCH="arm64"
    KERNEL_IMAGE="Image"
  fi

  # Clean the build directory
  log "Cleaning the build directory..."
  make distclean || warn "Failed to clean the build directory. Continuing with existing files."

  # Dynamically determine the defconfig based on the board name
  BOARD_NORMALIZED=$(echo "$BOARD" | tr '[:upper:]' '[:lower:]' | sed 's/arm-sbc-//')
  KERNEL_DEFCONFIG="armsbc-${BOARD_NORMALIZED}_defconfig"

  # Ensure the defconfig file exists and configure the kernel
  if [ ! -f "arch/$ARCH/configs/$KERNEL_DEFCONFIG" ]; then
    error "Defconfig file not found: arch/$ARCH/configs/$KERNEL_DEFCONFIG"
    exit 1
  fi

  if ! make ARCH=$ARCH CROSS_COMPILE=aarch64-linux-gnu- "$KERNEL_DEFCONFIG"; then
    error "Failed to configure Linux kernel with defconfig: $KERNEL_DEFCONFIG for $BOARD."
    exit 1
  fi

  log "Configuring Linux kernel with $KERNEL_DEFCONFIG for $BOARD."

  # Compile the kernel, DTBs, and modules
  if ! make ARCH=$ARCH CROSS_COMPILE=aarch64-linux-gnu- -j$(nproc) $KERNEL_IMAGE dtbs modules; then
    error "Linux kernel compilation failed."
    exit 1
  fi

  log "Linux kernel compiled successfully for $BOARD with $KERNEL_VERSION."
  
  # Copy the kernel image
  cp "arch/$ARCH/boot/$KERNEL_IMAGE" ../OUT || error "Failed to copy kernel $KERNEL_IMAGE."
  log "Copied kernel $KERNEL_IMAGE to OUT."

  # Install kernel modules
  make ARCH=$ARCH CROSS_COMPILE=aarch64-linux-gnu- INSTALL_MOD_PATH=../OUT modules_install || error "Failed to install kernel modules."

  # Copy .config with kernel version
  KERNEL_VERSION=$(make kernelrelease)
  cp .config ../OUT/config-$KERNEL_VERSION || error "Failed to copy .config."
  log "Copied config-$KERNEL_VERSION to OUT."

  # Copy System.map with kernel version
  cp System.map ../OUT/System.map-$KERNEL_VERSION || error "Failed to copy System.map."
  log "Copied System.map-$KERNEL_VERSION to OUT."

  cd ..
  log "Linux kernel compiled successfully for $BOARD with $KERNEL_VERSION."
}

copy_dts_files() {
  log "Copying DTS files for $BOARD..."

  # Determine the kernel directory
  if [[ "$KERNEL_SELECTION" -eq 1 ]]; then
    KERNEL_DIR="linux-${KERNEL_VERSION}" # Legacy kernel
  else
    KERNEL_DIR="linux-${KERNEL_VERSION}" # Latest kernel dynamically downloaded
  fi

  # Define DTS mappings
  case $BOARD in
    ARM-SBC-DCA-3288) DTS_FILE="rk3288-armsbc-dca";;
    ARM-SBC-K2-3288) DTS_FILE="rk3288-armsbc-k2";;
    ARM-SBC-DCA-3399) DTS_FILE="rk3399-armsbc-dca";;
    ARM-SBC-XZ-3399) DTS_FILE="rk3399-armsbc-xz";;
    ARM-SBC-DCA-3566) DTS_FILE="rk3566-armsbc-dca";;
    ARM-SBC-DCA-3568) DTS_FILE="rk3568-armsbc-dca";;
    ARM-SBC-EDG-E3576) DTS_FILE="rk3576-armsbc-edg";;
    ARM-SBC-NANO-3568) DTS_FILE="rk3568-armsbc-nano";;
    ARM-SBC-DCA-3588) DTS_FILE="rk3588-armsbc-dca";;
    ARM-SBC-EDGE-3588) DTS_FILE="rk3588-armsbc-edge";;
    ARM-SBC-RWA-3588) DTS_FILE="rk3588-armsbc-rwa";;
    *) error "No DTS mapping found for $BOARD." ;;
  esac

  # Append "lgcy" for legacy kernels
  if [[ "$KERNEL_SELECTION" -eq 1 ]]; then
    DTS_FILE="${DTS_FILE}-lgcy.dtb"
  else
    DTS_FILE="${DTS_FILE}.dtb"
  fi

  # Define DTS path
  DTS_PATH="${KERNEL_DIR}/arch/$ARCH/boot/dts/rockchip/$DTS_FILE"

  # Check if DTS file exists
  if [ -f "$DTS_PATH" ]; then
    cp "$DTS_PATH" OUT/ || error "Failed to copy DTS file $DTS_FILE to OUT directory."
    log "DTS file $DTS_FILE successfully copied to OUT directory."
  else
    error "DTS file $DTS_PATH not found. Ensure the kernel compilation generated the required DTS files."
  fi
}

# Main script execution
apply_patches
compile_atf
compile_optee
compile_uboot
compile_kernel
copy_dts_files

log "Compilation process completed successfully. All files are in OUT."

# Ask the user if they want to prepare the root filesystem
echo -e "\033[1;32mDo you want to create a root filesystem? [y/N]:\033[0m"  # Green prompt
read -r PREPARE_ROOTFS

if [[ "$PREPARE_ROOTFS" =~ ^[yY]$ ]]; then
    log "Starting root filesystem preparation..."
    # Pass required variables to the script
    export BOARD
    export ARCH
    export VERSION="default_version"  # Adjust or fetch dynamically if needed
    bash ./setup_rootfs.sh || {
        error "Root filesystem setup failed."
        exit 1
    }
    log "Root filesystem preparation completed successfully."
else
    log "Root filesystem preparation skipped."
fi

