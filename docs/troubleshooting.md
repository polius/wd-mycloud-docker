# Troubleshooting

All commands run on the NAS over SSH.

## A container did not come back after an update or a reboot

It has no restart policy. Start it and give it one:

```bash
docker start <name>
docker update --restart unless-stopped <name>
```

## `docker: command not found`

The `docker` command is linked in again at every boot. If it is missing, recreate the links:

```bash
bash /mnt/HD/HD_a2/Nas_Prog/docker/dockerctl.sh --links
```

## "another Docker daemon is running"

Another Docker, usually the old community app, is still running. Uninstall it in the dashboard and restart the NAS. Docker then starts by itself.

## A pull fails with "lsetxattr … operation not supported"

```
failed to register layer: lsetxattr /opt/base/sbin/nginx: xattr "security.capability": operation not supported
```

The image has a file that carries an extended attribute, usually a capability such as `security.capability` on `/usr/bin/ping`, and the NAS's disk can't store it. Docker 20.10 (the old community app) dropped such attributes without telling you. Docker 29 stops the pull instead. Images built on the `jlesage/*` base, such as `jlesage/dupeguru`, and `louislam/uptime-kuma` do this.

The app now tells Docker to drop them, the way 20.10 did. Install the latest `.bin` (**Apps > Install an app manually**) and pull again.

On an older build, add this line to `/mnt/HD/HD_a2/Nas_Prog/docker_data/daemon.json`, below `"storage-driver": "vfs",`, then [restart Docker](#restart-docker) and pull again:

```json
"storage-opts": ["vfs.xattrs=i_want_broken_containers"],
```

The cost: the attributes are dropped from every image, and the NAS can't store them anyway. Most containers don't need them: the usual reason, letting a normal user ping or open a port below 1024, is allowed in containers anyway (not with `--network host`). A program that needs another capability from its file fails when it starts instead of when you pull it. `docker info` also shows a warning that this setup is unsupported. To have pulls fail instead, put `DROP_XATTRS=0` in `/mnt/HD/HD_a2/Nas_Prog/docker_data/dockerctl.conf` and restart Docker.

## `setcap` fails with "Not supported"

```
Failed to set capabilities on file '/usr/bin/…': Not supported
```

The NAS's disk can't store file capabilities, so setting one fails: in an image whose startup script runs `setcap`, or in a `Dockerfile` with `RUN setcap …`. The step is often not needed here: if it is there so a normal user can ping or open a port below 1024, containers already allow both. Remove the step from your `Dockerfile`, or run the program as root (`--user 0`, if the image supports it).

## Restart Docker

```bash
bash /mnt/HD/HD_a2/Nas_Prog/docker/dockerctl.sh --restart
```

It keeps running even if your SSH connection drops.

## See what Docker is doing

```bash
bash /mnt/HD/HD_a2/Nas_Prog/docker/dockerctl.sh --status
tail -n 50 /mnt/HD/HD_a2/Nas_Prog/docker_data/logs/dockerd.log
tail -n 50 /mnt/HD/HD_a2/Nas_Prog/docker_data/logs/dockerctl.log
```

If the app fails to install or start, `cat /tmp/debug_apkg` shows what the NAS ran (it is cleared at reboot).
