# How it works

Technical details for the curious: where your data lives, what the WD firmware lacks, how the package is built and how to verify it.

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

- **Disk usage**: the WD kernel has no overlayfs, so Docker uses the `vfs` storage driver, which stores every image layer as a full copy. Images take several times more disk space than on a typical Linux machine (about 10 GB for ten common images).
- **cgroup v1**: the WD kernel (4.14) only has cgroup v1. Docker 29 supports it, but has announced its removal by May 2029. Releases follow new Docker versions automatically, new major versions included, so check the release notes before installing a new major.
- **Container port isolation**: the kernel has no iptables `raw` table, so Docker runs with `DOCKER_INSECURE_NO_IPTABLES_RAW=1`. This drops a hardening rule that blocks other hosts on your LAN from reaching container ports directly through routing; ports you publish with `-p` work as usual.
- **IPv6**: container IPv6 NAT is off (`"ip6tables": false`), because the kernel lacks `ip6table_nat`.
- **No bundled UI**: unlike the community app, Portainer is not installed. Run it as a container if you want it.

## Inside the app

The `.bin` is a standard My Cloud OS5 app package, built with WD's `mksapkg-OS5` tool. Inside:

| Part | What it does |
|---|---|
| `engine/` | Docker's official static binaries (`dockerd`, `containerd`, `runc`, `docker`, …) and the `docker compose` plugin |
| `dockerctl.sh` | Starts and stops Docker: loads the network kernel modules, mounts the cgroup controllers, mounts `/dev/pts`, links `docker` into `/sbin`, writes `daemon.json` on first start, starts `dockerd` and stops it gracefully |
| `init.sh`, `start.sh`, `stop.sh` | Run by the NAS at boot and shutdown, and during install, update and uninstall; each calls `dockerctl.sh` |
| `install.sh`, `remove.sh` | Copy the app into `Nas_Prog/docker` / remove it again. Never touch `Nas_Prog/docker_data` |
| `web/` | The info page behind the **Configure** button, filled in with your NAS's real paths |

What the WD firmware needs, and what the app does about it:

| Firmware | The app |
|---|---|
| The root filesystem is rebuilt in RAM at every boot | Recreates the `docker` links and mounts at every boot (`init.sh`, `start.sh`) |
| No overlayfs | `"storage-driver": "vfs"` and the classic image store (`"containerd-snapshotter": false`) |
| One combined `cpu,memory` cgroup hierarchy on `/sys/fs/cgroup` | Replaces it with the standard layout (one mount per controller), only if nothing uses it |
| No iptables `raw` table, no `ip6table_nat` | `DOCKER_INSECURE_NO_IPTABLES_RAW=1`, `"ip6tables": false` |
| `pivot_root` fails on the RAM root filesystem | `DOCKER_RAMDISK=1` |
| No `setsid`, `/tmp` mounted `noexec` | Avoided in the scripts |

During an update, WD runs the old app's `stop.sh` and `remove.sh`, then the new `install.sh`, `init.sh` and `start.sh`.

## Building it yourself

Releases are built by [GitHub Actions](../.github/workflows/release.yml), but you can build the same `.bin` on any computer with Docker (on Apple Silicon too, through emulation):

```bash
git clone https://github.com/polius/wd-mycloud-docker.git && cd wd-mycloud-docker
mkdir app-build && cp make-app.sh dockerctl.sh app-build/
docker run --rm --platform linux/amd64 -v "$PWD/app-build:/out" debian:bookworm-slim bash -c '
  apt-get update -qq &&
  apt-get install -y -qq --no-install-recommends curl ca-certificates openssl libxml2 >/dev/null &&
  bash /out/make-app.sh'
```

The build runs in a throwaway container that can only write to `app-build/`. Pass a version to build a specific one (`bash /out/make-app.sh 29.9.3`), and `-e MODELS="MyCloudPR2100"` to build only some models. It produces one `.bin` per model, `SHA256SUMS` and `release-notes.md`.

`make-app.sh` downloads WD's packaging tool from the [WDCommunity](https://github.com/WDCommunity/wdpksrc) project at a pinned commit and refuses to run it unless its SHA-256 matches.

## Verifying a release

Every release includes `SHA256SUMS`:

```bash
sha256sum -c SHA256SUMS        # Linux
shasum -a 256 -c SHA256SUMS    # macOS
```

The release notes also list the SHA-256 of Docker's official `docker-<version>.tgz`, so you can check that the engine inside the app is Docker's own, byte for byte.

## How releases are made

Every day, a [workflow](../.github/workflows/release.yml) checks download.docker.com for a new stable Docker release. If there is one, it builds the app for every supported model and publishes it as a release named after the Docker version (`v29.9.3`). New major versions (e.g. 30) are published the same way.
