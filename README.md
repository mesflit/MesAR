# Mesflit's Arch Repository

Custom Arch Linux PKGBUILD collection tailored for Arch Linux and its derivatives (CachyOS, EndeavourOS, Manjaro, etc.).

## Packages

| Package | Description |
| :--- | :--- |
| eden-emu-git | Eden Switch Emulator (Built from the latest Git master branch) |

---

## Installation & Usage

Ensure you have git and the base-devel group installed on your system:

sudo pacman -S --needed base-devel git

### 1. Clone the Repository
git clone https://github.com/mesflit/MesAR.git
cd MesAR

### 2. Build and Install
Navigate to the directory of the desired package and execute makepkg:

cd <package-name>
makepkg -si

---

## Updating & Clean Building

To pull the latest changes and perform a clean rebuild:

cd MesAR
git pull
cd <package-name>
rm -rf src build pkg *.pkg.tar.zst
makepkg -si

---

## Contributing
Feel free to open an Issue or submit a Pull Request if you encounter missing dependencies or build errors.

Maintainer: mesflit
