#!/bin/bash
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
cd "$SCRIPT_DIR"

# Load ALL env vars from ~/.claude/settings.json "env" section
_load_from_settings() {
    local settings="$HOME/.claude/settings.json"
    [ -f "$settings" ] || return 0
    # Strip JSONC comments, find "KEY": "VALUE" pairs inside env block
    local in_env=0
    while IFS= read -r line; do
        # Strip // comments
        line="${line%%//*}"
        if echo "$line" | grep -q '"env"'; then
            in_env=1; continue
        fi
        if [ "$in_env" = 1 ] && echo "$line" | grep -q '^[[:space:]]*}'; then
            break
        fi
        if [ "$in_env" = 1 ]; then
            local key val
            key=$(echo "$line" | sed -n 's/.*"\([^"]*\)"[[:space:]]*:.*/\1/p')
            val=$(echo "$line" | sed -n 's/.*:[[:space:]]*"\(.*\)".*/\1/p')
            if [ -n "$key" ] && [ -n "$val" ]; then
                # Don't override existing env vars
                if [ -z "${!key}" ]; then
                    export "$key=$val"
                fi
            fi
        fi
    done < "$settings"
}
_load_from_settings

if [ -f proxy.pid ] && kill -0 "$(cat proxy.pid)" 2>/dev/null; then
    echo "Proxy already running (PID: $(cat proxy.pid))"
    return 0 2>/dev/null || exit 0
fi

if [ ! -f bedrock-auth-proxy ]; then
    OS=$(uname -s | tr '[:upper:]' '[:lower:]')
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)  ARCH="amd64" ;;
        aarch64|arm64) ARCH="arm64" ;;
        *) echo "ERROR: Unsupported architecture: $ARCH"; return 1 2>/dev/null || exit 1 ;;
    esac
    SUFFIX=""
    [ "$OS" = "windows" ] && SUFFIX=".exe"
    URL="https://github.com/KevinZhao/bedrock-auth-proxy/releases/latest/download/bedrock-auth-proxy-${OS}-${ARCH}${SUFFIX}"
    echo "Downloading bedrock-auth-proxy from ${URL}..."
    curl -fSL -o bedrock-auth-proxy "$URL"
    chmod +x bedrock-auth-proxy
fi

./bedrock-auth-proxy >> proxy.log 2>&1 &
echo $! > proxy.pid

for i in $(seq 1 20); do
    if (echo > /dev/tcp/127.0.0.1/${PROXY_PORT:-8888}) 2>/dev/null; then
        echo "Proxy started (PID: $(cat proxy.pid))"
        return 0 2>/dev/null || exit 0
    fi
    sleep 0.25
done

echo "ERROR: Proxy failed to start. Check proxy.log"
kill "$(cat proxy.pid)" 2>/dev/null || true
rm -f proxy.pid
return 1 2>/dev/null || exit 1
