#!/bin/sh
set -eu

. /usr/bin/common.sh

log_info 'Docker secrets ...'

for var in $(env | cut -d= -f1 | grep '__FILE$' || true); do
	echo "[secret-init] Evaluating ${var} ..."

	eval "secret_path=\${${var}:-}"
	if [ -n "$secret_path" ] && [ -f "$secret_path" ]; then
		base_var=$(echo "$var" | sed 's/__FILE$//')
		export "${base_var}=$(cat "$secret_path")"
		echo "Success: ${base_var} set from ${var}"
	else
		echo "Cannot find secret in ${var} (${secret_path:-empty})"
	fi
done
