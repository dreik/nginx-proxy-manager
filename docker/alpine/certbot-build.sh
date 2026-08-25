#!/bin/sh
# Build /opt/certbot venv in a dedicated builder stage.
# pip stays in the venv; certbot-runtime.sh bakes musl compile deps into the final image
# so the npm user can install DNS plugins at runtime without root apk.
set -eu

CERTBOT_VERSION="${CERTBOT_VERSION:-}"

apk add --no-cache python3 py3-pip

python3 -m venv /opt/certbot
/opt/certbot/bin/pip install --no-cache-dir --upgrade pip

if [ -n "$CERTBOT_VERSION" ]; then
	/opt/certbot/bin/pip install --no-cache-dir "certbot==${CERTBOT_VERSION}" cryptography
else
	/opt/certbot/bin/pip install --no-cache-dir certbot cryptography
fi

sed -i 's/include-system-site-packages = false/include-system-site-packages = true/' /opt/certbot/pyvenv.cfg

# Drop bytecode caches from certbot packages
find /opt/certbot -type d -name '__pycache__' -exec rm -rf {} + 2>/dev/null || true
find /opt/certbot -type f -name '*.pyc' -delete 2>/dev/null || true

apk del py3-pip 2>/dev/null || true
rm -rf /root/.cache /var/cache/apk/*

echo ">>> certbot venv built ($( /opt/certbot/bin/certbot --version 2>&1 ))"
