#!/bin/bash
# The two add-ons together, standalone, without Home Assistant: "Mozilla accounts
# (self-hosted)" and "Firefox Sync" with accounts: self_hosted and the link code the first one
# prints, each with its /data and a /share (even mapped, they write no secret there), a mock
# Supervisor at 172.30.32.2 (tests/mock_supervisor.py), and in
# front of them what a user puts there: a reverse proxy with HTTPS for the public host names
# (Caddy with its internal CA, standing in for the NGINX Proxy Manager add-on; the sign-up gate
# route and /img/ as DOCS.md says) and a mail catcher (mailpit) for the codes. It runs
# firefox-sync's tests/test_fxa_flow.py (sign-up, email codes, keys, OAuth, tokenserver and sync,
# through the public URLs) and tests/test_fxa_pairing.py, checks the admin UI's view of the
# accounts, the accounts' backup_pre dump, and a restart (the keys kept).
#
#   tests/run-accounts.sh <sync image> <accounts image> <firefox-sync checkout> [bundled|addon]
#
# Named ffs-hat-*, removed at the end (KEEP=1: kept).
set -u
SYNC_IMAGE=${1:?sync image}
FXA_IMAGE=${2:?accounts image}
FFS=${3:?the firefox-sync checkout (its tests/)}
MODE=${4:-bundled}
ADDON_DB_IMAGE=${ADDON_DB_IMAGE:-mariadb:11.4}
HERE=$(cd "$(dirname "$0")" && pwd)
NET=ffs-hat
TOKEN=test-supervisor-token
WORK=$(mktemp -d /tmp/ffs-hat-fxa.XXXXXX)
FAILED=0 PASSED=0
CONTAINERS="ffs-hat-sync ffs-hat-accounts ffs-hat-supervisor ffs-hat-caddy ffs-hat-mailpit ffs-hat-mariadb"

say() { echo "== $*"; }
check() {
  if [ "$1" = "$2" ]; then echo "PASS: $3"; PASSED=$((PASSED + 1)); else
    echo "FAIL: $3 (got $1, expected $2)"; FAILED=$((FAILED + 1))
    [ -z "${STOP_ON_FAIL:-}" ] || { docker logs ffs-hat-accounts 2>&1 | grep -v '^s6-rc: info' | tail -40; docker logs ffs-hat-sync 2>&1 | grep -v '^s6-rc: info' | tail -20; exit 1; }
  fi
}
cleanup() {
  [ -n "${KEEP:-}" ] && { echo "kept: ${CONTAINERS}; ${WORK}"; return; }
  # shellcheck disable=SC2086
  docker rm -f ${CONTAINERS} > /dev/null 2>&1
  docker volume rm ffs-hat-caddy-data > /dev/null 2>&1
  docker network rm "${NET}" > /dev/null 2>&1
  sudo rm -rf "${WORK}"
}
trap cleanup EXIT
# shellcheck disable=SC2086
docker rm -f ${CONTAINERS} > /dev/null 2>&1
docker volume rm ffs-hat-caddy-data > /dev/null 2>&1
docker network rm "${NET}" > /dev/null 2>&1
docker network create --subnet 172.30.32.0/23 --gateway 172.30.32.1 --ip-range 172.30.33.0/24 "${NET}" > /dev/null || exit 1
mkdir -p "${WORK}/state" "${WORK}/share" "${WORK}/sync-data" "${WORK}/accounts-data" "${WORK}/ca"

start_supervisor() { # start_supervisor <options file of the add-on being started> [mysql]
  docker rm -f ffs-hat-supervisor > /dev/null 2>&1
  cp "$1" "${WORK}/state/options.json"
  docker run -d --name ffs-hat-supervisor --network "${NET}" --ip 172.30.32.2 --network-alias supervisor \
    -e SUPERVISOR_TOKEN="${TOKEN}" -e STATE_DIR=/state -e MOCK_MYSQL="${2:-}" \
    -v "${HERE}/mock_supervisor.py:/mock_supervisor.py:ro" -v "${WORK}/state:/state" \
    --entrypoint python3 "${SYNC_IMAGE}" /mock_supervisor.py > /dev/null
  sleep 1
}

