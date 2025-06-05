#!/bin/bash

# Script Name: set_env.sh

# Function to log messages with timestamps
log() {
  echo -e "\033[1;34m[$(date +'%Y-%m-%d %H:%M:%S')] $1\033[0m"
}

# Function to install required packages
install_packages() {
  log "Checking and installing required dependencies..."
  REQUIRED_PACKAGES=(
    "build-essential" "gcc" "gcc-arm-none-eabi" "make" "swig" "gcc-arm-linux-gnueabihf"
    "libssl-dev" "curl" "bison" "flex" "git" "wget" "bc" "python3" "libncurses-dev"
    "libgnutls28-dev" "uuid-dev" "python3-pip" "device-tree-compiler"
    "gcc-aarch64-linux-gnu" "g++-aarch64-linux-gnu" "qemu" "qemu-user"
    "qemu-user-static" "binfmt-support"
  )
  MISSING_PACKAGES=()

  for pkg in "${REQUIRED_PACKAGES[@]}"; do
    if ! dpkg -l | grep -qw "$pkg"; then
      MISSING_PACKAGES+=("$pkg")
    fi
  done

  if [ ${#MISSING_PACKAGES[@]} -gt 0 ]; then
    log "Installing missing packages: ${MISSING_PACKAGES[*]}"
    sudo apt update
    sudo apt install -y "${MISSING_PACKAGES[@]}" || { log "[ERROR] Failed to install some packages. Exiting."; exit 1; }
    log "All required system packages have been installed."
  else
    log "All required system dependencies are already installed."
  fi

  log "Checking and installing required Python packages..."
  REQUIRED_PYTHON_PACKAGES=("pyelftools")
  for pkg in "${REQUIRED_PYTHON_PACKAGES[@]}"; do
    if ! python3 -m pip show "$pkg" > /dev/null 2>&1; then
      log "Installing Python package: $pkg"
      python3 -m pip install "$pkg" || { log "[ERROR] Failed to install Python package: $pkg. Exiting."; exit 1; }
    else
      log "Python package $pkg is already installed."
    fi
  done
}

# Function to select board type and specific board
select_board() {
  while :; do
    echo -e "\033[1;32mSelect your board type:\033[0m"
    echo "1) Rockchip"
    echo "2) Allwinner"
    read -p "Enter the number corresponding to your choice: " BOARD_TYPE

    if [[ "$BOARD_TYPE" == "1" ]]; then
      # Rockchip board selected
      echo "Rockchip board selected."
      COMPILE_SCRIPT="./rk-compile.sh"
      echo -e "\033[1;32mSelect a Rockchip board:\033[0m"
      echo "1- ARM-SBC-DCA-3288"
      echo "2- ARM-SBC-K2-3288"
      echo "3- ARM-SBC-DCA-3399"
      echo "4- ARM-SBC-DCA-3566"
      echo "5- ARM-SBC-DCA-3568"
      echo "6- ARM-SBC-NANO-3568"
      echo "7- ARM-SBC-YKR-3568"
      echo "8- ARM-SBC-IDO-3576"
      echo "9- ARM-SBC-EDGE-3576"
      echo "10- ARM-SBC-DCA-3588"
      echo "11- ARM-SBC-EDGE-3588"
      echo "12- ARM-SBC-RWA-3588"
      read -p "Enter the number corresponding to your Rockchip board: " BOARD_SELECTION

      case $BOARD_SELECTION in
        1) BOARD="ARM-SBC-DCA-3288"; CHIP="rk3288"; ARCH="arm"; CROSS_COMPILE="arm-linux-gnueabihf-"; UBOOT_DEFCONFIG="armsbc-dca-rk3288_defconfig"; KERNEL_DEFCONFIG="armsbc-3288_defconfig"; DEVICE_TREE="rk3288-armsbc-dca.dts" ;;
        2) BOARD="ARM-SBC-K2-3288"; CHIP="rk3288"; ARCH="arm"; CROSS_COMPILE="arm-linux-gnueabihf-"; UBOOT_DEFCONFIG="armsbc-k2-rk3288_defconfig"; KERNEL_DEFCONFIG="armsbc-3288_defconfig"; DEVICE_TREE="rk3288-armsbc-k2.dts" ;;
        3) BOARD="ARM-SBC-DCA-3399"; CHIP="rk3399"; ARCH="arm64"; CROSS_COMPILE="aarch64-linux-gnu-"; UBOOT_DEFCONFIG="armsbc-dca-rk3399_defconfig"; KERNEL_DEFCONFIG="armsbc-3399_defconfig"; DEVICE_TREE="rk3399-armsbc-dca.dts" ;;
        4) BOARD="ARM-SBC-DCA-3566"; CHIP="rk3566"; ARCH="arm64"; CROSS_COMPILE="aarch64-linux-gnu-"; UBOOT_DEFCONFIG="armsbc-dca-rk3566_defconfig"; KERNEL_DEFCONFIG="armsbc-3566_defconfig"; DEVICE_TREE="rk3566-armsbc-dca.dts" ;;
        5) BOARD="ARM-SBC-DCA-3568"; CHIP="rk3568"; ARCH="arm64"; CROSS_COMPILE="aarch64-linux-gnu-"; UBOOT_DEFCONFIG="armsbc-dca-rk3568_defconfig"; KERNEL_DEFCONFIG="armsbc-3568_defconfig"; DEVICE_TREE="rk3568-armsbc-dca.dts" ;;
 	6) BOARD="ARM-SBC-NANO-3568"; CHIP="rk3568"; ARCH="arm64"; CROSS_COMPILE="aarch64-linux-gnu-"; UBOOT_DEFCONFIG="armsbc-nano-rk3568_defconfig"; KERNEL_DEFCONFIG="armsbc-3568_defconfig"; DEVICE_TREE="rk3568-armsbc-nano.dts" ;;
        7) BOARD="ARM-SBC-YKR-3568"; CHIP="rk3568"; ARCH="arm64"; CROSS_COMPILE="aarch64-linux-gnu-"; UBOOT_DEFCONFIG="armsbc-ykr-rk3568_defconfig"; KERNEL_DEFCONFIG="armsbc-3568_defconfig"; DEVICE_TREE="rk3568-armsbc-ykr.dts" ;;
        8) BOARD="ARM-SBC-IDO-3576"; CHIP="rk3576"; ARCH="arm64"; CROSS_COMPILE="aarch64-linux-gnu-"; UBOOT_DEFCONFIG="armsbc-ido-rk3576_defconfig"; KERNEL_DEFCONFIG="armsbc-3576_defconfig"; DEVICE_TREE="rk3576-armsbc-ido.dts" ;;
        9) BOARD="ARM-SBC-EDGE-3576"; CHIP="rk3576"; ARCH="arm64"; CROSS_COMPILE="aarch64-linux-gnu-"; UBOOT_DEFCONFIG="armsbc-edge-rk3576_defconfig"; KERNEL_DEFCONFIG="armsbc-3576_defconfig"; DEVICE_TREE="rk3576-armsbc-edge.dts" ;;
        10) BOARD="ARM-SBC-DCA-3588"; CHIP="rk3588"; ARCH="arm64"; CROSS_COMPILE="aarch64-linux-gnu-"; UBOOT_DEFCONFIG="armsbc-dca-rk3588_defconfig"; KERNEL_DEFCONFIG="armsbc-3588_defconfig"; DEVICE_TREE="rk3568-armsbc-dca.dts" ;;
        11) BOARD="ARM-SBC-EDGE-3588"; CHIP="rk3588"; ARCH="arm64"; CROSS_COMPILE="aarch64-linux-gnu-"; UBOOT_DEFCONFIG="armsbc-edge-rk3588_defconfig"; KERNEL_DEFCONFIG="armsbc-3588_defconfig"; DEVICE_TREE="rk3588-armsbc-edge.dts" ;;
        12) BOARD="ARM-SBC-RWA-3568"; CHIP="rk3568"; ARCH="arm64"; CROSS_COMPILE="aarch64-linux-gnu-"; UBOOT_DEFCONFIG="armsbc-rwa-rk3588_defconfig"; KERNEL_DEFCONFIG="armsbc-3588_defconfig"; DEVICE_TREE="rk3588-armsbc-rwa.dts" ;;
        *) log "[ERROR] Invalid Rockchip board selection. Please try again."; continue ;;
      esac

      # Export variables for Rockchip boards
      export BOARD CHIP ARCH CROSS_COMPILE UBOOT_DEFCONFIG KERNEL_DEFCONFIG DEVICE_TREE OUTPUT_DIR
      break

    elif [[ "$BOARD_TYPE" == "2" ]]; then
      # Allwinner board selected
      echo "Allwinner board selected."
      COMPILE_SCRIPT="./sunxi-compile.sh"
      echo -e "\033[1;32mSelect an Allwinner board:\033[0m"
      echo "1) ARM-SBC-RWA-A64"
      echo "2) ARM-SBC-RP-A40i"
      echo "3) ARM-SBC-RP-T527"
      echo "4) ARM-SBC-XZ-A83T"
      read -p "Enter the number corresponding to your Allwinner board: " BOARD_SELECTION

      case $BOARD_SELECTION in
        1) BOARD="ARM-SBC-RWA-A64"; CHIP="a64"; PROCESSOR_FAMILY="sun50i"; ARCH="arm64"; CROSS_COMPILE="aarch64-linux-gnu-"; UBOOT_DEFCONFIG="armsbc-rwa-a64_defconfig"; KERNEL_DEFCONFIG="armsbc-a64_defconfig"; DEVICE_TREE="sun50i-a64-armsbc-rwa.dts" ;;
        2) BOARD="ARM-SBC-RP-A40i"; CHIP="a40i"; PROCESSOR_FAMILY="sun8i"; ARCH="arm"; CROSS_COMPILE="arm-linux-gnueabihf-"; UBOOT_DEFCONFIG="armsbc-rp-a40i_defconfig"; KERNEL_DEFCONFIG="armsbc-a40i_defconfig"; DEVICE_TREE="sun8i-a40i-armsbc-rp.dts" ;;
        3) BOARD="ARM-SBC-RP-T527"; CHIP="t527"; PROCESSOR_FAMILY="sun55i"; ARCH="arm64"; CROSS_COMPILE="aarch64-linux-gnu-"; UBOOT_DEFCONFIG="armsbc-rp-t527_defconfig"; KERNEL_DEFCONFIG="armsbc-t527_defconfig"; DEVICE_TREE="sun55i-t527-armsbc-rp.dts" ;;
        4) BOARD="ARM-SBC-XZ-A83T"; CHIP="a83t"; PROCESSOR_FAMILY="sun8i"; ARCH="arm"; CROSS_COMPILE="arm-linux-gnueabihf-"; UBOOT_DEFCONFIG="armsbc-xz-a83t_defconfig"; KERNEL_DEFCONFIG="armsbc-a83_defconfig"; DEVICE_TREE="sun8i-a83t-armsbc-xz.dts" ;;
        *) log "[ERROR] Invalid Allwinner board selection. Please try again."; continue ;;
      esac

      # Export variables for Allwinner boards
      export BOARD CHIP PROCESSOR_FAMILY ARCH CROSS_COMPILE UBOOT_DEFCONFIG KERNEL_DEFCONFIG DEVICE_TREE OUTPUT_DIR
      break

    else
      log "[ERROR] Invalid board type selection. Please try again."
    fi
  done

  # Debug logs to verify selected variables
  log "[INFO] Selected board: $BOARD"
  log "[INFO] Chip: $CHIP"
  log "[INFO] Architecture: $ARCH"
  log "[INFO] Processor Family (if applicable): $PROCESSOR_FAMILY"
  log "[INFO] Cross-compiler: $CROSS_COMPILE"
  log "[INFO] Output directory: $OUTPUT_DIR"
}

