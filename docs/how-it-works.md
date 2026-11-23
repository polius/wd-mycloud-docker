# How it works

Technical details for the curious: where your data lives, what the WD firmware lacks, how the ARM models run current images, how the package is built and how to verify it.

## Where your data lives

The app keeps the Docker program and your data apart, the same way WD's own Plex app does (`Nas_Prog/plexmediaserver` and `Nas_Prog/plex_conf`):

| What | Where (on volume `/mnt/HD/HD_a2`) | Updates and uninstall |
|---|---|---|
| Docker program | `Nas_Prog/docker/engine/` | Replaced on update, removed on uninstall |
| Images, containers, volumes, networks | `Nas_Prog/docker_data/data/` | Never touched |
| Docker settings | `Nas_Prog/docker_data/daemon.json` | Never touched |
| Logs | `Nas_Prog/docker_data/logs/` | Never touched |
| Folders you mount into containers | wherever you chose | Never touched |

`daemon.json` is written once with defaults that suit this NAS, and is yours to edit afterwards (restart Docker to apply: `bash /mnt/HD/HD_a2/Nas_Prog/docker/dockerctl.sh --restart`).

## Limitations of the WD firmware

- **Disk usage and container creation**: the WD kernel has no overlayfs, so Docker uses the `vfs` storage driver, which stores every image layer as a full copy. Images take several times more disk space than on a typical Linux machine (about 10 GB for ten common images), and creating a container (`docker run`, or recreating it after an image update) copies the whole image first, so it takes longer. Starting a container that already exists, as at every reboot and update, copies nothing. See [Why not overlayfs?](#why-not-overlayfs)
- **File capabilities**: the data volume can't store `security.*` extended attributes, so Docker drops them from image files (`vfs.xattrs=i_want_broken_containers`, as Docker 20.10 did without asking). Without this, pulling images like `louislam/uptime-kuma` fails. The usual reasons for those attributes, a normal user pinging or opening a port below 1024, still work: Docker allows both in containers by default (not with `--network host`). A program that needs another capability from its file fails when it starts, and setting one (`setcap`, in a container or a `docker build`) fails with "Not supported". `docker info` warns that these attributes are discarded.
- **cgroup v1**: the WD kernel (4.14) only has cgroup v1. Docker 29 supports it, but has announced its removal by May 2029. Releases follow new Docker versions automatically, new major versions included, so check the release notes before installing a new major.
- **Container port isolation**: the kernel has no iptables `raw` table, so Docker runs with `DOCKER_INSECURE_NO_IPTABLES_RAW=1`. This drops a hardening rule that blocks other hosts on your LAN from reaching container ports directly through routing; ports you publish with `-p` work as usual.
- **IPv6**: container IPv6 NAT is off (`"ip6tables": false`), because the kernel lacks `ip6table_nat`.
- **No bundled UI**: unlike the community app, Portainer is not installed. Run it as a container if you want it.

### Why not overlayfs?

Docker itself already supports overlayfs; it's the WD kernel that lacks it, so no change to Docker can add it. The app would have to ship its own `overlay.ko` kernel module, and it doesn't, on purpose:

- **A kernel module only works with the exact kernel it was built for.** After a firmware update with a new kernel, the module would either be refused, so Docker couldn't start until a matching module was published, or, if the kernel doesn't check, load and possibly crash the NAS.
- **WD's GPL downloads don't include the My Cloud OS 5 kernel source** (only the older 2.x firmware), so the module couldn't be built from WD's own kernel.
- **Existing installs would lose sight of their containers**: images and containers made with `vfs` aren't visible with overlayfs, so switching means recreating them.

This is worth revisiting if a future firmware includes overlayfs, if WD publishes the OS 5 kernel source, or if a well-maintained module for it appears.

## ARM models: memory page size

The EX2 Ultra's kernel uses **32 KB memory pages** (`getconf PAGESIZE` prints `32768`; the Intel models use the usual 4 KB). A program is loaded into memory one page at a time, so the parts of the program file must line up with the page size. Most current ARM images are built for 4 KB pages: Alpine 3.18 and later, Debian 12 (bookworm), Ubuntu 24.04, and everything built on them, such as `nginx:alpine`. On this kernel their programs don't start: the container exits with code 139 (a crash), or with `error while loading shared libraries: ... ELF load command address/offset not page-aligned`. Older images (Alpine 3.17, Debian 11, Ubuntu 22.04) and programs written in Go are built for 64 KB and run as they are. Debian 13 (trixie) and Ubuntu 26.04 mostly do too, but still have a few libraries built for 4 KB, such as zlib.

The ARM app fixes this when a container starts, with **pagefix** (from this project, in [`pagefix/`](../pagefix)). It re-lays out each program file that can't load, so that it can: no instruction or address in it changes, only where its parts are placed in the file, and every rewrite is checked before it replaces the file. It works on the container's own copy of the image (with `vfs`, every container has one), so the image itself and other containers aren't changed. Files that already load are not touched. The first start of a new container checks all its files (a few seconds to minutes, depending on the image); later starts only check files changed since.

How it runs: in the ARM app, `engine/runc` is pagefix, and Docker's own `runc` is next to it as `engine/runc.real`, unmodified. Docker runs `runc` for everything a container does; pagefix passes every call straight to `runc.real`, and before a container starts it first fixes the container's files. It writes no logs, and a file it can't fix never stops a container from starting. It does nothing on a kernel with 4 KB pages.

What it costs, in the fixed files only:

- **Less hardening**: each fixed program has one memory page that is both writable and executable, and loses its read-only relocations (RELRO). Both make some memory-corruption bugs easier to exploit; neither changes what the program does.
- **Changed files**: package checkers (`apk audit`, `debsums`) and image scanners report the fixed files as modified.

What it can't fix:

- **Packages installed in a running container** (`apk add`, `apt-get install`) don't start until the container starts again: `docker restart <name>`.
- **Programs on volumes and mounted folders** are never touched.
- **Programs that assume 4 KB pages while running** can still fail. Rare; Node.js, for example, works but prints `pthread_create: Invalid argument` for one thread.
- **`docker build`**: each `RUN` step is fixed before it runs, but a program installed in a `RUN` step can't run in that same step: run it in the next one (`RUN apk add curl` then `RUN curl ...`, not `RUN apk add curl && curl ...`). This is with the builder the app comes with; with BuildKit (if you add the `buildx` plugin), `RUN` steps aren't fixed at all.

To see what in a container can't load, and whether pagefix can fix it:

```bash
bash /mnt/HD/HD_a2/Nas_Prog/docker/dockerctl.sh --pagefix-check <container>
```

To turn it off: `PAGEFIX=0` in `/mnt/HD/HD_a2/Nas_Prog/docker_data/dockerctl.conf`, then restart Docker. For one container only: `docker run -e PAGEFIX=0 ...`.

## What works in containers

Checked on a PR2100:

| Feature | On this NAS |
|---|---|
| Memory and swap limits (`--memory`, `--memory-swap`) | ✅ Work |
| Disk speed limits (`--device-read-bps`, `--device-write-iops`, …) | ❌ The kernel has no blkio throttling |
| Hardware video transcoding (Plex, Jellyfin) | ✅ The Intel GPU is available as `/dev/dri`: pass `--device /dev/dri` |
| VPN containers that use tun (OpenVPN, Tailscale, Gluetun) | ✅ Work: pass `--device /dev/net/tun --cap-add NET_ADMIN` |
| WireGuard in the kernel | ❌ Not in kernel 4.14: use an image that runs WireGuard in userspace (over `/dev/net/tun`) |
| macvlan networks (a container with its own address on your LAN) | ✅ Work: the NAS's network interface is `bond0` (`-o parent=bond0`) |
| A normal user opening a port below 1024, or pinging | ✅ Work (Docker's defaults), except with `--network host` |
| `setcap` in a container or a `docker build` | ❌ Fails with "Not supported": see [Troubleshooting](troubleshooting.md#setcap-fails-with-not-supported) |
| ARM-only images | ❌ The PR2100 and PR4100 are x86_64: they fail with `exec format error` |

## Inside the app

The `.bin` is a standard My Cloud OS5 app package, built with WD's `mksapkg-OS5` tool. Inside:

| Part | What it does |
|---|---|
| `engine/` | Docker's official static binaries (`dockerd`, `containerd`, `runc`, `docker`, …) and the `docker compose` plugin. ARM models also have pagefix as `engine/runc`, with Docker's `runc` as `engine/runc.real` ([why](#arm-models-memory-page-size)) |
| `dockerctl.sh` | Starts and stops Docker: loads the network kernel modules, mounts the cgroup controllers, mounts `/dev/pts`, links `docker` into `/sbin`, writes `daemon.json` on first start, starts `dockerd` and stops it gracefully |
| `init.sh`, `start.sh`, `stop.sh` | Run by the NAS at boot and shutdown, and during install, update and uninstall; each calls `dockerctl.sh` |
| `install.sh`, `remove.sh` | Copy the app into `Nas_Prog/docker` / remove it again. Never touch `Nas_Prog/docker_data` |
| `web/` | The info page behind the **Configure** button, filled in with your NAS's real paths |

What the WD firmware needs, and what the app does about it:

| Firmware | The app |
|---|---|
| The root filesystem is rebuilt in RAM at every boot | Recreates the `docker` links and mounts at every boot (`init.sh`, `start.sh`) |
| No overlayfs | `"storage-driver": "vfs"` and the classic image store (`"containerd-snapshotter": false`) |
| The data volume can't store `security.*` extended attributes | `dockerd --storage-opt vfs.xattrs=i_want_broken_containers` (only if `daemon.json` sets no `storage-opts`; off with `DROP_XATTRS=0` in `dockerctl.conf`) |
| One combined `cpu,memory` cgroup hierarchy on `/sys/fs/cgroup` | Replaces it with the standard layout (one mount per controller), only if nothing uses it |
| No iptables `raw` table, no `ip6table_nat` | `DOCKER_INSECURE_NO_IPTABLES_RAW=1`, `"ip6tables": false` |
| `pivot_root` fails on the RAM root filesystem | `DOCKER_RAMDISK=1` |
| No `setsid`, `/tmp` mounted `noexec` | Avoided in the scripts |

During an update, WD runs the old app's `stop.sh` and `remove.sh`, then the new `install.sh`, `init.sh` and `start.sh`.

## Building it yourself

Releases are built by [GitHub Actions](../.github/workflows/release.yml), but you can build the same `.bin` on any computer with Docker (on Apple Silicon too, through emulation):

```bash
git clone https://github.com/polius/wd-mycloud-docker.git && cd wd-mycloud-docker
mkdir app-build && cp -r make-app.sh dockerctl.sh pagefix app-build/
docker run --rm --platform linux/amd64 -v "$PWD/app-build:/out" debian:bookworm-slim bash -c '
  apt-get update -qq &&
  apt-get install -y -qq --no-install-recommends curl ca-certificates openssl libxml2 >/dev/null &&
  bash /out/make-app.sh'
```

The build runs in a throwaway container that can only write to `app-build/`. Pass a version to build a specific one (`bash /out/make-app.sh 29.9.3`), and `-e MODELS="MyCloudPR2100"` to build only some models. It produces one `.bin` per model, `SHA256SUMS` and `release-notes.md`.

`make-app.sh` downloads WD's packaging tool from the [WDCommunity](https://github.com/WDCommunity/wdpksrc) project at a pinned commit and refuses to run it unless its SHA-256 matches. For the ARM models it also downloads the official Go release named in `make-app.sh` (checked the same way), runs pagefix's tests, builds it, and stops if any program in the ARM engine wouldn't load with 32 KB pages.

## Verifying a release

Every release includes `SHA256SUMS`:

```bash
sha256sum -c SHA256SUMS        # Linux
shasum -a 256 -c SHA256SUMS    # macOS
```

The release notes also list the SHA-256 of Docker's official `docker-<version>.tgz`, so you can check that the engine inside the app is Docker's own, byte for byte (on the ARM models, Docker's `runc` is `engine/runc.real`; the release notes give pagefix's SHA-256).

## How releases are made

Every day, a [workflow](../.github/workflows/release.yml) checks download.docker.com for a new stable Docker release. If there is one, it builds the app for every supported model and publishes it as a release named after the Docker version (`v29.9.3`). New major versions (e.g. 30) are published the same way.