say "the reverse proxy (Caddy, its internal CA) and the mail catcher"
cat > "${WORK}/Caddyfile" <<'CADDY'
{
	# certificates of Caddy's internal CA only (never ACME)
	local_certs
	skip_install_trust
	servers {
		trusted_proxies static private_ranges
	}
}
accounts.fxa.test {
	reverse_proxy ffs-hat-accounts:3030
}
api.fxa.test {
	# the sign-up gate of the Firefox Sync add-on's admin UI (DOCS.md, docs/reverse-proxy.md#sign-up-gate)
	@create path /v1/account/create
	reverse_proxy @create ffs-hat-sync:8081
	reverse_proxy ffs-hat-accounts:9000
}
profile.fxa.test {
	# the avatars: img-proxy on 1114, the path as it is
	reverse_proxy /img/* ffs-hat-accounts:1114
	reverse_proxy ffs-hat-accounts:1111
}
pairing.fxa.test {
	reverse_proxy ffs-hat-accounts:8000
}
sync.fxa.test {
	reverse_proxy ffs-hat-sync:8000
}
CADDY
docker run -d --name ffs-hat-caddy --network "${NET}" \
  --network-alias accounts.fxa.test --network-alias api.fxa.test --network-alias profile.fxa.test \
  --network-alias pairing.fxa.test --network-alias sync.fxa.test \
  -v "${WORK}/Caddyfile:/etc/caddy/Caddyfile:ro" -v ffs-hat-caddy-data:/data/caddy caddy:alpine > /dev/null || exit 1
docker run -d --name ffs-hat-mailpit --network "${NET}" --network-alias mailpit \
  -e MP_SMTP_AUTH_ACCEPT_ANY=true -e MP_SMTP_AUTH_ALLOW_INSECURE=true axllent/mailpit:latest > /dev/null || exit 1
for _ in $(seq 1 30); do
  docker cp ffs-hat-caddy:/data/caddy/pki/authorities/local/root.crt "${WORK}/ca/root.crt" > /dev/null 2>&1 && break
  sleep 1
done
chmod 644 "${WORK}/ca/root.crt"

MOCK_MYSQL=
if [ "${MODE}" = addon ]; then
  say "a MariaDB container standing in for the MariaDB add-on (${ADDON_DB_IMAGE}), its service user"
  root=$(openssl rand -hex 16) service_pw=$(openssl rand -hex 24)
  docker run -d --name ffs-hat-mariadb --network "${NET}" --network-alias core-mariadb \
    -e MARIADB_ROOT_PASSWORD="${root}" "${ADDON_DB_IMAGE}" > /dev/null || exit 1
  for _ in $(seq 1 60); do
    docker exec -e MYSQL_PWD="${root}" ffs-hat-mariadb mariadb -uroot -e 'SELECT 1' > /dev/null 2>&1 && break
    sleep 2
  done
  docker exec -i -e MYSQL_PWD="${root}" ffs-hat-mariadb mariadb -uroot <<SQL
CREATE USER 'service'@'172.30.32.%' IDENTIFIED BY '${service_pw}';
CREATE USER 'service'@'172.30.33.%' IDENTIFIED BY '${service_pw}';
GRANT ALL PRIVILEGES ON *.* TO 'service'@'172.30.32.%' WITH GRANT OPTION;
GRANT ALL PRIVILEGES ON *.* TO 'service'@'172.30.33.%' WITH GRANT OPTION;
SQL
  MOCK_MYSQL="core-mariadb:3306:service:${service_pw}"
fi
db_containers=true
[ "${MODE}" = addon ] && db_containers=false

say "the accounts add-on (${MODE})"
cat > "${WORK}/accounts-data/options.json" <<JSON
{"fxa_content_url": "https://accounts.fxa.test", "fxa_auth_url": "https://api.fxa.test",
 "fxa_profile_url": "https://profile.fxa.test", "fxa_pairing_url": "wss://pairing.fxa.test",
 "sync_public_url": "https://sync.fxa.test", "fxa_db_containers": ${db_containers},
 "fxa_smtp_host": "mailpit", "fxa_smtp_port": 1025, "fxa_smtp_user": "", "fxa_smtp_pass": "",
 "fxa_smtp_secure": false, "fxa_smtp_sender": "Mozilla accounts <no-reply@fxa.test>", "fxa_signups": "open"}
JSON
start_supervisor "${WORK}/accounts-data/options.json" "${MOCK_MYSQL}"
start_accounts() {
  docker rm -f ffs-hat-accounts > /dev/null 2>&1
  # (NODE_EXTRA_CA_CERTS: the test proxy's CA; real host names have public certificates)
  docker run -d --name ffs-hat-accounts --hostname ffs-hat-accounts --network "${NET}" ${APPARMOR:+--security-opt apparmor=firefox_accounts} \
    -e SUPERVISOR_TOKEN="${TOKEN}" -e TZ=UTC -e NODE_EXTRA_CA_CERTS=/caddy-ca/root.crt \
    -v "${WORK}/accounts-data:/data" -v "${WORK}/share:/share" -v "${WORK}/ca:/caddy-ca:ro" "${FXA_IMAGE}" > /dev/null
}
start=$(date +%s)
start_accounts
ready=1
for _ in $(seq 1 300); do
  [ "$(docker inspect -f '{{.State.Running}}' ffs-hat-accounts)" = true ] || break
  if docker exec ffs-hat-accounts curl -sf -o /dev/null http://127.0.0.1:3030/__heartbeat__ 2> /dev/null &&
    docker exec ffs-hat-accounts curl -sf -o /dev/null http://127.0.0.1:8000/__heartbeat__ 2> /dev/null; then
    ready=0
    break
  fi
  sleep 3
done
check "${ready}" 0 "the accounts add-on starts: every server answers ($(( $(date +%s) - start )) s)"
[ -z "${APPARMOR:-}" ] || check "$(docker inspect -f '{{.AppArmorProfile}}' ffs-hat-accounts)" firefox_accounts "under its AppArmor profile"
docker logs ffs-hat-accounts 2>&1 | grep -E 'Database:|applied as|every user, grant|Wrote|Accounts:|Pointed' | sed 's/^/   /'
code=$(docker logs ffs-hat-accounts 2>&1 | sed -n 's/.*its option fxa_link_code): \([^ ]*\).*/\1/p' | tail -n 1 | tr -d '\033' | sed 's/\[0m$//')
check "$([ -n "${code}" ] && echo yes)" yes "the accounts add-on prints a link code (${code%%:*}:...)"
say "the link: only with the code"
# a third container on the add-on network, with /share mapped as any add-on may have it
third() { docker run --rm --network "${NET}" -v "${WORK}/share:/share" --entrypoint sh "${SYNC_IMAGE}" -c "$1"; }
check "$(third 'curl -s -o /dev/null -w "%{http_code}" http://ffs-hat-accounts:8101/v1/link')" 401 "the link endpoint without the code: 401"
check "$(third 'curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer wrong-token-wrong-token-wrong-token" http://ffs-hat-accounts:8101/v1/link')" 401 "the link endpoint with a wrong code: 401"
check "$(third "curl -s -o /dev/null -w '%{http_code}' -H 'Authorization: Bearer ${code#*:}' http://ffs-hat-accounts:8101/v1/link")" 200 "the link endpoint with the code: 200"
redis_pw=$(sudo sed -n 's/^FXA_REDIS_PASSWORD=//p' "${WORK}/accounts-data/secrets.env")
admin_pw=$(sudo sed -n 's/^FXA_ADMIN_DB_PASSWORD=//p' "${WORK}/accounts-data/secrets.env")
check "$(third "grep -rlE '${redis_pw}|${admin_pw}' /share 2> /dev/null | wc -l")" 0 "no secret of the accounts in /share for a third add-on"
sudo ls "${WORK}/accounts-data/fxa-keys" | tr '\n' ' '; echo
# (oauth-clients.json is written again at every start, by design: not a key)
KEYS="secret-key.json public-key.json vapid-keys.json openid-key.json"
keys_sum() { sudo sh -c "cd ${WORK}/accounts-data/fxa-keys && cat ${KEYS}" | md5sum; }
keys_before=$(keys_sum)
docker stats --no-stream --format '   memory of the accounts add-on: {{.MemUsage}}' ffs-hat-accounts

say "the Sync add-on, accounts: self_hosted"
cat > "${WORK}/sync-data/options.json" <<JSON
{"sync_public_url": "https://sync.fxa.test", "sync_max_users": "5", "admin": true, "sync_db_containers": ${db_containers}, "accounts": "self_hosted", "fxa_link_code": "${code}"}
JSON
start_supervisor "${WORK}/sync-data/options.json" "${MOCK_MYSQL}"
docker run -d --name ffs-hat-sync --hostname ffs-hat-sync --network "${NET}" ${APPARMOR:+--security-opt apparmor=firefox_sync} \
  -e SUPERVISOR_TOKEN="${TOKEN}" -e TZ=UTC -e SSL_CERT_FILE=/caddy-ca/root.crt \
  -v "${WORK}/sync-data:/data" -v "${WORK}/share:/share" -v "${WORK}/ca:/caddy-ca:ro" "${SYNC_IMAGE}" > /dev/null
ready=1
for _ in $(seq 1 120); do
  [ "$(docker inspect -f '{{.State.Running}}' ffs-hat-sync)" = true ] || break
  if docker exec ffs-hat-sync curl -sf -o /dev/null http://127.0.0.1:8000/__heartbeat__ 2> /dev/null &&
    docker exec ffs-hat-sync curl -sf -o /dev/null http://127.0.0.1:8080/healthz 2> /dev/null; then
    ready=0
    break
  fi
  sleep 2
done
check "${ready}" 0 "the Sync add-on starts with the self-hosted accounts"
docker logs ffs-hat-sync 2>&1 | grep -E 'Accounts:|Database:' | sed 's/^/   /'

say "tests/test_fxa_flow.py and tests/test_fxa_pairing.py through the public URLs"
docker cp "${FFS}/tests/test_fxa_flow.py" ffs-hat-sync:/tmp/test_fxa_flow.py > /dev/null
docker cp "${FFS}/tests/test_fxa_pairing.py" ffs-hat-sync:/tmp/test_fxa_pairing.py > /dev/null
fxa_pytest() { # fxa_pytest <test files>: in the Sync add-on's container (its Python has PyFxA)
  docker exec -e FXA_CONTENT_URL=https://accounts.fxa.test -e FXA_AUTH_URL=https://api.fxa.test \
    -e FXA_PROFILE_URL=https://profile.fxa.test -e FXA_PAIRING_URL=wss://pairing.fxa.test \
    -e SYNC_PUBLIC_URL=https://sync.fxa.test -e MAILPIT_URL=http://mailpit:8025 \
    -e REQUESTS_CA_BUNDLE=/caddy-ca/root.crt -e CA_BUNDLE=/caddy-ca/root.crt \
    -e PYTHONPATH=/app:/app/tools:/tmp/pydeps -e PYTHONDONTWRITEBYTECODE=1 -w /app ffs-hat-sync \
    python3 -m pytest -q -p no:cacheprovider --tb=short -rs "$@" 2>&1 | tail -20
  return "${PIPESTATUS[0]}"
}
fxa_pytest /tmp/test_fxa_flow.py
check "$?" 0 "test_fxa_flow.py: sign-up, codes by email, keys, OAuth, tokenserver, sync"
# the pairing test's websocket client (the e2e tests run it in their browser image)
docker exec ffs-hat-sync python3 -m pip install -q --target /tmp/pydeps websocket-client > /dev/null 2>&1
fxa_pytest /tmp/test_fxa_pairing.py
check "$?" 0 "test_fxa_pairing.py: two devices exchange a message through the pairing server"

say "the admin UI sees the accounts"
token=$(sudo sed -n 's/^ADMIN_METRICS_TOKEN=//p' "${WORK}/sync-data/secrets.env")
metrics=$(docker exec ffs-hat-supervisor curl -s -H "Authorization: Bearer ${token}" http://ffs-hat-sync:8080/metrics)
printf '%s\n' "${metrics}" > /tmp/ffs-hat-metrics-accounts.txt
printf '%s' "${metrics}" | grep -E '^ffs_accounts [1-9]'
check "$?" 0 "ffs_accounts counts the sign-up"
for c in "Accounts API" "Accounts pages" "Profile server" "Accounts database" "Accounts Redis" "Pairing server"; do
  printf '%s' "${metrics}" | grep -q "^ffs_up{component=\"${c}\"} 1$"
  check "$?" 0 "ffs_up{component=\"${c}\"} 1"
done
page=$(docker exec ffs-hat-supervisor curl -s -H 'X-Ingress-Path: /api/hassio_ingress/AbCd123' \
  -H 'X-Remote-User-Name: ingress-tester' -H 'X-Remote-User-Groups: system-admin' http://ffs-hat-sync:8099/)
printf '%s' "${page}" | grep -q '@example.com'
check "$?" 0 "the admin UI's overview (through the ingress) lists the new account"

say "backup_pre of the accounts, and a restart: the signing keys kept"
docker exec ffs-hat-accounts /usr/bin/fxa-backup-pre
check "$?" 0 "fxa-backup-pre"
sudo sh -c "zcat ${WORK}/accounts-data/backup/firefox-accounts-*.sql.gz" | grep -c 'CREATE DATABASE' | grep -q '^5$'
check "$?" 0 "the dump holds the five databases"
start_supervisor "${WORK}/accounts-data/options.json" "${MOCK_MYSQL}"
docker restart -t 60 ffs-hat-accounts > /dev/null
ready=1
for _ in $(seq 1 200); do
  docker exec ffs-hat-accounts curl -sf -o /dev/null http://127.0.0.1:3030/__heartbeat__ 2> /dev/null && { ready=0; break; }
  sleep 3
done
check "${ready}" 0 "the accounts add-on starts again"
check "$(keys_sum)" "${keys_before}" "the signing keys unchanged (${KEYS})"
if [ "${MODE}" = bundled ]; then
  say "a restore of the accounts: the data directory left out of the backup, the dump loaded"
  docker stop -t 60 ffs-hat-accounts > /dev/null
  sudo rm -rf "${WORK}/accounts-data/mariadb"
  start_accounts
  ready=1
  for _ in $(seq 1 200); do
    docker exec ffs-hat-accounts curl -sf -o /dev/null http://127.0.0.1:3030/__heartbeat__ 2> /dev/null && { ready=0; break; }
    sleep 3
  done
  check "${ready}" 0 "the accounts add-on starts from the dump"
  docker logs ffs-hat-accounts 2>&1 | grep -E 'Restored|Loading' | sed 's/^/   /'
  check "$(docker exec ffs-hat-accounts mariadb --protocol=socket -S /run/mysqld/mysqld.sock -uroot -sN -e 'SELECT COUNT(*) > 0 FROM fxa.accounts')" 1 "the accounts are back after the restore"
fi
docker logs ffs-hat-accounts > "${WORK}/accounts.log" 2>&1
cp "${WORK}/accounts.log" /tmp/ffs-hat-accounts-${MODE}.log
echo "== ${PASSED} passed, ${FAILED} failed"
[ "${FAILED}" = 0 ]
