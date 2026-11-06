#!/usr/bin/env bash
#
# export-docker-run.sh
#
# Read-only export of every container on this Docker host as the
# `docker run` commands needed to recreate it on a new Docker engine.
#
# Docker commands it runs (all read-only):
#   docker version, docker container ls, docker container inspect,
#   docker image inspect, docker image ls, docker network inspect
# It never starts, stops, pulls, removes or changes anything.
#
# The only thing it writes is two files in the same folder as this script:
#   docker-recreate-<date>.sh            exact commands (contains secrets, mode 600)
#   docker-recreate-<date>.redacted.sh   same commands, secret-looking values masked
#
# Only container settings that differ from the image defaults are exported,
# so a newer image version can bring its own defaults (PATH, CMD, ...).
#
# Usage:  bash export-docker-run.sh            (as root, with the old Docker running)
#         EXCLUDE="" bash export-docker-run.sh  (also export portainer)
#
# Part of https://github.com/polius/wd-mycloud-docker (migrating from another Docker).

if [ -z "${BASH_VERSION:-}" ]; then
  echo "error: run this with bash:  bash $0" >&2
  exit 1
fi

set -u -o pipefail
umask 077
# The NAS has no /dev/fd, so bash process substitution  < <(...)  fails there.
# Use pipes instead; lastpipe runs the last command of a pipe in this shell,
# so mapfile / while-read loops still fill variables here.
shopt -s lastpipe

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
STAMP=$(date +%Y%m%d-%H%M%S)
OUT="$SCRIPT_DIR/docker-recreate-$STAMP.sh"
RED="$SCRIPT_DIR/docker-recreate-$STAMP.redacted.sh"

S=$'\x1f'                                  # field separator inside templates
OLD_APP_DIR=/mnt/HD/HD_a2/Nas_Prog/docker  # old community Docker app folder
REDACTED='***REDACTED***'
# Containers not exported. Default: portainer (the community Docker app created it
# itself, with its data inside that app's folder). EXCLUDE="" exports everything.
read -r -a EXCLUDE <<<"${EXCLUDE-portainer}"
SECRET_RE='(TOKEN|PASS|PWD|SECRET|KEY|PRIVATE|CRED|AUTH)'

# ---------------------------------------------------------------- checks
if ! command -v docker >/dev/null 2>&1; then
  echo "error: docker command not found" >&2
  exit 1
fi
if ! SERVER_VERSION=$(docker version --format '{{.Server.Version}}' 2>/dev/null); then
  echo "error: cannot talk to the Docker daemon" >&2
  exit 1
fi

# ---------------------------------------------------------------- helpers

# Shell-quote a value only when needed (keeps accents readable).
q() {
  local s=$1 r="'\\''"
  if [[ $s =~ ^[A-Za-z0-9_./:=@%+,-]+$ ]]; then
    printf '%s' "$s"
  else
    printf "'%s'" "${s//\'/$r}"
  fi
}

