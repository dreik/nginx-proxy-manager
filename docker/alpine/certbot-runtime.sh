#!/bin/sh
# Runtime certbot wiring: python + compile deps for on-demand DNS plugins (non-root pip).
set -eu

apk add --no-cache \
	python3 \
	libffi \
	build-base \
	python3-dev \
	libffi-dev \
	openssl-dev \
	musl-dev

ln -sf /opt/certbot/bin/certbot /usr/bin/certbot

echo ">>> certbot $(certbot --version 2>&1)"
