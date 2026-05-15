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

## Security notes

- Runs as non-root (`USER nginx`); all runtime paths under `/tmp`
- `server_tokens off` — no nginx version in response headers
- Tokens never appear in access logs (access log format excludes auth headers)
- Supply-chain: single base image (`nginx:1.27-alpine`), pinned in the Dockerfile
