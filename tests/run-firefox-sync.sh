#!/bin/bash
# The "Firefox Sync" add-on run standalone, without Home Assistant: its image with
# /data/options.json, and a mock Supervisor (tests/mock_supervisor.py) at 172.30.32.2 on a
# network like the Supervisor's, which also sends the ingress requests. For each database mode:
#   bundled     the bundled MariaDB (sync_db_containers: true)
#   addon       a MariaDB container standing in for the MariaDB add-on (its "service" user,
#               given to the add-on through the mock services API)
# it checks: the start (the one-shots, fail closed), firefox-sync's tests/test_client_flow.py
# against the add-on's Sync server (upstream's mock FxA for the sign-ins), the admin UI through a
# simulated ingress (allowed only from 172.30.32.2, the user from the Supervisor's headers, the
# links rewritten), /metrics with the token, the discovery sent, the backup_pre dump, the
# privilege separation (each service its own user, tests/privsep.sh); and in the
# bundled mode: a restore from that dump (the raw files left out of the backup), and the
# keep-major guard.
#
#   tests/run-firefox-sync.sh <image> <firefox-sync checkout> [bundled|addon|all] [mariadb image]
#
# Everything it starts is named ffs-hat-*, removed at the end (KEEP=1: kept).
set -u
IMAGE=${1:?image}
FFS=${2:?the firefox-sync checkout (its tests/)}
MODES=${3:-all}
ADDON_DB_IMAGE=${4:-mariadb:11.4}
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=privsep.sh
. "${HERE}/privsep.sh"
NET=ffs-hat
SUBNET=172.30.32.0/23
TOKEN=test-supervisor-token
WORK=$(mktemp -d /tmp/ffs-hat.XXXXXX)
PUBLIC_URL=https://sync.example.org
FAILED=0
PASSED=0

say() { echo "== $*"; }
check() { # check <status> <expected> <what>
  if [ "$1" = "$2" ]; then echo "PASS: $3"; PASSED=$((PASSED + 1)); else echo "FAIL: $3 (got $1, expected $2)"; FAILED=$((FAILED + 1)); [ -z "${STOP_ON_FAIL:-}" ] || { docker logs ffs-hat-addon 2>&1 | tail -40; exit 1; }; fi
}
cleanup() {
  [ -n "${KEEP:-}" ] && { echo "kept: docker ps -a --filter name=ffs-hat; ${WORK}"; return; }
  docker rm -f ffs-hat-addon ffs-hat-supervisor ffs-hat-mockfxa ffs-hat-mariadb > /dev/null 2>&1
  docker network rm "${NET}" > /dev/null 2>&1
  sudo rm -rf "${WORK}" 2> /dev/null || rm -rf "${WORK}"
}
trap cleanup EXIT

docker rm -f ffs-hat-addon ffs-hat-supervisor ffs-hat-mockfxa ffs-hat-mariadb > /dev/null 2>&1
docker network rm "${NET}" > /dev/null 2>&1
docker network create --subnet "${SUBNET}" --gateway 172.30.32.1 --ip-range 172.30.33.0/24 "${NET}" > /dev/null || exit 1

mkdir -p "${WORK}/state"
docker run -d --name ffs-hat-supervisor --network "${NET}" --ip 172.30.32.2 --network-alias supervisor \
  -e SUPERVISOR_TOKEN="${TOKEN}" -e STATE_DIR=/state -e ADDON_HOSTNAME=ffs-hat-addon \
  -e MOCK_MYSQL="${MOCK_MYSQL:-}" \
  -v "${HERE}/mock_supervisor.py:/mock_supervisor.py:ro" -v "${WORK}/state:/state" \
  --entrypoint python3 "${IMAGE}" /mock_supervisor.py > /dev/null || exit 1
# upstream's mock FxA, shipped in the syncstorage-rs images (as tests/compose/sync.yml has it)
docker run -d --name ffs-hat-mockfxa --network "${NET}" --network-alias mock_fxa \
  -e MOCK_FXA_SERVER_HOST=0.0.0.0 -e MOCK_FXA_SERVER_PORT=6000 \
  --entrypoint sh "${IMAGE}" /app/scripts/start_mock_fxa_server.sh > /dev/null || exit 1

