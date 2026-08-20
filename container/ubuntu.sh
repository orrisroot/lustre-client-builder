#!/bin/bash
#
# Build the lustre client DEBs for Ubuntu (22.04 / 24.04).
#
# Two stages, mirroring the RPM side:
#   1. this container builds the source package (.dsc), the deb counterpart of
#      the source rpm
#   2. the binary packages are built in a minimal chroot created with
#      mmdebstrap, with the build dependencies resolved from debian/control
#      instead of being installed by hand
#
# lustre cannot be built from the .dsc alone the way sbuild or pbuilder would
# do it: the kernel module package is produced by module-assistant after
# dpkg-buildpackage (see the debs target of autoMakefile.am), so the upstream
# make targets are run inside the chroot instead.

set -eu

. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

lb_init

export DEBIAN_FRONTEND=noninteractive
apt update
apt upgrade -y

# only what is needed to produce the source package and the chroot
apt install -y build-essential debhelper quilt rsync ed dpkg-dev mmdebstrap \
               linux-headers-generic

lb_prepare "$(ls -d /usr/src/linux-headers-*-generic | sed -e 's+.*/linux-headers-++g')"
lb_extract

# --- source package -----------------------------------------------------------
# lustre generates debian/changelog from changelog.in, the version has to be
# updated the same way the debs target of autoMakefile.am does it
LUSTRE_VERSION="$(basename "${LUSTRE_BUILD_DIR}" | sed -e 's+^lustre-++' -e 's+_+-+g')"

pushd "${LUSTRE_BUILD_DIR}"
cp debian/changelog.in debian/changelog
CHANGELOG_VERSION="$(sed -ne '1s/^lustre (\(.*\)-[0-9][0-9]*).*$/\1/p' debian/changelog)"
if [ "${LUSTRE_VERSION}" != "${CHANGELOG_VERSION}" ]; then
  printf '1i\nlustre (%s-1) unstable; urgency=low\n\n  * Automated changelog entry update\n\n -- lustre-client-builder <root@localhost>  %s\n\n.\nwq\n' \
    "${LUSTRE_VERSION}" "$(date -R)" | ed debian/changelog
fi
# -d: the build dependencies belong in the chroot, not in this container
dpkg-buildpackage -S -us -uc -d -I.git
popd

DSC_NAME="lustre_${LUSTRE_VERSION}-1.dsc"
SOURCE_TARBALL="lustre_${LUSTRE_VERSION}-1.tar.gz"
[ -f "${DEST_DIR}/${DSC_NAME}" ] || lb_die "source package not found: ${DEST_DIR}/${DSC_NAME}"
echo "==> source pkg   : ${DSC_NAME}"

# --- binary packages ----------------------------------------------------------
CHROOT_DIR=/var/tmp/lustre-chroot
CHROOT_WORK=/build
OUT_DIR="${CHROOT_DIR}${CHROOT_WORK}/out"

APT_MIRROR="$(grep -hoE 'https?://[^ ]+/ubuntu' /etc/apt/sources.list /etc/apt/sources.list.d/*.sources 2>/dev/null | head -1)"
[ -n "${APT_MIRROR}" ] || APT_MIRROR="http://archive.ubuntu.com/ubuntu"

echo "==> chroot       : ${VERSION_CODENAME} (${APT_MIRROR})"
# the updates pocket is required, the kernel headers of a running system are
# almost never the ones the release shipped with
# the buildd variant of mmdebstrap 0.8 (22.04) does not pull in apt yet
mmdebstrap --variant=buildd --include=apt,ca-certificates \
           "${VERSION_CODENAME}" "${CHROOT_DIR}" \
           "deb ${APT_MIRROR} ${VERSION_CODENAME} main universe" \
           "deb ${APT_MIRROR} ${VERSION_CODENAME}-updates main universe" \
           "deb ${APT_MIRROR} ${VERSION_CODENAME}-security main universe"

# the source package is kept in its own directory: dpkg-buildpackage writes its
# results next to the source tree and the debs target moves them away, which
# would take the input source package with it
mkdir -p "${OUT_DIR}" "${CHROOT_DIR}${CHROOT_WORK}/srcpkg"
# this source package is only the input of the chroot build, which regenerates
# it together with a .changes file covering the binaries as well - leaving it
# behind would make the .changes of this stage refer to overwritten files
mv "${DEST_DIR}/${DSC_NAME}" "${DEST_DIR}/${SOURCE_TARBALL}" \
   "${CHROOT_DIR}${CHROOT_WORK}/srcpkg/"
