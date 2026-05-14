# bedrock-gateway

Centralized nginx-based gateway that lets Claude Code and Claude Cowork talk to
a custom LLM backend (e.g. Runway) via Amazon Bedrock `InvokeModel` wire format.
Drop-in replacement for the per-user `bedrock-auth-proxy` Go binary, designed
for Kubernetes deployment in front of a shared upstream.

## What it does

```
Claude Code (Bedrock mode)      ─┐
Claude Cowork (Desktop, 3p)     ─┤──► bedrock-gateway (this image) ──► Runway
                                 │
                      per-user token (header)
```

For the full topology and request lifecycle diagrams see
[`docs/architecture.md`](docs/architecture.md).

1. Accepts `POST /model/<id>/invoke` and `POST /model/<id>/invoke-with-response-stream`
2. Strips AWS SigV4 headers (`Authorization`, `X-Amz-*`)
3. Extracts the caller's token from either header:
   - `X-Runway-Token: <token>` (Claude Code via `ANTHROPIC_CUSTOM_HEADERS`)
   - `Authorization: Bearer <token>` (Claude Cowork via `inferenceCredentialHelper`)
4. Injects it under a configurable header name (`AUTH_HEADER_NAME`)
5. Rewrites path to `<UPSTREAM_BASE_PATH>/model/invoke[-with-response-stream]`
   and forwards unbuffered for SSE / AWS event-stream

## Config — container environment

| Variable            | Required | Default | Purpose                                                                 |
| ------------------- | :------: | :-----: | ----------------------------------------------------------------------- |
| `UPSTREAM_ENDPOINT` |    ✓     |   —     | Full URL including scheme and base path, e.g. `https://runway.internal/openai/bedrock_runtime` |
| `AUTH_HEADER_NAME`  |    ✓     |   —     | Header name the upstream expects (e.g. `token`)                         |
| `LISTEN_PORT`       |          |  `8080` | HTTP listen port                                                        |
| `LOG_LEVEL`         |          |  `warn` | nginx error log level (`debug` / `info` / `warn` / `error`)             |
| `DNS_RESOLVER`      |          | auto    | Space-separated IPs; auto-detected from `/etc/resolv.conf` if empty     |

## Build

```
make build                     # local dev image
make run                       # run on :18080 with a fake upstream
make smoke                     # hit routes, assert status codes
```

## Publish to AWS Public ECR

```
make push-ecr TAG=v0.1.0                              # default: linux/amd64
make push-ecr TAG=v0.1.0 PLATFORMS=linux/amd64,linux/arm64   # multi-arch
```

Produces images at `public.ecr.aws/$ECR_ALIAS/bedrock-gateway:$TAG` (and `:latest`).
If building for an architecture different from your host, first install qemu:

```
docker run --privileged --rm tonistiigi/binfmt --install amd64
```

## Endpoints exposed

| Path                                  | Behavior                                                                     |
| ------------------------------------- | ---------------------------------------------------------------------------- |
| `GET  /healthz`                       | `200 {"status":"ok"}` — for K8s liveness/readiness                           |
| `GET  /v1/models`                     | `200` with a curated static model list (edit template to customize)          |
| `POST /v1/messages/count_tokens`      | `501 not_implemented` — clients fall back to local estimation                |
| `POST /model/<id>/invoke`             | Forwards to `<UPSTREAM_BASE_PATH>/model/invoke`                              |
| `POST /model/<id>/invoke-with-response-stream` | Forwards with streaming (`proxy_buffering off`)                     |
| everything else                       | `404 not_found`                                                              |

## Client configuration

### Claude Code (CLI)

```json
{
  "env": {
    "CLAUDE_CODE_USE_BEDROCK": "1",
    "CLAUDE_CODE_SKIP_BEDROCK_AUTH": "1",
    "ANTHROPIC_BEDROCK_BASE_URL": "https://claude-gw.<your-domain>",
    "ANTHROPIC_CUSTOM_HEADERS": "X-Runway-Token: <your-token>",
    "AWS_REGION": "ap-northeast-1",
    "ANTHROPIC_MODEL": "global.anthropic.claude-opus-4-6-v1[1m]"
  }
}
```

