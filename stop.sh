#!/bin/bash
set -e
cd "$(dirname "$0")"

if [ -f proxy.pid ]; then
    kill "$(cat proxy.pid)" 2>/dev/null || true
    rm -f proxy.pid
fi
