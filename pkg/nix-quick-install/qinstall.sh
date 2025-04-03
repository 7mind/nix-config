#!/usr/bin/env bash

set -e

self="$(realpath "$0")"
self_dir="$(dirname "$self")"

function prepare_layout() {
  wipefs -a -f "$DISK1"
  dd if=/dev/zero of="$DISK1" bs=50M count=1

  partprobe
  udevadm settle

  parted --script "${DISK1}" -- \
    mklabel gpt \
    mkpart primary 1024MiB 100% \
    mkpart esp fat32 1MiB 1024MiB \
    set 2 boot on

  partprobe
  udevadm settle

  # sgdisk -n3:1M:+2048M -t3:EF00 -c 3:boot "$DISK1"
  # sgdisk "-n2:0:+${SWPSIZE}" -t2:8200 -c 2:swap "$DISK1"
  # sgdisk -n1:0:0 -t1:BF01 -c 1:root "$DISK1"

  SCHEME=-part
  TGT_ROOT=${DISK1}${SCHEME}1

  if [[ ! (-L "$TGT_ROOT") && ! (-b "$TGT_ROOT") ]]; then
    SCHEME=p
  fi

  TGT_ROOT=${DISK1}${SCHEME}1
  if [[ ! (-L "$TGT_ROOT") && ! (-b "$TGT_ROOT") ]]; then
    SCHEME=""
  fi

  TGT_ROOT=${DISK1}${SCHEME}1
  TGT_BOOT=${DISK1}${SCHEME}2

  if [[ ! (-L "$TGT_ROOT") && ! (-b "$TGT_ROOT") ]]; then
    echo "Missing root partition: ${TGT_ROOT}"
    exit 1
  fi

  if [[ ! (-L "$TGT_BOOT") && ! (-b "$TGT_BOOT") ]]; then
    echo "Missing boot partition: ${TGT_BOOT}"
    exit 1
  fi
}

function create_filesystems() {
  zfs_args=("$@")

  zpool create -f \
    -O mountpoint=none \
    -O atime=off \
    -o ashift=12 \
    -O acltype=posixacl \
    -O xattr=sa \
    "${zfs_args[@]}" \
    zroot \
    "${TGT_ROOT}"

  zfs create \
    -V "${SWPSIZE}" \
    -b "$(getconf PAGESIZE)" \
    -o compression=zle \
    -o logbias=throughput \
    -o sync=always \
    -o primarycache=metadata \
    -o secondarycache=none \
    -o com.sun:auto-snapshot=false \
    zroot/swap

  zfs create -o mountpoint=legacy zroot/root      # For /
  zfs create -o mountpoint=legacy zroot/root/home # For /home
  zfs create -o mountpoint=legacy zroot/root/nix  # For /nix

  mkfs.vfat "${TGT_BOOT}"
  mkswap -f "${TGT_SWAP}"
}

function mount_filesystems() {
  set -x
  mkdir -p /mnt
  mount -t zfs zroot/root /mnt
  mkdir -p /mnt/{nix,home,boot}
  mount -t zfs zroot/root/nix /mnt/nix
  mount -t zfs zroot/root/home /mnt/home
  swapon "${TGT_SWAP}"
  mount "${TGT_BOOT}" /mnt/boot
  set+x
}

function unmount_filesystems() {
  set -x
  umount /mnt/nix
  umount /mnt/home
  umount /mnt/boot
  umount /mnt

  swapoff -a
  zpool export -a
  set +x

  echo "Don't forget about 'zpool export zroot' in the end"
  # zpool export zroot
}

function install_nixos() {
  ZFS_ID="$(cat /dev/urandom | hexdump --no-squeezing -e '/1 "%x"' | head -c 8)"

  nixos-generate-config --root /mnt

  # sed -i '/\}\s*$/d' /mnt/etc/nixos/configuration.nix
  cp "${self_dir}"/../seed.nix /mnt/etc/nixos/
  cp "${self_dir}"/../seed-flake.nix /mnt/etc/nixos/flake.nix
  cp "${self_dir}"/../any.nix /mnt/etc/nixos/
  #cp "${self_dir}"/../any-nixos-generic.nix /mnt/etc/nixos/

  sed -i '/canTouchEfiVariables/d' /mnt/etc/nixos/configuration.nix
  sed -i '/systemd-boot/d' /mnt/etc/nixos/configuration.nix
  #sed -i 's/# Include the results of the hardware scan./ .\/seed.nix .\/any.nix .\/any-nixos-generic.nix /g' /mnt/etc/nixos/configuration.nix

  sed -i 's/# Include the results of the hardware scan./ .\/seed.nix /g' /mnt/etc/nixos/configuration.nix
  sed -i 's/__ZFSID__/'"${ZFS_ID}"'/g' /mnt/etc/nixos/seed.nix

  set +x

  echo "Going to run 'nixos-install --no-root-password' in 3 seconds..."
  sleep 3

  nixos-install --no-root-password
}

function read_parameters() {
  DISK1=$1

  if [[ ! (-L "$DISK1") && ! (-b "$DISK1") ]]; then
    echo "Missing disk: ${DISK1}"
    ls -la /dev/disk/by-id/
    exit 1
  fi

  SWPSIZE=${SWPSIZE:-16GiB}
  ENCRYPTED=${ENCRYPTED:-0}
  COMPRESSED=${COMPRESSED:-1}
  TGT_SWAP=/dev/zvol/zroot/swap

  echo "Will use ${DISK1}"
  echo "Swap size: SWPSIZE=${SWPSIZE}"
  echo "Encrypted: ENCRYPTED=${ENCRYPTED}"
  echo "Compressed: COMPRESSED=${COMPRESSED}"

  ZFS_ARGS=()
  if [[ "$COMPRESSED" == "1" ]]; then
    ZFS_ARGS+=("-O")
    ZFS_ARGS+=("compression=lz4")
  fi

  if [[ "$ENCRYPTED" == "1" ]]; then
    ZFS_ARGS+=("-O")
    ZFS_ARGS+=("encryption=on")
    ZFS_ARGS+=("-O")
    ZFS_ARGS+=("keyformat=passphrase")
  fi

  read -n 1 -s -r -p "Press any key to continue"
}

function do_install() {
  read_parameters "$@"
  set -x
  prepare_layout
  create_filesystems "${ZFS_ARGS[@]}"
  mount_filesystems
  install_nixos
  unmount_filesystems
  set +x
  reboot
}

echo "Usage:"
echo "  nix-quick-install install /dev/sdX"
echo "  nix-quick-install umount"
echo "  TGT_SWAP=/dev/sdXa TGT_BOOT=/dev/sdXb /dev/sdanix-quick-install mount"


for i in "$@"
do
case $i in
    install) shift && do_install "$@" ;;
    umount) shift && unmount_filesystems ;;
    mount) shift && mount_filesystems ;;
esac
done


