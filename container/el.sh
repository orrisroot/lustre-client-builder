#!/bin/bash
#
# Build the lustre client RPMs for RHEL clones (8 / 9 / 10).

set -eu

. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

lb_init

dnf update -y
dnf install -y dnf-plugins-core
case "${OS_MAJOR}" in
  8) dnf config-manager --enable powertools ;;
  *) dnf config-manager --enable crb ;;
esac
dnf group install -y "Development Tools"
dnf install -y which kmod
dnf install -y kernel-devel kernel-rpm-macros kernel-abi-stablelists
dnf install -y krb5-devel keyutils-libs-devel openssl-devel libyaml-devel libmount-devel libnl3-devel json-c-devel --nobest
dnf install -y swig libaio-devel readline-devel libuuid-devel python3-devel python3-setuptools openmpi-devel

. /etc/profile.d/modules.sh
module load mpi

lb_prepare "$(rpm -qa kernel-devel | sed -e 's+kernel-devel-++')"
lb_extract

pushd "${LUSTRE_BUILD_DIR}"
sh ./autogen.sh
./configure --disable-server --with-linux="/usr/src/kernels/${KERNEL_VERSION}"
# make dist
make srpm
# make dkms-srpms
SOURCE_RPM="$(pwd)/$(ls *src.rpm)"
popd

dnf install -y epel-release
dnf install -y mock
MOCK_CONFIG="${ID}-${OS_MAJOR}-${KERNEL_ARCH}"
mock -r ${MOCK_CONFIG} init
mock -r ${MOCK_CONFIG} install kernel-devel-${KERNEL_VERSION} kernel-headers-${KERNEL_VERSION} kernel-abi-stablelists
mock -r ${MOCK_CONFIG} install krb5-devel keyutils-libs-devel openssl-devel libyaml-devel libmount-devel libnl3-devel json-c-devel --nobest
mock -r ${MOCK_CONFIG} install swig libaio-devel readline-devel libuuid-devel python3-devel python3-setuptools openmpi-devel
mock -r ${MOCK_CONFIG} --no-clean --define "configure_args ''" --define "kdir /usr/src/kernels/${KERNEL_VERSION}" --define "kobjdir /usr/src/kernels/${KERNEL_VERSION}" --without servers --without ldiskfs --with gss --with gss_keyring ${SOURCE_RPM}
cp /var/lib/mock/${MOCK_CONFIG}/result/*.rpm "${DEST_DIR}/"
