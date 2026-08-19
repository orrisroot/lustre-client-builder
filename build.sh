#!/bin/bash
#
# Build a lustre client package inside a container.
# Rootless (user mode) podman is preferred, docker is used as a fallback.

set -eu

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISTROS_CONF="${BASE_DIR}/distros.conf"
BUILD_CONF="${BASE_DIR}/build.conf"
CONTAINER_DIR="${BASE_DIR}/container"
SRC_DIR="${BASE_DIR}/src"
DIST_DIR="${BASE_DIR}/dist"

error () {
  echo "Error: $*" >&2
}

list_targets () {
  awk '/^[[:space:]]*#/ || NF < 3 { next } { printf "  - %-14s %s\n", $1, $2 }' "${DISTROS_CONF}"
}

# print "IMAGE FAMILY" for the given target name
lookup_target () {
  awk -v name="$1" '/^[[:space:]]*#/ || NF < 3 { next } $1 == name { print $2, $3; found = 1; exit } END { exit !found }' "${DISTROS_CONF}"
}

usage () {
  local name="$(basename "$0")"
  cat <<EOS
Usage: ${name} [OPTIONS] TARGET

Options:
  -s, --source NAME    lustre source tarball in src/ (default: ${LUSTRE_SOURCE:-none})
  -e, --engine ENGINE  container engine to use: podman or docker (default: auto detect)
  -P, --no-pull        use the base image in the local storage as it is,
                       without refreshing it from the registry
  -k, --keep           keep the container after the build has finished
  -L, --no-log         do not write a build log under dist/log/
  -h, --help           show this message

Environment variables:
  LUSTRE_SOURCE        same as --source
  CONTAINER_ENGINE     same as --engine

TARGET:
$(list_targets)
EOS
}

[ -f "${DISTROS_CONF}" ] || { error "target list not found: ${DISTROS_CONF}"; exit 1; }

# defaults, overridden by the environment and the command line
if [ -z "${LUSTRE_SOURCE:-}" ] && [ -f "${BUILD_CONF}" ]; then
  . "${BUILD_CONF}"
fi

ENGINE="${CONTAINER_ENGINE:-}"
PULL="yes"
KEEP="no"
LOG="yes"
TARGET=""

while [ $# -gt 0 ]; do
  case "$1" in
    -s|--source)
      [ $# -ge 2 ] || { error "$1 requires an argument"; exit 1; }
      LUSTRE_SOURCE="$2"
      shift 2
      ;;
    -e|--engine)
      [ $# -ge 2 ] || { error "$1 requires an argument"; exit 1; }
      ENGINE="$2"
      shift 2
      ;;
    -P|--no-pull)
      PULL="no"
      shift
      ;;
    -k|--keep)
      KEEP="yes"
      shift
      ;;
    -L|--no-log)
      LOG="no"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      error "unknown option: $1"
      usage
      exit 1
      ;;
    *)
      [ -z "${TARGET}" ] || { error "too many arguments: $1"; usage; exit 1; }
      TARGET="$1"
      shift
      ;;
  esac
done

if [ -z "${TARGET}" ]; then
  usage
  exit 1
fi

if ! TARGET_INFO="$(lookup_target "${TARGET}")"; then
  error "unknown target: ${TARGET}"
  usage
  exit 1
fi
IMAGE="${TARGET_INFO% *}"
FAMILY="${TARGET_INFO#* }"

BUILD_SCRIPT="${CONTAINER_DIR}/${FAMILY}.sh"
[ -f "${BUILD_SCRIPT}" ] || { error "build script not found: ${BUILD_SCRIPT}"; exit 1; }

# --- lustre source ------------------------------------------------------------
if [ -z "${LUSTRE_SOURCE:-}" ]; then
  error "no lustre source specified, use --source or set LUSTRE_SOURCE in ${BUILD_CONF}"
  exit 1
fi
LUSTRE_SOURCE="$(basename "${LUSTRE_SOURCE}")"
if [ ! -f "${SRC_DIR}/${LUSTRE_SOURCE}" ]; then
  error "lustre source not found: ${SRC_DIR}/${LUSTRE_SOURCE}"
  exit 1
fi

# --- container engine ---------------------------------------------------------
if [ -z "${ENGINE}" ]; then
  for candidate in podman docker; do
    if command -v "${candidate}" > /dev/null 2>&1; then
      ENGINE="${candidate}"
      break
    fi
  done
