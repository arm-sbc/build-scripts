#!/bin/bash

# Function to log messages with timestamps
log() {
  echo -e "\033[1;34m[$(date +'%Y-%m-%d %H:%M:%S')] $1\033[0m"  # Blue color for logs
}

# Function to install required packages
install_packages() {
  log "Installing required packages..."
  sudo apt update
  sudo apt install -y build-essential gcc curl make libssl-dev bison flex swig git wget bc python3 python3-pip device-tree-compiler gcc-aarch64-linux-gnu g++-aarch64-linux-gnu gcc-arm-none-eabi gcc-arm-linux-gnueabihf libgnutls28-dev uuid-dev

  log "Ensuring pip is installed and updated..."
  python3 -m ensurepip --upgrade
  python3 -m pip install --upgrade pip

  log "Installing Python package: pyelftools==0.29"
  python3 -m pip install pyelftools==0.29
}

# Function to download required sources
download_sources() {
  log "Downloading U-Boot source..."
  if [ ! -d "u-boot" ]; then
    git clone https://github.com/u-boot/u-boot.git
  else
    log "U-Boot source already exists. Skipping download."
  fi

  log "Downloading RKBin repository..."
  if [ ! -d "rkbin" ]; then
    git clone https://github.com/rockchip-linux/rkbin.git
  else
    log "RKBin repository already exists. Skipping download."
  fi

  log "Downloading Trusted Firmware..."
  if [ ! -d "arm-trusted-firmware" ]; then
    git clone https://github.com/ARM-software/arm-trusted-firmware.git
    cd arm-trusted-firmware || exit 1
    git checkout master || { log "Failed to checkout the master branch."; exit 1; }
    cd ..
  else
    log "Trusted Firmware source already exists. Skipping download."
  fi

  log "Downloading OP-TEE source..."
  if [ ! -d "optee_os" ]; then
    git clone https://github.com/OP-TEE/optee_os.git
  else
    log "OP-TEE source already exists. Skipping download."
  fi
}

# Function to prepare the output directory
prepare_output_directory() {
  log "Preparing output directory..."
  mkdir -p OUT
  log "Output directory prepared."
}

# Function to select a board
select_board() {
  echo -e "\033[1;32mSelect a board from the list below:\033[0m"  # Green color for prompts
  echo "1- ARM-SBC-DCA-3288"
  echo "2- ARM-SBC-K2-3288"
  echo "3- ARM-SBC-DCA-3399"
  echo "4- ARM-SBC-XZ-3399"
  echo "5- ARM-SBC-DCA-3566"
  echo "6- ARM-SBC-DCA-3568"
  echo "7- ARM-SBC-EDG-E3576"
  echo "8- ARM-SBC-NANO-3568"
  echo "9- ARM-SBC-DCA-3588"
  echo "10- ARM-SBC-EDGE-3588"
  echo "11- ARM-SBC-RWA-3588"
  read -p $'\033[1;32mEnter the number corresponding to your board: \033[0m' BOARD_SELECTION

  case $BOARD_SELECTION in
    1) BOARD="ARM-SBC-DCA-3288"; CHIP="rk3288"; UBOOT_DEFCONFIG="armsbc-dca-3288_defconfig"; KERNEL_DEFCONFIG="armsbc-3288_defconfig" ;;
    2) BOARD="ARM-SBC-K2-3288"; CHIP="rk3288"; UBOOT_DEFCONFIG="armsbc-k2-3288_defconfig"; KERNEL_DEFCONFIG="armsbc-3288_defconfig" ;;
    3) BOARD="ARM-SBC-DCA-3399"; CHIP="rk3399"; UBOOT_DEFCONFIG="armsbc-dca-3399_defconfig"; KERNEL_DEFCONFIG="armsbc-3399_defconfig" ;;
    4) BOARD="ARM-SBC-XZ-3399"; CHIP="rk3399"; UBOOT_DEFCONFIG="armsbc-xz-3399_defconfig"; KERNEL_DEFCONFIG="armsbc-3399_defconfig" ;;
    5) BOARD="ARM-SBC-DCA-3566"; CHIP="rk3566"; UBOOT_DEFCONFIG="armsbc-dca-3566_defconfig"; KERNEL_DEFCONFIG="armsbc-3566_defconfig" ;;
    6) BOARD="ARM-SBC-DCA-3568"; CHIP="rk3568"; UBOOT_DEFCONFIG="armsbc-dca-3568_defconfig"; KERNEL_DEFCONFIG="armsbc-3568_defconfig" ;;
    7) BOARD="ARM-SBC-EDG-E3576"; CHIP="rk3576"; UBOOT_DEFCONFIG="armsbc-edg-3576_defconfig"; KERNEL_DEFCONFIG="armsbc-3576_defconfig" ;;
    8) BOARD="ARM-SBC-NANO-3568"; CHIP="rk3568"; UBOOT_DEFCONFIG="armsbc-nano-3568_defconfig"; KERNEL_DEFCONFIG="armsbc-3568_defconfig" ;;
    9) BOARD="ARM-SBC-DCA-3588"; CHIP="rk3588"; UBOOT_DEFCONFIG="armsbc-dca-3588_defconfig"; KERNEL_DEFCONFIG="armsbc-3588_defconfig" ;;
    10) BOARD="ARM-SBC-EDGE-3588"; CHIP="rk3588"; UBOOT_DEFCONFIG="armsbc-edge-3588_defconfig"; KERNEL_DEFCONFIG="armsbc-3588_defconfig" ;;
    11) BOARD="ARM-SBC-RWA-3588"; CHIP="rk3588"; UBOOT_DEFCONFIG="armsbc-rwa-3588_defconfig"; KERNEL_DEFCONFIG="armsbc-3588_defconfig" ;;
    *) echo -e "\033[1;31mInvalid selection.\033[0m"; exit 1 ;;  # Red for errors
  esac

  log "Selected board: $BOARD with chip: $CHIP"
  export BOARD CHIP UBOOT_DEFCONFIG KERNEL_DEFCONFIG
}

