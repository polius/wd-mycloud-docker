# Migrating from the community Docker app

If you run Docker through the older community app (WDCommunity, Docker 20.10), move your containers over in a few steps. Do this from your local network: if you reach the NAS remotely through a container (a Cloudflare tunnel, for example), that access goes down while Docker is switched.

1. **Save the commands that recreate your containers.** With the old Docker still running, on the NAS:

   ```bash
   mkdir -p /mnt/HD/HD_a2/docker-migration && cd /mnt/HD/HD_a2/docker-migration
   curl -fsSLO https://raw.githubusercontent.com/polius/wd-mycloud-docker/main/export-docker-run.sh
   bash export-docker-run.sh
   ```

   It only reads from Docker, and writes `docker-recreate-<date>.sh` (exact, **contains your containers' secrets**, readable only by root) and a `.redacted.sh` copy you can share. Review it: it notes anything that needs attention, such as data stored in Docker volumes or inside the old app's folder.

2. **Uninstall the old Docker app** in the dashboard. WD leaves its folder behind, and the new app installs into the same place, so remove it and restart the NAS:

   ```bash
   rm -rf /mnt/HD/HD_a2/Nas_Prog/docker
   reboot
   ```

3. **Install this app** ([Install](../README.md#install)).

4. **Recreate your containers:**

   ```bash
   sh /mnt/HD/HD_a2/docker-migration/docker-recreate-<date>.sh
   ```

   Images are pulled again by tag, so `:latest` images may be newer than the ones you had. Check that every container starts (`docker ps -a`); a much newer image may need a changed setting.

Your old Docker data stays untouched in `Nas_Prog/_docker/`. Delete it once everything runs (`rm -rf /mnt/HD/HD_a2/Nas_Prog/_docker`). Portainer, which the old app installed by itself, is left out of the export (`EXCLUDE="" bash export-docker-run.sh` includes it).
