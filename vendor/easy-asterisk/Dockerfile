FROM ubuntu:24.04

ENV LANG=en_US.UTF-8 \
    LANGUAGE=en_US:en \
    LC_ALL=en_US.UTF-8 \
    DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    asterisk \
    asterisk-core-sounds-en \
    asterisk-core-sounds-en-wav \
    asterisk-moh-opsound-wav \
    tcpdump \
    sngrep \
    curl \
    dnsutils \
    iproute2 \
    net-tools \
    openssl \
    python3 \
    python3-pip \
    python3-bcrypt \
    locales \
    && locale-gen en_US.UTF-8 \
    && rm -rf /var/lib/apt/lists/*

# NOTE: Opus transcoding (codec_opus.so) is NOT available on Ubuntu 24.04
# due to a packaging bug. Opus pass-through still works via res_format_attr_opus.so.

RUN mkdir -p /etc/asterisk/certs \
             /var/lib/asterisk/static-http \
             /var/log/asterisk \
             /var/spool/asterisk \
             /var/run/asterisk \
    && chown -R asterisk:asterisk \
             /etc/asterisk \
             /var/lib/asterisk \
             /var/log/asterisk \
             /var/spool/asterisk \
             /var/run/asterisk

# Management script and helpers
COPY easy-asterisk-v0.10.0.sh /usr/local/bin/easy-asterisk
COPY scripts/vpn-diagnostics.sh /usr/local/bin/vpn-diagnostics
COPY scripts/dns-whitelist.sh /usr/local/bin/dns-whitelist
COPY docker/entrypoint.sh /entrypoint.sh
RUN chmod +x /usr/local/bin/easy-asterisk \
             /usr/local/bin/vpn-diagnostics \
             /usr/local/bin/dns-whitelist \
             /entrypoint.sh

EXPOSE 5060/udp 5060/tcp 5061/tcp
EXPOSE 8080/tcp 8088/tcp 8089/tcp
EXPOSE 3478/udp
EXPOSE 10000-10100/udp

HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
    CMD asterisk -rx "core show version" || exit 1

ENTRYPOINT ["/entrypoint.sh"]
