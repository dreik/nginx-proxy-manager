#!/bin/sh
# Local/manual full integration test for the Alpine + OpenResty NPM image.
# Not wired into CI — run against a container you started yourself.
#
# Usage: ./docker/alpine/fulltest.sh [base_url] [identity] [secret]
#
# Defaults: http://127.0.0.1:8181  test@test.com  test1234
#
# Start the main test container with published ports, e.g.:
#   docker run -d --name npm-alpine-test \
#     -p 8181:81 -p 8080:80 -p 8443:443 \
#     -v ./data:/data -v ./letsencrypt:/etc/letsencrypt \
#     local/nginx-proxy-manager:alpine-openresty
# Port 8080:80 is required for the CRUD proxy-host routing check.
#
# Environment:
#   CONTAINER=...     main container name (default: npm-alpine-test)
#   IMAGE=...         image for auxiliary tests (default: local/nginx-proxy-manager:alpine-openresty)
#   SKIP_ISOLATED=1   skip fresh setup / PUID / IPv6 / certbot auxiliary container tests

set -eu

BASE="${1:-http://127.0.0.1:8181}"
IDENTITY="${2:-test@test.com}"
SECRET="${3:-test1234}"
CONTAINER="${CONTAINER:-npm-alpine-test}"
IMAGE="${IMAGE:-local/nginx-proxy-manager:alpine-openresty}"
SKIP_ISOLATED="${SKIP_ISOLATED:-0}"

PASS=0
FAIL=0
SKIP=0
AUX_CONTAINERS=""

pass() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1"; }
skip() { SKIP=$((SKIP + 1)); printf 'SKIP  %s\n' "$1"; }

section() { printf '\n=== %s ===\n' "$1"; }

http_code() {
	curl -sS --noproxy '*' --connect-timeout 5 --max-time 15 \
		-o /tmp/npm-fulltest-body.txt -w '%{http_code}' "$1" 2>/dev/null || echo '000'
}

aux_cleanup() {
	for _c in $AUX_CONTAINERS; do
		docker rm -f "$_c" >/dev/null 2>&1 || true
	done
}

aux_start() {
	_name="$1"
	shift
	AUX_CONTAINERS="$AUX_CONTAINERS $_name"
	docker rm -f "$_name" >/dev/null 2>&1 || true
	# shellcheck disable=SC2068
	docker run -d --name "$_name" "$@" "$IMAGE" >/dev/null
}