### Claude Cowork (Desktop, MDM)

Push a managed-preferences profile (macOS `.mobileconfig` or Windows registry)
with these keys:

```
inferenceProvider            = "bedrock"
inferenceBedrockBaseUrl      = "https://claude-gw.<your-domain>"
inferenceCredentialHelper    = "/usr/local/bin/runway-token.sh"
inferenceModels              = [ "global.anthropic.claude-opus-4-6-v1", ... ]
```

`runway-token.sh` prints the user's token to stdout. See
<https://claude.com/docs/cowork/3p/configuration> for the full MDM schema.

## Kubernetes

This image listens on plain HTTP. TLS termination belongs in the layer in front
(Ingress, ALB, NLB-with-ACM). K8s manifests live at `../k8s/` (forthcoming).

## Diagnostics

Access log is a single-line JSON record per request, written to stdout. Useful
fields when triaging streaming / fallback issues:

| Field                     | Meaning                                                                            |
| ------------------------- | ---------------------------------------------------------------------------------- |
| `request_id`              | nginx-generated id; forwarded as `X-Request-Id` to upstream — use to correlate logs |
| `is_stream`               | `"1"` = `/invoke-with-response-stream`; `"0"` = unary `/invoke` or other path       |
| `auth_present`            | `"1"` = a token header was extracted; `"0"` = client misconfig (caused the 401)     |
| `req_ms`                  | Total wall-clock time client → nginx → upstream → client                            |
| `upstream_connect_ms`     | TCP+TLS handshake to upstream                                                      |
| `upstream_header_ms`      | First-byte latency from upstream (≈ time-to-first-token for streaming)             |
| `upstream_ms`             | Time until upstream finished sending body (= stream close time when streaming)     |
| `upstream_bytes_received` | Bytes nginx read from upstream — for truncated streams, the actual payload size   |
| `request_completion`      | `"OK"` = full body delivered; `""` = aborted (client dropped or upstream RST)       |
| `connection`              | nginx TCP connection serial; pair with `connection_requests` to find the same conn |

### Triaging the streaming → non-streaming fallback (Claude Code)

If a Claude Code client reports `Error streaming, falling back to non-streaming
mode`, find the matching access-log record:

```bash
kubectl logs <gateway-pod> --since=10m \
  | jq 'select(.is_stream=="1") | select(.req_ms | tonumber > 10)'
```

Common signatures:

| Symptom in access log                                                  | Likely cause                                |
| ---------------------------------------------------------------------- | ------------------------------------------- |
| `req_ms ≈ 25`, `request_completion=""`, `upstream_bytes_received` >0   | Upstream RST mid-stream (idle-timeout cut)  |
| `req_ms ≈ 25`, `upstream_status="504"`                                 | Upstream gateway timeout                    |
| `req_ms ≈ 25`, `upstream_status="200"`, `upstream_bytes_received` <500 | Upstream returned 200 but empty body        |
| `upstream_status="499"`                                                | Client gave up first (Claude Code watchdog) |

When a fixed `req_ms` value (e.g. ~25s) repeats across many requests, that
value is the *upstream* idle timeout — not anything in this image. The fix
must happen on the upstream side.

If you also need errno-level detail (`recv() failed`, `upstream prematurely
closed connection`), set `LOG_LEVEL=info` in the Deployment env. Volume is
modest at info; do not use `debug` outside one-off investigations.

## Security notes

- Runs as non-root (`USER nginx`); all runtime paths under `/tmp`
- `server_tokens off` — no nginx version in response headers
- Tokens never appear in access logs (access log format excludes auth headers)
- Supply-chain: single base image (`nginx:1.27-alpine`), pinned in the Dockerfile
