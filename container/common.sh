#!/bin/bash
#
# Common helpers for the in-container build scripts.
#
# The host side (build.sh) mounts:
#   /opt/builder  (ro)  this directory
#   /src          (ro)  lustre source tarballs
#   /dist         (rw)  build results
# and passes the tarball to build in ${LUSTRE_SOURCE}.

LB_SRC_DIR="${LB_SRC_DIR:-/src}"
LB_DIST_DIR="${LB_DIST_DIR:-/dist}"

lb_die () {
  echo "Error: $*" >&2
  exit 1
}

# Check the environment and set SYSTEM_ID / OS_MAJOR / LUSTRE_SOURCE_PATH.
lb_init () {
  if [ ! -f /.dockerenv ] && [ ! -f /run/.containerenv ]; then
    lb_die "this script must be run inside a container (podman or docker)"
  fi
  [ -f /etc/os-release ] || lb_die "/etc/os-release file not found"
  [ -n "${LUSTRE_SOURCE:-}" ] || lb_die "LUSTRE_SOURCE is not set"
  [ -d "${LB_DIST_DIR}" ] || lb_die "output directory not mounted: ${LB_DIST_DIR}"

  LUSTRE_SOURCE_PATH="${LB_SRC_DIR}/${LUSTRE_SOURCE}"
  [ -f "${LUSTRE_SOURCE_PATH}" ] || lb_die "lustre source not found: ${LUSTRE_SOURCE_PATH}"

  . /etc/os-release
  SYSTEM_ID="${ID}-${VERSION_ID}"
  OS_MAJOR="${VERSION_ID%%.*}"

  echo "==> distribution : ${SYSTEM_ID}"
  echo "==> source       : ${LUSTRE_SOURCE}"
}

# Create the destination directory for the given kernel version and cd into it.
# Sets KERNEL_VERSION / KERNEL_ARCH / DEST_DIR.
lb_prepare () {
  KERNEL_VERSION="$1"
  [ -n "${KERNEL_VERSION}" ] || lb_die "kernel version could not be detected"
  KERNEL_ARCH="${KERNEL_VERSION##*.}"
  DEST_DIR="${LB_DIST_DIR}/${SYSTEM_ID}/${KERNEL_VERSION}"

  echo "==> kernel       : ${KERNEL_VERSION}"
  echo "==> destination  : ${DEST_DIR}"

  mkdir -p "${DEST_DIR}"
  cd "${DEST_DIR}"
}

# Unpack the source tarball into DEST_DIR and set LUSTRE_BUILD_DIR.
# The build tree is removed on success and kept on failure for inspection.
lb_extract () {
  LUSTRE_BUILD_DIR="${DEST_DIR}/$(basename "${LUSTRE_SOURCE}" .tar.gz)"
  rm -rf "${LUSTRE_BUILD_DIR}"
  tar zxf "${LUSTRE_SOURCE_PATH}" -C "${DEST_DIR}"
  [ -d "${LUSTRE_BUILD_DIR}" ] || lb_die "unexpected tarball layout: ${LUSTRE_BUILD_DIR} not found"
  trap 'lb_cleanup $?' EXIT
}

# Directory mock writes its results and logs to.  The build logs stay there,
# only the packages are copied next to the other results.
lb_mock_resultdir () {
  echo "${DEST_DIR}/log/mock-$1"
}

# Copy the packages mock produced up into DEST_DIR, keeping the logs in place.
lb_collect_rpms () {
  local dir
  dir="$(lb_mock_resultdir "$1")"
  cp "${dir}"/*.rpm "${DEST_DIR}/"
  echo "==> ${1} packages : $(ls "${dir}"/*.rpm | wc -l) files, logs in ${dir}"
}

# Copy the packages built in a separate directory next to the other results.
lb_collect_debs () {
  local dir="$1"
  cp "${dir}"/* "${DEST_DIR}/"
  echo "==> deb packages : $(ls "${dir}" | wc -l) files"
}

lb_cleanup () {
  local status="${1:-0}"
  if [ "${status}" -eq 0 ]; then
    rm -rf "${LUSTRE_BUILD_DIR}"
    echo "==> done, packages are in ${DEST_DIR}"
  else
    echo "==> build failed, the build tree is kept: ${LUSTRE_BUILD_DIR}" >&2
  fi
  return 0
}
