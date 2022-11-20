FROM docker.io/library/debian:bookworm-slim

RUN set -x \
 && apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates lighttpd curl jq coreutils bash \ 
 && rm -rf /var/lib/apt/lists/* \
 && mkdir -p /srv

COPY *.sh /srv
COPY lighttpd.conf /etc/lighttpd/lighttpd.conf
CMD ["/usr/sbin/lighttpd", "-f", "/etc/lighttpd/lighttpd.conf", "-D"]
