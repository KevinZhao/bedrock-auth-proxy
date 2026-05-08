IMAGE        ?= bedrock-gateway
TAG          ?= dev
PLATFORMS    ?= linux/amd64

# AWS Public ECR — override ECR_ALIAS to publish under a different registry.
ECR_ALIAS    ?= n3l4x8f3
ECR_REGISTRY ?= public.ecr.aws/$(ECR_ALIAS)
ECR_IMAGE    ?= $(ECR_REGISTRY)/$(IMAGE)

.PHONY: build run test test-entrypoint test-smoke push-ecr login-ecr clean

build:
	docker build -t $(IMAGE):$(TAG) .

# Start a container pointing at a fake upstream for local smoke testing.
# Use `make run` in one terminal, `make test-smoke` in another.
run:
	docker run --rm \
		-e UPSTREAM_ENDPOINT="https://runway.example.com/openai/bedrock_runtime" \
		-e AUTH_HEADER_NAME="token" \
		-p 18080:8080 \
		$(IMAGE):$(TAG)

# Full test suite — runs entrypoint validation and smoke test.
# Requires `make run` in a separate terminal (or a reachable GATEWAY_URL).
test: test-entrypoint test-smoke

# Entrypoint config validation — spawns containers with bad configs.
test-entrypoint:
	IMAGE=$(IMAGE):$(TAG) ./test/entrypoint-test.sh

# HTTP-level smoke test against a running gateway.
# Override GATEWAY_URL to point at a K8s deployment instead of localhost.
GATEWAY_URL ?= http://localhost:18080
test-smoke:
	GATEWAY_URL=$(GATEWAY_URL) ./test/smoke-test.sh

# Authenticate to AWS Public ECR (us-east-1 is the control plane for public registries).
login-ecr:
	@test -n "$(ECR_ALIAS)" || (echo "ERROR: set ECR_ALIAS first" >&2; exit 1)
	aws ecr-public get-login-password --region us-east-1 \
		| docker login --username AWS --password-stdin public.ecr.aws

# Build for the target platforms and push to Public ECR.
# Requires `docker buildx` and a builder that supports the target platforms.
# If you are building for a foreign arch, run this once on the host:
#   docker run --privileged --rm tonistiigi/binfmt --install <arch>
push-ecr: login-ecr
	@test -n "$(ECR_ALIAS)" || (echo "ERROR: set ECR_ALIAS first" >&2; exit 1)
	docker buildx build \
		--platform $(PLATFORMS) \
		-t $(ECR_IMAGE):$(TAG) \
		-t $(ECR_IMAGE):latest \
		--push \
		.

clean:
	-docker rmi $(IMAGE):$(TAG)