looks_secret_name()  { local u=${1^^}; [[ $u =~ $SECRET_RE ]]; }
looks_secret_value() { [[ ${#1} -ge 32 && $1 =~ ^[A-Za-z0-9+=_.-][A-Za-z0-9+/=_.-]+$ ]]; }

in_list() { local x=$1 y; shift; for y in "$@"; do [[ $x == "$y" ]] && return 0; done; return 1; }

# get_list <array-name> <container|image|network> <id> <template>
# Fills the array with one element per output line (template uses println).
get_list() {
  local -n _gl_arr=$1
  docker "$2" inspect --format "$4" "$3" | mapfile -t _gl_arr
  # docker appends a final newline: drop the resulting empty last element
  if (( ${#_gl_arr[@]} )) && [[ -z ${_gl_arr[-1]} ]]; then
    _gl_arr=("${_gl_arr[@]:0:${#_gl_arr[@]}-1}")
  fi
}

# readkv <assoc-name> <container|image> <id> <template of "key<TAB>value" lines>
readkv() {
  local -n _kv_map=$1
  local k v
  _kv_map=()
  docker "$2" inspect --format "$4" "$3" | while IFS=$'\t' read -r k v; do
    [[ -n $k ]] && _kv_map[$k]=$v
  done
}

# Build a "key<TAB>{{template}}" per line template.
kv_template() {
  local out=""
  while (( $# )); do out+="$1"$'\t'"$2"$'\n'; shift 2; done
  printf '%s' "$out"
}

# Per-container option lines: exact and redacted versions.
add()  { EX+=("$1"); RD+=("${2-$1}"); }
note() { NX+=("$1"); NR+=("${2-$1}"); }
# Append a line to the output body (exact, redacted).
b()    { BODY_EX+="$1"$'\n'; BODY_RD+="${2-$1}"$'\n'; }

# ---------------------------------------------------------------- templates
C_TPL=$(kv_template \
  name       '{{.Name}}' \
  id         '{{.ID}}' \
  image      '{{.Config.Image}}' \
  imageid    '{{.Image}}' \
  state      '{{.State.Status}}' \
  restart    '{{.HostConfig.RestartPolicy.Name}}' \
  restartmax '{{.HostConfig.RestartPolicy.MaximumRetryCount}}' \
  netmode    '{{.HostConfig.NetworkMode}}' \
  hostname   '{{.Config.Hostname}}' \
  domainname '{{.Config.Domainname}}' \
  user       '{{.Config.User}}' \
  workdir    '{{.Config.WorkingDir}}' \
  stopsignal '{{.Config.StopSignal}}' \
  tty        '{{.Config.Tty}}' \
  stdin      '{{.Config.OpenStdin}}' \
  privileged '{{.HostConfig.Privileged}}' \
  readonly   '{{.HostConfig.ReadonlyRootfs}}' \
  init       '{{.HostConfig.Init}}' \
  publishall '{{.HostConfig.PublishAllPorts}}' \
  memory     '{{.HostConfig.Memory}}' \
  memswap    '{{.HostConfig.MemorySwap}}' \
  memres     '{{.HostConfig.MemoryReservation}}' \
  nanocpus   '{{.HostConfig.NanoCPUs}}' \
  cpushares  '{{.HostConfig.CPUShares}}' \
  cpuset     '{{.HostConfig.CpusetCpus}}' \
  pids       '{{.HostConfig.PidsLimit}}' \
  shm        '{{.HostConfig.ShmSize}}' \
  ipc        '{{.HostConfig.IpcMode}}' \
  pid        '{{.HostConfig.PidMode}}' \
  uts        '{{.HostConfig.UTSMode}}' \
  runtime    '{{.HostConfig.Runtime}}' \
  cgparent   '{{.HostConfig.CgroupParent}}' \
  logtype    '{{.HostConfig.LogConfig.Type}}' \
  cmd        '{{json .Config.Cmd}}' \
  entrypoint '{{json .Config.Entrypoint}}' \
  health     '{{json .Config.Healthcheck}}')

I_TPL=$(kv_template \
  user       '{{.Config.User}}' \
  workdir    '{{.Config.WorkingDir}}' \
  stopsignal '{{.Config.StopSignal}}' \
  cmd        '{{json .Config.Cmd}}' \
  entrypoint '{{json .Config.Entrypoint}}' \
  health     '{{json .Config.Healthcheck}}')

T_ENV='{{range .Config.Env}}{{println .}}{{end}}'
T_CMD='{{range .Config.Cmd}}{{println .}}{{end}}'
T_ENTRY='{{range .Config.Entrypoint}}{{println .}}{{end}}'
T_IMG_VOLS='{{range $k, $v := .Config.Volumes}}{{println $k}}{{end}}'
T_LABELS='{{range $k, $v := .Config.Labels}}{{$k}}={{$v}}{{println}}{{end}}'
T_NETS='{{range $n, $c := .NetworkSettings.Networks}}{{$n}}'"$S"'{{if $c.IPAMConfig}}{{$c.IPAMConfig.IPv4Address}}{{end}}'"$S"'{{join $c.Aliases ","}}{{println}}{{end}}'
T_PORTS='{{range $p, $b := .HostConfig.PortBindings}}{{range $b}}{{$p}}'"$S"'{{.HostIP}}'"$S"'{{.HostPort}}{{println}}{{end}}{{end}}'
T_MOUNTS='{{range .Mounts}}{{.Type}}'"$S"'{{.Name}}'"$S"'{{.Source}}'"$S"'{{.Destination}}'"$S"'{{.RW}}'"$S"'{{.Mode}}{{println}}{{end}}'
T_DEVICES='{{range .HostConfig.Devices}}{{.PathOnHost}}'"$S"'{{.PathInContainer}}'"$S"'{{.CgroupPermissions}}{{println}}{{end}}'
T_CAPADD='{{range .HostConfig.CapAdd}}{{println .}}{{end}}'
T_CAPDROP='{{range .HostConfig.CapDrop}}{{println .}}{{end}}'
T_SECOPT='{{range .HostConfig.SecurityOpt}}{{println .}}{{end}}'
T_HOSTS='{{range .HostConfig.ExtraHosts}}{{println .}}{{end}}'
T_DNS='{{range .HostConfig.DNS}}{{println .}}{{end}}'
T_GROUPS='{{range .HostConfig.GroupAdd}}{{println .}}{{end}}'
T_TMPFS='{{range $k, $v := .HostConfig.Tmpfs}}{{$k}}'"$S"'{{$v}}{{println}}{{end}}'
T_SYSCTL='{{range $k, $v := .HostConfig.Sysctls}}{{$k}}={{$v}}{{println}}{{end}}'
T_ULIMITS='{{range .HostConfig.Ulimits}}{{.Name}}={{.Soft}}:{{.Hard}}{{println}}{{end}}'
T_LOGOPTS='{{range $k, $v := .HostConfig.LogConfig.Config}}{{$k}}={{$v}}{{println}}{{end}}'

# ---------------------------------------------------------------- state
declare -A USED_NETS=()
declare -A USED_IMAGES=()
BODY_EX=""
BODY_RD=""
WARN_COUNT=0

# ---------------------------------------------------------------- one container
export_one() {
  local cid=$1
  local -A C=() I=()
  local -a img_env=() img_vols=() img_labels=()
  local -a envs=() labels=() cmd_args=() ent=() list=() connect=()
  local name iid nm primary line i x

  EX=(); RD=(); NX=(); NR=()

  readkv C container "$cid" "$C_TPL"
  name=${C[name]#/}
  iid=${C[imageid]}
  USED_IMAGES[$iid]=1
  readkv I image "$iid" "$I_TPL"
  get_list img_env    image "$iid" "$T_ENV"
  get_list img_vols   image "$iid" "$T_IMG_VOLS"
  get_list img_labels image "$iid" "$T_LABELS"

  # restart policy
  case ${C[restart]} in
    ''|no) ;;
    on-failure)
      if [[ ${C[restartmax]} =~ ^[0-9]+$ ]] && (( C[restartmax] > 0 )); then
        add "--restart on-failure:${C[restartmax]}"
      else
        add "--restart on-failure"
      fi ;;
    *) add "--restart ${C[restart]}" ;;
  esac

  # network mode
  nm=${C[netmode]}
  case $nm in
    default|bridge|'') primary=bridge ;;
    host|none) add "--network $nm"; primary=$nm ;;
    container:*)
      add "--network $(q "$nm")"; primary=$nm
      note "uses another container's network ($nm): that container must be created first, and its id will change" ;;
    *) add "--network $(q "$nm")"; primary=$nm; USED_NETS[$nm]=1 ;;
  esac

  # networks attached (static IPs, aliases, extra networks)
  local net ip aliases a
  local -a arr al
  get_list list container "$cid" "$T_NETS"
  for line in "${list[@]}"; do
    IFS=$S read -r net ip aliases <<<"$line"
    [[ -z $net || $net == bridge || $net == host || $net == none ]] && continue
    USED_NETS[$net]=1
    al=()
    IFS=, read -ra arr <<<"$aliases"
    for a in "${arr[@]}"; do
      [[ -n $a && $a != "$name" && $a != "${C[id]:0:12}" ]] && al+=("$a")
    done
    if [[ $net == "$primary" ]]; then
      [[ -n $ip ]] && add "--ip $ip"
      for a in "${al[@]}"; do add "--network-alias $(q "$a")"; done
    else
      x="docker network connect"
      [[ -n $ip ]] && x+=" --ip $ip"
      for a in "${al[@]}"; do x+=" --alias $(q "$a")"; done
      connect+=("$x $(q "$net") $(q "$name")")
    fi
  done

  # hostname (skip the default = short container id, and host networking)
  if [[ $nm != host && $nm != container:* && -n ${C[hostname]} && ${C[hostname]} != "${C[id]:0:12}" ]]; then
    add "--hostname $(q "${C[hostname]}")"
  fi
  [[ -n ${C[domainname]} ]] && add "--domainname $(q "${C[domainname]}")"

  # published ports (ignored by Docker with host networking)
  local p hip hport cport spec
  if [[ $nm != host ]]; then
    get_list list container "$cid" "$T_PORTS"
    for line in "${list[@]}"; do
      IFS=$S read -r p hip hport <<<"$line"
      [[ -z $p ]] && continue
      cport=${p%/tcp}
      if [[ -n $hip && $hip != 0.0.0.0 && $hip != :: ]]; then
        spec="$hip:$hport:$cport"
      elif [[ -n $hport ]]; then
        spec="$hport:$cport"
      else
        spec="$cport"
      fi
      add "-p $spec"
    done
    [[ ${C[publishall]} == true ]] && add "-P"
  fi

  # mounts
  local type vname src dst rw mode o optstr
  local -a opts
  get_list list container "$cid" "$T_MOUNTS"
  for line in "${list[@]}"; do
    IFS=$S read -r type vname src dst rw mode <<<"$line"
    [[ -z $type ]] && continue
    opts=()
    [[ $rw == false ]] && opts+=(ro)
    for o in ${mode//,/ }; do [[ $o == z || $o == Z ]] && opts+=("$o"); done
    optstr=""
    (( ${#opts[@]} )) && optstr=":$(IFS=,; printf '%s' "${opts[*]}")"
    case $type in
      bind)
        add "-v $(q "$src:$dst$optstr")"
        if [[ $src == "$OLD_APP_DIR" || $src == "$OLD_APP_DIR"/* ]]; then
          note "bind mount $src is INSIDE the old Docker app folder: uninstalling the app may delete it. Copy it out first."
          (( WARN_COUNT++ ))
        fi
        if [[ ! -e $src ]]; then
          note "bind mount source $src does not exist on the host right now"
        fi ;;
      volume)
        if [[ $vname =~ ^[0-9a-f]{64}$ ]]; then
          if in_list "$dst" "${img_vols[@]}"; then
            note "anonymous volume at $dst (declared by the image, recreated automatically) will start EMPTY. Old data: $src"
          else
            add "-v $(q "$dst")"
            note "anonymous volume at $dst will start EMPTY. Old data: $src"
          fi
        else
          add "-v $(q "$vname:$dst$optstr")"
          note "named volume '$vname' lives inside Docker's storage: the new engine starts it EMPTY. Old data: $src"
        fi
        (( WARN_COUNT++ )) ;;
      tmpfs) ;;  # covered by HostConfig.Tmpfs below
      *)
        note "mount type '$type' at $dst is not exported, add it by hand"
        (( WARN_COUNT++ )) ;;
    esac
  done
  get_list list container "$cid" "$T_TMPFS"
  for line in "${list[@]}"; do
    IFS=$S read -r dst o <<<"$line"
    if [[ -n $o ]]; then add "--tmpfs $(q "$dst:$o")"; else add "--tmpfs $(q "$dst")"; fi
  done

  # devices
  local dh dc dp
  get_list list container "$cid" "$T_DEVICES"
  for line in "${list[@]}"; do
    IFS=$S read -r dh dc dp <<<"$line"
    if [[ -z $dp || $dp == rwm ]]; then add "--device $(q "$dh:$dc")"; else add "--device $(q "$dh:$dc:$dp")"; fi
  done

  # environment (only what differs from the image)
  local k v
  get_list envs container "$cid" "$T_ENV"
  for x in "${envs[@]}"; do
    in_list "$x" "${img_env[@]}" && continue
    k=${x%%=*}; v=${x#*=}
    if looks_secret_name "$k" || looks_secret_value "$v"; then
      add "-e $(q "$x")" "-e $(q "$k=$REDACTED")"
    else
      add "-e $(q "$x")"
    fi
  done

  # labels (only what differs from the image)
  get_list labels container "$cid" "$T_LABELS"
  for x in "${labels[@]}"; do
    in_list "$x" "${img_labels[@]}" && continue
    add "--label $(q "$x")"
  done

  # user, workdir, stop signal (only if different from the image)
  [[ ${C[user]} != "${I[user]}" ]] && add "--user $(q "${C[user]}")"
  [[ ${C[workdir]} != "${I[workdir]}" ]] && add "--workdir $(q "${C[workdir]}")"
  [[ -n ${C[stopsignal]} && ${C[stopsignal]} != "${I[stopsignal]}" ]] && add "--stop-signal ${C[stopsignal]}"

  # security / privileges
  [[ ${C[privileged]} == true ]] && add "--privileged"
  get_list list container "$cid" "$T_CAPADD";  for x in "${list[@]}"; do add "--cap-add $x"; done
  get_list list container "$cid" "$T_CAPDROP"; for x in "${list[@]}"; do add "--cap-drop $x"; done
  get_list list container "$cid" "$T_SECOPT";  for x in "${list[@]}"; do add "--security-opt $(q "$x")"; done
  get_list list container "$cid" "$T_GROUPS";  for x in "${list[@]}"; do add "--group-add $(q "$x")"; done
  [[ ${C[readonly]} == true ]] && add "--read-only"
  [[ ${C[init]} == true ]] && add "--init"

  # resources
  [[ ${C[memory]} =~ ^[0-9]+$ ]] && (( C[memory] > 0 )) && add "--memory ${C[memory]}"
  [[ ${C[memswap]} =~ ^-?[0-9]+$ ]] && [[ ${C[memswap]} != 0 ]] && add "--memory-swap ${C[memswap]}"
  [[ ${C[memres]} =~ ^[0-9]+$ ]] && (( C[memres] > 0 )) && add "--memory-reservation ${C[memres]}"
  if [[ ${C[nanocpus]} =~ ^[0-9]+$ ]] && (( C[nanocpus] > 0 )); then
    add "--cpus $(awk -v n="${C[nanocpus]}" 'BEGIN { printf "%g", n / 1e9 }')"
  fi
  [[ ${C[cpushares]} =~ ^[0-9]+$ ]] && (( C[cpushares] > 0 )) && add "--cpu-shares ${C[cpushares]}"
  [[ -n ${C[cpuset]} ]] && add "--cpuset-cpus ${C[cpuset]}"
  [[ ${C[pids]} =~ ^[0-9]+$ ]] && (( C[pids] > 0 )) && add "--pids-limit ${C[pids]}"
  [[ ${C[shm]} =~ ^[0-9]+$ ]] && (( C[shm] > 0 && C[shm] != 67108864 )) && add "--shm-size ${C[shm]}"
  get_list list container "$cid" "$T_ULIMITS"; for x in "${list[@]}"; do add "--ulimit $x"; done
  get_list list container "$cid" "$T_SYSCTL";  for x in "${list[@]}"; do add "--sysctl $(q "$x")"; done

  # namespaces / runtime
  case ${C[ipc]} in ''|private|shareable) ;; *) add "--ipc $(q "${C[ipc]}")" ;; esac
  [[ -n ${C[pid]} ]] && add "--pid $(q "${C[pid]}")"
  [[ -n ${C[uts]} ]] && add "--uts $(q "${C[uts]}")"
  [[ -n ${C[runtime]} && ${C[runtime]} != runc ]] && add "--runtime ${C[runtime]}"
  [[ -n ${C[cgparent]} ]] && add "--cgroup-parent $(q "${C[cgparent]}")"

  # name resolution
  get_list list container "$cid" "$T_HOSTS"; for x in "${list[@]}"; do add "--add-host $(q "$x")"; done
  get_list list container "$cid" "$T_DNS";   for x in "${list[@]}"; do add "--dns $x"; done

  # logging
  get_list list container "$cid" "$T_LOGOPTS"
  if [[ ${C[logtype]} != json-file ]] || (( ${#list[@]} )); then
    add "--log-driver ${C[logtype]}"
    for x in "${list[@]}"; do add "--log-opt $(q "$x")"; done
  fi

  # terminal
  [[ ${C[tty]} == true ]] && add "-t"
  [[ ${C[stdin]} == true ]] && add "-i"

  # healthcheck override: reported, not translated
  if [[ ${C[health]} != "${I[health]}" && ${C[health]} != null ]]; then
    note "healthcheck differs from the image, add --health-* flags by hand: ${C[health]}" \
         "healthcheck differs from the image, add --health-* flags by hand (see exact file)"
    (( WARN_COUNT++ ))
  fi

  # entrypoint / command (only if different from the image)
  if [[ ${C[entrypoint]} != "${I[entrypoint]}" ]]; then
    get_list ent      container "$cid" "$T_ENTRY"
    get_list cmd_args container "$cid" "$T_CMD"
    if (( ${#ent[@]} == 0 )); then
      add "--entrypoint ''"
    else
      add "--entrypoint $(q "${ent[0]}")"
      cmd_args=("${ent[@]:1}" "${cmd_args[@]}")
    fi
  elif [[ ${C[cmd]} != "${I[cmd]}" ]]; then
    get_list cmd_args container "$cid" "$T_CMD"
  fi

  local img_ex img_rd ra ua red_next=0
  img_ex=$(q "${C[image]}")
  img_rd=$img_ex
  for a in "${cmd_args[@]}"; do
    ra=$a
    ua=${a^^}
    if (( red_next )) || looks_secret_value "$a"; then
      ra=$REDACTED
    elif [[ $ua =~ ^--?[A-Z_-]*${SECRET_RE}[A-Z_-]*= ]]; then
      ra="${a%%=*}=$REDACTED"
    fi
    red_next=0
    [[ $ua =~ ^--?[A-Z_-]*${SECRET_RE}[A-Z_-]*$ ]] && red_next=1
    img_ex+=" $(q "$a")"
    img_rd+=" $(q "$ra")"
  done

  # ---- write the block
  local digests
  digests=$(docker image inspect --format '{{join .RepoDigests " "}}' "$iid" 2>/dev/null)
  b "# ------------------------------------------------------------------"
  b "# $name   (state when exported: ${C[state]})"
  b "# image: ${C[image]}   image id: ${iid#sha256:}"
  [[ -n $digests ]] && b "# digest: $digests"
  for i in "${!NX[@]}"; do b "# NOTE: ${NX[i]}" "# NOTE: ${NR[i]}"; done
  b "docker run -d \\"
  b "  --name $(q "$name") \\"
  for i in "${!EX[@]}"; do b "  ${EX[i]} \\" "  ${RD[i]} \\"; done
  b "  $img_ex" "  $img_rd"
  for x in "${connect[@]}"; do b "$x"; done
  b ""

  echo "  exported: $name"
}

# ---------------------------------------------------------------- main
echo "Docker engine $SERVER_VERSION: exporting containers (read-only)..."

docker container ls -a --format '{{.Names}}' | sort | mapfile -t NAMES
if (( ${#NAMES[@]} == 0 )); then
  echo "no containers found" >&2
  exit 1
fi

# cloudflared first: it carries remote access, recreate it before the rest
ORDERED=()
SKIPPED=()
for n in "${NAMES[@]}"; do [[ $n == cloudflared ]] && ORDERED+=("$n"); done
for n in "${NAMES[@]}"; do
  [[ -z $n || $n == cloudflared ]] && continue
  if in_list "$n" "${EXCLUDE[@]}"; then SKIPPED+=("$n"); echo "  skipped:  $n (excluded)"; continue; fi
  ORDERED+=("$n")
done

for n in "${ORDERED[@]}"; do
  export_one "$n"
done

# ---- networks used by the containers
NET_EX=""
ipam=(); nopts=()   # filled by get_list (nameref)
for net in $(printf '%s\n' "${!USED_NETS[@]}" | sort); do
  line="docker network create --driver $(docker network inspect --format '{{.Driver}}' "$net")"
  get_list ipam network "$net" '{{range .IPAM.Config}}{{.Subnet}}'"$S"'{{.Gateway}}'"$S"'{{.IPRange}}{{println}}{{end}}'
  for x in "${ipam[@]}"; do
    IFS=$S read -r sub gw rng <<<"$x"
    [[ -n $sub ]] && line+=" --subnet $sub"
    [[ -n $gw  ]] && line+=" --gateway $gw"
    [[ -n $rng ]] && line+=" --ip-range $rng"
  done
  [[ $(docker network inspect --format '{{.Internal}}'   "$net") == true ]] && line+=" --internal"
  [[ $(docker network inspect --format '{{.Attachable}}' "$net") == true ]] && line+=" --attachable"
  [[ $(docker network inspect --format '{{.EnableIPv6}}' "$net") == true ]] && line+=" --ipv6"
  get_list nopts network "$net" '{{range $k, $v := .Options}}{{$k}}={{$v}}{{println}}{{end}}'
  for x in "${nopts[@]}"; do line+=" -o $(q "$x")"; done
  members=$(docker network inspect --format '{{range .Containers}}{{.Name}} {{end}}' "$net")
  NET_EX+="# used by: ${members% }"$'\n'"$line $(q "$net")"$'\n\n'
done

# ---- images on this host that no container uses
UNUSED=""
docker image ls --no-trunc --format '{{.ID}} {{.Repository}}:{{.Tag}}' | while read -r iid ref; do
  [[ -z $iid ]] && continue
  [[ -n ${USED_IMAGES[$iid]:-} ]] && continue
  UNUSED+="#   $ref"$'\n'
done

# ---- write both files
write_file() {  # write_file <path> <body>
  {
    echo "#!/bin/sh"
    echo "#"
    echo "# Commands to recreate all containers on a new Docker engine."
    echo "# Exported $(date '+%Y-%m-%d %H:%M:%S') from $(hostname), Docker engine $SERVER_VERSION."
    echo "# Generated by export-docker-run.sh (read-only export). REVIEW BEFORE RUNNING."
    echo "#"
    echo "# - Images are pulled again by tag. ':latest' tags may bring newer versions;"
    echo "#   the digest comment above each container is the exact image used today."
    echo "# - Only settings that differ from the image defaults are included."
    echo "# - Can be run whole (sh <file>) or one command at a time."
    echo "# - Order: networks first, then cloudflared (remote access), then the rest."
    (( ${#SKIPPED[@]} )) && echo "# - Not recreated (excluded on purpose): ${SKIPPED[*]}"
    echo
    if [[ -n $NET_EX ]]; then
      echo "# ================================================================== networks"
      printf '%s' "$NET_EX"
    fi
    echo "# ================================================================== containers"
    printf '%s' "$2"
    if [[ -n $UNUSED ]]; then
      echo "# ================================================================== info"
      echo "# Images on the old host not used by any container (not recreated):"
      printf '%s' "$UNUSED"
    fi
  } >"$1"
  chmod 600 "$1"
}

write_file "$OUT" "$BODY_EX"
write_file "$RED" "$BODY_RD"

echo
echo "Containers exported: ${#ORDERED[@]}   networks: ${#USED_NETS[@]}   notes needing attention: $WARN_COUNT"
echo "Exact commands (CONTAINS SECRETS, mode 600): $OUT"
echo "Redacted copy (safe to share):               $RED"