fi

[ -n "${ENGINE}" ] || { error "neither podman nor docker was found"; exit 1; }
command -v "${ENGINE}" > /dev/null 2>&1 || { error "container engine not found: ${ENGINE}"; exit 1; }

ENGINE_KIND="$(basename "${ENGINE}")"
RUN_OPTS=(--privileged --name "${TARGET}")

case "${ENGINE_KIND}" in
  podman*)
    # a container of the same name may be left over from a previous --keep run
    RUN_OPTS+=(--replace)
    if [ "$(${ENGINE} info --format '{{.Host.Security.Rootless}}' 2> /dev/null)" = "true" ]; then
      MODE="rootless"
      # rootless podman needs a subuid/subgid range for the calling user
      if ! ${ENGINE} unshare true > /dev/null 2>&1; then
        error "rootless podman is not usable for $(id -un)"
        error "add a subuid/subgid range, e.g.: sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 $(id -un)"
        error "and run: podman system migrate"
        exit 1
      fi
    else
      MODE="rootful"
    fi
    ;;
  *)
    MODE="rootful"
    echo "Warning: ${ENGINE_KIND} runs the build as the real root user," >&2
    echo "         the files under dist/ will be owned by root." >&2
    echo "         Rootless podman is recommended: $0 --engine podman ${TARGET}" >&2
    ;;
esac

if [ "${KEEP}" != "yes" ]; then
  RUN_OPTS+=(--rm)
fi
# the image is refreshed explicitly before the run, see run_build()
RUN_OPTS+=(--pull=never)

# keep stdin open for the build script; a tty is only useful when the output is
# not captured into a log file
RUN_OPTS+=(-i)
if [ "${LOG}" != "yes" ] && [ -t 0 ] && [ -t 1 ]; then
  RUN_OPTS+=(-t)
fi

RUN_OPTS+=(-e "LUSTRE_SOURCE=${LUSTRE_SOURCE}")
# only dist/ is writable, the scripts and the sources are mounted read only
RUN_OPTS+=(-v "${CONTAINER_DIR}:/opt/builder:ro")
RUN_OPTS+=(-v "${SRC_DIR}:/src:ro")
RUN_OPTS+=(-v "${DIST_DIR}:/dist")

image_exists () {
  case "${ENGINE_KIND}" in
    podman*) "${ENGINE}" image exists "$1" ;;
    *)       "${ENGINE}" image inspect "$1" > /dev/null 2>&1 ;;
  esac
}

# Refresh the base image and run the build.  When the registry cannot be
# reached the image already in the local storage is used instead, so a build
# never fails just because the image could not be refreshed.
run_build () {
  if [ "${PULL}" = "yes" ]; then
    if ! "${ENGINE}" pull "${IMAGE}"; then
      if image_exists "${IMAGE}"; then
        echo "Warning: could not refresh ${IMAGE}," >&2
        echo "         continuing with the image in the local storage." >&2
      else
        error "could not pull ${IMAGE}"
        return 1
      fi
    fi
  elif ! image_exists "${IMAGE}"; then
    error "${IMAGE} is not in the local storage, run without --no-pull"
    return 1
  fi

  "${ENGINE}" run "${RUN_OPTS[@]}" "${IMAGE}" /bin/bash "/opt/builder/${FAMILY}.sh"
}

mkdir -p "${DIST_DIR}"

echo "==> engine       : ${ENGINE_KIND} (${MODE})"
echo "==> image        : ${IMAGE}"
echo "==> script       : container/${FAMILY}.sh"
echo "==> source       : src/${LUSTRE_SOURCE}"
echo "==> output       : ${DIST_DIR}"

if [ "${LOG}" != "yes" ]; then
  run_build
  exit $?
fi

LOG_DIR="${DIST_DIR}/log"
LOG_FILE="${LOG_DIR}/${TARGET}-$(date '+%Y%m%d-%H%M%S').log"
mkdir -p "${LOG_DIR}"
echo "==> log          : ${LOG_FILE}"

set +e
run_build 2>&1 | tee "${LOG_FILE}"
STATUS="${PIPESTATUS[0]}"
set -e

if [ "${STATUS}" -ne 0 ]; then
  error "build failed (exit ${STATUS}), see ${LOG_FILE}"
fi
exit "${STATUS}"
