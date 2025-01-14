#!/bin/bash

echo "Select your board:"
echo "1) Rockchip"
echo "2) Allwinner"

read -p "Enter the number corresponding to your choice: " BOARD_CHOICE

if [ "$BOARD_CHOICE" == "1" ]; then
    echo "Rockchip board selected."
    # Existing Rockchip setup

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

    echo "Selected board: $BOARD with chip: $CHIP"
    export BOARD CHIP UBOOT_DEFCONFIG KERNEL_DEFCONFIG

elif [ "$BOARD_CHOICE" == "2" ]; then
    echo "Allwinner board selected."
    
    echo "Select your Allwinner board:"
    echo "1) ARM-SBC-RWA-A64"
    echo "2) ARM-SBC-RP-A40i"
    echo "3) ARM-SBC-RP-T527"
    echo "4) ARM-SBC-XZ-A64"
    echo "5) ARM-SBC-XZ-A20"

    read -p "Enter the number corresponding to your choice: " ALLWINNER_CHOICE

    case $ALLWINNER_CHOICE in
        1) BOARD="ARM-SBC-RWA-A64"; CHIP="a64"; UBOOT_DEFCONFIG="armsbc-rwa-a64_defconfig"; KERNEL_DEFCONFIG="armsbc-a64_defconfig" ;;
        2) BOARD="ARM-SBC-RP-A40i"; CHIP="a40i"; UBOOT_DEFCONFIG="armsbc-rp-a40i_defconfig"; KERNEL_DEFCONFIG="armsbc-a40i_defconfig" ;;
        3) BOARD="ARM-SBC-RP-T527"; CHIP="t527"; UBOOT_DEFCONFIG="armsbc-rp-t527_defconfig"; KERNEL_DEFCONFIG="armsbc-t527_defconfig" ;;
        4) BOARD="ARM-SBC-XZ-A64"; CHIP="a64"; UBOOT_DEFCONFIG="armsbc-xz-a64_defconfig"; KERNEL_DEFCONFIG="armsbc-a64_defconfig" ;;
        5) BOARD="ARM-SBC-XZ-A20"; CHIP="a20"; UBOOT_DEFCONFIG="armsbc-xz-a20_defconfig"; KERNEL_DEFCONFIG="armsbc-a20_defconfig" ;;
        *) echo -e "\033[1;31mInvalid selection.\033[0m"; exit 1 ;;  # Red for errors
    esac

    echo "Selected board: $BOARD with chip: $CHIP"
    export BOARD CHIP UBOOT_DEFCONFIG KERNEL_DEFCONFIG

else
    echo "Invalid choice. Exiting."
    exit 1
fi

# Common steps for all boards
# Install required packages
log() {
  echo -e "\033[1;34m[$(date +'%Y-%m-%d %H:%M:%S')] $1\033[0m"  # Blue color for logs
}

install_packages() {
  log "Installing required packages..."
  sudo apt update
  sudo apt install -y build-essential gcc curl make libssl-dev bison flex swig git wget bc python3 python3-pip device-tree-compiler gcc-aarch64-linux-gnu g++-aarch64-linux-gnu
}

log "Starting environment setup..."
install_packages

# Proceed to compilation
read -p "Do you want to proceed with compiling? (y/n): " CONTINUE_COMPILE
if [[ "$CONTINUE_COMPILE" =~ ^[Yy]$ ]]; then
    if [ -f "./compile.sh" ]; then
        chmod +x ./compile.sh
        log "Starting compilation with ./compile.sh..."
        ./compile.sh
    else
        log "[ERROR] compile.sh not found in the current directory. Exiting."
        exit 1
    fi
else
    log "Compilation skipped. Environment setup complete."
    log "You can manually run ./compile.sh when ready."
fi
