#!/bin/bash

# Script Name: set_env.sh
# Function to log messages with timestamps
log() {
  echo -e "\033[1;34m[$(date +'%Y-%m-%d %H:%M:%S')] $1\033[0m"  # Blue color for logs
}

# Function to install required packages
install_packages() {
  log "Checking and installing required dependencies..."
  REQUIRED_PACKAGES=("build-essential" "gcc" "make" "swig" "gcc-arm-linux-gnueabihf" "libssl-dev" "curl" "bison" "flex" "git" "wget" "bc" "python3" "libgnutls28-dev" "uuid-dev" "python3-pip" "device-tree-compiler" "gcc-aarch64-linux-gnu" "g++-aarch64-linux-gnu")
  MISSING_PACKAGES=()

  # Check each package
  for pkg in "${REQUIRED_PACKAGES[@]}"; do
    if ! dpkg -l | grep -qw "$pkg"; then
      MISSING_PACKAGES+=("$pkg")
    fi
  done

  # Install missing packages
  if [ ${#MISSING_PACKAGES[@]} -gt 0 ]; then
    log "The following packages are missing and will be installed: ${MISSING_PACKAGES[*]}"
    sudo apt update
    sudo apt install -y "${MISSING_PACKAGES[@]}" || { log "[ERROR] Failed to install some packages. Exiting."; exit 1; }
    log "All required packages have been installed."
  else
    log "All required dependencies are already installed."
  fi
}


# Function to prepare the output directory
prepare_output_directory() {
  log "Preparing output directory..."
  mkdir -p OUT || { log "[ERROR] Failed to create OUT directory."; exit 1; }
  log "Output directory prepared."
}


# Function to select board type and specific board
select_board() {
  while :; do
    echo -e "\033[1;32mSelect your board type:\033[0m"
    echo "1) Rockchip"
    echo "2) Allwinner"
    read -p "Enter the number corresponding to your choice: " BOARD_TYPE

    if [[ "$BOARD_TYPE" == "1" ]]; then
      echo "Rockchip board selected."
      echo -e "\033[1;32mSelect a Rockchip board:\033[0m"
      echo "1- ARM-SBC-DCA-3288"
      echo "2- ARM-SBC-K2-3288"
      echo "3- ARM-SBC-DCA-3399"
      echo "4- ARM-SBC-XZ-3399"
      echo "5- ARM-SBC-DCA-3566"
      echo "6- ARM-SBC-DCA-3568"
      echo "7- ARM-SBC-EDG-3576"
      echo "8- ARM-SBC-NANO-3568"
      echo "9- ARM-SBC-DCA-3588"
      echo "10- ARM-SBC-EDGE-3588"
      echo "11- ARM-SBC-RWA-3588"
      read -p "Enter the number corresponding to your Rockchip board: " BOARD_SELECTION

      case $BOARD_SELECTION in
        1) BOARD="ARM-SBC-DCA-3288"; CHIP="rk3288"; UBOOT_DEFCONFIG="armsbc-dca-3288_defconfig"; KERNEL_DEFCONFIG="armsbc-3288_defconfig" ;;
        2) BOARD="ARM-SBC-K2-3288"; CHIP="rk3288"; UBOOT_DEFCONFIG="armsbc-k2-3288_defconfig"; KERNEL_DEFCONFIG="armsbc-3288_defconfig" ;;
        3) BOARD="ARM-SBC-DCA-3399"; CHIP="rk3399"; UBOOT_DEFCONFIG="armsbc-dca-3399_defconfig"; KERNEL_DEFCONFIG="armsbc-3399_defconfig" ;;
        4) BOARD="ARM-SBC-XZ-3399"; CHIP="rk3399"; UBOOT_DEFCONFIG="armsbc-xz-3399_defconfig"; KERNEL_DEFCONFIG="armsbc-3399_defconfig" ;;
        5) BOARD="ARM-SBC-DCA-3566"; CHIP="rk3566"; UBOOT_DEFCONFIG="armsbc-dca-3566_defconfig"; KERNEL_DEFCONFIG="armsbc-3566_defconfig" ;;
        6) BOARD="ARM-SBC-DCA-3568"; CHIP="rk3568"; UBOOT_DEFCONFIG="armsbc-dca-3568_defconfig"; KERNEL_DEFCONFIG="armsbc-3568_defconfig" ;;
        7) BOARD="ARM-SBC-EDG-3576"; CHIP="rk3576"; UBOOT_DEFCONFIG="armsbc-edg-3576_defconfig"; KERNEL_DEFCONFIG="armsbc-3576_defconfig" ;;
        8) BOARD="ARM-SBC-NANO-3568"; CHIP="rk3568"; UBOOT_DEFCONFIG="armsbc-nano-3568_defconfig"; KERNEL_DEFCONFIG="armsbc-3568_defconfig" ;;
        9) BOARD="ARM-SBC-DCA-3588"; CHIP="rk3588"; UBOOT_DEFCONFIG="armsbc-dca-3588_defconfig"; KERNEL_DEFCONFIG="armsbc-3588_defconfig" ;;
        10) BOARD="ARM-SBC-EDGE-3588"; CHIP="rk3588"; UBOOT_DEFCONFIG="armsbc-edge-3588_defconfig"; KERNEL_DEFCONFIG="armsbc-3588_defconfig" ;;
        11) BOARD="ARM-SBC-RWA-3588"; CHIP="rk3588"; UBOOT_DEFCONFIG="armsbc-rwa-3588_defconfig"; KERNEL_DEFCONFIG="armsbc-3588_defconfig" ;;
        *) log "[ERROR] Invalid Rockchip board selection. Please try again."; continue ;;
      esac
      break
    elif [[ "$BOARD_TYPE" == "2" ]]; then
      echo "Allwinner board selected."
      echo -e "\033[1;32mSelect an Allwinner board:\033[0m"
      echo "1) ARM-SBC-RWA-A64"
      echo "2) ARM-SBC-RP-A40i"
      echo "3) ARM-SBC-RP-T527"
      echo "4) ARM-SBC-XZ-A64"
      echo "5) ARM-SBC-XZ-A20"
      echo "6) ARM-SBC-XZ-A83T"
      read -p "Enter the number corresponding to your Allwinner board: " BOARD_SELECTION

      case $BOARD_SELECTION in
        1) BOARD="ARM-SBC-RWA-A64"; CHIP="a64"; UBOOT_DEFCONFIG="armsbc-rwa-a64_defconfig"; KERNEL_DEFCONFIG="armsbc-a64_defconfig" ;;
        2) BOARD="ARM-SBC-RP-A40i"; CHIP="a40i"; UBOOT_DEFCONFIG="armsbc-rp-a40i_defconfig"; KERNEL_DEFCONFIG="armsbc-a40i_defconfig" ;;
        3) BOARD="ARM-SBC-RP-T527"; CHIP="t527"; UBOOT_DEFCONFIG="armsbc-rp-t527_defconfig"; KERNEL_DEFCONFIG="armsbc-t527_defconfig" ;;
        4) BOARD="ARM-SBC-XZ-A64"; CHIP="a64"; UBOOT_DEFCONFIG="armsbc-xz-a64_defconfig"; KERNEL_DEFCONFIG="armsbc-a64_defconfig" ;;
        5) BOARD="ARM-SBC-XZ-A20"; CHIP="a20"; UBOOT_DEFCONFIG="armsbc-xz-a20_defconfig"; KERNEL_DEFCONFIG="armsbc-a20_defconfig" ;;
        6) BOARD="ARM-SBC-XZ-A83T"; CHIP="a83t"; UBOOT_DEFCONFIG="armsbc-xz-a83t_defconfig"; KERNEL_DEFCONFIG="armsbc-a83_defconfig" ;;
        *) log "[ERROR] Invalid Allwinner board selection. Please try again."; continue ;;
      esac
      break
    else
      log "[ERROR] Invalid board type selection. Please try again."
    fi
  done

  export BOARD CHIP UBOOT_DEFCONFIG KERNEL_DEFCONFIG
  log "Selected board: $BOARD with chip: $CHIP"
}