# options <file> <sync_db_containers> [extra json]
options() {
  printf '{"sync_public_url": "%s", "sync_max_users": "1", "admin": true, "sync_db_containers": %s, "accounts": "mozilla"%s}\n' \
    "${PUBLIC_URL}" "$2" "${3:-}" > "$1"
  cp "$1" "${WORK}/state/options.json"
}
# raw_options <file> <json>: options as they are
raw_options() { printf '%s\n' "$2" > "$1"; cp "$1" "${WORK}/state/options.json"; }
# start_addon <data dir>: the add-on as the Supervisor starts it (init: false, its /data, the token)
start_addon() {
  docker rm -f ffs-hat-addon > /dev/null 2>&1
  # APPARMOR=1: under the add-on's own profile (apparmor.txt, loaded with apparmor_parser)
  docker run -d --name ffs-hat-addon --hostname ffs-hat-addon --network "${NET}" ${APPARMOR:+--security-opt apparmor=firefox_sync} \
    -e SUPERVISOR_TOKEN="${TOKEN}" -e TZ=Europe/Rome \
    -e FXA_OAUTH_SERVER_URL=http://mock_fxa:6000 -e FXA_EMAIL_DOMAIN=api-accounts.stage.mozaws.net \
    -v "$1:/data" "${IMAGE}" > /dev/null
}
# wait_ready: the Sync server and the admin UI answer (up to 4 minutes), or the add-on exited
wait_ready() {
  for _ in $(seq 1 120); do
    if [ "$(docker inspect -f '{{.State.Running}}' ffs-hat-addon 2> /dev/null)" != true ]; then
      return 1
    fi
    if docker exec ffs-hat-addon curl -sf http://127.0.0.1:8000/__heartbeat__ > /dev/null 2>&1 &&
      docker exec ffs-hat-addon curl -sf http://127.0.0.1:8080/healthz > /dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  return 1
}
# wait_exit: the add-on stopped by itself (fail closed), its exit code
wait_exit() {
  for _ in $(seq 1 60); do
    if [ "$(docker inspect -f '{{.State.Running}}' ffs-hat-addon 2> /dev/null)" != true ]; then
      docker inspect -f '{{.State.ExitCode}}' ffs-hat-addon
      return
    fi
    sleep 2
  done
  echo running
}
secret() { sudo sed -n "s/^$1=//p" "$2/secrets.env"; }
# ingress <path> [curl args]: a request through the add-on's ingress, as the Supervisor sends it
ingress() {
  local path=$1
  shift
  docker exec ffs-hat-supervisor curl -s -o /dev/null -w '%{http_code}' \
    -H "X-Ingress-Path: /api/hassio_ingress/AbCd123" -H "X-Remote-User-Name: ${INGRESS_USER:-ingress-tester}" \
    -H "X-Remote-User-Id: 0123456789abcdef" -H "X-Remote-User-Display-Name: Ingress Tester" \
    -H "X-Remote-User-Groups: ${INGRESS_GROUPS:-system-admin,system-users}" "$@" "http://ffs-hat-addon:8099${path}"
}
ingress_body() {
  docker exec ffs-hat-supervisor curl -s \
    -H "X-Ingress-Path: /api/hassio_ingress/AbCd123" -H "X-Remote-User-Name: ingress-tester" \
    -H "X-Remote-User-Groups: system-admin" "http://ffs-hat-addon:8099$1"
}
client_flow() { # client_flow <data dir> <db host>
  local pw
  pw=$(secret SYNC_TOKENSERVER_DB_PASSWORD "$1")
  docker cp "${FFS}/tests/test_client_flow.py" ffs-hat-addon:/tmp/test_client_flow.py > /dev/null
  docker exec -e SYNC_SERVER_URL=http://127.0.0.1:8000 -e SYNC_PUBLIC_URL="${PUBLIC_URL}" -e SYNC_MAX_USERS=1 \
    -e SYNC_TOKENSERVER__DATABASE_URL="mysql://tokenserver:${pw}@$2:3306/tokenserver" \
    -e PYTHONPATH=/app:/app/tools -e PYTHONDONTWRITEBYTECODE=1 -w /app ffs-hat-addon \
    python3 -m pytest -q -p no:cacheprovider --tb=short /tmp/test_client_flow.py 2>&1 | tail -15
  return "${PIPESTATUS[0]}"
}