# Function to clean and prepare build directories
clean_build_directories() {
  log "Cleaning previous build directories..."

  # Remove u-boot directory
  [ -d "u-boot" ] && rm -rf "u-boot"

  # Find and remove any directory that starts with "linux-"
  for linux_dir in linux-*; do
    if [ -d "$linux_dir" ]; then
      log "Removing directory: $linux_dir"
      rm -rf "$linux_dir"
    fi
  done

  log "Build directories cleaned."
}

prepare_output_directory() {
  OUTPUT_DIR="$(pwd)/OUT-${BOARD}"  # Use absolute path for output directory
  export OUTPUT_DIR

  log "Preparing output directory: $OUTPUT_DIR..."

  if [ -d "$OUTPUT_DIR" ]; then
    log "Cleaning output directory contents..."
    sudo rm -rf "$OUTPUT_DIR"/* || { log "[ERROR] Failed to clean $OUTPUT_DIR."; exit 1; }
  else
    log "Creating output directory: $OUTPUT_DIR..."
    mkdir -p "$OUTPUT_DIR" || { log "[ERROR] Failed to create $OUTPUT_DIR."; exit 1; }
  fi

  log "Output directory is ready."
}

# Function to download sources dynamically based on the build option
download_sources() {
  case "$BUILD_OPTION" in
    "uboot"|"all")
      log "Downloading U-Boot source..."
      if [ ! -d "u-boot" ]; then
        git clone https://github.com/u-boot/u-boot.git || { log "[ERROR] Failed to clone U-Boot repository."; exit 1; }
        cd u-boot || { log "[ERROR] Failed to enter U-Boot directory."; exit 1; }
        # Fetch all tags and determine the latest stable version
        log "Fetching U-Boot tags to determine the latest stable version..."
        git fetch --tags || { log "[ERROR] Failed to fetch tags from U-Boot repository."; exit 1; }
        STABLE_TAG=$(git tag -l | grep -E '^v[0-9]+\.[0-9]+$' | sort -V | tail -n 1)
        
        if [ -z "$STABLE_TAG" ]; then
          log "[ERROR] Failed to determine the latest stable version of U-Boot. Falling back to the main branch."
        else
          log "Latest stable U-Boot version determined: $STABLE_TAG"
          git checkout -b "$STABLE_TAG-branch" "$STABLE_TAG" || { log "[ERROR] Failed to checkout U-Boot stable version $STABLE_TAG."; exit 1; }
        fi
        cd - > /dev/null
      else
        log "U-Boot source already exists. Skipping download."
      fi

      # Rockchip-specific downloads for U-Boot
      if [[ "$CHIP" == "rk"* ]]; then
        log "Downloading RKBin repository for Rockchip..."
        if [ ! -d "rkbin" ]; then
          git clone https://github.com/rockchip-linux/rkbin.git || { log "[ERROR] Failed to clone RKBin repository."; exit 1; }
        else
          log "RKBin repository already exists. Skipping download."
        fi

        log "Downloading Trusted Firmware (ATF) for Rockchip..."
        if [ ! -d "arm-trusted-firmware" ]; then
          git clone https://github.com/ARM-software/arm-trusted-firmware.git || { log "[ERROR] Failed to clone ATF repository."; exit 1; }
        else
          log "ATF source already exists. Skipping download."
        fi

        log "Downloading OP-TEE for Rockchip..."
        if [ ! -d "optee_os" ]; then
          git clone https://github.com/OP-TEE/optee_os.git || { log "[ERROR] Failed to clone OP-TEE repository."; exit 1; }
        else
          log "OP-TEE source already exists. Skipping download."
        fi
      fi

      # Allwinner-specific downloads for U-Boot
      if [[ "$CHIP" == "a"* ]]; then
        log "Downloading Trusted Firmware (ATF) for Allwinner..."
        if [ ! -d "arm-trusted-firmware" ]; then
          git clone https://github.com/ARM-software/arm-trusted-firmware.git || { log "[ERROR] Failed to clone ATF repository."; exit 1; }
        else
          log "ATF source already exists. Skipping download."
        fi
      fi
      ;;
    "kernel")
      log "Kernel sources will be downloaded separately during kernel selection."
      ;;
    *)
      log "[ERROR] Invalid or unsupported build option: $BUILD_OPTION"
      exit 1
      ;;
  esac

  log "All required sources for the selected build option downloaded successfully."
}

# Function to select kernel version
select_kernel_version() {
  # Allwinner boards: use latest stable kernel
  if [[ "$CHIP" == "a"* ]]; then
    log "Allwinner board selected. Automatically fetching the latest stable kernel from kernel.org..."
    LATEST_KERNEL=$(curl -s https://www.kernel.org/ | grep -oP 'linux-[0-9]+\.[0-9]+\.[0-9]+(?=\.tar\.xz)' | grep -v -E 'rc|rc[0-9]+' | head -n 1 | sed 's/linux-//')
    log "[DEBUG] Fetched LATEST_KERNEL (stable): ${LATEST_KERNEL:-undefined}"

    if [ -z "$LATEST_KERNEL" ]; then
      log "[ERROR] Failed to fetch the latest stable kernel version from kernel.org. Exiting."
      exit 1
    fi

    KERNEL_VERSION="$LATEST_KERNEL"
    KERNEL_SOURCE="https://cdn.kernel.org/pub/linux/kernel/v${LATEST_KERNEL%%.*}.x/linux-${LATEST_KERNEL}.tar.xz"
    COMPILE_SCRIPT="./sunxi-compile.sh"
  
  else
    # For RK3588, RK3576, and other non-Allwinner chips: use latest stable kernel
    log "Fetching the latest stable kernel version for $CHIP from kernel.org..."
    LATEST_KERNEL=$(curl -s https://www.kernel.org/ | grep -oP 'linux-[0-9]+\.[0-9]+\.[0-9]+(?=\.tar\.xz)' | grep -v -E 'rc|rc[0-9]+' | head -n 1 | sed 's/linux-//')

    if [ -z "$LATEST_KERNEL" ]; then
      log "[ERROR] Failed to fetch the latest stable kernel version from kernel.org. Exiting."
      exit 1
    fi

    KERNEL_VERSION="$LATEST_KERNEL"
    KERNEL_SOURCE="https://cdn.kernel.org/pub/linux/kernel/v${LATEST_KERNEL%%.*}.x/linux-${LATEST_KERNEL}.tar.xz"
    COMPILE_SCRIPT="./rk-compile.sh"
  fi

  log "[INFO] Selected kernel version: $KERNEL_VERSION"
  log "[INFO] Kernel source: $KERNEL_SOURCE"
  log "[INFO] Compile script set to: $COMPILE_SCRIPT"
  export KERNEL_VERSION KERNEL_SOURCE COMPILE_SCRIPT
}

download_kernel_source() {
  log "Downloading kernel source..."

  # Debugging logs for kernel variables
  log "[DEBUG] KERNEL_VERSION: ${KERNEL_VERSION:-undefined}"
  log "[DEBUG] KERNEL_SOURCE: ${KERNEL_SOURCE:-undefined}"

  if [ -z "$KERNEL_SOURCE" ]; then
    log "[ERROR] Kernel source URL is empty. Please check the kernel version selection."
    exit 1
  fi

  # Handle upstream kernel as a tarball
  if [ ! -f "linux-${KERNEL_VERSION}.tar.xz" ]; then
    log "Downloading kernel tarball..."
    wget "$KERNEL_SOURCE" -O "linux-${KERNEL_VERSION}.tar.xz" || { log "[ERROR] Failed to download kernel tarball."; exit 1; }
  else
    log "Kernel tarball already exists. Skipping download."
  fi

  if [ ! -d "linux-${KERNEL_VERSION}" ]; then
    log "Extracting kernel source..."
    tar -xf "linux-${KERNEL_VERSION}.tar.xz" || { log "[ERROR] Failed to extract kernel tarball."; exit 1; }
  else
    log "Kernel source already prepared."
  fi

  log "Kernel source downloaded and prepared."
}

build_options() {
  log "Select the build option:"
  PS3="Enter your choice: "
  options=("U-Boot only" "Kernel only" "RootFS only" "All")
  select opt in "${options[@]}"; do
    case $opt in
      "U-Boot only")
        BUILD_OPTION="uboot"
        export BOARD CHIP ARCH CROSS_COMPILE UBOOT_DEFCONFIG KERNEL_DEFCONFIG
        log "Debug: BUILD_OPTION=$BUILD_OPTION, BOARD=$BOARD, CHIP=$CHIP, ARCH=$ARCH, CROSS_COMPILE=$CROSS_COMPILE"
        download_sources
        $COMPILE_SCRIPT uboot || { log "[ERROR] Failed to build U-Boot."; exit 1; }
        break
        ;;
      "Kernel only")
        BUILD_OPTION="kernel"
        select_kernel_version
        download_kernel_source
        export BOARD CHIP ARCH CROSS_COMPILE KERNEL_VERSION UBOOT_DEFCONFIG KERNEL_DEFCONFIG
        log "Debug: BUILD_OPTION=$BUILD_OPTION, BOARD=$BOARD, CHIP=$CHIP, ARCH=$ARCH, CROSS_COMPILE=$CROSS_COMPILE, KERNEL_VERSION=$KERNEL_VERSION"
        $COMPILE_SCRIPT kernel || { log "[ERROR] Failed to build Kernel."; exit 1; }
        break
        ;;
      "RootFS only")
        BUILD_OPTION="rootfs"
        VERSION="jammy"  # Default RootFS version (adjustable)
        export BOARD ARCH VERSION
        log "Debug: BUILD_OPTION=$BUILD_OPTION, BOARD=$BOARD, ARCH=$ARCH, VERSION=$VERSION"
        
        if [ -x "./setup_rootfs.sh" ]; then
          ./setup_rootfs.sh || { log "[ERROR] Failed to prepare RootFS."; exit 1; }
        else
          log "[ERROR] RootFS script setup_rootfs.sh not found or not executable."
          exit 1
        fi
        break
        ;;
      "All")
        BUILD_OPTION="all"
        select_kernel_version
        download_sources
        download_kernel_source
        export BOARD CHIP ARCH CROSS_COMPILE KERNEL_VERSION UBOOT_DEFCONFIG KERNEL_DEFCONFIG VERSION="jammy"
        log "Debug: BUILD_OPTION=$BUILD_OPTION, BOARD=$BOARD, CHIP=$CHIP, ARCH=$ARCH, CROSS_COMPILE=$CROSS_COMPILE, KERNEL_VERSION=$KERNEL_VERSION, VERSION=$VERSION"
        
        if ! $COMPILE_SCRIPT all; then
          log "[ERROR] Failed to build all components."
          exit 1
        fi

        if [ -x "./setup_rootfs.sh" ]; then
          ./setup_rootfs.sh || { log "[ERROR] Failed to prepare RootFS."; exit 1; }
        else
          log "[ERROR] RootFS script setup_rootfs.sh not found or not executable."
          exit 1
        fi
        break
        ;;
      *)
        log "Invalid option. Please try again."
        ;;
    esac
  done
}

# Main script execution
log "Starting script execution..."
install_packages
select_board
clean_build_directories
prepare_output_directory
build_options
