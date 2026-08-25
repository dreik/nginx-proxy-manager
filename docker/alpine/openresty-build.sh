#!/bin/sh
# Build OpenResty for Alpine (version from OPENRESTY_VERSION / docker/alpine/versions.env).
# Source from GitHub tags; mirror-tarballs prepares the official bundle.
# JOBS=2 by default (same as docker-nginx-full).
set -eu

OPENRESTY_VERSION="${OPENRESTY_VERSION:?OPENRESTY_VERSION is required}"
GEOIP2_REF="${GEOIP2_REF:?GEOIP2_REF is required}"
USE_LTO="${USE_LTO:-0}"
JOBS="${JOBS:-2}"

echo ">>> [$(date -Iseconds)] Building OpenResty ${OPENRESTY_VERSION} (USE_LTO=${USE_LTO} JOBS=${JOBS} GEOIP2_REF=${GEOIP2_REF})"

apk add --no-cache \
	bash \
	build-base \
	ca-certificates \
	git \
	linux-headers \
	openssl-dev \
	pcre2-dev \
	zlib-dev \
	libmaxminddb-dev \
	wget \
	curl \
	perl \
	readline-dev \
	ncurses-dev \
	patch

CC_OPT="-O2"
LD_OPT=""
if [ "$USE_LTO" = "1" ]; then
	CC_OPT="${CC_OPT} -flto=auto"
	LD_OPT="-flto=auto"
fi

export CC="${CC:-gcc}"
export CXX="${CXX:-g++}"

cd /tmp

echo ">>> [$(date -Iseconds)] Downloading OpenResty source from GitHub"
curl -fsSL --retry 3 --connect-timeout 30 --max-time 300 \
	-o "openresty-${OPENRESTY_VERSION}-src.tar.gz" \
	"https://github.com/openresty/openresty/archive/refs/tags/v${OPENRESTY_VERSION}.tar.gz"

tar -xzf "openresty-${OPENRESTY_VERSION}-src.tar.gz"
mv "openresty-${OPENRESTY_VERSION}" /tmp/openresty-src

# openresty.org/download often stalls; nginx.org hosts the same nginx-$ver tarball.
sed -i 's|https://openresty.org/download/nginx-\$ver.tar.gz|https://nginx.org/download/nginx-\$ver.tar.gz|g' \
	/tmp/openresty-src/util/mirror-tarballs

# mirror-tarballs assumes docs/html exists before copying index pages
sed -i 's|cp \$root/html/index.html docs/html/|mkdir -p docs/html\ncp \$root/html/index.html docs/html/|' \
	/tmp/openresty-src/util/mirror-tarballs

echo ">>> [$(date -Iseconds)] Preparing bundle (mirror-tarballs via make)"
cd /tmp/openresty-src
make

echo ">>> [$(date -Iseconds)] Cloning geoip2 module @ ${GEOIP2_REF}"
git clone https://github.com/leev/ngx_http_geoip2_module.git /tmp/ngx_http_geoip2_module
git -C /tmp/ngx_http_geoip2_module checkout --detach "${GEOIP2_REF}"

cd "/tmp/openresty-src/openresty-${OPENRESTY_VERSION}"

