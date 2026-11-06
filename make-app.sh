#!/usr/bin/env bash
#
# make-app.sh: build the "docker" app for WD My Cloud OS5 NAS devices, with the
# official Docker engine inside. Community build, not affiliated with Docker, Inc.
# or Western Digital: https://github.com/polius/wd-mycloud-docker
#
# Usage:  bash make-app.sh [VERSION]      (default: the latest stable Docker release)
#
# Run it from the repository root, in a throwaway container that can only write to the
# folder holding this script and dockerctl.sh (it builds next to itself):
#
#   mkdir app-build && cp make-app.sh dockerctl.sh app-build/
#   docker run --rm --platform linux/amd64 -v "$PWD/app-build:/out" debian:bookworm-slim \
#     bash -c 'apt-get update -qq && apt-get install -y -qq --no-install-recommends \
#              curl ca-certificates openssl libxml2 >/dev/null && bash /out/make-app.sh'
#
# Result:  app-build/<model>_docker_<VERSION>.bin (one per model in MODELS), SHA256SUMS and
#          release-notes.md. Install the .bin in the NAS dashboard
#          (Apps > Install an app manually). Installing a newer one later = updating
#          Docker; containers, images and volumes stay in <volume>/Nas_Prog/docker_data.
#
# What goes into the app:
#   engine/          official static binaries from download.docker.com (docker-<VERSION>.tgz)
#                    + the latest docker compose plugin from GitHub (sha256 checked)
#   dockerctl.sh     starts/stops the engine (see its header)
#   init.sh, start.sh, stop.sh, install.sh, remove.sh, ...   the NAS app hooks
#
# It deletes and moves nothing: it builds in docker-build/ next to this script, keeps
# that folder (delete it by hand when done) and copies the .bin out. If either already
# exists, it stops.
#
# The .bin is made with WD's packaging tool mksapkg-OS5 (Linux x86_64; needs
# libxml2.so.2 and openssl), downloaded from the WDCommunity project at a pinned
# commit and checked against a known sha256 before it runs. It signs the app with
# Blowfish (openssl bf-cbc); on OpenSSL 3 this script turns on the "legacy" provider
# for the build, and it fails if the signature (apkg.sign) comes out empty.

if [ -z "${BASH_VERSION:-}" ]; then
  echo "error: run this with bash:  bash $0" >&2
  exit 1
fi

set -u -o pipefail

# ---------------------------------------------------------------- settings
APP_NAME=docker
# mksapkg model names (space separated); one .bin per model. Intel (x86_64) OS5 models only:
# the engine is x86_64. PR2100 tested; PR4100 is the same family and firmware.
read -r -a MODELS <<<"${MODELS:-MyCloudPR2100 MyCloudPR4100}"
STATIC_URL=https://download.docker.com/linux/static/stable/x86_64
COMPOSE_URL=https://github.com/docker/compose/releases
MKSAPKG_URL=https://raw.githubusercontent.com/WDCommunity/wdpksrc/f7a6c485b6285c342727006507f79bf5e4d119f0/mksapkg-OS5
MKSAPKG_SHA256=62340b1d0eb0433fffa7ceb1a5b6d4886e69b93e6e60297b2f984f5f3557e67a
# Docker's current official mark ("docker-mark-ocean-blue.png" from Docker's logo kit,
# https://www.docker.com/static/Docker-Logos-1.zip, via https://www.docker.com/company/newsroom/media-resources/),
# scaled to fit a 256x256 transparent canvas with a 16 px margin (not cropped, stretched or recoloured)
APP_ICON_B64='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'

SELF="$(cd "$(dirname "$0")" && pwd -P)/$(basename "$0")"
OUT=$(dirname "$SELF")

# ---------------------------------------------------------------- helpers
log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else openssl dgst -sha256 "$1" | awk '{print $NF}'; fi
}
b64_decode() { openssl base64 -d -A; }