# Function to select the kernel version
select_kernel_version() {
  echo -e "\033[1;32mSelect the kernel version to use:\033[0m"  # Green for prompts
  echo "1- Legacy kernel (6.1.75)"
  echo "2- Latest upstream kernel"
  read -p $'\033[1;32mEnter the number corresponding to your selection: \033[0m' KERNEL_SELECTION

  case $KERNEL_SELECTION in
    1)
      KERNEL_VERSION="6.1.75"
      KERNEL_SOURCE="https://github.com/arm-sbc/rk-kernel-6.1.75.git"
      PATCH_DIR="patches-legacy"
      ;;
    2)
      log "Fetching the latest kernel version dynamically..."
      LATEST_KERNEL=$(curl -s https://www.kernel.org/ | grep -oP 'linux-[0-9]+\.[0-9]+\.[0-9]+(?=\.tar\.xz)' | head -n 1 | sed 's/linux-//')
      if [ -z "$LATEST_KERNEL" ]; then
        log "[ERROR] Failed to fetch the latest kernel version. Exiting."
        exit 1
      fi
      KERNEL_VERSION="$LATEST_KERNEL"
      KERNEL_SOURCE="https://cdn.kernel.org/pub/linux/kernel/v${LATEST_KERNEL%%.*}.x/linux-${LATEST_KERNEL}.tar.xz"
      PATCH_DIR="patches"
      ;;
    *)
      echo -e "\033[1;31mInvalid selection.\033[0m"; exit 1 ;;  # Red for errors
  esac

  log "[INFO] Selected kernel version: $KERNEL_VERSION"
  log "[INFO] Kernel source: $KERNEL_SOURCE"
  log "[INFO] Patches directory: $PATCH_DIR"
  export KERNEL_VERSION KERNEL_SOURCE PATCH_DIR
}

# Function to download and prepare the kernel source
download_kernel_source() {
  log "Downloading kernel source..."
  if [ "$KERNEL_SELECTION" -eq 1 ]; then
    if [ ! -d "linux-${KERNEL_VERSION}" ]; then
      log "Cloning legacy kernel repository..."
      git clone "$KERNEL_SOURCE" "linux-${KERNEL_VERSION}" || { log "[ERROR] Failed to clone legacy kernel repository."; exit 1; }
    else
      log "Legacy kernel source already exists. Skipping download."
    fi
  else
    if [ ! -f "linux-${KERNEL_VERSION}.tar.xz" ]; then
      log "Downloading latest kernel tarball..."
      wget "$KERNEL_SOURCE" -O "linux-${KERNEL_VERSION}.tar.xz" || { log "[ERROR] Failed to download latest kernel tarball."; exit 1; }
    else
      log "Latest kernel tarball already exists. Skipping download."
    fi

    if [ ! -d "linux-${KERNEL_VERSION}" ]; then
      log "Extracting latest kernel source..."
      tar -xf "linux-${KERNEL_VERSION}.tar.xz" || { log "[ERROR] Failed to extract kernel tarball."; exit 1; }
    else
      log "Kernel source already prepared."
    fi
  fi
  log "Kernel source downloaded and prepared."
}

# Function to ask whether to continue with the compilation script
ask_to_continue() {
  read -p $'\033[1;32mDo you want to proceed with the compilation (compile.sh)? [y/N]: \033[0m' CONTINUE
  if [[ "$CONTINUE" =~ ^[Yy]$ ]]; then
    log "[INFO] Starting compile.sh..."
    if [ -f "./compile.sh" ]; then
      chmod +x ./compile.sh
      ./compile.sh
    else
      log "[ERROR] compile.sh not found in the current directory. Exiting."
      exit 1
    fi
  else
    log "[INFO] Environment setup complete. Exiting without starting compile.sh."
  fi
}

# Main script execution
install_packages
download_sources
prepare_output_directory

select_board
select_kernel_version
download_kernel_source

log "Environment setup complete. Ready for compilation."
ask_to_continue

