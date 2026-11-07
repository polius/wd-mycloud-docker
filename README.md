<div align="center">
<img src="docs/assets/icon.png" alt="Docker for WD My Cloud" width="96">
<h1 align="center">Docker for WD My Cloud</h1>

**The official Docker Engine, always up to date, on your WD My Cloud OS5 NAS: installed and updated from the dashboard.**

<p align="center">
<a href="https://github.com/polius/wd-mycloud-docker/actions/workflows/release.yml"><img src="https://github.com/polius/wd-mycloud-docker/actions/workflows/release.yml/badge.svg" alt="Release"></a>&nbsp;<a href="https://github.com/polius/wd-mycloud-docker/releases/latest"><img alt="GitHub Release" src="https://img.shields.io/github/v/release/polius/wd-mycloud-docker"></a>&nbsp;<a href="https://github.com/polius/wd-mycloud-docker/releases"><img alt="Downloads" src="https://img.shields.io/github/downloads/polius/wd-mycloud-docker/total"></a>&nbsp;<a href="LICENSE"><img alt="License: MIT" src="https://img.shields.io/badge/License-MIT-blue.svg"></a>
</p>

<br>

<img src="docs/assets/dashboard.png" alt="The Docker app in the WD My Cloud dashboard, showing version 29.9.3" width="720">

</div>

## Features

- **Official Docker, unmodified**, with `docker compose` included.
- **Always up to date**: a new release within a day of every Docker release.
- **No SSH needed to install or update**: you upload one file in the dashboard.
- **Your containers are kept** across updates and reboots.

## Supported models

| Model | Status |
|---|---|
| My Cloud PR2100 | ✅ Tested (OS 5.33.102) |
| My Cloud PR4100 | Should work, not tested yet ([tell us](https://github.com/polius/wd-mycloud-docker/issues)) |

Intel models with **My Cloud OS 5** only. ARM models (EX2 Ultra, EX2100, EX4100, Mirror Gen 2) are not supported.

## Install

1. Download the `.bin` for your model from the [latest release](https://github.com/polius/wd-mycloud-docker/releases/latest).
2. In the NAS dashboard, go to **Apps > Install an app manually** and choose the file.

Docker starts right away. Use it over SSH (turn it on in **Settings > Network > SSH**, user `sshd`). Give every container `--restart unless-stopped`, or it won't come back after an update or a reboot.

> Already using the old community Docker app? Follow [Migrating](docs/migrating.md) instead, so your containers come along.

## Updating Docker

Install the newer `.bin` the same way: **Apps > Install an app manually**. Your containers stop, Docker is updated, and they start again. Nothing is deleted.

> [!TIP]
> Get notified of new versions: **Watch > Custom > Releases** on this page.

## Uninstall

In the dashboard, open the **Docker** app and choose **Uninstall**. Docker's own data (images, containers, Docker volumes, settings and logs) is kept in `/mnt/HD/HD_a2/Nas_Prog/docker_data` until you delete it. Folders you mounted into containers are never touched.

## More

[Troubleshooting](docs/troubleshooting.md) · [How it works](docs/how-it-works.md)

## Disclaimer

This is a community project. It is not affiliated with, endorsed by or supported by Docker, Inc. or Western Digital. Docker and the Docker logo are trademarks of Docker, Inc.; WD and My Cloud are trademarks of Western Digital. Use at your own risk: back up what matters before changing your NAS.

## License

[MIT](LICENSE)
