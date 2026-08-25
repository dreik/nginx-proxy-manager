#!/bin/sh
set -eu

. /usr/bin/common.sh

if [ "$(id -u)" != '0' ]; then
	log_fatal "This docker container must be run as root, do not specify a user.
You can specify PUID and PGID env vars to run processes as that user and group after initialization."
fi

if [ "$(is_true "${DEBUG:-}")" = '1' ]; then
	set -x
fi

log_info "Configuring ${NPMUSER} user ..."
if id -u "$NPMUSER" >/dev/null 2>&1; then
	usermod -o -u "$PUID" "$NPMUSER"
else
	useradd -o -u "$PUID" -U -d "$NPMHOME" -s /sbin/nologin "$NPMUSER"
fi

log_info "Configuring ${NPMGROUP} group ..."
if [ "$(get_group_id "$NPMGROUP")" = '' ]; then
	groupadd -f -g "$PGID" "$NPMGROUP" 2>/dev/null || groupadd -o -g "$PGID" "$NPMGROUP"
else
	groupmod -o -g "$PGID" "$NPMGROUP"
fi

groupmod -o -g "$PGID" "$NPMGROUP"
if [ "$(get_group_id "$NPMGROUP")" != "$PGID" ]; then
	echo 'ERROR: Unable to set group id properly' >&2
	exit 1
fi

usermod -G "$PGID" "$NPMUSER"
if [ "$(id -g "$NPMUSER")" != "$PGID" ]; then
	echo 'ERROR: Unable to set group against the user properly' >&2
	exit 1
fi

mkdir -p "$NPMHOME"
chown -R "$PUID:$PGID" "$NPMHOME"

rm -f /etc/nginx/conf.d/dev.conf

log_info 'Checking paths ...'
if [ ! -d /data ]; then
	log_fatal '/data is not mounted! Check your docker configuration.'
fi
if [ ! -d /etc/letsencrypt ]; then
	log_fatal '/etc/letsencrypt is not mounted! Check your docker configuration.'
fi

mkdir -p \
	/data/nginx \
	/data/custom_ssl \
	/data/logs \
	/data/access \
	/data/nginx/default_host \
	/data/nginx/default_www \
	/data/nginx/proxy_host \
	/data/nginx/redirection_host \
	/data/nginx/stream \
	/data/nginx/dead_host \
	/data/nginx/temp \
	/data/letsencrypt-acme-challenge \
	/run/nginx \
	/tmp/nginx/body \
	/var/log/nginx \
	/var/lib/logrotate \
	/var/lib/nginx/cache/public \
	/var/lib/nginx/cache/private \
	/var/cache/nginx/proxy_temp \
	/usr/lib/nginx/modules

touch /var/log/nginx/error.log || true
chmod 777 /var/log/nginx/error.log || true
chmod -R 777 /var/cache/nginx || true
if [ -f /etc/logrotate.d/nginx-proxy-manager ]; then
	chmod 644 /etc/logrotate.d/nginx-proxy-manager
fi

log_info 'Admin Port ...'
NPM_ADMIN_PORT="${NPM_ADMIN_PORT:-81}"
case "$NPM_ADMIN_PORT" in
	*[!0-9]*)
		echo "WARNING: NPM_ADMIN_PORT must be a number. Defaulting to 81" >&2
		NPM_ADMIN_PORT=81
		;;
esac

PRODFILE="/etc/nginx/conf.d/production.conf"
if is_mounted "$PRODFILE"; then
	echo "WARNING: skipping ${PRODFILE} — mounted file" >&2
elif [ -f "${PRODFILE}.template" ]; then
	if sed -E "s/\\{\\{NPM_ADMIN_PORT\\}\\}/${NPM_ADMIN_PORT}/g" "${PRODFILE}.template" > "$PRODFILE" && [ -s "$PRODFILE" ]; then
		log_info "Generated ${PRODFILE} from template"
	else
		log_fatal "Failed to generate ${PRODFILE} from template"
	fi
fi

log_info 'Dynamic resolvers ...'
if [ "$(is_true "${DISABLE_RESOLVER:-}")" = '0' ]; then
	if [ "$(is_true "${DISABLE_IPV6:-}")" = '1' ]; then
		printf 'resolver %s ipv6=off valid=10s;\n' \
			"$(awk 'BEGIN{ORS=" "} $1=="nameserver" { sub(/%.*$/,"",$2); print ($2 ~ ":")? "["$2"]": $2}' /etc/resolv.conf)" \
			> /etc/nginx/conf.d/include/resolvers.conf
	else
		printf 'resolver %s valid=10s;\n' \
			"$(awk 'BEGIN{ORS=" "} $1=="nameserver" { sub(/%.*$/,"",$2); print ($2 ~ ":")? "["$2"]": $2}' /etc/resolv.conf)" \
			> /etc/nginx/conf.d/include/resolvers.conf
	fi
fi

/usr/local/bin/ipv6.sh

. /usr/local/bin/secrets.sh

log_info 'Setting ownership ...'

chown root /tmp/nginx

chownit() {
	dir="$1"
	recursive="${2:-true}"
	force="${3:-false}"

	if [ ! -e "$dir" ]; then
		return 0
	fi

	have="$(stat -c '%u:%g' "$dir")"
	echo "- $dir ... "

	if [ "$force" = 'true' ] || [ "$have" != "$PUID:$PGID" ]; then
		if [ "$recursive" = 'true' ] && [ -d "$dir" ]; then
			chown -R "$PUID:$PGID" "$dir"
		else
			chown "$PUID:$PGID" "$dir"
		fi
		echo '    DONE'
	else
		echo '    SKIPPED'
	fi
}

# Volume mounts may match PUID/PGID at the root while subdirs are still root-owned.
chownit /data true true
chownit /etc/letsencrypt true true

for loc in \
	/run/nginx \
	/tmp/nginx \
	/var/cache/nginx \
	/var/lib/logrotate \
	/var/lib/nginx \
	/var/log/nginx \
	/etc/nginx/nginx \
	/etc/nginx/nginx.conf \
	/etc/nginx/conf.d
do
	chownit "$loc"
done

# Ensure the JWT key file is owned by the runtime user, even when the /data
# directory ownership already matches PUID:PGID (chownit skips recursion then).
# Also tighten mode for pre-existing keys written as 0644 before the 0o600 fix.
if [ -f /data/keys.json ]; then
	chown "$PUID:$PGID" /data/keys.json
	chmod 600 /data/keys.json
fi

if [ "$(is_true "${SKIP_CERTBOT_OWNERSHIP:-}")" = '1' ]; then
	log_info 'Skipping ownership change of certbot directories'
else
	log_info 'Changing ownership of certbot directories, this may take some time ...'
	chownit /opt/certbot false
	chownit /opt/certbot/bin false

	find /opt/certbot/lib -type d -name site-packages 2>/dev/null | while read -r site_packages_dir; do
		chownit "$site_packages_dir"
	done
fi

printf '
-------------------------------------
 _   _ ____  __  __
| \\ | |  _ \\|  \\/  |
|  \\| | |_) | |\\/| |
| |\\  |  __/| |  | |
|_| \\_|_|   |_|  |_|
-------------------------------------
User:  %s PUID:%s ID:%s GROUP:%s
Group: %s PGID:%s ID:%s
-------------------------------------
' \
	"$NPMUSER" "$PUID" "$(id -u "$NPMUSER")" "$(id -g "$NPMUSER")" \
	"$NPMGROUP" "$PGID" "$(get_group_id "$NPMGROUP")"
