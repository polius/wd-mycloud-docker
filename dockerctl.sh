#!/usr/bin/env bash
#
# dockerctl.sh: start and stop the official Docker engine on a WD My Cloud OS5 NAS.
#
# It ships inside the "docker" NAS app (built by make-app.sh), next to the engine:
#
#   <volume>/Nas_Prog/docker/            the app (replaced at every app upgrade)
#     dockerctl.sh                       this script
#     engine/                            official static binaries + docker compose plugin
#
# Your Docker data lives OUTSIDE the app folder, next to it, so installing, upgrading or
# uninstalling the app never touches it (same pattern as WD's own Plex app:
# Nas_Prog/plexmediaserver + Nas_Prog/plex_conf):
#
#   <volume>/Nas_Prog/docker_data/       e.g. /mnt/HD/HD_a2/Nas_Prog/docker_data
#     daemon.json                        dockerd settings (written once, then yours)
#     dockerctl.conf                     optional overrides of the settings below
#     data/                              Docker data root (images, containers, volumes)
#     logs/                              dockerd.log and dockerctl.log
#
# The NAS calls this script from the app's scripts: init.sh (--links) and start.sh
# (--start) at boot and after an install, stop.sh (--stop) at shutdown and before an
# upgrade, remove.sh (--stop, --unlink) when the app is uninstalled.
#
# Commands (run as root, e.g.  bash /mnt/HD/HD_a2/Nas_Prog/docker/dockerctl.sh --status):
#   --start | --stop | --restart | --status
#   --links | --unlink   create / remove the command links (/sbin/docker, ...)
#
# Commands that stop Docker re-launch themselves in the background when run over
# SSH, because remote SSH may go through a container (e.g. cloudflared).
#
# Updating Docker = installing the app .bin of the newer version in the NAS dashboard
# (Apps > Install an app manually). Containers stop and come back by their restart
# policies; images, containers and volumes stay in <volume>/Nas_Prog/docker_data/data.
#
# NAS notes: the firmware has no setsid, no /dev/fd (no  < <(...)  here), and /tmp is
# noexec. The root filesystem is in RAM, so the links in /sbin are made at every boot.

if [ -z "${BASH_VERSION:-}" ]; then
  echo "error: run this with bash:  bash $0 ..." >&2
  exit 1
fi

set -u -o pipefail