# Function to download U-Boot and required binaries
download_sources() {
  log "Downloading U-Boot source..."
  if [ ! -d "u-boot" ]; then
    git clone https://github.com/u-boot/u-boot.git || { log "[ERROR] Failed to clone U-Boot repository."; exit 1; }
  else
    log "U-Boot source already exists. Skipping download."
  fi

  # Rockchip-specific downloads
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
      log "Trusted Firmware source already exists. Skipping download."
    fi

    log "Downloading OP-TEE for Rockchip..."
    if [ ! -d "optee_os" ]; then
      git clone https://github.com/OP-TEE/optee_os.git || { log "[ERROR] Failed to clone OP-TEE repository."; exit 1; }
    else
      log "OP-TEE source already exists. Skipping download."
    fi
  fi

  # Allwinner-specific downloads-part of uboot
  if [[ "$CHIP" == "a"* ]]; then
    log "Downloading Trusted Firmware (ATF) for Allwinner..."
    if [ ! -d "arm-trusted-firmware" ]; then
      git clone https://github.com/ARM-software/arm-trusted-firmware.git || { log "[ERROR] Failed to clone ATF repository."; exit 1; }
    else
      log "Trusted Firmware source already exists. Skipping download."
    fi
  fi

  log "All required sources for U-Boot and binaries downloaded successfully."
}