rm -f "${DEST_DIR}"/lustre_*_source.changes "${DEST_DIR}"/lustre_*_source.buildinfo

# the kernel module package needs this exact kernel in the chroot, which no
# Build-Depends can express - the same injection the RPM side does for mock
cat > "${CHROOT_DIR}${CHROOT_WORK}/build.sh" <<INNER
#!/bin/bash
set -eu
export DEBIAN_FRONTEND=noninteractive
cd ${CHROOT_WORK}

apt-get update
apt-get install -y --no-install-recommends "linux-headers-${KERNEL_VERSION}"
apt-get build-dep -y "${CHROOT_WORK}/srcpkg/${DSC_NAME}"
# debian/control does not declare everything configure needs, these are the
# packages the declared Build-Depends miss
apt-get install -y --no-install-recommends flex bison swig kmod \
                   mpi-default-dev libkrb5-dev libkeyutils-dev libnl-3-dev \
                   libjson-c-dev libsnmp-dev libpython3-dev \
                   python3-distutils-extra

# each make target gets its own tree: dpkg-buildpackage regenerates the source
# package from the tree it runs in, and debian/rules clean does not remove the
# kbuild leftovers of a previous build
build_target () {
  local wrap="\$1" target="\$2"

  # extracted without a target directory so that dpkg-source picks the
  # canonical lustre-<version> name, each target in its own wrapper directory
  mkdir -p "${CHROOT_WORK}/\${wrap}"
  (
    cd "${CHROOT_WORK}/\${wrap}"
    dpkg-source -x "${CHROOT_WORK}/srcpkg/${DSC_NAME}"
    cd lustre-*/
    sh ./autogen.sh
    ./configure --disable-server --with-linux="/usr/src/linux-headers-${KERNEL_VERSION}/"
    # dpkg-buildpackage regenerates the source package from this tree and
    # debian/rules clean does not remove the kernel feature tests configure
    # leaves behind
    rm -rf kconftest.dir kconftest.results
    # BUILD_DKMS only adds the dkms package to binary-indep, so one
    # dpkg-buildpackage run produces the userspace, the dkms and (through the
    # module-assistant step of the debs target) the kernel module packages
    BUILD_DKMS=true make "\${target}"
    cp -v debs/* ${CHROOT_WORK}/out/
    # the debs target does not collect the dkms package
    cp -v ../lustre-*-modules-dkms_*.deb ${CHROOT_WORK}/out/
  )
}

build_target build debs
INNER
chmod +x "${CHROOT_DIR}${CHROOT_WORK}/build.sh"

# mmdebstrap leaves /dev empty because a rootless container cannot mknod, so
# the device nodes are bind mounted one by one
CHROOT_DEV_NODES="null zero full random urandom tty"
mkdir -p "${CHROOT_DIR}/dev/pts" "${CHROOT_DIR}/dev/shm"
for node in ${CHROOT_DEV_NODES}; do
  touch "${CHROOT_DIR}/dev/${node}"
  mount --bind "/dev/${node}" "${CHROOT_DIR}/dev/${node}"
done
mount -t devpts -o gid=5,mode=620,ptmxmode=666 devpts "${CHROOT_DIR}/dev/pts"
# apt opens a pty for its terminal log, which needs /dev/ptmx
ln -sf pts/ptmx "${CHROOT_DIR}/dev/ptmx"
mount -t tmpfs tmpfs "${CHROOT_DIR}/dev/shm"
mount -t proc proc "${CHROOT_DIR}/proc"
mount -t sysfs sys "${CHROOT_DIR}/sys"
cp /etc/resolv.conf "${CHROOT_DIR}/etc/resolv.conf"

chroot "${CHROOT_DIR}" "${CHROOT_WORK}/build.sh"

umount "${CHROOT_DIR}/sys" "${CHROOT_DIR}/proc" "${CHROOT_DIR}/dev/shm" "${CHROOT_DIR}/dev/pts"
for node in ${CHROOT_DEV_NODES}; do
  umount "${CHROOT_DIR}/dev/${node}"
done

lb_collect_debs "${OUT_DIR}"