wait_healthy() {
	_c="$1"
	_tries="${2:-25}"
	_i=1
	while [ "$_i" -le "$_tries" ]; do
		_hc=$(docker inspect "$_c" --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' 2>/dev/null || echo none)
		if [ "$_hc" = 'healthy' ]; then
			return 0
		fi
		if ! docker ps --filter "name=^/${_c}$" --filter status=running -q | grep -q .; then
			docker logs "$_c" 2>&1 | tail -20
			return 1
		fi
		sleep 2
		_i=$((_i + 1))
	done
	return 1
}

api_inside() {
	_c="$1"
	_method="$2"
	_path="$3"
	_body="${4:-}"
	if [ -n "$_body" ]; then
		docker exec "$_c" curl -sS --noproxy '*' --connect-timeout 5 --max-time 30 \
			-X "$_method" "http://127.0.0.1:81${_path}" \
			-H 'Content-Type: application/json' \
			-d "$_body"
	else
		docker exec "$_c" curl -sS --noproxy '*' --connect-timeout 5 --max-time 15 \
			-X "$_method" "http://127.0.0.1:81${_path}"
	fi
}

reset_test_dir() {
	_dir="$1"
	docker run --rm -v "${_dir}:/target" alpine:3.24 sh -c 'rm -rf /target/* /target/.[!.]* 2>/dev/null || true'
	mkdir -p "$_dir"
}

trap aux_cleanup EXIT INT TERM

section 'Container'
if docker ps --filter "name=${CONTAINER}" --filter status=running -q | grep -q .; then
	pass "container ${CONTAINER} running"
else
	fail "container ${CONTAINER} not running"
	printf '\nTOTAL: FAIL (container down)\n'
	exit 1
fi

section 'Healthcheck'
if docker exec "$CONTAINER" /usr/bin/check-health >/tmp/npm-fulltest-health.txt 2>&1; then
	pass "check-health ($(tr -d '\n' </tmp/npm-fulltest-health.txt))"
else
	fail "check-health ($(tr -d '\n' </tmp/npm-fulltest-health.txt))"
fi

HC=$(docker inspect "$CONTAINER" --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}')
[ "$HC" = 'healthy' ] || [ "$HC" = 'starting' ] && pass "docker HEALTHCHECK status=${HC}" \
	|| fail "docker HEALTHCHECK status=${HC}"

section 'Runtime'
docker exec "$CONTAINER" /usr/sbin/nginx -t >/tmp/npm-fulltest-nginx-t.txt 2>&1 \
	&& pass 'nginx -t' || fail "nginx -t ($(tail -1 /tmp/npm-fulltest-nginx-t.txt))"

docker exec "$CONTAINER" sh -c 'pgrep nginx >/dev/null && pgrep -f "/app/index.js" >/dev/null' \
	&& pass 'processes (nginx + backend)' \
	|| fail 'processes (nginx + backend)'

section 'Public HTTP'
code=$(http_code "${BASE}/")
[ "$code" = '200' ] && pass "GET / HTTP ${code}" || fail "GET / HTTP ${code}"

code=$(http_code "${BASE}/api/")
body=$(cat /tmp/npm-fulltest-body.txt)
echo "$body" | grep -q '"status":"OK"' \
	&& pass "GET /api/ HTTP ${code}" || fail "GET /api/ HTTP ${code}"

section 'Authentication'
LOGIN=$(curl -sS --noproxy '*' -X POST "${BASE}/api/tokens" \
	-H 'Content-Type: application/json' \
	-d "{\"identity\":\"${IDENTITY}\",\"secret\":\"${SECRET}\"}")
TOKEN=$(echo "$LOGIN" | jq -r '.token // empty' 2>/dev/null || true)
if [ -n "$TOKEN" ] && [ "$TOKEN" != 'null' ]; then
	pass 'POST /api/tokens'
else
	fail "POST /api/tokens ($(echo "$LOGIN" | head -c 120))"
fi

section 'Authenticated API'
if [ -z "$TOKEN" ] || [ "$TOKEN" = 'null' ]; then
	skip 'authenticated API (no token)'
else
	for path in \
		/api/users \
		/api/settings \
		/api/version/check \
		/api/nginx/proxy-hosts \
		/api/nginx/redirection-hosts \
		/api/nginx/dead-hosts \
		/api/nginx/streams \
		/api/nginx/access-lists \
		/api/nginx/certificates \
		/api/reports/hosts \
		/api/audit-log; do
		code=$(curl -sS --noproxy '*' --connect-timeout 5 --max-time 15 \
			-H "Authorization: Bearer ${TOKEN}" \
			-o /tmp/npm-fulltest-body.txt -w '%{http_code}' "${BASE}${path}")
		[ "$code" = '200' ] && pass "GET ${path} HTTP ${code}" \
			|| fail "GET ${path} HTTP ${code} ($(head -c 80 /tmp/npm-fulltest-body.txt))"
	done
fi

section 'CRUD proxy host'
if [ -z "$TOKEN" ] || [ "$TOKEN" = 'null' ]; then
	skip 'CRUD proxy host (no token)'
else
	CREATE=$(curl -sS --noproxy '*' -X POST "${BASE}/api/nginx/proxy-hosts" \
		-H "Authorization: Bearer ${TOKEN}" \
		-H 'Content-Type: application/json' \
		-d '{"domain_names":["fulltest.local"],"forward_scheme":"http","forward_host":"127.0.0.1","forward_port":81,"enabled":true}')
	HID=$(echo "$CREATE" | jq -r '.id // empty' 2>/dev/null || true)
	if [ -n "$HID" ] && [ "$HID" != 'null' ]; then
		pass "POST /api/nginx/proxy-hosts id=${HID}"
		sleep 1
		code=$(curl -sS --noproxy '*' -H 'Host: fulltest.local' \
			-o /tmp/npm-fulltest-body.txt -w '%{http_code}' 'http://127.0.0.1:8080/api/')
		grep -q '"status":"OK"' /tmp/npm-fulltest-body.txt \
			&& pass "proxy routing via port 80 HTTP ${code}" \
			|| fail "proxy routing via port 80 HTTP ${code}"
		curl -sS --noproxy '*' -X DELETE "${BASE}/api/nginx/proxy-hosts/${HID}" \
			-H "Authorization: Bearer ${TOKEN}" >/dev/null
		pass "DELETE /api/nginx/proxy-hosts/${HID}"
	else
		fail "POST /api/nginx/proxy-hosts ($(echo "$CREATE" | head -c 120))"
	fi
fi

if [ "$SKIP_ISOLATED" = '1' ]; then
	section 'Isolated tests'
	skip 'isolated tests (SKIP_ISOLATED=1)'
else
	section 'Fresh setup (empty /data)'
	FRESH=fulltest-fresh
	FRESH_DATA=/tmp/npm-fulltest-fresh/data
	FRESH_LE=/tmp/npm-fulltest-fresh/letsencrypt
	reset_test_dir "$FRESH_DATA"
	reset_test_dir "$FRESH_LE"
	aux_start "$FRESH" \
		-v "${FRESH_DATA}:/data" \
		-v "${FRESH_LE}:/etc/letsencrypt"
	if wait_healthy "$FRESH"; then
		API=$(api_inside "$FRESH" GET /api/)
		echo "$API" | grep -q '"setup":false' \
			&& pass 'GET /api/ setup=false on empty database' \
			|| fail "GET /api/ expected setup=false ($(echo "$API" | head -c 120))"

		CREATE_USER=$(api_inside "$FRESH" POST /api/users \
			'{"name":"Fresh Admin","nickname":"Admin","email":"fresh@fulltest.local","auth":{"type":"password","secret":"freshpass123"}}')
		echo "$CREATE_USER" | jq -e '.id' >/dev/null 2>&1 \
			&& pass 'POST /api/users (setup wizard)' \
			|| fail "POST /api/users ($(echo "$CREATE_USER" | head -c 120))"

		API2=$(api_inside "$FRESH" GET /api/)
		echo "$API2" | grep -q '"setup":true' \
			&& pass 'GET /api/ setup=true after first user' \
			|| fail "GET /api/ expected setup=true ($(echo "$API2" | head -c 120))"

		LOGIN=$(api_inside "$FRESH" POST /api/tokens \
			'{"identity":"fresh@fulltest.local","secret":"freshpass123"}')
		FRESH_TOKEN=$(echo "$LOGIN" | jq -r '.token // empty' 2>/dev/null || true)
		if [ -n "$FRESH_TOKEN" ] && [ "$FRESH_TOKEN" != 'null' ]; then
			pass 'POST /api/tokens (fresh user)'
		else
			fail "POST /api/tokens fresh user ($(echo "$LOGIN" | head -c 120))"
		fi
	else
		fail "fresh container did not become healthy"
	fi

	section 'PUID/PGID (1000:1000)'
	PUID_C=fulltest-puid
	PUID_DATA=/tmp/npm-fulltest-puid/data
	PUID_LE=/tmp/npm-fulltest-puid/letsencrypt
	reset_test_dir "$PUID_DATA"
	reset_test_dir "$PUID_LE"
	aux_start "$PUID_C" \
		-e PUID=1000 \
		-e PGID=1000 \
		-v "${PUID_DATA}:/data" \
		-v "${PUID_LE}:/etc/letsencrypt"
	if wait_healthy "$PUID_C"; then
		DATA_UID=$(docker exec "$PUID_C" stat -c '%u' /data)
		[ "$DATA_UID" = '1000' ] && pass "/data owned by uid 1000" \
			|| fail "/data owned by uid ${DATA_UID} (expected 1000)"

		NPM_UID=$(docker exec "$PUID_C" id -u npm 2>/dev/null || echo '')
		[ "$NPM_UID" = '1000' ] && pass "npm user uid is 1000" \
			|| fail "npm user uid is ${NPM_UID} (expected 1000)"

		NGINX_USER=$(docker exec "$PUID_C" ps aux | awk '/nginx: master process/ {print $2; exit}')
		case "$NGINX_USER" in
			npm) pass "nginx master runs as npm" ;;
			*) fail "nginx master runs as ${NGINX_USER:-unknown} (expected npm)" ;;
		esac

		BACKEND_USER=$(docker exec "$PUID_C" ps aux | awk '/\/app\/index.js/ {print $2; exit}')
		case "$BACKEND_USER" in
			npm) pass "backend runs as npm" ;;
			*) fail "backend runs as ${BACKEND_USER:-unknown} (expected npm)" ;;
		esac

		if docker exec "$PUID_C" test -f /data/keys.json; then
			KEYS_OWNER=$(docker exec "$PUID_C" stat -c '%u:%g' /data/keys.json)
			[ "$KEYS_OWNER" = '1000:1000' ] && pass "/data/keys.json owned by 1000:1000" \
				|| fail "/data/keys.json owned by ${KEYS_OWNER} (expected 1000:1000)"

			KEYS_MODE=$(docker exec "$PUID_C" stat -c '%a' /data/keys.json)
			[ "$KEYS_MODE" = '600' ] && pass "/data/keys.json mode 600" \
				|| fail "/data/keys.json mode ${KEYS_MODE} (expected 600)"
		else
			fail '/data/keys.json missing after healthy start'
		fi
	else
		fail "PUID container did not become healthy"
	fi

	section 'DISABLE_IPV6'
	IPV6_C=fulltest-ipv6
	IPV6_DATA=/tmp/npm-fulltest-ipv6/data
	IPV6_LE=/tmp/npm-fulltest-ipv6/letsencrypt
	reset_test_dir "$IPV6_DATA"
	reset_test_dir "$IPV6_LE"
	aux_start "$IPV6_C" \
		-e DISABLE_IPV6=true \
		-v "${IPV6_DATA}:/data" \
		-v "${IPV6_LE}:/etc/letsencrypt"
	if wait_healthy "$IPV6_C" 15; then
		DEFAULT_CONF=$(docker exec "$IPV6_C" cat /etc/nginx/conf.d/default.conf)
		echo "$DEFAULT_CONF" | grep -q '#listen \[::\]' \
			&& pass 'default.conf has commented listen [::]' \
			|| fail 'default.conf missing commented listen [::]'
		if echo "$DEFAULT_CONF" | grep -E '^[[:space:]]*listen \[::\]' >/dev/null 2>&1; then
			fail 'default.conf still has active listen [::] with DISABLE_IPV6=true'
		else
			pass 'default.conf has no active listen [::]'
		fi
	else
		fail "DISABLE_IPV6 container did not become healthy"
	fi

	section 'Certbot DNS plugin (on-demand install)'
	CERT_C=fulltest-certbot
	CERT_DATA=/tmp/npm-fulltest-certbot/data
	CERT_LE=/tmp/npm-fulltest-certbot/letsencrypt
	reset_test_dir "$CERT_DATA"
	reset_test_dir "$CERT_LE"
	aux_start "$CERT_C" \
		-e PUID=1000 \
		-e PGID=1000 \
		-v "${CERT_DATA}:/data" \
		-v "${CERT_LE}:/etc/letsencrypt"
	if wait_healthy "$CERT_C"; then
		docker exec -u 1000:1000 "$CERT_C" sh -c \
			'export CERTBOT_VERSION=$(certbot --version 2>&1 | grep -Eo "[0-9](\.[0-9]+)+"); node /app/scripts/install-certbot-plugins duckdns' \
			>/tmp/npm-fulltest-certbot-install.txt 2>&1 \
			&& pass 'install-certbot-plugins duckdns (uid 1000)' \
			|| fail "install-certbot-plugins duckdns ($(tail -3 /tmp/npm-fulltest-certbot-install.txt))"

		docker exec -u 1000:1000 "$CERT_C" certbot plugins 2>/dev/null | grep -q 'dns-duckdns' \
			&& pass 'certbot plugins lists dns-duckdns' \
			|| fail 'certbot plugins missing dns-duckdns'

		docker exec "$CERT_C" apk info -e build-base >/dev/null 2>&1 \
			&& pass 'compile deps (build-base) remain in image for musl DNS-plugin wheels' \
			|| fail 'build-base missing (required for non-root pip plugin installs on Alpine)'
	else
		fail "certbot container did not become healthy"
	fi

	section 'INITIAL_ADMIN env'
	INIT_C=fulltest-initial-admin
	INIT_DATA=/tmp/npm-fulltest-initial-admin/data
	INIT_LE=/tmp/npm-fulltest-initial-admin/letsencrypt
	reset_test_dir "$INIT_DATA"
	reset_test_dir "$INIT_LE"
	aux_start "$INIT_C" \
		-e INITIAL_ADMIN_EMAIL=initial@fulltest.local \
		-e INITIAL_ADMIN_PASSWORD=initialpass123 \
		-v "${INIT_DATA}:/data" \
		-v "${INIT_LE}:/etc/letsencrypt"
	if wait_healthy "$INIT_C"; then
		INIT_API=$(api_inside "$INIT_C" GET /api/)
		echo "$INIT_API" | grep -q '"setup":true' \
			&& pass 'GET /api/ setup=true with INITIAL_ADMIN env' \
			|| fail "GET /api/ expected setup=true ($(echo "$INIT_API" | head -c 120))"

		INIT_LOGIN=$(api_inside "$INIT_C" POST /api/tokens \
			'{"identity":"initial@fulltest.local","secret":"initialpass123"}')
		INIT_TOKEN=$(echo "$INIT_LOGIN" | jq -r '.token // empty' 2>/dev/null || true)
		if [ -n "$INIT_TOKEN" ] && [ "$INIT_TOKEN" != 'null' ]; then
			pass 'POST /api/tokens (INITIAL_ADMIN user)'
		else
			fail "POST /api/tokens INITIAL_ADMIN ($(echo "$INIT_LOGIN" | head -c 120))"
		fi
	else
		fail "INITIAL_ADMIN container did not become healthy"
	fi

	section 'DISABLE_RESOLVER'
	RES_C=fulltest-resolver
	RES_DATA=/tmp/npm-fulltest-resolver/data
	RES_LE=/tmp/npm-fulltest-resolver/letsencrypt
	reset_test_dir "$RES_DATA"
	reset_test_dir "$RES_LE"
	aux_start "$RES_C" \
		-e DISABLE_RESOLVER=true \
		-v "${RES_DATA}:/data" \
		-v "${RES_LE}:/etc/letsencrypt"
	if wait_healthy "$RES_C"; then
		if docker exec "$RES_C" test -f /etc/nginx/conf.d/include/resolvers.conf 2>/dev/null; then
			RES_CONTENT=$(docker exec "$RES_C" cat /etc/nginx/conf.d/include/resolvers.conf 2>/dev/null || true)
			if [ -z "$(echo "$RES_CONTENT" | tr -d '[:space:]')" ]; then
				pass 'resolvers.conf empty with DISABLE_RESOLVER=true'
			else
				fail "resolvers.conf not empty with DISABLE_RESOLVER=true"
			fi
		else
			pass 'resolvers.conf not created with DISABLE_RESOLVER=true'
		fi
	else
		fail "DISABLE_RESOLVER container did not become healthy"
	fi

	section 'SKIP_CERTBOT_OWNERSHIP'
	SKIP_C=fulltest-skip-certbot
	SKIP_DATA=/tmp/npm-fulltest-skip-certbot/data
	SKIP_LE=/tmp/npm-fulltest-skip-certbot/letsencrypt
	reset_test_dir "$SKIP_DATA"
	reset_test_dir "$SKIP_LE"
	aux_start "$SKIP_C" \
		-e SKIP_CERTBOT_OWNERSHIP=1 \
		-v "${SKIP_DATA}:/data" \
		-v "${SKIP_LE}:/etc/letsencrypt"
	if wait_healthy "$SKIP_C"; then
		SKIP_OWNER=$(docker exec "$SKIP_C" stat -c '%u:%g' /opt/certbot 2>/dev/null || echo '')
		[ "$SKIP_OWNER" = '0:0' ] && pass '/opt/certbot remains root-owned' \
			|| fail "/opt/certbot owner is ${SKIP_OWNER} (expected 0:0)"
	else
		fail "SKIP_CERTBOT_OWNERSHIP container did not become healthy"
	fi

	section 'Docker secrets __FILE'
	SEC_C=fulltest-secrets
	SEC_DATA=/tmp/npm-fulltest-secrets/data
	SEC_LE=/tmp/npm-fulltest-secrets/letsencrypt
	reset_test_dir "$SEC_DATA"
	reset_test_dir "$SEC_LE"
	docker run --rm -v "${SEC_DATA}:/target" alpine:3.24 \
		sh -c "printf 'fulltest-secret-value' > /target/secret.txt"
	SEC_FILE="${SEC_DATA}/secret.txt"
	aux_start "$SEC_C" \
		-e TEST_SECRET__FILE=/run/secrets/test_secret \
		-v "${SEC_DATA}:/data" \
		-v "${SEC_LE}:/etc/letsencrypt" \
		-v "${SEC_FILE}:/run/secrets/test_secret:ro"
	if wait_healthy "$SEC_C"; then
		SECRET_ENV=$(docker exec "$SEC_C" sh -c "tr '\\0' '\\n' < /proc/\$(pgrep -f '/app/index.js' | head -1)/environ 2>/dev/null | grep '^TEST_SECRET=' || true")
		echo "$SECRET_ENV" | grep -q 'TEST_SECRET=fulltest-secret-value' \
			&& pass 'TEST_SECRET loaded from __FILE env' \
			|| fail "TEST_SECRET not in backend environ (${SECRET_ENV:-missing})"
	else
		fail "secrets container did not become healthy"
	fi
fi

section 'Summary'
TOTAL=$((PASS + FAIL + SKIP))
printf '\nTOTAL: %s | PASS: %s | FAIL: %s | SKIP: %s\n' "$TOTAL" "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
