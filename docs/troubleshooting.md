# Troubleshooting

<details>
<summary>Check what Docker is doing</summary>

```bash
bash /mnt/HD/HD_a2/Nas_Prog/docker/dockerctl.sh --status
tail -n 50 /mnt/HD/HD_a2/Nas_Prog/docker_data/logs/dockerd.log
tail -n 50 /mnt/HD/HD_a2/Nas_Prog/docker_data/logs/dockerctl.log
cat /tmp/debug_apkg      # what the NAS ran when installing or starting apps (cleared at reboot)
```

</details>

<details>
<summary>"another Docker daemon is running"</summary>

A different Docker (usually the old community app) is still running. Uninstall it in the dashboard, restart the NAS, and the app starts Docker by itself.

</details>

<details>
<summary>A container did not come back after an update or a reboot</summary>

It has no restart policy. Start it and give it one:

```bash
docker start <name>
docker update --restart unless-stopped <name>
```

</details>

<details>
<summary><code>docker: command not found</code> over SSH</summary>

The `docker` command links are created at every boot. If they are missing, recreate them:

```bash
bash /mnt/HD/HD_a2/Nas_Prog/docker/dockerctl.sh --links
```

</details>

<details>
<summary>Restart Docker</summary>

```bash
bash /mnt/HD/HD_a2/Nas_Prog/docker/dockerctl.sh --restart
```

Over SSH it runs in the background, so it finishes even if your connection drops; follow it with `tail -f /mnt/HD/HD_a2/Nas_Prog/docker_data/logs/dockerctl.log`.

</details>
