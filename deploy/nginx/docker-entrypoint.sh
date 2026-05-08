#!/bin/sh
set -eu

# ---------------------------------------------------------------------------
# Required
# ---------------------------------------------------------------------------
: "${UPSTREAM_ENDPOINT:?UPSTREAM_ENDPOINT is required (e.g. https://runway.internal.example.com/openai/bedrock_runtime)}"
: "${AUTH_HEADER_NAME:?AUTH_HEADER_NAME is required (e.g. token)}"

# AUTH_HEADER_NAME is substituted into the nginx config verbatim — reject any
# character that could inject additional directives (whitespace, newlines,
# braces, semicolons). RFC 7230 tokens: ALPHA / DIGIT / "-" are all we need.
case "$AUTH_HEADER_NAME" in
    *[!A-Za-z0-9-]*|"")
        echo "ERROR: AUTH_HEADER_NAME may only contain [A-Za-z0-9-] and must be non-empty" >&2
        exit 1
        ;;
esac

# ---------------------------------------------------------------------------
# Optional (with defaults)
# ---------------------------------------------------------------------------
LISTEN_PORT="${LISTEN_PORT:-8080}"
LOG_LEVEL="${LOG_LEVEL:-warn}"

# ---------------------------------------------------------------------------
# Parse UPSTREAM_ENDPOINT into scheme / host / port / base_path.
# Pure POSIX sh — no bashisms.
# ---------------------------------------------------------------------------
url="$UPSTREAM_ENDPOINT"

scheme="${url%%://*}"
case "$scheme" in
    http|https) ;;
    *) echo "ERROR: UPSTREAM_ENDPOINT must start with http:// or https://" >&2; exit 1 ;;
esac

rest="${url#*://}"
hostport="${rest%%/*}"
case "$rest" in
    */*) path="/${rest#*/}" ;;
    *)   path="" ;;
esac

host="${hostport%%:*}"
if [ "$hostport" = "$host" ]; then
    [ "$scheme" = "https" ] && port=443 || port=80
else
    port="${hostport##*:}"
fi
path="${path%/}"

# ---------------------------------------------------------------------------
# Resolve DNS servers at container start so `resolver` gets real IPs.
# Prefer explicit DNS_RESOLVER env var, otherwise parse /etc/resolv.conf.
# ---------------------------------------------------------------------------
if [ -z "${DNS_RESOLVER:-}" ]; then
    DNS_RESOLVER="$(awk '/^nameserver/ {printf "%s ", $2}' /etc/resolv.conf | sed 's/ *$//')"
    [ -z "$DNS_RESOLVER" ] && DNS_RESOLVER="1.1.1.1 8.8.8.8"
fi

export UPSTREAM_SCHEME="$scheme"
export UPSTREAM_HOST="$host"
export UPSTREAM_PORT="$port"
export UPSTREAM_BASE_PATH="$path"
export LISTEN_PORT LOG_LEVEL DNS_RESOLVER AUTH_HEADER_NAME

echo "[entrypoint] upstream scheme=$UPSTREAM_SCHEME host=$UPSTREAM_HOST port=$UPSTREAM_PORT base_path='$UPSTREAM_BASE_PATH'"
echo "[entrypoint] listen port=$LISTEN_PORT auth_header=<set,len=${#AUTH_HEADER_NAME}> log_level=$LOG_LEVEL dns='$DNS_RESOLVER'"

# ---------------------------------------------------------------------------
# Render both config files.
# nginx.conf needs LOG_LEVEL + DNS_RESOLVER; gateway.conf needs the rest.
# ---------------------------------------------------------------------------
envsubst '${LOG_LEVEL} ${DNS_RESOLVER}' \
    < /etc/nginx/nginx.conf > /tmp/nginx.conf
cat /tmp/nginx.conf > /etc/nginx/nginx.conf
rm -f /tmp/nginx.conf

envsubst '${LISTEN_PORT} ${UPSTREAM_HOST} ${UPSTREAM_PORT} ${UPSTREAM_SCHEME} ${UPSTREAM_BASE_PATH} ${AUTH_HEADER_NAME}' \
    < /etc/nginx/templates/gateway.conf.template > /etc/nginx/conf.d/gateway.conf

# ---------------------------------------------------------------------------
# Validate rendered config before starting.
# ---------------------------------------------------------------------------
nginx -t

exec "$@"
