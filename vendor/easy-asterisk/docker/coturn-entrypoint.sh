#!/bin/sh
# ================================================================
# Robust coturn entrypoint
#
# The coturn/coturn Docker image's native entrypoint uses:
#   exec $(eval "echo $@")
# which is fragile — if DETECT_EXTERNAL_IP's DNS lookup returns empty,
# the eval produces an empty token → "ERROR: CONFIG: Unknown argument:"
#
# This wrapper reuses the image's detect-external-ip script but avoids
# the eval word-splitting issue. If detection fails, we simply omit
# --external-ip rather than passing a blank argument.
# ================================================================

# Use explicit PUBLIC_IP if provided, otherwise auto-detect
if [ -z "$PUBLIC_IP" ]; then
    PUBLIC_IP=$(detect-external-ip 2>/dev/null || true)
fi

# Only add --external-ip if we actually have an IP
EXTERNAL_IP_ARG=""
if [ -n "$PUBLIC_IP" ]; then
    EXTERNAL_IP_ARG="--external-ip=$PUBLIC_IP"
fi

exec turnserver "$@" $EXTERNAL_IP_ARG
