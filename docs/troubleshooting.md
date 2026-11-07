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
