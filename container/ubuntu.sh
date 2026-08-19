#!/bin/bash
#
# Build the lustre client DEBs for Ubuntu (22.04 / 24.04).

set -eu

. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

lb_init

export DEBIAN_FRONTEND=noninteractive
apt update
apt upgrade -y

# See: https://docs.oracle.com/en-us/iaas/Content/lustre/clients-for-ubuntu.htm#ubuntu24x86-build
apt install -y linux-headers-generic
apt install -y build-essential module-assistant debhelper quilt rsync flex bison mpi-default-dev
apt install -y libreadline-dev libselinux-dev libsnmp-dev
apt install -y kmod swig pkg-config
apt install -y libkrb5-dev libkeyutils-dev libssl-dev libyaml-dev libmount-dev libnl-3-dev libjson-c-dev
apt install -y libpython3-dev python3-distutils-extra

lb_prepare "$(ls -d /usr/src/linux-headers-*-generic | sed -e 's+.*/linux-headers-++g')"
lb_extract

pushd "${LUSTRE_BUILD_DIR}"
sh ./autogen.sh
./configure --disable-server --with-linux="/usr/src/linux-headers-${KERNEL_VERSION}/"
# make dist
make debs
cp ./debs/*.deb "${DEST_DIR}/"
popd
