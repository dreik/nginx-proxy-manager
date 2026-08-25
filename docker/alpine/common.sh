#!/bin/sh
set -eu

CYAN='\033[1;36m'
BLUE='\033[1;34m'
RED='\033[1;31m'
RESET='\033[0m'

PUID=${PUID:-0}
PGID=${PGID:-0}
NPMUSER=npm
NPMGROUP=npm
NPMHOME=/tmp/npmuserhome
export PUID PGID NPMUSER NPMGROUP NPMHOME

CERTBOT_VERSION="$(certbot --version 2>/dev/null | grep -Eo '[0-9](\.[0-9]+)+' || echo unknown)"
export CERTBOT_VERSION

if [ "$PUID" -ne 0 ] && [ "$PGID" = 0 ]; then
	PGID=$PUID
fi

log_info() {
	printf "${BLUE}> ${CYAN}%s${RESET}\n" "$1"
}

log_fatal() {
	printf "${RED}--------------------------------------${RESET}\n"
	printf "${RED}ERROR: %s${RESET}\n" "$1"
	printf "${RED}--------------------------------------${RESET}\n"
	exit 1
}

get_group_id() {
	if [ -n "${1:-}" ]; then
		getent group "$1" | cut -d: -f3
	fi
}

is_true() {
	val=$(echo "${1:-}" | tr '[:upper:]' '[:lower:]')
	case "$val" in true|on|1|yes) echo 1 ;; *) echo 0 ;; esac
}

is_mounted() {
	awk -v p="$1" '$5 == p { found=1 } END { exit !found }' /proc/self/mountinfo
}
