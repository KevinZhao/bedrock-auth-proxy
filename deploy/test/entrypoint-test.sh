#!/usr/bin/env bash
#
# Unit tests for the entrypoint script — runs the image with various bad
# configs and asserts it refuses to start. Meant for CI / post-build; does
# NOT need a running upstream.
#
# Usage:
#   IMAGE=bedrock-gateway:dev ./entrypoint-test.sh

set -u

IMAGE="${IMAGE:-bedrock-gateway:dev}"

PASS=0
FAIL=0

color() {
    if [ -t 1 ]; then
        case "$1" in
            green) printf '\033[32m' ;;
            red)   printf '\033[31m' ;;
            reset) printf '\033[0m'  ;;
        esac
    fi
}

# Returns the container exit code for a one-shot docker run.
run_and_exit_code() {
    docker run --rm "$@" "$IMAGE" nginx -t >/dev/null 2>&1
    echo $?
}

assert_exit() {
    local name="$1"; local expected_code_class="$2"; shift 2
    # expected_code_class: "zero" (must succeed) or "nonzero" (must fail)
    local actual=$(run_and_exit_code "$@")
    case "$expected_code_class" in
        zero)
            if [ "$actual" = "0" ]; then
                color green; printf 'PASS'; color reset
                printf ' %-55s (exit=0)\n' "$name"
                PASS=$((PASS + 1))
            else
                color red; printf 'FAIL'; color reset
                printf ' %-55s (expected 0, got %s)\n' "$name" "$actual"
                FAIL=$((FAIL + 1))
            fi
            ;;
        nonzero)
            if [ "$actual" != "0" ]; then
                color green; printf 'PASS'; color reset
                printf ' %-55s (exit=%s, refused to start)\n' "$name" "$actual"
                PASS=$((PASS + 1))
            else
                color red; printf 'FAIL'; color reset
                printf ' %-55s (expected failure, got exit=0)\n' "$name"
                FAIL=$((FAIL + 1))
            fi
            ;;
    esac
}

echo "============================================================"
echo "entrypoint config validation tests"
echo "  image : $IMAGE"
echo "============================================================"

echo
echo "-- Required vars --"
assert_exit "missing UPSTREAM_ENDPOINT refused" nonzero \
    -e AUTH_HEADER_NAME=token
assert_exit "missing AUTH_HEADER_NAME refused" nonzero \
    -e UPSTREAM_ENDPOINT=https://example.com

echo
echo "-- UPSTREAM_ENDPOINT format --"
assert_exit "non-http scheme refused (file://)" nonzero \
    -e UPSTREAM_ENDPOINT=file:///etc/passwd \
    -e AUTH_HEADER_NAME=token
assert_exit "no scheme refused" nonzero \
    -e UPSTREAM_ENDPOINT=example.com \
    -e AUTH_HEADER_NAME=token
assert_exit "valid https accepted" zero \
    -e UPSTREAM_ENDPOINT=https://example.com/base \
    -e AUTH_HEADER_NAME=token
assert_exit "valid http accepted" zero \
    -e UPSTREAM_ENDPOINT=http://example.com \
    -e AUTH_HEADER_NAME=token
assert_exit "explicit port accepted" zero \
    -e UPSTREAM_ENDPOINT=https://example.com:8443/foo \
    -e AUTH_HEADER_NAME=token

echo
echo "-- AUTH_HEADER_NAME validation (injection surface) --"
assert_exit "empty AUTH_HEADER_NAME refused" nonzero \
    -e UPSTREAM_ENDPOINT=https://example.com \
    -e AUTH_HEADER_NAME=''
assert_exit "AUTH_HEADER_NAME with space refused" nonzero \
    -e UPSTREAM_ENDPOINT=https://example.com \
    -e 'AUTH_HEADER_NAME=token foo'
assert_exit "AUTH_HEADER_NAME with semicolon refused" nonzero \
    -e UPSTREAM_ENDPOINT=https://example.com \
    -e 'AUTH_HEADER_NAME=token;evil'
assert_exit "AUTH_HEADER_NAME with newline refused" nonzero \
    -e UPSTREAM_ENDPOINT=https://example.com \
    -e "$(printf 'AUTH_HEADER_NAME=token\ninjected')"
assert_exit "AUTH_HEADER_NAME alnum+dash accepted" zero \
    -e UPSTREAM_ENDPOINT=https://example.com \
    -e 'AUTH_HEADER_NAME=X-Runway-Token'

echo
echo "-- UPSTREAM host/port/path injection surface --"
assert_exit "UPSTREAM host with semicolon refused" nonzero \
    -e 'UPSTREAM_ENDPOINT=https://evil;inject/' \
    -e AUTH_HEADER_NAME=token
assert_exit "UPSTREAM path with double-quote refused" nonzero \
    -e 'UPSTREAM_ENDPOINT=https://ok/path";add_header evil' \
    -e AUTH_HEADER_NAME=token
assert_exit "UPSTREAM path with brace refused" nonzero \
    -e 'UPSTREAM_ENDPOINT=https://ok/path}{injected' \
    -e AUTH_HEADER_NAME=token
assert_exit "UPSTREAM path with space refused" nonzero \
    -e 'UPSTREAM_ENDPOINT=https://ok/path with space' \
    -e AUTH_HEADER_NAME=token
assert_exit "UPSTREAM port non-numeric refused" nonzero \
    -e 'UPSTREAM_ENDPOINT=https://host:abc/' \
    -e AUTH_HEADER_NAME=token
assert_exit "LISTEN_PORT non-numeric refused" nonzero \
    -e UPSTREAM_ENDPOINT=https://ok/ \
    -e AUTH_HEADER_NAME=token \
    -e 'LISTEN_PORT=80;worker_processes 99'
assert_exit "LISTEN_PORT numeric accepted" zero \
    -e UPSTREAM_ENDPOINT=https://ok/ \
    -e AUTH_HEADER_NAME=token \
    -e LISTEN_PORT=9090
assert_exit "empty path (no trailing slash) accepted" zero \
    -e UPSTREAM_ENDPOINT=https://host.example \
    -e AUTH_HEADER_NAME=token
assert_exit "deep path with hyphen/underscore accepted" zero \
    -e UPSTREAM_ENDPOINT=https://host.example/a/b_c/d-e \
    -e AUTH_HEADER_NAME=token

echo
echo "============================================================"
if [ "$FAIL" -eq 0 ]; then
    color green; echo "ALL GREEN  passed=$PASS failed=0"; color reset
    exit 0
else
    color red; echo "FAILED     passed=$PASS failed=$FAIL"; color reset
    exit 1
fi
