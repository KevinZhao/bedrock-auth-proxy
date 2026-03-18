#!/bin/bash
set -e
cd "$(dirname "$0")"

if [ -f proxy.pid ] && kill -0 "$(cat proxy.pid)" 2>/dev/null; then
    exit 0
fi

if [ ! -f bedrock-auth-proxy ]; then
    echo "ERROR: bedrock-auth-proxy binary not found. Download from:"
    echo "  https://github.com/KevinZhao/bedrock-auth-proxy/releases"
    exit 1
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
