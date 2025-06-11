# build-scripts
![Logo](https://github.com/arm-sbc/binaries/blob/main/logo2.png)
Firmware build script for ARM-SBC boards.

Plaese use ubuntu 22 for building.

The script will install necessary dependencies for compilation, however there might some challenges depends on the installed packages, 

if the build fails install the missing dependencies.

	git clone https://github.com/arm-sbc/build-scripts.git
  	cd build-scripts
  	./set_env.sh

select the board

follow instructions

The script will download upstream kernel, uboot, and will provide an option for rootfs creation for ubuntu and debian, and will create a single image which can be flashed in to the board
