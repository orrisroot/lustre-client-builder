#!/bin/bash

DATA='{
  "alma-8": { "repo": "docker.io/library/almalinux:8", "script": "el8.sh" },
  "alma-9": { "repo": "docker.io/library/almalinux:9", "script": "el9.sh" },
  "alma-10": { "repo": "docker.io/library/almalinux:10", "script": "el10.sh" },
  "rocky-8": { "repo": "docker.io/rockylinux/rockylinux:8", "script": "el8.sh" },
  "rocky-9": { "repo": "docker.io/rockylinux/rockylinux:9", "script": "el9.sh" },
  "rocky-10": { "repo": "docker.io/rockylinux/rockylinux:10", "script": "el10.sh" },
  "ubuntu-22.04": { "repo": "docker.io/library/ubuntu:22.04", "script": "ubuntu2204.sh" },
  "ubuntu-24.04": { "repo": "docker.io/library/ubuntu:24.04", "script": "ubuntu2404.sh" }
}'

TYPES=$(echo "${DATA}" | jq -r 'keys | join(" ")')

usage () {
  echo "Usage: $(basename $1) TYPE"
  echo "options:"
  echo "  - TYPE: ${TYPES}"
}

if [ $# -ne 1 ]; then
  usage $0
  exit 1
fi

NAME=$1
if ! echo "${DATA}" | jq -e "has(\"${NAME}\")" > /dev/null; then
  echo "Error: uknown type: ${NAME}"
  usage $0
  exit 1;
fi
REPO=$(echo "${DATA}" | jq -r ".\"${NAME}\".repo")
SCRIPT=$(echo "${DATA}" | jq -r ".\"${NAME}\".script")
DOCKER_OPTS="--privileged -it --rm --pull=always"

podman run ${DOCKER_OPTS} --name "${NAME}" -v $(pwd)/work:/work "${REPO}" /bin/bash "/work/bin/${SCRIPT}"
