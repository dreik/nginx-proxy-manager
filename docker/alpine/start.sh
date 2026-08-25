#!/bin/sh
set -eu

. /usr/bin/common.sh

cd /app || exit 1

log_info 'Starting nginx ...'
(
	while :; do
		su-exec "$PUID:$PGID" nginx || true
		sleep 1
	done
) &
nginx_pid=$!

log_info 'Starting backend ...'
(
	if [ "${DEVELOPMENT:-}" = 'true' ] && [ -f /app/node_modules/nodemon/bin/nodemon.js ]; then
		exec su-exec "$PUID:$PGID" sh -c \
			"export HOME=$NPMHOME; export CERTBOT_VERSION=$CERTBOT_VERSION; exec node --max_old_space_size=250 --abort_on_uncaught_exception /app/node_modules/nodemon/bin/nodemon.js"
	fi

	if [ "${DEVELOPMENT:-}" = 'true' ]; then
		log_info 'DEVELOPMENT=true but nodemon not found, using node restart loop'
	fi

	while :; do
		su-exec "$PUID:$PGID" sh -c \
			"export HOME=$NPMHOME; export CERTBOT_VERSION=$CERTBOT_VERSION; exec node --abort_on_uncaught_exception --max_old_space_size=250 /app/index.js" || true
		sleep 1
	done
) &
backend_pid=$!

term_handler() {
	log_info 'Shutting down ...'
	kill -TERM "$nginx_pid" "$backend_pid" 2>/dev/null || true
	wait "$nginx_pid" 2>/dev/null || true
	wait "$backend_pid" 2>/dev/null || true
	exit 0
}

trap term_handler INT TERM

while kill -0 "$nginx_pid" 2>/dev/null && kill -0 "$backend_pid" 2>/dev/null; do
	sleep 2
done

wait "$nginx_pid" 2>/dev/null || true
wait "$backend_pid" 2>/dev/null || true
exit 1