# latest stable static Docker release
latest_engine_version() {
  curl -fsSL "$STATIC_URL/" \
    | grep -o 'docker-[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\.tgz' \
    | sed 's/^docker-//; s/\.tgz$//' \
    | awk -F. '{ printf "%05d%05d%05d %s\n", $1, $2, $3, $0 }' \
    | sort -n | tail -n 1 | cut -d' ' -f2
}

# ---------------------------------------------------------------- engine
fetch_engine() {   # fetch_engine <version> <app folder>: engine/ with docker + compose
  local v=$1 app=$2 dl=$WORK/download got tag url want have
  mkdir -p "$dl" || die "cannot create $dl"
  log "downloading $STATIC_URL/docker-$v.tgz"
  curl -fsSL --retry 3 -o "$dl/docker-$v.tgz" "$STATIC_URL/docker-$v.tgz" || die "download of docker-$v.tgz failed"
  ENGINE_SHA256=$(sha256_of "$dl/docker-$v.tgz")
  log "docker-$v.tgz sha256 $ENGINE_SHA256"
  tar -xzf "$dl/docker-$v.tgz" -C "$dl" || die "cannot unpack docker-$v.tgz"
  [[ -x $dl/docker/dockerd && -x $dl/docker/docker ]] || die "unexpected archive layout in docker-$v.tgz"
  got=$("$dl/docker/dockerd" --version 2>&1)
  [[ $got == *"version $v,"* ]] || die "dockerd reports '$got' (expected $v)"
  cp -a "$dl/docker" "$app/engine" || die "cannot copy the engine into $app"

  url=$(curl -fsSLI -o /dev/null -w '%{url_effective}' "$COMPOSE_URL/latest") || die "cannot reach GitHub"
  tag=${url##*/}
  [[ $tag == v[0-9]* ]] || die "cannot find the latest docker compose version ($url)"
  log "downloading docker compose $tag"
  curl -fsSL --retry 3 -o "$dl/docker-compose" "$COMPOSE_URL/download/$tag/docker-compose-linux-x86_64" \
    && curl -fsSL --retry 3 -o "$dl/docker-compose.sha256" "$COMPOSE_URL/download/$tag/docker-compose-linux-x86_64.sha256" \
    || die "docker compose download failed"
  want=$(awk '{ print $1 }' "$dl/docker-compose.sha256"); have=$(sha256_of "$dl/docker-compose")
  [[ -n $want && $want == "$have" ]] || die "docker compose checksum mismatch"
  cp "$dl/docker-compose" "$app/engine/docker-compose" && chmod 755 "$app/engine/docker-compose" \
    || die "cannot copy docker compose into $app"
  COMPOSE_VERSION=${tag#v}
  COMPOSE_SHA256=$have
  log "docker compose $COMPOSE_VERSION ready (sha256 $have)"
}

# ---------------------------------------------------------------- app files
write_app_files() {   # write_app_files <app folder> <version>; folder name must be $APP_NAME
  local out=$1 v=$2
  mkdir -p "$out/web" || die "cannot create $out"

  # same fields and layout as the WDCommunity apps that install fine on OS5.
  # Description: Docker's own, from https://docs.docker.com/get-started/docker-overview/
  printf '%s\n' \
    "Package:	$APP_NAME" \
    "Version:	$v" \
    "Packager:	wd-mycloud-docker" \
    "Email:" \
    "Homepage:	https://github.com/polius/wd-mycloud-docker" \
    "Description:	Docker is an open platform for developing, shipping, and running applications. Docker enables you to separate your applications from your infrastructure so you can deliver software quickly." \
    "Icon:	$APP_NAME.png" \
    "AddonShowName:	Docker" \
    "AddonIndexPage:	index.html" \
    "AddonUsedPort:" \
    "InstDepend:" \
    "InstConflict:" \
    "StartDepend:" \
    "StartConflict:" \
    "CenterType:" \
    "UserControl:" \
    "MinFWVer:	5.0.0" \
    "MaxFWVer:" \
    "IndividualFlag: 0" >"$out/apkg.rc"

  # The dashboard loads the icon through /var/www/<app>/ (init.sh links that to web/),
  # like the old community Docker app, which kept it only in web/. Put it in both places.
  printf '%s' "$APP_ICON_B64" | b64_decode >"$out/web/$APP_NAME.png" 2>/dev/null \
    || die "cannot write the app icon (openssl missing?)"
  cp "$out/web/$APP_NAME.png" "$out/$APP_NAME.png" || die "cannot copy the app icon"

  cp "$OUT/dockerctl.sh" "$out/dockerctl.sh" || die "dockerctl.sh must be next to make-app.sh"

  # Hooks run by the NAS. Every one logs to /tmp/debug_apkg (the NAS's app debug log).
  # They find dockerctl.sh next to themselves, in the installed app folder.
  local hdr='#!/bin/sh
APP=$(cd "$(dirname "$0")" && pwd)
CTL=$APP/dockerctl.sh
LOG=/tmp/debug_apkg
echo "'"$APP_NAME"': $0 $*" >>$LOG
BASH_BIN=$(command -v bash)
[ -n "$BASH_BIN" ] && [ -f "$CTL" ] || { echo "'"$APP_NAME"': bash or $CTL missing" >>$LOG; exit 1; }'

  # install.sh: $1 = unpacked package folder, $2 = Nas_Prog folder.
  # Upgrade: first stop the Docker of the installed version with its own stop.sh, so its
  # running files can be replaced. Containers are kept; start.sh brings them back.
  cat >"$out/install.sh" <<EOF
#!/bin/sh
LOG=/tmp/debug_apkg
echo "$APP_NAME: \$0 \$*" >>\$LOG
path_src=\$1
NAS_PROG=\$2
[ -d "\$path_src" ] && [ -d "\$NAS_PROG" ] || { echo "$APP_NAME: install.sh: bad arguments" >>\$LOG; exit 1; }
OLD=\$NAS_PROG/$APP_NAME
if [ -f "\$OLD/stop.sh" ]; then
  echo "$APP_NAME: stopping the installed version before replacing it" >>\$LOG
  sh "\$OLD/stop.sh" "\$OLD" >>\$LOG 2>&1
fi
cp -rf "\$path_src" "\$NAS_PROG"
exit 0
EOF

  printf '%s\n' '#!/bin/sh' 'exit 0' >"$out/preinst.sh"

  # init.sh (boot and after install, before start.sh): command links + web page
  cat >"$out/init.sh" <<EOF
$hdr
mkdir -p /var/www
ln -sfn "\$APP/web" /var/www/$APP_NAME
# the info page (Configure button) with this NAS's real paths
DATA=\$(dirname "\$APP")/docker_data
[ -f "\$APP/web/index.html.in" ] && sed -e "s#@APP@#\$APP#g" -e "s#@DATA@#\$DATA#g" "\$APP/web/index.html.in" >"\$APP/web/index.html"
"\$BASH_BIN" "\$CTL" --links >>\$LOG 2>&1
exit 0
EOF

  cat >"$out/start.sh" <<EOF
$hdr
"\$BASH_BIN" "\$CTL" --start >>\$LOG 2>&1
EOF

  cat >"$out/stop.sh" <<EOF
$hdr
"\$BASH_BIN" "\$CTL" --stop >>\$LOG 2>&1
EOF

  # clean.sh / remove.sh run when the app is uninstalled in the dashboard.
  cat >"$out/clean.sh" <<EOF
#!/bin/sh
rm -f /var/www/$APP_NAME
exit 0
EOF

  # remove.sh: deletes only the app folder; <volume>/Nas_Prog/docker_data (data, settings, logs) stays.
  cat >"$out/remove.sh" <<EOF
$hdr
"\$BASH_BIN" "\$CTL" --stop >>\$LOG 2>&1
"\$BASH_BIN" "\$CTL" --unlink >>\$LOG 2>&1
rm -f /var/www/$APP_NAME
APKG_PATH=\${1:-\$APP}
case "\$APKG_PATH" in
  */Nas_Prog/$APP_NAME) rm -rf "\$APKG_PATH" ;;
esac
exit 0
EOF

  # Info page behind the dashboard's "Configure" button. init.sh fills in @APP@ and @DATA@
  # with this NAS's real paths (from index.html.in); index.html is the same page with
  # generic paths until then.
  cat >"$out/web/index.html.in" <<EOF
<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8"><title>Docker $v</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
body{font-family:-apple-system,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;max-width:46rem;margin:2rem auto;padding:0 1rem;line-height:1.5;color:#1d2433}
h1{margin-bottom:.2rem} h2{margin-top:1.8rem;font-size:1.15rem} .sub{color:#5b6475;margin-top:0}
code{background:#f1f3f6;padding:.1rem .3rem;border-radius:4px;font-size:.92em;word-break:break-all}
table{border-collapse:collapse;width:100%} td{padding:.35rem .5rem;border-bottom:1px solid #e3e6eb;vertical-align:top} td:first-child{white-space:nowrap;color:#5b6475}
.ok{color:#1a7f37;font-weight:600} small{color:#5b6475}
</style></head><body>
<h1>Docker $v</h1>
<p class="sub">Community build for WD My Cloud OS5. Not affiliated with Docker, Inc. or Western Digital.</p>

<h2>What is installed</h2>
<table>
<tr><td>Docker Engine</td><td>$v: Docker's official static binaries from <code>download.docker.com</code>, unmodified.<br><small>sha256 of docker-$v.tgz: <code>$ENGINE_SHA256</code></small></td></tr>
<tr><td>docker compose</td><td>$COMPOSE_VERSION: Docker's official plugin from <code>github.com/docker/compose</code>, checksum verified.<br><small>sha256: <code>$COMPOSE_SHA256</code></small></td></tr>
</table>

<h2>Where things are on this NAS</h2>
<table>
<tr><td>Docker program</td><td><code>@APP@/engine</code><br><small>Part of this app: replaced on every update, removed on uninstall.</small></td></tr>
<tr><td>Your images, containers, volumes, networks</td><td><code>@DATA@/data</code><br><small>Outside the app: never touched by updates or uninstall.</small></td></tr>
<tr><td>Docker settings</td><td><code>@DATA@/daemon.json</code></td></tr>
<tr><td>Logs</td><td><code>@DATA@/logs/</code> (<code>dockerd.log</code>, <code>dockerctl.log</code>)</td></tr>
<tr><td>Folders you mount into containers</td><td>Wherever you chose (e.g. <code>-v /mnt/HD/HD_a2/MyApp:/data</code>). Never touched by this app.</td></tr>
</table>

<h2>Updating Docker</h2>
<p>Install the <code>.bin</code> of the newer version in the dashboard (<i>Apps &gt; Install an app manually</i>). What happens:</p>
<ol>
<li>Docker stops. All running containers are <b>stopped gracefully</b> (each gets up to 30 seconds to shut down).</li>
<li>The Docker program files are replaced with the new version.</li>
<li>Docker starts again, and containers with a restart policy (<code>--restart always</code> or <code>unless-stopped</code>) <b>start again by themselves</b>.</li>
</ol>
<p class="ok">Nothing is deleted: your images, containers, volumes, networks, settings and mounted folders all stay.</p>
<p><small>Containers created without a restart policy are not started again automatically: start them with <code>docker start &lt;name&gt;</code>. Your services are down for the time Docker and your containers take to stop and start (usually a minute or two).</small></p>

<h2>Uninstalling</h2>
<p>Removes the Docker program only. Your data stays in <code>@DATA@</code> until you delete it yourself.</p>

<h2>Commands (over SSH, as root)</h2>
<p><code>docker</code> and <code>docker compose</code> work as usual. To check or restart Docker itself:<br>
<code>bash @APP@/dockerctl.sh --status</code><br><code>bash @APP@/dockerctl.sh --restart</code></p>

<h2>Source</h2>
<p>Scripts, build process and releases: <a href="https://github.com/polius/wd-mycloud-docker">github.com/polius/wd-mycloud-docker</a></p>
</body></html>
EOF
  sed -e 's#@APP@#<volume>/Nas_Prog/docker#g' -e 's#@DATA@#<volume>/Nas_Prog/docker_data#g' \
    "$out/web/index.html.in" | sed -e 's#<volume>#\&lt;volume\&gt;#g' >"$out/web/index.html"

  chmod 755 "$out"/*.sh
}

# ---------------------------------------------------------------- mksapkg
get_mksapkg() {   # prints the path of a verified mksapkg-OS5
  local tool=$1/mksapkg-OS5
  curl -fsSL --retry 3 -o "$tool" "$MKSAPKG_URL" || die "cannot download mksapkg-OS5"
  [[ $(sha256_of "$tool") == "$MKSAPKG_SHA256" ]] \
    || die "mksapkg-OS5 checksum mismatch ($tool): refusing to run it"
  chmod +x "$tool"
  printf '%s\n' "$tool"
}

# ---------------------------------------------------------------- main
(( $# <= 1 )) || die "usage: make-app.sh [VERSION]"
[[ $(uname -s) == Linux && $(uname -m) == x86_64 ]] \
  || die "mksapkg-OS5 and dockerd need Linux x86_64: run this in the container shown in the header"
for t in curl tar openssl; do
  command -v "$t" >/dev/null 2>&1 || die "'$t' is needed to build the app"
done
[[ -f $OUT/dockerctl.sh ]] || die "dockerctl.sh must be next to make-app.sh ($OUT)"

VERSION=${1:-}
if [[ -z $VERSION ]]; then
  VERSION=$(latest_engine_version) || true
  [[ -n $VERSION ]] || die "cannot find the latest Docker version at $STATIC_URL"
  log "latest stable Docker: $VERSION"
fi
[[ $VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "invalid version '$VERSION' (expected e.g. 29.9.3)"

# mksapkg works in the current folder and writes ../<model>*.bin*
WORK=$OUT/${APP_NAME}-build
[[ -e $WORK ]] && die "$WORK already exists (earlier build): delete it by hand first"
for f in "${MODELS[@]/%/_${APP_NAME}_${VERSION}.bin}" SHA256SUMS release-notes.md; do
  [[ -e $OUT/$f ]] && die "$OUT/$f already exists: delete it by hand first"
done
mkdir "$WORK" && mkdir "$WORK/tools" "$WORK/pkg" || die "cannot create $WORK"

# mksapkg signs the app with  echo <name> | openssl bf-cbc -md sha256 -out apkg.sign -k <key>.
# OpenSSL 3 keeps Blowfish in its "legacy" provider, which is off by default; without it
# mksapkg still reports success but writes an empty signature. Turn the legacy provider
# on for this build only (a config file in the build folder), and check it works.
bf_ok() { echo test | openssl bf-cbc -md sha256 -k test -out /dev/null >/dev/null 2>&1; }
if ! bf_ok; then
  printf '%s\n' 'openssl_conf = openssl_init' '[openssl_init]' 'providers = provider_sect' \
    '[provider_sect]' 'default = default_sect' 'legacy = legacy_sect' \
    '[default_sect]' 'activate = 1' '[legacy_sect]' 'activate = 1' >"$WORK/openssl-legacy.cnf"
  export OPENSSL_CONF=$WORK/openssl-legacy.cnf
  bf_ok || die "openssl can't do Blowfish (bf-cbc), which mksapkg needs to sign the app (no OpenSSL legacy provider?)"
  log "OpenSSL 3: legacy provider turned on for this build (mksapkg signs with Blowfish)"
fi

APP=$WORK/pkg/$APP_NAME
mkdir "$APP" || die "cannot create $APP"
ENGINE_SHA256=""; COMPOSE_VERSION=""; COMPOSE_SHA256=""; BIN_ROWS=""
fetch_engine "$VERSION" "$APP"
( write_app_files "$APP" "$VERSION" ) || die "cannot write the app files (build folder kept: $WORK)"
TOOL=$(get_mksapkg "$WORK/tools") || die "cannot get mksapkg-OS5 (build folder kept: $WORK)"

for m in "${MODELS[@]}"; do
  OUTLOG=$WORK/mksapkg-$m.out
  if ! ( cd "$APP" && "$TOOL" -E -s -m "$m" ) >"$OUTLOG" 2>&1; then
    cat "$OUTLOG" >&2
    die "mksapkg failed for $m (build folder kept: $WORK)"
  fi
  # mksapkg exits 0 even when a step fails: check its output and the signature ourselves
  if grep -qi 'error' "$OUTLOG"; then
    cat "$OUTLOG" >&2
    die "mksapkg reported an error for $m (log: $OUTLOG; build folder kept: $WORK)"
  fi
  SIGN_SIZE=$(wc -c <"$APP/apkg.sign" 2>/dev/null || echo 0)
  (( SIGN_SIZE > 16 )) || die "apkg.sign is $SIGN_SIZE bytes: the app was not signed (build folder kept: $WORK)"
  BUILT=$(ls -1 "$WORK/pkg/${m}_${APP_NAME}_${VERSION}.bin"* 2>/dev/null | head -n1)
  [[ -n $BUILT ]] || { cat "$OUTLOG" >&2; die "mksapkg did not produce a .bin for $m (build folder kept: $WORK)"; }
  BIN=$OUT/${m}_${APP_NAME}_${VERSION}.bin
  cp "$BUILT" "$BIN" || die "cannot copy $BUILT to $BIN"
  BIN_SHA=$(sha256_of "$BIN")
  printf '%s  %s\n' "$BIN_SHA" "${BIN##*/}" >>"$OUT/SHA256SUMS"
  BIN_ROWS+="| \`${BIN##*/}\` | ${m#MyCloud} | $(( $(wc -c <"$BIN") / 1000000 )) MB | \`$BIN_SHA\` |"$'\n'
  log "built $BIN ($(wc -c <"$BIN") bytes, sha256 $BIN_SHA)"
done

# Release notes (used by the GitHub release; handy for a local build too)
cat >"$OUT/release-notes.md" <<EOF
Docker Engine **$VERSION** packaged as an app for WD My Cloud OS5 (Intel models).

| Component | Version | Source |
|---|---|---|
| Docker Engine | $VERSION | Official static binaries from download.docker.com, unmodified ([release notes](https://docs.docker.com/engine/release-notes/${VERSION%%.*}/)) |
| docker compose | $COMPOSE_VERSION | Official plugin from [docker/compose](https://github.com/docker/compose/releases/tag/v$COMPOSE_VERSION), checksum verified |

### Install or update

1. Download the \`.bin\` for your model.
2. In the NAS dashboard: **Apps > Install an app manually**, and choose it.

Updating keeps your images, containers, volumes and settings. Containers stop and, if they have a restart policy, start again by themselves. See the [README](https://github.com/polius/wd-mycloud-docker#updating-docker) for details.

### Files

| File | Model | Size | SHA-256 |
|---|---|---|---|
${BIN_ROWS}
Inputs: \`docker-$VERSION.tgz\` sha256 \`$ENGINE_SHA256\` · \`docker-compose-linux-x86_64\` sha256 \`$COMPOSE_SHA256\`
EOF
log "Docker $VERSION (docker-$VERSION.tgz sha256 $ENGINE_SHA256), docker compose $COMPOSE_VERSION"
log "wrote $OUT/SHA256SUMS and $OUT/release-notes.md"
log "build folder kept, delete it by hand when done: $WORK"
log "install it in the NAS dashboard: Apps > Install an app manually"
