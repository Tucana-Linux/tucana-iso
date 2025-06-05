#!/bin/bash
# Build a Tucana ISO 
set -e
# The build directory, must be absolute path not relative
BUILD_DIR=/media/EXSTOR/iso-builds
# Mercury repo server
REPO=https://repo.tucanalinux.org/development/mercury
# Tucana kernel version
KERNEL_VERSION=6.15.0

# Don't touch
ROOT=$BUILD_DIR/squashfs-root

# Cleanup old build stuff (if there is any)
mkdir -p $BUILD_DIR
cd $BUILD_DIR
rm -rf *

# Make root folder
mkdir -p $ROOT

# Bootstrap
neptune-bootstrap $ROOT --y
sed -i "s@\"http.*\"@\"${REPO}\"@" $ROOT/etc/neptune/repositories.yaml
# Chroot commands

# Mount temp filesystems
mount --bind /dev $ROOT/dev
mount --bind /dev/pts $ROOT/dev/pts
mount --bind /proc $ROOT/proc
mount --bind /sys $ROOT/sys

# Install 
chroot $ROOT /bin/bash -c "systemd-machine-id-setup && systemctl preset-all" 

# Basic first-install things
echo "nameserver 1.1.1.1" > $BUILD_DIR/squashfs-root/etc/resolv.conf
chroot $ROOT /bin/bash -c "make-ca -g --force"
chroot $ROOT /bin/bash -c "pwconv"
# Install network manager and the kernel
chroot $ROOT /bin/bash -c "neptune sync"
chroot $ROOT /bin/bash -c "neptune install --y linux-tucana squashfs-tools rsync network-manager mpc linux-firmware"
chroot $ROOT /bin/bash -c "systemctl enable NetworkManager"
# Locales
echo "Building Locales"
echo "en_US.UTF-8 UTF-8" > $ROOT/etc/locale.gen
chroot $ROOT /bin/bash -c "locale-gen"
# User account setup
chroot $ROOT /bin/bash -c "useradd -m live"
chroot $ROOT /bin/bash -c "printf 'tucana\ntucana\n' | passwd live"
chroot $ROOT /bin/bash -c "gpasswd -a live wheel"
  # Disable password for sudo
cat > $ROOT/etc/sudoers.d/00-sudo << "EOF"
Defaults secure_path="/usr/sbin:/usr/bin"
%wheel ALL=(ALL) NOPASSWD: ALL
EOF
# Copy any custom config files
if [[ -d $BUILD_DIR/custom_config ]]; then
	cp -r $BUILD_DIR/custom_config $ROOT
fi

# Install a desktop enviorment and any other packages (you can choose here)
# Gnome
chroot $ROOT /bin/bash -c "neptune install --y gnome gparted firefox lightdm xdg-user-dirs gedit vim flatpak gnome-tweaks gedit file-roller openssh calamares"
chroot $ROOT /bin/bash -c "gsettings set org.gnome.shell favorite-apps \"['org.gnome.Nautilus.desktop', 'firefox.desktop', 'org.gnome.Terminal.desktop', 'calamares.desktop']\""
# XFCE 
#chroot $ROOT /bin/bash -c "neptune install --y xfce4 lightdm gedit polkit-gnome firefox lightdm xdg-user-dirs vim xfce4-terminal flatpak gnome-software libsoup3 openssh calamares"
# Plasma 6
#chroot $ROOT /bin/bash -c "neptune install --y plasma-desktop-full firefox lightdm xdg-user-dirs kate vim flatpak ark calamares libsoup3"

chroot $ROOT /bin/bash -c "chown -R live:live /home/live"
# Add the desktop, music documents, downloads and other folders
chroot $ROOT /bin/bash -c "su live -c xdg-user-dirs-update"
# Symlink calamares to desktop
ln -sfv /usr/share/applications/calamares.desktop $ROOT/home/live/Desktop/
chroot $ROOT /bin/bash -c "chown -R live:live /home/live"
# Setup autologin
chroot $ROOT /bin/bash -c "systemctl enable lightdm"
#chroot $ROOT /bin/bash -c "systemctl enable sshd"
sed -i 's/#autologin-user=/autologin-user=live/' $ROOT/etc/lightdm/lightdm.conf
# plasma is plasmawayland, gnome is gnome-wayland
sed -i 's/#autologin-session=/autologin-session=gnome-wayland/' $ROOT/etc/lightdm/lightdm.conf

