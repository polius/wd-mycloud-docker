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

The image has a file that carries an extended attribute, usually a capability such as `security.capability`, and the NAS's disk can't store it. Docker 20.10 (the old community app) dropped such attributes without telling you. Docker 29 stops the pull instead. Images built on the `jlesage/*` base, such as `jlesage/dupeguru`, do this.

To have Docker drop them again, add this line to `/mnt/HD/HD_a2/Nas_Prog/docker_data/daemon.json`, below `"storage-driver": "vfs",`:

```json
"storage-opts": ["vfs.xattrs=i_want_broken_containers"],
```

Then [restart Docker](#restart-docker) and pull again. Images pull and update as usual.

The cost: the attributes are dropped from every image, and the NAS can't store them anyway. Most containers don't need them. One that does, for example a program that runs as a normal user and opens a port below 1024, fails when it starts instead of when you pull it. `docker info` also shows a warning that this setup is unsupported.

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
