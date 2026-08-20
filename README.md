# lustre client build tool

Build lustre client packages (RPM / DEB) for several distributions inside a
container.  The build runs with **rootless (user mode) podman** by default, so
neither a docker daemon nor root privileges on the host are required.
docker is still supported as a fallback.

## Requirements

- `podman` (rootless) or `docker`
- a subuid / subgid range for the user when podman is used rootless
  (normally set up by the distribution; check with `grep $(id -un) /etc/subuid`).
  If it is missing:

  ```
  sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 $(id -un)
  podman system migrate
  ```

## Usage

1. Put the lustre source tarball into `src/`.

2. Run the build for the target distribution:

   ```
   ./build.sh rocky-9
   ```

   ```
   Usage: build.sh [OPTIONS] TARGET

   Options:
     -s, --source NAME    lustre source tarball in src/ (default: build.conf)
     -e, --engine ENGINE  container engine to use: podman or docker (default: auto detect)
     -P, --no-pull        use the cached base image without refreshing it
     -k, --keep           keep the container after the build has finished
     -L, --no-log         do not write a build log under dist/log/
     -h, --help           show this message
   ```

   Targets: `alma-8`, `alma-9`, `alma-10`, `rocky-8`, `rocky-9`, `rocky-10`,
   `ubuntu-22.04`, `ubuntu-24.04` (see `distros.conf`).

3. The packages are written to
   `dist/<distribution>-<version>/<kernel-version>/`, the output of the run is
   kept in `dist/log/<target>-<timestamp>.log`.

Both a kernel module package built against the kernel of the base image and a
DKMS package that builds the modules on the target machine are produced:

| | RHEL clones | Ubuntu |
|---|---|---|
| kernel module | `kmod-lustre-client` | `lustre-client-modules-<kver>` |
| dkms | `lustre-client-dkms` | `lustre-client-modules-dkms` |
| userspace | `lustre-client`, `lustre-client-devel`, ... | `lustre-client-utils`, `lustre-dev`, ... |
| source package | `.src.rpm` | `.dsc` + `.tar.gz` + `.changes` |

The tarball to build is taken from `build.conf`, and can be overridden per run:

```
./build.sh --source lustre-2.15.6.tar.gz alma-9
LUSTRE_SOURCE=lustre-2.15.6.tar.gz ./build.sh alma-9
```

The engine can be selected the same way, with `--engine` or the
`CONTAINER_ENGINE` environment variable.

## How the packages are built

Both distribution families build in two stages, so that the binary packages
come out of a minimal chroot rather than out of the container the sources were
prepared in:

1. the container unpacks the sources and builds the **source package** only
   (`make srpm` / `make dkms-srpms`, `dpkg-buildpackage -S`)
2. the source package is rebuilt into binary packages in a minimal chroot -
   `mock` for the RHEL clones, a chroot created with `mmdebstrap` for Ubuntu -
   where the build dependencies come from the package metadata instead of
   being installed by hand

The build logs of the second stage are kept next to the packages, in
`dist/<distribution>/<kernel>/log/`.

Two things cannot be expressed as build dependencies and are installed
explicitly in the chroot:

- the kernel of the base image (`kernel-devel-<version>` / `linux-headers-<version>`),
  because the module package has to be built against exactly that kernel
- on Ubuntu, the packages lustre needs but `debian/control` does not declare
  (`flex`, `bison`, `swig`, `libpython3-dev`, `libnl-3-dev`, `libjson-c-dev`,
  `libkrb5-dev`, `mpi-default-dev`, ...)

Ubuntu does not use `sbuild` or `pbuilder` even though they are the usual
counterpart of `mock`: lustre builds its kernel module package with
module-assistant *after* `dpkg-buildpackage` (see the `debs` target of
`autoMakefile.am`), which a `.dsc` driven builder cannot reproduce.  The
upstream make targets are run inside the chroot instead.

## Layout

```
build.sh              host side entry point, starts the container
build.conf            default settings (lustre source tarball)
distros.conf          build targets: name, container image, script family
container/            mounted read only on /opt/builder in the container
  common.sh           shared helpers (environment check, unpack, destination)
  el.sh               build for RHEL clones 8 / 9 / 10 (rpm, via mock)
  ubuntu.sh           build for Ubuntu 22.04 / 24.04 (deb, via mmdebstrap)
src/                  lustre source tarballs, mounted read only on /src
dist/                 build results, mounted read write on /dist
```

Adding a distribution that an existing script can handle only needs a new line
in `distros.conf`.

## Notes

- Only `dist/` is mounted writable; the build scripts and the sources are
  mounted read only, so a build cannot damage its own inputs.
- Under rootless podman `root` inside the container is mapped to the calling
  user on the host, so the packages under `dist/` are owned by that user and can
  be deleted without `sudo`.  With docker they are owned by `root` instead.
- The container runs `--privileged`, which under rootless podman only grants
  the capabilities inside the user namespace - nothing is gained on the host.
  `mock` (used for the RHEL clone builds) works unmodified in that environment.
- SELinux does not need a relabel of the working directory because
  `--privileged` disables the label separation for the container.
- On failure the unpacked source tree is kept under the destination directory
  for inspection; on success it is removed.
- The base image is refreshed from the registry on every run.  When the pull
  fails (registry unreachable, rate limited, expired credentials) the image
  already in the local storage is used instead and the build continues with a
  warning; `--no-pull` skips the refresh altogether.
- Container images and the mock chroots are stored under
  `~/.local/share/containers`; a build needs several GB of free space there.
- Public images need no login, but podman also reads `~/.docker/config.json`
  and sends the credentials found there without falling back to an anonymous
  pull.  A stale Docker Hub entry therefore makes the pull fail with
  `unable to retrieve auth token: invalid username/password`; fix it with
  `docker logout` (anonymous pull) or `podman login docker.io`.
