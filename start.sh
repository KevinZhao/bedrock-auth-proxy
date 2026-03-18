#!/bin/bash
set -e
cd "$(dirname "$0")"

if [ -f proxy.pid ] && kill -0 "$(cat proxy.pid)" 2>/dev/null; then
    exit 0
fi

if [ ! -f bedrock-auth-proxy ]; then
    OS=$(uname -s | tr '[:upper:]' '[:lower:]')
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)  ARCH="amd64" ;;
        aarch64|arm64) ARCH="arm64" ;;
        *) echo "ERROR: Unsupported architecture: $ARCH"; exit 1 ;;
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
    if curl -sf http://127.0.0.1:${PROXY_PORT:-8888}/ > /dev/null 2>&1; then
        exit 0
    fi
    sleep 0.25
done

echo "ERROR: Proxy failed to start. Check proxy.log"
kill "$(cat proxy.pid)" 2>/dev/null || true
rm -f proxy.pid
exit 1