# Disable pkexec prompt
cat > $ROOT/etc/polkit-1/rules.d/50-nopasswd_global.rules << "EOF"
/* Allow members of the wheel group to execute any actions
 * without password authentication, similar to "sudo NOPASSWD:"
 */
polkit.addRule(function(action, subject) {
    if (subject.isInGroup("wheel")) {
        return polkit.Result.YES;
    }
});

EOF


# Change the init script 
echo '#!/bin/sh

PATH=/usr/bin:/usr/sbin
export PATH

problem()
{
   printf "Encountered a problem!\n\nDropping you to a shell.\n\n"
   sh
}

no_device()
{
   printf "The device %s, which is supposed to contain the\n" $1
   printf "root file system, does not exist.\n"
   printf "Please fix this problem and exit this shell.\n\n"
}

no_mount()
{
   printf "Could not mount device %s\n" $1
   printf "Sleeping forever. Please reboot and fix the kernel command line.\n\n"
   printf "Maybe the device is formatted with an unsupported file system?\n\n"
   printf "Or maybe filesystem type autodetection went wrong, in which case\n"
   printf "you should add the rootfstype=... parameter to the kernel command line.\n\n"
   printf "Available partitions:\n"
}

do_mount_root()
{
   mkdir /.root
   mkdir -p /mnt
   mkdir -p /squash
   mknod /dev/loop0 b 7 0
   device="/dev/disk/by-label/tucana"
   # Mount Rootfs
   echo "Mounting USB Container Drive"
   mount $device /mnt
   echo "Mounting squashfs as overlay"
   mkdir -p /cow
   mount -t tmpfs tmpfs /cow
   mkdir -p /cow/mod
   mkdir -p /cow/buffer

   mount /mnt/boot/tucana.squashfs /squash -t squashfs -o loop
   mount -t overlay -o lowerdir=/squash,upperdir=/cow/mod,workdir=/cow/buffer overlay /.root
   mkdir -p /.root/mnt/changes
   mkdir -p /.root/mnt/container
   mount --bind /cow/mod /.root/mnt/changes
   mount --bind /mnt /.root/mnt/container
}

do_add_squashfs_to_calamares()
{
    UNPACKFS_CONF="/.root/usr/share/calamares/modules/unpackfs.conf"
    
    # Iterate through all .squashfs files in /mnt/boot/
    find /mnt/boot/ -maxdepth 1 -type f -name "*.squashfs" | while read -r squashfs_file; do
        # Extract the filename without path and extension to use as a target directory
        squashfs_basename=$(basename "$squashfs_file")
        sqfs="/mnt/container/boot/$squashfs_basename" 
        
        # Add a new entry to unpackfs.conf
        echo "Adding squashfs entry for: $squashfs_file"
        echo "-   source: \"$sqfs\"" >> "$UNPACKFS_CONF"
        echo "    sourcefs: \"squashfs\"" >> "$UNPACKFS_CONF"
        echo "    destination: \"\"" >> "$UNPACKFS_CONF"
        echo "" >> "$UNPACKFS_CONF"
    done
}


do_try_resume()
{
   case "$resume" in
      UUID=* ) eval $resume; resume="/dev/disk/by-uuid/$UUID"  ;;
      LABEL=*) eval $resume; resume="/dev/disk/by-label/$LABEL" ;;
   esac

   if $noresume || ! [ -b "$resume" ]; then return; fi

   ls -lH "$resume" | ( read x x x x maj min x
       echo -n ${maj%,}:$min > /sys/power/resume )
}

init=/sbin/init
root=
rootdelay=
rootfstype=auto
ro="ro"
rootflags=
device=
resume=
noresume=false

mount -n -t devtmpfs devtmpfs /dev
mount -n -t proc     proc     /proc
mount -n -t sysfs    sysfs    /sys
mount -n -t tmpfs    tmpfs    /run