# ---------------------------------------------------------------- locations
# physical path (pwd -P), so /shares/Volume_1/... resolves to /mnt/HD/HD_a2/...
SELF="$(cd "$(dirname "$0")" && pwd -P)/$(basename "$0")"
APP_DIR=$(dirname "$SELF")
ENGINE_DIR=$APP_DIR/engine
case $APP_DIR in
  */Nas_Prog/*) VOLUME=${APP_DIR%%/Nas_Prog/*} ;;
  *) echo "error: $SELF must be inside the NAS app folder (<volume>/Nas_Prog/docker)" >&2; exit 1 ;;
esac
BASE=${APP_DIR%/*}/docker_data   # <volume>/Nas_Prog/docker_data, next to the app folder

# ---------------------------------------------------------------- settings
DATA_ROOT=$BASE/data
STOP_TIMEOUT=120         # seconds to wait for dockerd to stop all containers
START_TIMEOUT=90         # seconds to wait for dockerd to answer
BIN_DIR=/sbin            # where the docker commands are linked (in RAM, made at boot)
PLUGIN_DIR=/usr/local/lib/docker/cli-plugins
MODULE_DIR=/usr/local/modules/driver

[[ -f $BASE/dockerctl.conf ]] && . "$BASE/dockerctl.conf"

DAEMON_JSON=$BASE/daemon.json
LOG_DIR=$BASE/logs
DOCKERD_LOG=$LOG_DIR/dockerd.log
CTL_LOG=$LOG_DIR/dockerctl.log
PIDFILE=/var/run/docker.pid
SOCK=/var/run/docker.sock
LOCK=/var/run/dockerctl.lock

# Kernel modules needed by Docker networking, in load order (same list as the old
# community Docker app).
MODULES=(nf_conntrack nf_nat nf_defrag_ipv4 nf_conntrack_ipv4 nf_nat_ipv4 x_tables
         xt_conntrack xt_addrtype xt_tcpudp xt_nat nf_nat_masquerade_ipv4 ipt_MASQUERADE
         ip_tables iptable_filter iptable_nat llc stp bridge br_netfilter)

ORIG_ARGS=("$@")

# ---------------------------------------------------------------- helpers
ts()   { date '+%Y-%m-%d %H:%M:%S'; }
log() {
  local line; line="$(ts) $*"
  printf '%s\n' "$line" >&2
  # when detached, stderr already goes to the log file
  [[ -z ${DOCKERCTL_DETACHED:-} && -d $LOG_DIR ]] && printf '%s\n' "$line" >>"$CTL_LOG"
  return 0
}
die()  { log "ERROR: $*"; exit 1; }

# The NAS firmware has no setsid: use busybox's if there is one, otherwise the
# process group + SIGHUP-ignored fallback below.
SETSID=()
if command -v setsid >/dev/null 2>&1; then SETSID=(setsid)
elif busybox setsid true >/dev/null 2>&1; then SETSID=(busybox setsid)
fi
dk()   { "$ENGINE_DIR/docker" -H "unix://$SOCK" "$@"; }

require_root()   { [[ $(id -u) == 0 ]] || die "must run as root"; }
volume_mounted() { grep -q " $VOLUME " /proc/mounts; }

wait_for_volume() {
  local i
  for (( i = 0; i < 120; i++ )); do
    volume_mounted && return 0
    sleep 1
  done
  die "$VOLUME is not mounted"
}

take_lock() {
  if ! mkdir "$LOCK" 2>/dev/null; then
    local p; p=$(cat "$LOCK/pid" 2>/dev/null)
    if [[ -n $p ]] && kill -0 "$p" 2>/dev/null; then
      die "another dockerctl.sh is running (pid $p)"
    fi
    rm -rf "$LOCK"
    mkdir "$LOCK" || die "cannot create $LOCK"
  fi
  echo $$ >"$LOCK/pid"
  trap 'rm -rf "$LOCK"' EXIT
}

# Re-launch in the background when run over SSH, so stopping Docker (and with it a
# cloudflared tunnel) can't kill this script halfway.
detach_if_remote() {
  [[ -n ${DOCKERCTL_DETACHED:-} ]] && return 0
  [[ -z ${SSH_CONNECTION:-}${SSH_CLIENT:-} ]] && return 0
  mkdir -p "$LOG_DIR"
  echo "Running in the background so it survives the SSH connection dropping"
  echo "(remote SSH may go through a container, which will stop)."
  echo "Follow progress with:  tail -f $CTL_LOG"
  # own process group (set -m) + SIGHUP ignored (nohup): survives the SSH session ending
  set -m
  DOCKERCTL_DETACHED=1 nohup "${SETSID[@]}" bash "$SELF" "${ORIG_ARGS[@]}" </dev/null >>"$CTL_LOG" 2>&1 &
  disown 2>/dev/null
  exit 0
}

rotate() {  # rotate <file>: keep one old copy when over 20 MB
  [[ -f $1 ]] || return 0
  local size; size=$(wc -c <"$1")
  (( size > 20 * 1024 * 1024 )) && mv -f "$1" "$1.1"
  return 0
}

app_version()    { "$ENGINE_DIR/dockerd" --version 2>/dev/null | sed -n 's/^Docker version \([^,]*\),.*/\1/p'; }
daemon_version() { dk version --format '{{.Server.Version}}' 2>/dev/null; }
daemon_answers() { daemon_version >/dev/null; }

