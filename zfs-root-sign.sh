#!/usr/bin/env bash

# https://github.com/openzfs/zfs/issues/12540

test $EUID -eq 0 || echo "Exiting, must have root... use sudo!"
test $EUID -eq 0 || exit 1

TOPLOC=/var/lib; MOKLOC=$TOPLOC/shim-signed/mok
zpool get -H feature@encryption \
      $(df $TOPLOC --output=source | tail -n-1 | cut -d/ -f1) | \
    grep -qP '\sactive\s'
if [ $? -ne 0 ]; then
    echo "Exiting, meant for ZFS natively encrypted root fs!"
    echo "Follow this first: tinyurl.com/55szb8bm"; exit 1
fi

if [ -d $MOKLOC ]; then
    echo "Exiting, machine owner key directory found!"; exit 1
fi

cat <<MSG
-----------------------------------------------------
Note: cryptsetup is required but stumbles with ZFS.
      So, you may safely ignore messages saying...
        ERROR: Couldn't resolve device and
        WARNING: Couldn't determine root device
-----------------------------------------------------

MSG
read -e -p "$USER@$HOSTNAME, proceed with changes? [y/N] " DOIT
[[ "$DOIT" == [Yy]* ]] || exit

set -Eeuxo pipefail # https://wiki.debian.org/SecureBoot/VirtualMachine
lsb_release -c | fgrep trixie; uname -m | fgrep x86_64

pushd /tmp/
apt-get -y install sbsigntool efitools mokutil

# https://wiki.debian.org/SecureBoot#Generating_a_new_key
mkdir -p $MOKLOC; pushd $MOKLOC
openssl req -new -x509 -newkey rsa:2048 -keyout MOK.priv -outform DER \
        -out MOK.der -days 36500 -subj "/CN=$USER@$HOSTNAME/" \
        -nodes # https://serverfault.com/questions/366372
openssl x509 -inform der -in MOK.der -out MOK.pem
cp MOK.der /boot/efi  # copy public key so it can be imported via bios/firmware

ln -fs $PWD/MOK.der /root/mok.der; ln -fs $PWD/MOK.priv /root/mok.priv
fgrep  '# sign_tool' /etc/dkms/framework.conf && \
    sed -i~ -e 's/# sign_tool/sign_tool/g' /etc/dkms/framework.conf

# https://wiki.debian.org/SecureBoot#Set_Linux_kernel_info_variables
VERSION="$(uname -r)"
SHORT_VERSION="$(uname -r | cut -d - -f 1-2)"
MODULES_DIR=/lib/modules/$VERSION
KBUILD_DIR=/usr/lib/linux-kbuild-$SHORT_VERSION

sbsign --key MOK.priv --cert MOK.pem "/boot/vmlinuz-$VERSION" \
       --output "/boot/vmlinuz-$VERSION.tmp"    # sign kernel just in case
mv "/boot/vmlinuz-$VERSION.tmp" "/boot/vmlinuz-$VERSION"

# https://wiki.debian.org/SecureBoot#Using_your_key_to_sign_modules_.28Traditional_Way.29
pushd "$MODULES_DIR/updates/dkms" # For dkms packages; esp. zfs

# echo -n "Passphrase for the private key: "
# read -s KBUILD_SIGN_PIN
# export KBUILD_SIGN_PIN   # annoying & zfs root encryption required so added -nodes above too

for ii in *.ko ; do
    sudo --preserve-env=KBUILD_SIGN_PIN "$KBUILD_DIR"/scripts/sign-file sha512 \
         /root/mok.priv /root/mok.der "$ii" ;
done
popd; popd

# openzfs.github.io/openzfs-docs/Getting%20Started/Debian/Debian%20Bullseye%20Root%20on%20ZFS.html
apt-get -y reinstall grub-efi grub-efi-amd64-signed

# https://github.com/openzfs/zfs/issues/12540
apt-get -y --install-suggests reinstall \
        cryptsetup-initramfs  # required; reinstall insures initramfs is updated

mokutil --sb-state   # only being used for reporting, not key management

# https://wiki.debian.org/SecureBoot <<-- added
mokutil --import /var/lib/shim-signed/mok/MOK.der

popd; cat <<MSG

   Done. Now manually reboot to enroll /boot/efi/MOK.der into your
   computer's DB via the bios/firmware (and enable secure boot).
MSG