echo ">>> [$(date -Iseconds)] Configuring OpenResty"
if [ -n "$LD_OPT" ]; then
	./configure \
		--prefix=/etc/nginx \
		--sbin-path=/usr/sbin/nginx \
		--modules-path=/usr/lib/nginx/modules \
		--conf-path=/etc/nginx/nginx.conf \
		--error-log-path=/var/log/nginx/error.log \
		--http-log-path=/var/log/nginx/access.log \
		--pid-path=/run/nginx/nginx.pid \
		--lock-path=/run/nginx/nginx.lock \
		--http-client-body-temp-path=/var/cache/nginx/client_temp \
		--http-proxy-temp-path=/var/cache/nginx/proxy_temp \
		--http-fastcgi-temp-path=/var/cache/nginx/fastcgi_temp \
		--http-uwsgi-temp-path=/var/cache/nginx/uwsgi_temp \
		--http-scgi-temp-path=/var/cache/nginx/scgi_temp \
		--user=nobody \
		--group=nobody \
		--with-compat \
		--with-threads \
		--with-http_addition_module \
		--with-http_auth_request_module \
		--with-http_dav_module \
		--with-http_flv_module \
		--with-http_gunzip_module \
		--with-http_gzip_static_module \
		--with-http_mp4_module \
		--with-http_random_index_module \
		--with-http_realip_module \
		--with-http_secure_link_module \
		--with-http_slice_module \
		--with-http_ssl_module \
		--with-http_stub_status_module \
		--with-http_sub_module \
		--with-http_v2_module \
		--with-mail \
		--with-mail_ssl_module \
		--with-stream \
		--with-stream_realip_module \
		--with-stream_ssl_module \
		--with-stream_ssl_preread_module \
		--with-http_v3_module \
		--add-dynamic-module=/tmp/ngx_http_geoip2_module \
		--with-cc-opt="${CC_OPT}" \
		--with-ld-opt="${LD_OPT}"
else
	./configure \
		--prefix=/etc/nginx \
		--sbin-path=/usr/sbin/nginx \
		--modules-path=/usr/lib/nginx/modules \
		--conf-path=/etc/nginx/nginx.conf \
		--error-log-path=/var/log/nginx/error.log \
		--http-log-path=/var/log/nginx/access.log \
		--pid-path=/run/nginx/nginx.pid \
		--lock-path=/run/nginx/nginx.lock \
		--http-client-body-temp-path=/var/cache/nginx/client_temp \
		--http-proxy-temp-path=/var/cache/nginx/proxy_temp \
		--http-fastcgi-temp-path=/var/cache/nginx/fastcgi_temp \
		--http-uwsgi-temp-path=/var/cache/nginx/uwsgi_temp \
		--http-scgi-temp-path=/var/cache/nginx/scgi_temp \
		--user=nobody \
		--group=nobody \
		--with-compat \
		--with-threads \
		--with-http_addition_module \
		--with-http_auth_request_module \
		--with-http_dav_module \
		--with-http_flv_module \
		--with-http_gunzip_module \
		--with-http_gzip_static_module \
		--with-http_mp4_module \
		--with-http_random_index_module \
		--with-http_realip_module \
		--with-http_secure_link_module \
		--with-http_slice_module \
		--with-http_ssl_module \
		--with-http_stub_status_module \
		--with-http_sub_module \
		--with-http_v2_module \
		--with-mail \
		--with-mail_ssl_module \
		--with-stream \
		--with-stream_realip_module \
		--with-stream_ssl_module \
		--with-stream_ssl_preread_module \
		--with-http_v3_module \
		--add-dynamic-module=/tmp/ngx_http_geoip2_module \
		--with-cc-opt="${CC_OPT}"
fi

echo ">>> [$(date -Iseconds)] Compiling OpenResty -j${JOBS}"
make -j"${JOBS}"
echo ">>> [$(date -Iseconds)] Installing OpenResty"
make install

echo ">>> [$(date -Iseconds)] Stripping binaries"
mkdir -p /usr/lib/nginx/modules /etc/nginx/modules
find /usr/lib/nginx/modules -name '*.so' -exec strip -s {} \; 2>/dev/null || true
strip -s /usr/sbin/nginx 2>/dev/null || true
find /etc/nginx -type f \( -name 'luajit' -o -name 'lua' -o -name '*.so' \) -exec strip -s {} \; 2>/dev/null || true

printf 'load_module /usr/lib/nginx/modules/ngx_http_geoip2_module.so;\n' \
	> /etc/nginx/modules/00-geoip2.conf

echo ">>> [$(date -Iseconds)] OpenResty build completed"
/usr/sbin/nginx -V
