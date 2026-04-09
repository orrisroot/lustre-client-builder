#!/bin/bash

set -e

if [ ! -f /.dockerenv -a ! -f /run/.containerenv ]; then
  echo "Error: running environment is not inside a docker container"
  exit 1
fi

if [ ! -f /etc/os-release ]; then
  echo "Error: /etc/os-release file not found"
  exit 1
fi

if [ ! -f /work/env ]; then
  echo "Error: /work/env env file not found"
  exit 1
fi

WORK_DIR=/work
. "${WORK_DIR}/env"

export DEBIAN_FRONTEND=noninteractive
apt update
apt upgrade -y

. /etc/os-release
SYSTEM_ID="${ID}-${VERSION_ID}"

# See: https://docs.oracle.com/en-us/iaas/Content/lustre/clients-for-ubuntu.htm#ubuntu24x86-build
# sudo apt-get install -y libreadline-dev libpython3-dev libkrb5-dev libkeyutils-dev flex bison libmount-dev quilt swig libtool make libnl-3-dev libnl-genl-3-dev libnl-3-dev pkg-config libhwloc-dev libnl-genl-3-dev libyaml-dev libtool libyaml-dev ed libreadline-dev dpatch libsnmp-dev mpi-default-dev libncurses5-dev libncurses-dev bison flex gnupg libelf-dev gcc libssl-dev bc wget bzip2 build-essential udev kmod cpio module-assistant debhelper libsnmp-dev mpi-default-dev libssl-dev python3-distutils-extra rsync

apt install -y linux-headers-generic
apt install -y build-essential module-assistant debhelper quilt rsync flex bison mpi-default-dev
apt install -y libreadline-dev libselinux-dev libsnmp-dev
apt install -y kmod swig pkg-config
apt install -y libkrb5-dev libkeyutils-dev libssl-dev libyaml-dev libmount-dev libnl-3-dev libjson-c-dev
apt install -y libpython3-dev python3-distutils-extra

KERNEL_VERSION="$(ls -d /usr/src/linux-headers-*-generic | sed -e 's+.*/linux-headers-++g')"
KERNEL_ARCH="$(echo ${KERNEL_VERSION} | sed -e 's+.*\.++g')"
DEST_DIR="${WORK_DIR}/dist/${SYSTEM_ID}/${KERNEL_VERSION}"
[ ! -d "${DEST_DIR}" ] && mkdir -p "${DEST_DIR}"
cd "${DEST_DIR}"

LUSTRE_SOURCE_PATH="${WORK_DIR}/src/${LUSTRE_SOURCE}"
LUSTRE_BUILD_DIR="${DEST_DIR}/$(basename "${LUSTRE_SOURCE}" .tar.gz)"

tar zxvf "${LUSTRE_SOURCE_PATH}"
pushd "${LUSTRE_BUILD_DIR}"
sh ./autogen.sh
./configure --disable-server --with-linux="/usr/src/linux-headers-${KERNEL_VERSION}/"
# make dist
make debs
cp ./debs/*.deb ${DEST_DIR}/
popd

rm -rf "${LUSTRE_BUILD_DIR}"
