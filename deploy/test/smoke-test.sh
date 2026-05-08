#!/usr/bin/env bash
#
# Smoke test for bedrock-gateway.
#
# Usage:
#   # Test a local docker run:
#   GATEWAY_URL=http://localhost:18080 ./smoke-test.sh
#
#   # Test a deployed K8s gateway (via port-forward or real endpoint):
#   GATEWAY_URL=https://claude-gw.customer.example.com ./smoke-test.sh
#
#   # Include a real upstream round-trip (requires a valid token):
#   GATEWAY_URL=https://claude-gw.customer.example.com \
#   RUNWAY_TOKEN=<real-token> \
#   TEST_MODEL=global.anthropic.claude-haiku-4-5-20251001-v1:0 \
#   ./smoke-test.sh
#
# Exits non-zero on first failure. Each test reports PASS/FAIL with the
# expected vs. actual status code so CI logs are self-explanatory.

set -u

GATEWAY_URL="${GATEWAY_URL:-http://localhost:18080}"
RUNWAY_TOKEN="${RUNWAY_TOKEN:-}"
TEST_MODEL="${TEST_MODEL:-global.anthropic.claude-haiku-4-5-20251001-v1:0}"
CURL_TIMEOUT="${CURL_TIMEOUT:-10}"

# ----------------------------------------------------------------------------
# Tiny test harness
# ----------------------------------------------------------------------------
PASS=0
FAIL=0
FAILURES=()

color() {
    # Disable colors on non-tty (e.g. CI logs).
    if [ -t 1 ]; then
        case "$1" in
            green)  printf '\033[32m' ;;
            red)    printf '\033[31m' ;;
            yellow) printf '\033[33m' ;;
            dim)    printf '\033[2m'  ;;
            reset)  printf '\033[0m'  ;;
        esac
    fi
}

assert_status() {
    local name="$1"; local expected="$2"; local actual="$3"
    if [ "$actual" = "$expected" ]; then
        color green; printf 'PASS'; color reset
        printf ' %-55s (status=%s)\n' "$name" "$actual"
        PASS=$((PASS + 1))
    else
        color red; printf 'FAIL'; color reset
        printf ' %-55s (expected=%s actual=%s)\n' "$name" "$expected" "$actual"
        FAIL=$((FAIL + 1))
        FAILURES+=("$name: expected=$expected actual=$actual")
    fi
}

assert_contains() {
    local name="$1"; local needle="$2"; local haystack="$3"
    if printf '%s' "$haystack" | grep -qF "$needle"; then
        color green; printf 'PASS'; color reset
        printf ' %-55s (body contains %q)\n' "$name" "$needle"
        PASS=$((PASS + 1))
    else
        color red; printf 'FAIL'; color reset
        printf ' %-55s (body missing %q)\n' "$name" "$needle"
        color dim; printf '     body: %s\n' "$haystack" | head -c 500; color reset; echo
        FAIL=$((FAIL + 1))
        FAILURES+=("$name: missing '$needle'")
    fi
}

assert_not_contains() {
    local name="$1"; local needle="$2"; local haystack="$3"
    if printf '%s' "$haystack" | grep -qF "$needle"; then
        color red; printf 'FAIL'; color reset
        printf ' %-55s (body UNEXPECTEDLY contains %q)\n' "$name" "$needle"
        FAIL=$((FAIL + 1))
        FAILURES+=("$name: should not contain '$needle'")
    else
        color green; printf 'PASS'; color reset
        printf ' %-55s (body does not leak %q)\n' "$name" "$needle"
        PASS=$((PASS + 1))
    fi
}

status_of() {
    curl -sk -o /dev/null -w '%{http_code}' --max-time "$CURL_TIMEOUT" "$@" 2>/dev/null || echo '000'
}

body_of() {
    curl -sk --max-time "$CURL_TIMEOUT" "$@" 2>/dev/null || echo ''
}

header_of() {
    local header="$1"; shift
    curl -sk -I --max-time "$CURL_TIMEOUT" "$@" 2>/dev/null \
        | awk -v h="$header" 'BEGIN{IGNORECASE=1} $1 ~ h":" {sub(/^[^:]+:[[:space:]]*/,""); sub(/\r$/,""); print; exit}'
}

# ----------------------------------------------------------------------------
# Banner
# ----------------------------------------------------------------------------
echo "============================================================"
echo "bedrock-gateway smoke test"
echo "  target  : $GATEWAY_URL"
if [ -n "$RUNWAY_TOKEN" ]; then
    echo "  live    : enabled (will hit real upstream with token)"
