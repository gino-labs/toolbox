#!/usr/bin/bash
set -eo pipefail

usage() {
  echo "Usage: sudo ./make-media.sh <path-to-dvd-iso> <path-to-kickstart> <new-iso-filename>"
  exit 1
}

if [[ $1 == "--help" || $1 == "-h" ]]; then
  usage
fi

if [[ $EUID -ne 0 ]]; then
  echo "Please run script with sudo."
  usage
fi

if [[ ! -f $1 ]]; then
  echo "$1 not a file."
  usage
fi

if [[ ! -f $2 ]]; then
  echo "$2 not a file."
  usage
fi

if [[ -z $3 ]]; then
  echo "Give live ISO a filename."
  usage
fi

BUILD_DIR="build"
#TMP_DIR="$(mktemp -du XXXXX)"
ISO="$(realpath $1)"
KICKSTART="$(realpath $2)"
NEW_ISO_NAME=${3}

mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"
livemedia-creator \
  --make-iso \
  --iso="$ISO" \
  --ks="$KICKSTART" \
  --iso-name="${NEW_ISO_NAME}.iso" \
  --resultdir="$NEW_ISO_NAME" \
  --ram=8192 \
  --vcpus=4

echo "Live ISO created at $BUILD_DIR/$NEW_ISO_NAME/${NEW_ISO_NAME}.iso"

