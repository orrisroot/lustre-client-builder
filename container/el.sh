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

# --- source packages -----------------------------------------------------------
# only the source packages are built here, the binaries are built by mock in a
# minimal chroot below
pushd "${LUSTRE_BUILD_DIR}"
sh ./autogen.sh
./configure --disable-server --with-linux="/usr/src/kernels/${KERNEL_VERSION}"
make srpm
make dkms-srpms
SOURCE_RPM="$(ls "$(pwd)"/*.src.rpm | grep -v dkms)"
DKMS_SOURCE_RPM="$(ls "$(pwd)"/*dkms*.src.rpm)"
popd

echo "==> source rpm   : $(basename "${SOURCE_RPM}")"
echo "==> dkms src rpm : $(basename "${DKMS_SOURCE_RPM}")"

# --- binary packages -----------------------------------------------------------
dnf install -y epel-release
dnf install -y mock
MOCK_CONFIG="${ID}-${OS_MAJOR}-${KERNEL_ARCH}"
MOCK_OPTS="-r ${MOCK_CONFIG}"

mock ${MOCK_OPTS} init

# the dkms package is kernel independent, build it first while the chroot still
# contains nothing but the declared BuildRequires
# the bcond flags are not stored in the source rpm, they have to be passed
# again or the spec falls back to its defaults (servers and zfs enabled)
mock ${MOCK_OPTS} --resultdir "$(lb_mock_resultdir dkms)" --without servers --without zfs --without ldiskfs --rebuild "${DKMS_SOURCE_RPM}"
lb_collect_rpms dkms

# the kernel module package needs the kernel of this container in the chroot,
# which no BuildRequires can express
mock ${MOCK_OPTS} install kernel-devel-${KERNEL_VERSION} kernel-headers-${KERNEL_VERSION} kernel-abi-stablelists
mock ${MOCK_OPTS} install krb5-devel keyutils-libs-devel openssl-devel libyaml-devel libmount-devel libnl3-devel json-c-devel --nobest
mock ${MOCK_OPTS} install swig libaio-devel readline-devel libuuid-devel python3-devel python3-setuptools openmpi-devel
mock ${MOCK_OPTS} --no-clean --resultdir "$(lb_mock_resultdir kmod)" --define "configure_args ''" --define "kdir /usr/src/kernels/${KERNEL_VERSION}" --define "kobjdir /usr/src/kernels/${KERNEL_VERSION}" --without servers --without ldiskfs --with gss --with gss_keyring "${SOURCE_RPM}"
lb_collect_rpms kmod