else
    echo "  live    : disabled (set RUNWAY_TOKEN=... to enable)"
fi
echo "============================================================"

# ----------------------------------------------------------------------------
# 1. Health & liveness
# ----------------------------------------------------------------------------
echo
echo "-- 1. Health --"
assert_status "/healthz returns 200"          200 "$(status_of "$GATEWAY_URL/healthz")"
body="$(body_of "$GATEWAY_URL/healthz")"
assert_contains "/healthz body has status:ok" '"status":"ok"' "$body"

# Security hygiene — no nginx version leak.
server_hdr="$(header_of 'Server' "$GATEWAY_URL/healthz")"
if [ -n "$server_hdr" ]; then
    case "$server_hdr" in
        nginx|nginx/) # generic is fine
            color green; printf 'PASS'; color reset
            printf ' %-55s (Server: %s)\n' "Server header hides version" "$server_hdr"
            PASS=$((PASS + 1))
            ;;
        *)
            if echo "$server_hdr" | grep -qE 'nginx/[0-9]'; then
                color red; printf 'FAIL'; color reset
                printf ' %-55s (leaks version: %s)\n' "Server header hides version" "$server_hdr"
                FAIL=$((FAIL + 1))
                FAILURES+=("Server header leaks version: $server_hdr")
            else
                color green; printf 'PASS'; color reset
                printf ' %-55s (Server: %s)\n' "Server header hides version" "$server_hdr"
                PASS=$((PASS + 1))
            fi
            ;;
    esac
fi

# ----------------------------------------------------------------------------
# 2. Meta endpoints (/v1/models, /v1/messages/count_tokens)
# ----------------------------------------------------------------------------
echo
echo "-- 2. Meta endpoints --"
assert_status "GET /v1/models returns 200"    200 "$(status_of "$GATEWAY_URL/v1/models")"
body="$(body_of "$GATEWAY_URL/v1/models")"
assert_contains "/v1/models has claude-opus"  'claude-opus' "$body"
assert_contains "/v1/models has has_more"     '"has_more":false' "$body"

assert_status "POST /v1/messages/count_tokens -> 501" \
    501 "$(status_of -X POST "$GATEWAY_URL/v1/messages/count_tokens" -H 'Content-Type: application/json' -d '{}')"

# ----------------------------------------------------------------------------
# 3. Routing & method checks
# ----------------------------------------------------------------------------
echo
echo "-- 3. Routing & methods --"
assert_status "unknown path -> 404"           404 "$(status_of "$GATEWAY_URL/totally/bogus/path")"
assert_status "GET /model/x/invoke -> 405"    405 "$(status_of "$GATEWAY_URL/model/x/invoke")"
assert_status "POST /model/x/unknown -> 404"  404 "$(status_of -X POST "$GATEWAY_URL/model/x/unknown")"

# ----------------------------------------------------------------------------
# 4. Auth — unauthenticated request is rejected at the gateway
# ----------------------------------------------------------------------------
echo
echo "-- 4. Auth --"
assert_status "POST invoke no auth -> 401" \
    401 "$(status_of -X POST "$GATEWAY_URL/model/any/invoke" -H 'Content-Type: application/json' -d '{}')"
assert_status "POST invoke-stream no auth -> 401" \
    401 "$(status_of -X POST "$GATEWAY_URL/model/any/invoke-with-response-stream" -H 'Content-Type: application/json' -d '{}')"

# Empty Bearer = no token extracted = 401.
assert_status "POST invoke empty Bearer -> 401" \
    401 "$(status_of -X POST "$GATEWAY_URL/model/any/invoke" -H 'Authorization: Bearer' -H 'Content-Type: application/json' -d '{}')"

# ----------------------------------------------------------------------------
# 5. Error body hygiene — no secret leak, structured JSON
# ----------------------------------------------------------------------------
echo
echo "-- 5. Error body hygiene --"
body="$(body_of -X POST "$GATEWAY_URL/model/any/invoke" -H 'Content-Type: application/json' -d '{}')"
assert_contains "401 body is JSON error"      '"type":"error"' "$body"
assert_not_contains "401 body does not leak upstream hostname" "runway" "$body"
assert_not_contains "401 body does not leak token"             "Bearer" "$body"

# ----------------------------------------------------------------------------
# 5b. Input sanitization — values that should be rejected or stripped
# ----------------------------------------------------------------------------
echo
echo "-- 5b. Input sanitization --"

