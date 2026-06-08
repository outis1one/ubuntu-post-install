# ================================================================
# Easy Asterisk - Docker Container
# Asterisk PBX with web admin and optional STUN support
#
# Usage:
#   docker compose up -d                    # Asterisk only
#   docker compose --profile stun up -d     # Asterisk + self-hosted STUN
#   docker exec -it easy-asterisk easy-asterisk  # Interactive management
#   docker exec -it easy-asterisk vpn-diagnostics # VPN diagnostics
#   docker exec -it easy-asterisk dns-whitelist   # DNS whitelist check
# ================================================================

FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8

# Install Asterisk and all dependencies (matches install_asterisk_packages)
RUN echo "exit 101" > /usr/sbin/policy-rc.d && chmod +x /usr/sbin/policy-rc.d && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        asterisk \
        asterisk-core-sounds-en-gsm \
        asterisk-modules \
        ca-certificates \
        openssl \
        curl \
        wget \
        tcpdump \
        sngrep \
        python3 \
        iproute2 \
        net-tools \
        dnsutils \
        iputils-ping \
        procps \
        lsof \
    && rm -rf /var/lib/apt/lists/* \
    && rm -f /usr/sbin/policy-rc.d \
    && ldconfig \
    && update-ca-certificates 2>/dev/null || true

# NOTE: Opus transcoding (codec_opus.so) is NOT available on Ubuntu 24.04 due to
# a packaging bug (Launchpad #2044135). The Digium precompiled binary is ABI-incompatible.
# Opus pass-through (phone-to-phone) still works via res_format_attr_opus.so from
# asterisk-modules. Only Opus<->ulaw transcoding is missing, which is rarely needed
# since modern SIP phones all support the same codecs natively.

# Create required directories
RUN mkdir -p \
    /etc/easy-asterisk \
    /etc/asterisk/certs \
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

# Docker detection marker (used by is_docker() in the script)
RUN touch /.dockerenv

# Copy the main management script
COPY easy-asterisk-v0.10.0.sh /usr/local/bin/easy-asterisk
RUN chmod +x /usr/local/bin/easy-asterisk

# Copy diagnostic and utility scripts
COPY scripts/vpn-diagnostics.sh /usr/local/bin/vpn-diagnostics
COPY scripts/dns-whitelist.sh /usr/local/bin/dns-whitelist
RUN chmod +x /usr/local/bin/vpn-diagnostics /usr/local/bin/dns-whitelist

# Copy entrypoint
COPY docker/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# SIP signaling
EXPOSE 5060/udp
EXPOSE 5060/tcp
EXPOSE 5061/tcp

# Web admin + provisioning
EXPOSE 8080/tcp
EXPOSE 8088/tcp
EXPOSE 8089/tcp

# STUN (if running coturn in same container; default 3478, configurable via TURN_PORT)
EXPOSE 3478/udp

# RTP media range (use --network host in production for full range)
# Docker port-mapping 10000 ports is impractical; host networking recommended
EXPOSE 10000-10100/udp

# Persistent data
VOLUME ["/etc/asterisk", "/etc/easy-asterisk", "/var/log/asterisk"]

HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
    CMD asterisk -rx "core show version" >/dev/null 2>&1 || exit 1

ENTRYPOINT ["/entrypoint.sh"]
