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

dnf update -y

. /etc/os-release
SYSTEM_ID="${ID}-${VERSION_ID}"

dnf install -y dnf-plugins-core
dnf config-manager --enable powertools
dnf group install -y "Development Tools"
dnf install -y which kmod
dnf install -y kernel-devel kernel-rpm-macros kernel-abi-stablelists
dnf install -y krb5-devel keyutils-libs-devel openssl-devel libyaml-devel libmount-devel libnl3-devel json-c-devel --nobest
dnf install -y swig libaio-devel readline-devel libuuid-devel python3-devel python3-setuptools openmpi-devel

. /etc/profile.d/modules.sh
module load mpi

KERNEL_VERSION="$(rpm -qa kernel-devel | sed -e 's+kernel-devel-++')"
KERNEL_ARCH="$(echo ${KERNEL_VERSION} | sed -e 's+.*\.++g')"
DEST_DIR="${WORK_DIR}/dist/${SYSTEM_ID}/${KERNEL_VERSION}"
[ ! -d "${DEST_DIR}" ] && mkdir -p "${DEST_DIR}"
cd "${DEST_DIR}"

LUSTRE_SOURCE_PATH="${WORK_DIR}/src/${LUSTRE_SOURCE}"
LUSTRE_BUILD_DIR="${DEST_DIR}/$(basename "${LUSTRE_SOURCE}" .tar.gz)"

tar zxvf "${LUSTRE_SOURCE_PATH}"
pushd "${LUSTRE_BUILD_DIR}"
sh ./autogen.sh
./configure --disable-server --with-linux=/usr/src/kernels/${KERNEL_VERSION}
# make dist
make srpm
# make dkms-srpms
SOURCE_RPM="$(pwd)/$(ls *src.rpm)"
popd

dnf install -y epel-release
dnf install -y mock
MOCK_CONFIG="$(echo $SYSTEM_ID | sed -e 's+\..*$++g')-$KERNEL_ARCH"
mock -r ${MOCK_CONFIG} init
mock -r ${MOCK_CONFIG} install kernel-devel-${KERNEL_VERSION} kernel-headers-${KERNEL_VERSION} kernel-abi-stablelists
mock -r ${MOCK_CONFIG} install krb5-devel keyutils-libs-devel openssl-devel libyaml-devel libmount-devel libnl3-devel json-c-devel --nobest
mock -r ${MOCK_CONFIG} install swig libaio-devel readline-devel libuuid-devel python3-devel python3-setuptools openmpi-devel
mock -r ${MOCK_CONFIG} --no-clean --define "configure_args ''" --define "kdir /usr/src/kernels/${KERNEL_VERSION}" --define "kobjdir /usr/src/kernels/${KERNEL_VERSION}" --without servers --without ldiskfs --with gss --with gss_keyring ${SOURCE_RPM}
cp /var/lib/mock/${MOCK_CONFIG}/result/*.rpm ${DEST_DIR}/

rm -rf "${LUSTRE_BUILD_DIR}"
