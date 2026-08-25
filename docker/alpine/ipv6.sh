#!/bin/sh
# Toggle listen [::] in existing nginx configs (parity with s6 prepare/50-ipv6.sh).
set -eu

. /usr/bin/common.sh

log_info 'IPv6 ...'

process_folder() {
	_folder="$1"
	[ -d "$_folder" ] || return 0

	if [ "$(is_true "${DISABLE_IPV6:-}")" = '1' ]; then
		_sed_regex='s/^([^#]*)listen \[::\]/\1#listen [::]/g'
	else
		_sed_regex='s/^(\s*)#listen \[::\]/\1listen [::]/g'
	fi

	find "$_folder" -type f -name '*.conf' | while read -r _file; do
		if is_mounted "$_file"; then
			echo "WARNING: skipping ${_file} — mounted file" >&2
			continue
		fi
		_tmpfile="${_file}.tmp"
		if sed -E "$_sed_regex" "$_file" > "$_tmpfile" && [ -s "$_tmpfile" ]; then
			mv "$_tmpfile" "$_file"
		else
			echo "WARNING: skipping ${_file} — sed produced empty output" >&2
			rm -f "$_tmpfile"
		fi
	done

	if [ -d "$_folder" ]; then
		chown -R "$PUID:$PGID" "$_folder" 2>/dev/null || true
	fi
}

process_folder /etc/nginx/conf.d
process_folder /data/nginx
