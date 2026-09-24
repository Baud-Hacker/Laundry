FROM openresty/openresty:alpine

# Runtime libs for the FFI bindings, plus tooling for the entrypoint.
# The -dev packages provide the bare .so symlinks ffi.load prefers.
RUN apk add --no-cache \
      libsodium libsodium-dev \
      sqlite sqlite-libs sqlite-dev \
      openssl bash curl perl

# Application code.
COPY lua  /opt/laundry/lua
COPY db   /opt/laundry/db
COPY test /opt/laundry/test
COPY bin/laundry /usr/local/bin/laundry

# nginx / OpenResty config.
COPY nginx/nginx.conf /usr/local/openresty/nginx/conf/nginx.conf
COPY nginx/conf.d     /etc/nginx/conf.d

COPY docker/entrypoint.sh /entrypoint.sh
RUN chmod +x /usr/local/bin/laundry /entrypoint.sh \
    && mkdir -p /etc/laundry /etc/nginx/ssl /var/www/hidden /var/www/decoy /var/log/nginx \
    && rm -f /etc/nginx/conf.d/default.conf /usr/local/openresty/nginx/conf/conf.d/default.conf

EXPOSE 80 443
ENTRYPOINT ["/entrypoint.sh"]
