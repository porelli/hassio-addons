#!/bin/bash
# The "AirConnect" add-on run standalone, without Home Assistant and without any player: its
# image, with a mock Supervisor (tests/mock_supervisor.py, which gives bashio the options) at
# 172.30.32.2 on a network like the Supervisor's. The add-on runs on that network, not on the
# host's (the mock must be reachable as "supervisor"): the bridges search it and find nobody.
# For a few sets of options it checks the command line each bridge runs with (its
# /proc/<pid>/cmdline), that it runs as the airconnect user, that a bridge turned off does not
# run, that a config file in /config is passed, that a wrong interface stops the add-on, and
# that a stop is quick.
#
#   tests/run-airconnect.sh <image> [python image for the mock Supervisor]
#
# APPARMOR=1: the add-on under its own profile (airconnect/apparmor.txt, loaded first with
# sudo apparmor_parser), as the Supervisor runs it. Everything it starts is named ach-*,
# removed at the end (KEEP=1: kept).
set -u
IMAGE=${1:?image}
MOCK_IMAGE=${2:-python:3-alpine}
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=privsep.sh
. "${HERE}/privsep.sh"
NET=ach
SUBNET=172.30.32.0/23
TOKEN=test-supervisor-token
WORK=$(mktemp -d /tmp/ach.XXXXXX)
FAILED=0
PASSED=0

say() { echo "== $*"; }
check() { # check <got> <expected> <what>
  if [ "$1" = "$2" ]; then echo "PASS: $3"; PASSED=$((PASSED + 1)); else echo "FAIL: $3 (got '$1', expected '$2')"; FAILED=$((FAILED + 1)); fi
}
cleanup() {
  [ -n "${KEEP:-}" ] && { echo "kept: docker ps -a --filter name=ach-; ${WORK}"; return; }
  docker rm -f ach-addon ach-supervisor > /dev/null 2>&1
  docker network rm "${NET}" > /dev/null 2>&1
  rm -rf "${WORK}"
}
trap cleanup EXIT

if [ -n "${APPARMOR:-}" ]; then
  sudo apparmor_parser -r -W "${HERE}/../airconnect/apparmor.txt" || exit 1
fi
docker rm -f ach-addon ach-supervisor > /dev/null 2>&1
docker network rm "${NET}" > /dev/null 2>&1
docker network create --subnet "${SUBNET}" --gateway 172.30.32.1 --ip-range 172.30.33.0/24 "${NET}" > /dev/null || exit 1
mkdir -p "${WORK}/state" "${WORK}/config"
docker run -d --name ach-supervisor --network "${NET}" --ip 172.30.32.2 --network-alias supervisor \
  -e SUPERVISOR_TOKEN="${TOKEN}" -e STATE_DIR=/state \
  -v "${HERE}/mock_supervisor.py:/mock_supervisor.py:ro" -v "${WORK}/state:/state" \
  "${MOCK_IMAGE}" python3 /mock_supervisor.py > /dev/null || exit 1
# (listening: bashio asks it once per bridge start)
for _ in $(seq 1 30); do
  docker exec ach-supervisor python3 -c 'import socket; socket.create_connection(("127.0.0.1", 80), 1)' > /dev/null 2>&1 && break
  sleep 1
done

# start <options json> [docker run arguments]: the add-on as the Supervisor starts it (init:
# false, the token), with these options
start() {
  printf '%s\n' "$1" > "${WORK}/state/options.json"
  shift
  docker rm -f ach-addon > /dev/null 2>&1
  docker run -d --name ach-addon --network "${NET}" ${APPARMOR:+--security-opt apparmor=airconnect} \
    -e SUPERVISOR_TOKEN="${TOKEN}" "$@" "${IMAGE}" > /dev/null || exit 1
}
# wait_log <text>: the add-on's log has the text (up to 30 s)
wait_log() {
  for _ in $(seq 1 30); do
    docker logs ach-addon 2>&1 | grep -qF -- "$1" && return 0
    sleep 1
  done
  return 1
}
# cmdline <bridge>: the command line of the running bridge, its arguments space-separated (the
# bridges parse -d in place: all=info reads "all info" there; the log has the command line too)
cmdline() {
  # shellcheck disable=SC2016 # (expanded in the container)
  docker exec ach-addon sh -c 'for d in /proc/[0-9]*; do
      c=$(tr "\0" " " < "$d/cmdline" 2> /dev/null) || continue
      case "$c" in "/usr/bin/$0 "*) echo "${c% }" ;; esac
    done' "$1" 2> /dev/null
}
# bridge <bridge> <expected command line>: it runs with it, as airconnect
bridge() {
  wait_log "bridge (AirConnect" || true
  sleep 2
  check "$(cmdline "$1")" "$2" "$1's command line"
  [ -n "$2" ] || return 0
  check "$(privsep_user ach-addon "/usr/bin/$1 ")" airconnect "$1 runs as airconnect"
  [ -z "${APPARMOR:-}" ] ||
    check "$(docker exec ach-addon sh -c 'cat /proc/$(pidof "$0")/attr/current' "$1" 2> /dev/null)" "airconnect//bridge (enforce)" "$1 in the bridges' AppArmor profile"
}