common_checks() { # common_checks <data dir> <db host>
  local data=$1 db=$2 out token
  say "Sync: tests/test_client_flow.py against the add-on"
  client_flow "${data}" "${db}"
  check "$?" 0 "test_client_flow.py (sign-in, sync, SYNC_MAX_USERS=1)"

  say "the admin UI through the ingress"
  check "$(ingress /)" 200 "ingress: the overview, signed in by X-Remote-User-Name"
  out=$(ingress_body /)
  printf '%s' "${out}" | grep -q 'href="/api/hassio_ingress/AbCd123/static/style.css"'
  check "$?" 0 "ingress: the links rewritten under X-Ingress-Path"
  printf '%s' "${out}" | grep -q 'href="/users\|href="/static'
  check "$?" 1 "ingress: no absolute link left"
  printf '%s' "${out}" | grep -q 'ingress-tester'
  check "$?" 0 "ingress: the page names the Home Assistant user"
  check "$(INGRESS_GROUPS=system-users ingress /)" 303 "ingress: a user not in system-admin is sent to the sign-in"
  check "$(docker exec ffs-hat-supervisor curl -s -o /dev/null -w '%{http_code}' -H 'X-Ingress-Path: /api/hassio_ingress/AbCd123' -I http://ffs-hat-addon:8099/login)" 200 "ingress: the sign-in page"
  check "$(docker exec ffs-hat-supervisor curl -s -o /dev/null -w '%{http_code}' -I 'http://ffs-hat-addon:8099/' )" 400 "ingress: no X-Ingress-Path, no request"
  check "$(docker exec ffs-hat-mockfxa curl -s -o /dev/null -w '%{http_code}' -H 'X-Ingress-Path: /api/hassio_ingress/AbCd123' -H 'X-Remote-User-Name: ingress-tester' -H 'X-Remote-User-Groups: system-admin' http://ffs-hat-addon:8099/)" 403 "ingress: refused from another address than the Supervisor's"
  # the header straight to the admin UI's own port, from another container: not trusted
  check "$(docker exec ffs-hat-mockfxa curl -s -o /dev/null -w '%{http_code}' -H 'X-Remote-User-Name: ingress-tester' -H 'X-Remote-User-Groups: system-admin' http://ffs-hat-addon:8080/)" 303 "admin UI port: the header ignored from another container"
  local location
  location=$(docker exec ffs-hat-supervisor curl -s -o /dev/null -w '%{redirect_url}' -H 'X-Ingress-Path: /api/hassio_ingress/AbCd123' -H 'X-Remote-User-Name: x' -H 'X-Remote-User-Groups: system-users' http://ffs-hat-addon:8099/)
  case "${location}" in */api/hassio_ingress/AbCd123/login*) check 0 0 "ingress: the redirect rewritten (${location})" ;; *) check "${location}" "…/api/hassio_ingress/AbCd123/login" "ingress: the redirect rewritten" ;; esac

  say "metrics and discovery"
  token=$(secret ADMIN_METRICS_TOKEN "${data}")
  out=$(docker exec ffs-hat-supervisor curl -s -H "Authorization: Bearer ${token}" http://ffs-hat-addon:8080/metrics)
  printf '%s' "${out}" | grep -q '^ffs_sync_accounts 1$'
  check "$?" 0 "/metrics with ADMIN_METRICS_TOKEN: ffs_sync_accounts 1"
  check "$(docker exec ffs-hat-supervisor curl -s -o /dev/null -w '%{http_code}' -H 'Authorization: Bearer wrong' http://ffs-hat-addon:8080/metrics)" 404 "/metrics with a wrong token: 404"
  printf '%s\n' "${out}" > "${WORK}/metrics-$3.txt"
  python3 - "${WORK}/state/discovery.json" "${token}" <<'PY'
import json, sys
messages = json.load(open(sys.argv[1]))
m = [x for x in messages if x["service"] == "firefox_sync"][-1]
assert m["config"]["host"] == "ffs-hat-addon", m
assert m["config"]["port"] == 8080, m
assert m["config"]["metrics_token"] == sys.argv[2]
print("discovery:", {k: (v if k != "metrics_token" else "<token>") for k, v in m["config"].items()})
PY
  check "$?" 0 "discovery: firefox_sync with the admin UI's host, port and token"

  say "backup_pre: the dump, recorded for the admin UI"
  docker exec ffs-hat-addon /usr/bin/ffs-backup-pre
  check "$?" 0 "ffs-backup-pre"
  sudo sh -c "ls ${data}/backup/firefox-sync-*.sql.gz" > /dev/null 2>&1
  check "$?" 0 "the dump in /data/backup"
  sudo sh -c "zcat ${data}/backup/firefox-sync-*.sql.gz" | grep -q 'CREATE DATABASE.*`syncstorage`'
  check "$?" 0 "the dump holds the storage database"
  out=$(docker exec ffs-hat-supervisor curl -s -H "Authorization: Bearer ${token}" http://ffs-hat-addon:8080/metrics)
  sleep 1
  for _ in $(seq 1 40); do
    out=$(docker exec ffs-hat-supervisor curl -s -H "Authorization: Bearer ${token}" http://ffs-hat-addon:8080/metrics)
    printf '%s' "${out}" | grep -q '^ffs_backup_last_ok{scope="sync"} 1$' && break
    sleep 3
  done
  printf '%s' "${out}" | grep -q '^ffs_backup_last_ok{scope="sync"} 1$'
  check "$?" 0 "the admin UI sees the backup (ffs_backup_last_ok{scope=\"sync\"} 1)"
  printf '%s\n' "${out}" > "${WORK}/metrics-$3-after-backup.txt"
  cp "${WORK}/metrics-$3-after-backup.txt" "/tmp/ffs-hat-metrics-$3.txt"

  say "privilege separation: each service its own user, none reads another's secrets"
  privsep_runs_as ffs-hat-addon app /app/bin/syncserver
  privsep_runs_as ffs-hat-addon ffs-admin "ffs-admin serve"
  privsep_runs_as ffs-hat-addon www-data "nginx: worker"
  [ "$3" != bundled ] || privsep_runs_as ffs-hat-addon mysql "mariadbd --user"
  local files expected=5
  [ "$3" = bundled ] && expected=6 # (the pin of the bundled MariaDB)
  read -r -a files <<< "$(privsep_files ffs-hat-addon /run/ffs/sync.env /data/secrets.env /data/options.json \
    /data/firefox-sync.env '/data/backup/firefox-sync-*.sql.gz' /run/s6/container_environment/SUPERVISOR_TOKEN)"
  check "${#files[@]}" "${expected}" "privilege separation: the ${expected} secret files exist (${files[*]##*/})"
  for user in app ffs-admin www-data; do
    privsep_denied ffs-hat-addon "${user}" "" "${files[@]}" dir:/app/bin dir:/usr/local/bin dir:/data dir:/data/backup dir:/run/ffs
  done
}

run_bundled() {
  local data=${WORK}/data-bundled
  mkdir -p "${data}"
  options "${data}/options.json" true
  say "bundled MariaDB: first start"
  start_addon "${data}"
  wait_ready
  check "$?" 0 "the add-on starts (bundled MariaDB)"
  [ -z "${APPARMOR:-}" ] || check "$(docker inspect -f '{{.AppArmorProfile}}' ffs-hat-addon)" firefox_sync "under its AppArmor profile"
  docker logs ffs-hat-addon 2>&1 | grep -E 'Generated|Database:|Migrations completed|Current users|applied as|Sent the discovery' | sed 's/^/   /'
  check "$(sudo stat -c %a "${data}/secrets.env")" 600 "secrets.env is 0600"
  check "$(sudo sed -n 's/^SYNC_MARIADB_IMAGE=//p' "${data}/firefox-sync.env")" "mariadb:$(docker exec ffs-hat-addon sh -c "mariadbd --version | sed -n 's/.* Ver \([0-9]*\)\..*/\1/p'")" "the pin of the data's major in /data/firefox-sync.env"
  local before
  before=$(sudo md5sum "${data}/secrets.env")
  common_checks "${data}" 127.0.0.1 bundled

  say "a second start: the secrets kept"
  docker restart -t 60 ffs-hat-addon > /dev/null
  wait_ready
  check "$?" 0 "the add-on starts again"
  check "$(sudo md5sum "${data}/secrets.env")" "${before}" "secrets.env unchanged"

  say "a restore: the data directory left out of the backup, the dump loaded"
  docker stop -t 60 ffs-hat-addon > /dev/null
  sudo rm -rf "${data}/mariadb"
  start_addon "${data}"
  wait_ready
  check "$?" 0 "the add-on starts from the dump"
  docker logs ffs-hat-addon 2>&1 | grep -E 'Restored|Loading' | sed 's/^/   /'
  local users
  users=$(docker exec -e MYSQL_PWD="$(secret SYNC_TOKENSERVER_DB_PASSWORD "${data}")" ffs-hat-addon mariadb -h 127.0.0.1 -u tokenserver -sN tokenserver -e 'SELECT COUNT(DISTINCT email) FROM users')
  check "${users}" 1 "the account is back after the restore"
  docker exec -e MYSQL_PWD="$(secret SYNC_STORAGE_DB_PASSWORD "${data}")" ffs-hat-addon mariadb -h 127.0.0.1 -u syncstorage -sN syncstorage -e 'SELECT COUNT(*) FROM bso' | grep -qv '^0$'
  check "$?" 0 "the synced items are back after the restore"

  say "the keep-major guard"
  docker stop -t 60 ffs-hat-addon > /dev/null
  local major
  major=$(sudo sed -n 's/^SYNC_MARIADB_IMAGE=mariadb://p' "${data}/firefox-sync.env")
  sudo sed -i "s/^SYNC_MARIADB_IMAGE=.*/SYNC_MARIADB_IMAGE=mariadb:$((major - 1))/" "${data}/firefox-sync.env"
  start_addon "${data}"
  check "$(wait_exit)" 1 "data pinned to MariaDB $((major - 1)): the add-on does not start"
  docker logs ffs-hat-addon 2>&1 | grep -q "Not started: the server would upgrade the data"
  check "$?" 0 "the log says why, and how to go on"
  sudo sed -i "s/^SYNC_MARIADB_IMAGE=.*/SYNC_MARIADB_IMAGE=mariadb:$((major + 1))/" "${data}/firefox-sync.env"
  start_addon "${data}"
  check "$(wait_exit)" 1 "data of a newer major ($((major + 1))): refused"
  sudo sed -i "s/^SYNC_MARIADB_IMAGE=.*/SYNC_MARIADB_IMAGE=mariadb:$((major - 1))/" "${data}/firefox-sync.env"
  options "${data}/options.json" true ', "sync_mariadb_upgrade": true'
  start_addon "${data}"
  wait_ready
  check "$?" 0 "sync_mariadb_upgrade on: the add-on starts, mariadb-upgrade runs"
  check "$(sudo sed -n 's/^SYNC_MARIADB_IMAGE=//p' "${data}/firefox-sync.env")" "mariadb:${major}" "the pin moved to the server's major"

  say "fail closed: a bad option stops the add-on before the Sync server"
  docker stop -t 60 ffs-hat-addon > /dev/null
  raw_options "${data}/options.json" '{"sync_public_url": "sync.example.org", "sync_max_users": "1", "admin": true, "sync_db_containers": true, "accounts": "mozilla"}'
  start_addon "${data}"
  check "$(wait_exit)" 1 "sync_public_url without https://: the add-on stops"
  raw_options "${data}/options.json" "{\"sync_public_url\": \"${PUBLIC_URL}\", \"sync_max_users\": \"1\", \"admin\": true, \"sync_db_containers\": true, \"accounts\": \"self_hosted\"}"
  start_addon "${data}"
  check "$(wait_exit)" 1 "accounts: self_hosted without fxa_link_code: the add-on stops"
  docker logs ffs-hat-addon 2>&1 | grep -q "Mozilla accounts (self-hosted)"
  check "$?" 0 "the log says where the link code comes from"
  docker logs ffs-hat-addon > "${WORK}/addon-bundled.log" 2>&1
}

run_addon_db() {
  local data=${WORK}/data-addon root
  mkdir -p "${data}"
  root=$(openssl rand -hex 16)
  SERVICE_PW=$(openssl rand -hex 24)
  say "a MariaDB container standing in for the MariaDB add-on (${ADDON_DB_IMAGE}), its service user"
  docker rm -f ffs-hat-mariadb > /dev/null 2>&1
  docker run -d --name ffs-hat-mariadb --network "${NET}" --network-alias core-mariadb \
    -e MARIADB_ROOT_PASSWORD="${root}" "${ADDON_DB_IMAGE}" > /dev/null || return 1
  for _ in $(seq 1 60); do
    docker exec -e MYSQL_PWD="${root}" ffs-hat-mariadb mariadb -uroot -e 'SELECT 1' > /dev/null 2>&1 && break
    sleep 2
  done
  # as the add-on's mariadb-post creates it (home-assistant/app-mariadb)
  docker exec -i -e MYSQL_PWD="${root}" ffs-hat-mariadb mariadb -uroot <<SQL
CREATE USER 'service'@'172.30.32.%' IDENTIFIED BY '${SERVICE_PW}';
CREATE USER 'service'@'172.30.33.%' IDENTIFIED BY '${SERVICE_PW}';
GRANT ALL PRIVILEGES ON *.* TO 'service'@'172.30.32.%' WITH GRANT OPTION;
GRANT ALL PRIVILEGES ON *.* TO 'service'@'172.30.33.%' WITH GRANT OPTION;
FLUSH PRIVILEGES;
SQL
  # the mock Supervisor now offers the mysql service
  docker rm -f ffs-hat-supervisor > /dev/null
  docker run -d --name ffs-hat-supervisor --network "${NET}" --ip 172.30.32.2 --network-alias supervisor \
    -e SUPERVISOR_TOKEN="${TOKEN}" -e STATE_DIR=/state -e ADDON_HOSTNAME=ffs-hat-addon \
    -e MOCK_MYSQL="core-mariadb:3306:service:${SERVICE_PW}" \
    -v "${HERE}/mock_supervisor.py:/mock_supervisor.py:ro" -v "${WORK}/state:/state" \
    --entrypoint python3 "${IMAGE}" /mock_supervisor.py > /dev/null || return 1
  options "${data}/options.json" false
  say "the MariaDB add-on: first start"
  start_addon "${data}"
  wait_ready
  check "$?" 0 "the add-on starts (the MariaDB add-on)"
  docker logs ffs-hat-addon 2>&1 | grep -E 'Database:|applied as|every user, grant|Migrations completed|Current users' | sed 's/^/   /'
  check "$(docker exec ffs-hat-addon sh -c 'pgrep -x mariadbd > /dev/null && echo running || echo none')" none "no bundled mariadbd runs"
  docker exec -e MYSQL_PWD="${root}" ffs-hat-mariadb mariadb -uroot -sN -e "SELECT CONCAT(user,'@',host) FROM mysql.user WHERE user IN ('tokenserver','syncstorage','ffs_admin_ui','ffs_admin_sync') ORDER BY user" | tr '\n' ' '
  echo
  check "$(docker exec -e MYSQL_PWD="${root}" ffs-hat-mariadb mariadb -uroot -sN -e "SELECT COUNT(*) FROM mysql.user WHERE user IN ('tokenserver','syncstorage','ffs_admin_ui','ffs_admin_sync')")" 4 "the stack's own four users, created by the bootstrap as the service user"
  common_checks "${data}" core-mariadb addon
  docker logs ffs-hat-addon > "${WORK}/addon-mariadb.log" 2>&1
}

case "${MODES}" in
  bundled) run_bundled ;;
  addon) run_addon_db ;;
  all) run_bundled; run_addon_db ;;
esac
echo "== ${PASSED} passed, ${FAILED} failed"
[ "${FAILED}" = 0 ]