#function to select kernel
select_kernel_version() {
  # Check if the selected board is Allwinner
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
    log "[INFO] Automatically selected latest stable kernel version: $KERNEL_VERSION"
    log "[INFO] Kernel source URL: $KERNEL_SOURCE"
    export KERNEL_VERSION KERNEL_SOURCE
  else
    echo -e "\033[1;32mSelect the kernel version to use:\033[0m"  # Green for prompts
    echo "1- Legacy kernel (6.1.75)"
    echo "2- Latest upstream kernel"
    read -p $'\033[1;32mEnter the number corresponding to your selection: \033[0m' KERNEL_SELECTION

    case $KERNEL_SELECTION in
      1)
        KERNEL_VERSION="6.1.75"
        KERNEL_SOURCE="https://github.com/arm-sbc/rk-kernel-6.1.75.git"
        ;;
      2)
        log "Fetching the latest kernel version dynamically..."
        LATEST_KERNEL=$(curl -s https://www.kernel.org/ | grep -oP 'linux-[0-9]+\.[0-9]+\.[0-9]+(?=\.tar\.xz)' | grep -v -E 'rc|rc[0-9]+' | head -n 1 | sed 's/linux-//')
        if [ -z "$LATEST_KERNEL" ]; then
          log "[ERROR] Failed to fetch the latest stable kernel version. Exiting."
          exit 1
        fi
        KERNEL_VERSION="$LATEST_KERNEL"
        KERNEL_SOURCE="https://cdn.kernel.org/pub/linux/kernel/v${LATEST_KERNEL%%.*}.x/linux-${LATEST_KERNEL}.tar.xz"
        ;;
      *)
        echo -e "\033[1;31mInvalid selection.\033[0m"; exit 1 ;;  # Red for errors
    esac

    log "[INFO] Selected kernel version: $KERNEL_VERSION"
    log "[INFO] Kernel source: $KERNEL_SOURCE"
    export KERNEL_VERSION KERNEL_SOURCE
  fi
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

  if [[ "$KERNEL_VERSION" == "6.1.75" ]]; then
    # Handle legacy kernel as a Git repository
    log "Legacy kernel selected. Cloning the repository..."
    if [ ! -d "linux-${KERNEL_VERSION}" ]; then
      git clone "$KERNEL_SOURCE" "linux-${KERNEL_VERSION}" || { log "[ERROR] Failed to clone legacy kernel repository."; exit 1; }
    else
      log "Legacy kernel repository already exists. Skipping clone."
    fi
  else
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
  fi

  log "Kernel source downloaded and prepared."
}

# Main script execution
log "Starting script execution..."
install_packages
prepare_output_directory
select_board
download_sources
select_kernel_version
download_kernel_source

#Prompt for compilation
read -p $'\033[1;32m[STEP 7] Do you want to proceed with compiling? (y/n): \033[0m' CONTINUE_COMPILE
if [[ "$CONTINUE_COMPILE" =~ ^[Yy]$ ]]; then
    # Determine the appropriate script for the selected board
    if [[ "$CHIP" == "a64" || "$CHIP" == "a40i" || "$CHIP" == "a83t" || "$CHIP" == "t527" ]]; then
        SCRIPT="sunxi-compile.sh"
    else
        SCRIPT="rk-compile.sh"
    fi

    # Check if the selected script exists, make it executable, and run it
    if [ -f "./$SCRIPT" ]; then
        chmod +x ./"$SCRIPT"
        log "[STEP 7] Starting compilation with ./$SCRIPT..."
        ./"$SCRIPT"
        if [ $? -eq 0 ]; then
            log "[INFO] Compilation completed successfully."
        else
            log "[ERROR] Compilation failed. Check the logs for details."
            exit 1
        fi
    else
        log "[ERROR] $SCRIPT not found in the current directory. Exiting."
        exit 1
    fi
else
    log "[STEP 7] Compilation skipped. Environment setup complete."
    log "You can manually run the appropriate script when ready:"
    log "  For Allwinner: ./sunxi-compile.sh"
    log "  For Rockchip: ./rk-compile.sh"
fi