# dockerd processes are told apart by their binary path. After an app upgrade that
# replaced the files under a running dockerd, its path ends in " (deleted)": still ours.
our_pid() {
  local p exe
  for p in $(pidof dockerd 2>/dev/null); do
    exe=$(readlink "/proc/$p/exe" 2>/dev/null)
    [[ $exe == "$ENGINE_DIR"/* ]] && { echo "$p"; return 0; }
  done
  return 1
}
foreign_dockerd() {
  local p exe
  for p in $(pidof dockerd 2>/dev/null); do
    exe=$(readlink "/proc/$p/exe" 2>/dev/null)
    [[ $exe == "$ENGINE_DIR"/* ]] || { echo "pid $p ($exe)"; return 0; }
  done
  return 1
}
check_no_foreign() {
  local f
  if f=$(foreign_dockerd); then
    die "another Docker daemon is running: $f. Stop or uninstall the other Docker first."
  fi
}

write_daemon_json() {
  [[ -f $DAEMON_JSON ]] && return 0
  mkdir -p "$BASE"
  cat >"$DAEMON_JSON" <<EOF
{
  "data-root": "$DATA_ROOT",
  "storage-driver": "vfs",
  "features": { "containerd-snapshotter": false },
  "ip6tables": false,
  "shutdown-timeout": 30,
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
EOF
  log "wrote $DAEMON_JSON"
}

# ---------------------------------------------------------------- host preparation
# The kernel (4.14) has no overlayfs, no iptable_raw and no ip6table_nat: vfs storage,
# "ip6tables": false and DOCKER_INSECURE_NO_IPTABLES_RAW=1 cover that.

mount_cgroups() {
  local cg=/sys/fs/cgroup sys _h _n enabled fstype children
  fstype=$(awk -v m="$cg" '$2 == m { t = $3 } END { print t }' /proc/mounts)
  # At boot the WD firmware mounts ONE combined cgroup hierarchy (cpu,memory) directly
  # on /sys/fs/cgroup. Docker needs the usual layout: a tmpfs there, with one mount per
  # controller. Like the old Docker app (and WD's own /usr/sbin/cgroupfs-mount), unmount
  # it first. Only if it holds nothing but its root cgroup (checked on a PR2100: no
  # child cgroups, no limits), so nothing on the NAS loses its cgroup.
  if [[ $fstype == cgroup ]]; then
    children=$(find "$cg" -mindepth 1 -maxdepth 1 -type d | wc -l)
    (( children == 0 )) \
      || die "$cg is a cgroup hierarchy with $children child cgroup(s) in use: not unmounting it"
    umount "$cg" || die "cannot unmount the firmware cgroup hierarchy on $cg"
    log "unmounted the firmware's combined cgroup hierarchy from $cg"
    fstype=""
  fi
  if [[ -z $fstype ]]; then
    mount -t tmpfs -o uid=0,gid=0,mode=0755 cgroup "$cg" || die "cannot mount tmpfs on $cg"
  fi
  while read -r sys _h _n enabled; do
    [[ $sys == \#* || $enabled != 1 ]] && continue
    # already mounted somewhere (alone or combined, e.g. cpu,cpuacct)?
    awk -v s="$sys" '$3 == "cgroup" { n = split($4, o, ","); for (i = 1; i <= n; i++) if (o[i] == s) f = 1 } END { exit !f }' /proc/mounts \
      && continue
    mkdir -p "$cg/$sys"
    mount -t cgroup -o "$sys" cgroup "$cg/$sys" || log "warning: cannot mount cgroup $sys"
  done </proc/cgroups
}

load_modules() {
  local m
  if [[ ! -d /proc/sys/net/ipv6 ]]; then
    insmod "$MODULE_DIR/ipv6.ko" disable_ipv6=1 2>/dev/null || log "warning: cannot load ipv6"
  fi
  for m in "${MODULES[@]}"; do
    grep -q "^$m " /proc/modules && continue
    if [[ ! -f $MODULE_DIR/$m.ko ]]; then
      log "warning: module $m.ko not found in $MODULE_DIR"
      continue
    fi
    insmod "$MODULE_DIR/$m.ko" 2>/dev/null || log "warning: cannot load module $m"
  done
}

do_links() {
  local f n d
  [[ -x $ENGINE_DIR/dockerd ]] || die "no engine in $ENGINE_DIR"
  # remove links left over from another engine location (an older setup or another app)
  for f in "$BIN_DIR"/docker* "$BIN_DIR"/containerd* "$BIN_DIR"/ctr "$BIN_DIR"/runc; do
    [[ -L $f ]] || continue
    [[ -e $f && $(readlink "$f") == "$ENGINE_DIR"/* ]] && continue
    rm -f "$f"
  done
  for f in "$ENGINE_DIR"/*; do
    n=${f##*/}
    [[ $n == docker-compose* ]] && continue
    ln -sfn "$ENGINE_DIR/$n" "$BIN_DIR/$n"
  done
  # a firmware copy of docker earlier on PATH would shadow ours (RAM only, back at reboot)
  for d in /usr/sbin /usr/bin /bin; do
    [[ $d == "$BIN_DIR" ]] && continue
    if [[ -f $d/docker && ! -L $d/docker ]]; then
      mv -f "$d/docker" "$d/docker.wd-orig" && log "moved firmware $d/docker aside to $d/docker.wd-orig"
    fi
  done
  mkdir -p "$PLUGIN_DIR"
  [[ -x $ENGINE_DIR/docker-compose ]] && ln -sfn "$ENGINE_DIR/docker-compose" "$PLUGIN_DIR/docker-compose"
  # iptables extensions: older OS5 firmware needed /usr/lib/xtables -> usrlib/xtables (the old
  # app did this). 5.33 ships them in /usr/lib/x86_64-linux-gnu/xtables and iptables finds
  # them itself, so only link when that old target exists (never a dangling link).
  if [[ ! -e /usr/lib/xtables && ! -L /usr/lib/xtables && -d /usr/local/modules/usrlib/xtables ]]; then
    ln -s /usr/local/modules/usrlib/xtables /usr/lib/xtables
  fi
  local resolved; resolved=$(command -v docker)
  [[ $resolved == "$BIN_DIR/docker" ]] || log "warning: 'docker' resolves to '$resolved', not $BIN_DIR/docker"
  return 0
}

do_unlink() {
  local f d
  for f in "$BIN_DIR"/* "$PLUGIN_DIR"/docker-compose; do
    [[ -L $f && $(readlink "$f") == "$ENGINE_DIR"/* ]] && rm -f "$f"
  done
  for d in /usr/sbin /usr/bin /bin; do
    [[ -f $d/docker.wd-orig && ! -e $d/docker ]] && mv -f "$d/docker.wd-orig" "$d/docker"
  done
  return 0
}

prepare_host() {
  wait_for_volume
  load_modules
  mount_cgroups
  if ! grep -q ' /dev/pts ' /proc/mounts; then
    mkdir -p /dev/pts
    mount -t devpts -o gid=5,mode=620 devpts /dev/pts || log "warning: cannot mount /dev/pts"
  fi
  do_links
}

# ---------------------------------------------------------------- start / stop
do_start() {
  local pid i running want
  [[ -x $ENGINE_DIR/dockerd ]] || die "no engine in $ENGINE_DIR"
  check_no_foreign
  if pid=$(our_pid); then
    # Normally an upgrade stops Docker first (install.sh runs the old stop.sh). If the
    # running dockerd is still the old version anyway, restart it on the new engine.
    running=$(daemon_version); want=$(app_version)
    if [[ -n $running && -n $want && $running != "$want" ]]; then
      log "dockerd $running is running, but this app is $want: restarting it on $want"
      do_stop
    else
      log "dockerd ${running:-?} already running (pid $pid)"
      do_links
      return 0
    fi
  fi
  prepare_host
  write_daemon_json
  mkdir -p "$LOG_DIR" "$DATA_ROOT"
  rotate "$DOCKERD_LOG"
  rm -f "$PIDFILE"

  local -a envs=("PATH=$ENGINE_DIR:$PATH" "DOCKER_RAMDISK=1")  # rootfs is in RAM: no pivot_root
  if ! iptables -t raw -L -n >/dev/null 2>&1; then
    envs+=("DOCKER_INSECURE_NO_IPTABLES_RAW=1")                # kernel has no iptable_raw
  fi
  ulimit -n 1048576 2>/dev/null || ulimit -n 65536 2>/dev/null

  log "starting dockerd $(app_version) (data: $DATA_ROOT)"
  (
    # own session if possible; otherwise its own process group and SIGHUP ignored
    [[ ${#SETSID[@]} -eq 0 ]] && trap '' HUP
    exec "${SETSID[@]}" env "${envs[@]}" "$ENGINE_DIR/dockerd" \
      --config-file "$DAEMON_JSON" --pidfile "$PIDFILE" -H "unix://$SOCK"
  ) </dev/null >>"$DOCKERD_LOG" 2>&1 &

  for (( i = 0; i < START_TIMEOUT; i++ )); do
    if daemon_answers; then
      log "dockerd $(daemon_version) is up"
      return 0
    fi
    if (( i > 5 )) && ! our_pid >/dev/null; then
      break
    fi
    sleep 1
  done
  log "dockerd did not come up. Last lines of $DOCKERD_LOG:"
  tail -n 20 "$DOCKERD_LOG" >&2
  return 1
}

# Stopping dockerd itself (SIGTERM) stops every container gracefully WITHOUT
# marking them as stopped by the user, so restart policies bring them back.
do_stop() {
  local pid i p exe
  if ! pid=$(our_pid); then
    log "dockerd is not running"
    return 0
  fi
  log "stopping dockerd (pid $pid) and its containers"
  kill -TERM "$pid"
  for (( i = 0; i < STOP_TIMEOUT; i++ )); do
    [[ -d /proc/$pid ]] || break
    sleep 1
  done
  if [[ -d /proc/$pid ]]; then
    log "warning: dockerd still running after ${STOP_TIMEOUT}s, killing it"
    kill -KILL "$pid"
    sleep 2
  fi
  # leftover containerd / shims from our engine (only after an unclean stop)
  for p in $(pidof containerd containerd-shim containerd-shim-runc-v2 2>/dev/null); do
    exe=$(readlink "/proc/$p/exe" 2>/dev/null)
    [[ $exe == "$ENGINE_DIR"/* ]] && { log "stopping leftover $exe (pid $p)"; kill -TERM "$p"; }
  done
  rm -f "$PIDFILE"
  log "dockerd stopped"
}

cmd_status() {
  local pid f
  echo "app engine:        $(app_version || echo none)   ($ENGINE_DIR)"
  echo "data:              $DATA_ROOT"
  if pid=$(our_pid); then
    echo "dockerd:           running (pid $pid)"
    if daemon_answers; then
      echo "server version:    $(daemon_version)"
      echo "containers:        $(dk ps -q | wc -l) running / $(dk ps -aq | wc -l) total"
      echo "storage driver:    $(dk info --format '{{.Driver}}')"
    fi
  else
    echo "dockerd:           not running"
  fi
  f=$(foreign_dockerd) && echo "WARNING:           another dockerd is running: $f"
  [[ -x $ENGINE_DIR/docker-compose ]] && echo "compose plugin:    $("$ENGINE_DIR/docker-compose" version --short 2>/dev/null)"
  echo "docker on PATH:    $(command -v docker || echo none)"
}

# ---------------------------------------------------------------- main
usage() {
  sed -n '2,/^$/p' "$SELF" | sed 's/^# \{0,1\}//'
  exit 1
}

case ${1:-} in
  --start)     require_root; wait_for_volume; mkdir -p "$LOG_DIR"; take_lock; do_start ;;
  --stop)      require_root; detach_if_remote; take_lock; do_stop ;;
  --restart)   require_root; detach_if_remote; take_lock; do_stop; do_start ;;
  --status)    cmd_status ;;
  --links)     require_root; wait_for_volume; do_links ;;
  --unlink)    require_root; do_unlink ;;
  *)           usage ;;
esac
