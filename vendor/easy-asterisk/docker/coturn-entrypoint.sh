#!/bin/bash
# coturn-entrypoint.sh — robust wrapper for the coturn Docker image.
#
# The coturn image's default entrypoint uses:
#   exec $(eval "echo $@")
# which fails when detect-external-ip returns empty — produces a blank token
# and coturn logs "ERROR: CONFIG: Unknown argument:"
#
# This wrapper avoids eval word-splitting and only adds --external-ip when
# an IP is actually obtained.

set -e

# Use explicitly set PUBLIC_IP, or try auto-detection
ext_ip="${PUBLIC_IP:-}"
if [[ -z "$ext_ip" ]] && command -v detect-external-ip &>/dev/null; then
    ext_ip=$(detect-external-ip 2>/dev/null || true)
fi

if [[ -n "$ext_ip" ]]; then
    exec turnserver "$@" --external-ip="$ext_ip"
else
    exec turnserver "$@"
fi