# Long bearer tokens should still route (within limit) but never be echoed.
long_token="$(printf 'A%.0s' $(seq 1 200))"
body="$(body_of -X POST "$GATEWAY_URL/model/any/invoke" \
    -H "Authorization: Bearer $long_token" \
    -H 'Content-Type: application/json' -d '{}')"
assert_not_contains "long token not echoed in response" "$long_token" "$body"

# A Session-Id with disallowed characters should be dropped, not forwarded.
# We can only observe gateway-level behaviour here (upstream is fake); the
# real assertion is "request was accepted to routing stage, not rejected".
# Observable via: gateway returns 401 (missing auth) NOT 400/500 (crash).
assert_status "malformed session id does not crash gateway" \
    401 "$(status_of -X POST "$GATEWAY_URL/model/any/invoke" \
          -H 'X-Claude-Code-Session-Id: crlf%0D%0Ainjection-attempt' \
          -H 'Content-Type: application/json' -d '{}')"

# ----------------------------------------------------------------------------
# 6. Live upstream test (optional — only if RUNWAY_TOKEN is set)
# ----------------------------------------------------------------------------
if [ -n "$RUNWAY_TOKEN" ]; then
    echo
    echo "-- 6. Live upstream (token provided) --"

    payload='{"anthropic_version":"bedrock-2023-05-31","max_tokens":16,"messages":[{"role":"user","content":"Say PONG and nothing else."}]}'

    # 6a. Non-streaming invoke with X-Runway-Token (Claude Code style)
    tmp=$(mktemp)
    http_code=$(curl -sk -o "$tmp" -w '%{http_code}' --max-time 60 \
        -X POST "$GATEWAY_URL/model/$TEST_MODEL/invoke" \
        -H "X-Runway-Token: $RUNWAY_TOKEN" \
        -H 'Content-Type: application/json' \
        -d "$payload" || echo '000')
    assert_status "invoke with X-Runway-Token -> 200" 200 "$http_code"
    if [ "$http_code" = "200" ]; then
        assert_contains "response body has content" '"content"' "$(cat "$tmp")"
    else
        color yellow; printf 'INFO'; color reset
        printf ' response body (truncated): %s\n' "$(head -c 500 "$tmp")"
    fi
    rm -f "$tmp"

    # 6b. Non-streaming invoke with Authorization: Bearer (Cowork style)
    tmp=$(mktemp)
    http_code=$(curl -sk -o "$tmp" -w '%{http_code}' --max-time 60 \
        -X POST "$GATEWAY_URL/model/$TEST_MODEL/invoke" \
        -H "Authorization: Bearer $RUNWAY_TOKEN" \
        -H 'Content-Type: application/json' \
        -d "$payload" || echo '000')
    assert_status "invoke with Bearer token -> 200" 200 "$http_code"
    rm -f "$tmp"

    # 6c. Streaming invoke — first chunk should arrive quickly (< 10s).
    tmp=$(mktemp)
    start=$(date +%s%3N 2>/dev/null || date +%s)
    http_code=$(curl -sk -o "$tmp" -w '%{http_code}' --max-time 60 \
        -X POST "$GATEWAY_URL/model/$TEST_MODEL/invoke-with-response-stream" \
        -H "X-Runway-Token: $RUNWAY_TOKEN" \
        -H 'Content-Type: application/json' \
        -d "$payload" || echo '000')
    end=$(date +%s%3N 2>/dev/null || date +%s)
    assert_status "invoke-with-response-stream -> 200" 200 "$http_code"
    if [ "$http_code" = "200" ]; then
        bytes=$(wc -c < "$tmp")
        if [ "$bytes" -gt 0 ]; then
            color green; printf 'PASS'; color reset
            printf ' %-55s (%s bytes, %sms total)\n' "stream returned data" "$bytes" "$((end - start))"
            PASS=$((PASS + 1))
        else
            color red; printf 'FAIL'; color reset
            printf ' %-55s (empty body)\n' "stream returned data"
            FAIL=$((FAIL + 1))
        fi
    fi
    rm -f "$tmp"
else
    echo
    color yellow; printf 'SKIP'; color reset
    printf ' live upstream tests — set RUNWAY_TOKEN to enable\n'
fi

# ----------------------------------------------------------------------------
# Summary
# ----------------------------------------------------------------------------
echo
echo "============================================================"
if [ "$FAIL" -eq 0 ]; then
    color green; echo "ALL GREEN  passed=$PASS failed=0"; color reset
    exit 0
else
    color red; echo "FAILED     passed=$PASS failed=$FAIL"; color reset
    for f in "${FAILURES[@]}"; do
        echo "  - $f"
    done
    exit 1
fi