say "the default options"
start '{"airupnp": true, "aircast": true, "upnp_latency": "1000:2000", "log_level": "info"}'
bridge airupnp "/usr/bin/airupnp -Z -b eth0 -l 1000:2000 -d all info"
bridge aircast "/usr/bin/aircast -Z -b eth0 -d all info"
wait_log "Interface eth0 (the default route's)" && r=found || r=missing
check "${r}" found "the interface of the default route, in the log"
sleep 5
check "$(docker inspect -f '{{.State.Running}}' ach-addon)" true "still running after a while (no restarts)"
check "$(docker exec ach-addon cat /usr/share/airconnect/version)" "$(docker logs ach-addon 2>&1 | sed -n 's/.*bridge (AirConnect \([^)]*\)).*/\1/p' | head -n 1)" "the AirConnect version in the log"
start_s=$(date +%s)
docker stop ach-addon > /dev/null
check "$(($(date +%s) - start_s < 10))" 1 "a stop takes less than 10 s"
docker logs ach-addon > "${WORK}/defaults.log" 2>&1

say "every option of airupnp, aircast off"
start '{"airupnp": true, "aircast": false, "interface": "eth0", "upnp_port": 49200,
  "upnp_latency": "500:1000:f", "codec": "flac:5/1152", "name_format": "%s (AirPlay)",
  "upnp_exclude_models": "Sonos One,Play:5", "upnp_exclude_model_numbers": "S18", "noflush": true,
  "log_level": "debug"}'
bridge airupnp "/usr/bin/airupnp -Z -b eth0:49200 -l 500:1000:f -c flac:5/1152 -N %s (AirPlay) -m Sonos One,Play:5 -n S18 --noflush -d all debug"
bridge aircast ""
wait_log "The Chromecast bridge (aircast) is off" && r=found || r=missing
check "${r}" found "aircast off, in the log"

say "aircast's options, airupnp off, pcm (UPnP only)"
start '{"airupnp": false, "aircast": true, "upnp_latency": "1000:2000", "cast_latency": "1000",
  "codec": "pcm", "cast_media_volume": 0.3, "name_format": "AirPlay %s", "log_level": "warn"}'
bridge aircast "/usr/bin/aircast -Z -b eth0 -l 1000 -N AirPlay %s -v 0.3 -d all warn"
bridge airupnp ""
wait_log "Chromecast has no pcm" && r=found || r=missing
check "${r}" found "pcm left out for aircast, in the log"

say "a config file in /config (addon_config)"
printf '<?xml version="1.0"?>\n<airupnp>\n<common><enabled>1</enabled></common>\n</airupnp>\n' > "${WORK}/config/airupnp.xml"
chmod 0755 "${WORK}/config" && chmod 0644 "${WORK}/config/airupnp.xml"
start '{"airupnp": true, "aircast": true, "upnp_latency": "1000:2000", "log_level": "info"}' -v "${WORK}/config:/config:ro"
bridge airupnp "/usr/bin/airupnp -Z -b eth0 -l 1000:2000 -d all info -x /config/airupnp.xml"
bridge aircast "/usr/bin/aircast -Z -b eth0 -d all info"

say "a wrong interface stops the add-on"
start '{"airupnp": true, "aircast": true, "interface": "nope0", "upnp_latency": "1000:2000", "log_level": "info"}'
wait_log "No interface nope0 on this host" && r=found || r=missing
check "${r}" found "the wrong interface, in the log"
for _ in $(seq 1 20); do [ "$(docker inspect -f '{{.State.Running}}' ach-addon)" = false ] && break; sleep 1; done
check "$(docker inspect -f '{{.State.Running}}' ach-addon)" false "the add-on stopped"

if [ -n "${APPARMOR:-}" ]; then
  say "AppArmor"
  check "$(docker inspect -f '{{.AppArmorProfile}}' ach-addon)" airconnect "the add-on's profile"
fi

echo "== the default run's log:"
cat "${WORK}/defaults.log"
echo "== ${PASSED} passed, ${FAILED} failed"
[ "${FAILED}" = 0 ]