read -r cmdline < /proc/cmdline

for param in $cmdline ; do
  case $param in
    init=*      ) init=${param#init=}             ;;
    root=*      ) root=${param#root=}             ;;
    rootdelay=* ) rootdelay=${param#rootdelay=}   ;;
    rootfstype=*) rootfstype=${param#rootfstype=} ;;
    rootflags=* ) rootflags=${param#rootflags=}   ;;
    resume=*    ) resume=${param#resume=}         ;;
    noresume    ) noresume=true                   ;;
    ro          ) ro="ro"                         ;;
    rw          ) ro="rw"                         ;;
  esac
done

# udevd location depends on version
if [ -x /sbin/udevd ]; then
  UDEVD=/sbin/udevd
elif [ -x /lib/udev/udevd ]; then
  UDEVD=/lib/udev/udevd
elif [ -x /lib/systemd/systemd-udevd ]; then
  UDEVD=/lib/systemd/systemd-udevd
else
  echo "Cannot find udevd nor systemd-udevd"
  problem
fi

${UDEVD} --daemon --resolve-names=never
udevadm trigger
udevadm settle

if [ -f /etc/mdadm.conf ] ; then mdadm -As                       ; fi
if [ -x /sbin/vgchange  ] ; then /sbin/vgchange -a y > /dev/null ; fi
if [ -n "$rootdelay"    ] ; then sleep "$rootdelay"              ; fi

do_try_resume # This function will not return if resuming from disk
do_mount_root
do_add_squashfs_to_calamares

killall -w ${UDEVD##*/}

exec switch_root /.root "$init" "$@"' > $ROOT/usr/share/mkinitramfs/init.in

# Generate initrd
#echo 'EARLY_LOAD_MODULES="xe"' > $ROOT/etc/early_load_modules.conf
chroot $ROOT /bin/bash -c "mkinitramfs $KERNEL_VERSION-tucana --live"

# Reinstall initrd so it doesn't mess with the final system
chroot $ROOT /bin/bash -c "neptune reinstall --y mkinitramfs"


# Makes gnome work
chroot $ROOT /bin/bash -c "gdk-pixbuf-query-loaders --update-cache"

# Setup flatpak
chroot $ROOT /bin/bash -c "flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo"

# Unmount temp filesystems and generate squashfs
cd $BUILD_DIR
umount $ROOT/dev/pts
umount $ROOT/dev
umount $ROOT/proc
umount $ROOT/sys
mksquashfs squashfs-root tucana.squashfs


# Start building the iso
git clone https://github.com/Tucana-Linux/tucana-iso.git

mkdir -p iso
cd iso
mkdir -p boot/grub buffer mod isolinux unmod
# Copy some stuff and build the efi.img file
# Change kernel ver isolinux
sed -i "s/5\.18\.0/$KERNEL_VERSION/g" $BUILD_DIR/tucana-iso/isolinux/isolinux.cfg
sed -i "s/6\.0\.9/$KERNEL_VERSION/g" $BUILD_DIR/tucana-iso/grub/grub.cfg

cp -rpv $BUILD_DIR/tucana-iso/isolinux/* isolinux
cp -rpv $BUILD_DIR/tucana-iso/grub boot/
cd boot/grub
bash .mkefi
cd ../../

# Copy the squashfs, initramfs and kernel
cp -pv $ROOT/boot/vmlinuz-* $BUILD_DIR/iso/boot/vmlinuz-$KERNEL_VERSION-tucana
cp -pv $ROOT/initrd* $BUILD_DIR/iso/boot
cp -pv $BUILD_DIR/tucana.squashfs $BUILD_DIR/iso/boot

# Build the iso
xorriso -as mkisofs \
  -isohybrid-mbr $BUILD_DIR/tucana-iso/isohdpfx.bin \
  -c isolinux/boot.cat \
  -b isolinux/isolinux.bin \
  -no-emul-boot \
  -boot-load-size 4 \
  -boot-info-table \
  -eltorito-alt-boot \
  -e boot/grub/efi.img \
  -no-emul-boot \
  -isohybrid-gpt-basdat \
  -o tucana.iso -V tucana \
  .
mv tucana.iso ../





