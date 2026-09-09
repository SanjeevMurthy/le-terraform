#!/usr/bin/env bash
# Build both container images and push them to Artifact Registry.
#
#   source scripts/env.sh
#   ./scripts/build-and-push.sh              # tag = current git short SHA
#   ./scripts/build-and-push.sh v1           # tag = v1
#
# Why the git SHA and not "latest": "latest" is a moving target. If two Pods
# start at different times they can silently run different code, and
# "kubectl rollout undo" has nothing to roll back to. An immutable tag makes
# every deployment traceable to one commit.

set -euo pipefail

: "${PROJECT_ID:?run: source scripts/env.sh}"
: "${IMAGE_REPO:?run: source scripts/env.sh}"

TAG="${1:-$(git rev-parse --short HEAD)}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "==> Building tag: ${TAG}"
echo "    api -> ${IMAGE_REPO}/api:${TAG}"
echo "    web -> ${IMAGE_REPO}/web:${TAG}"
echo

# --platform is not optional if you are on an Apple Silicon Mac. Without it
# you build arm64 images, push them happily, and then watch every Pod fail
# with "exec format error" on the amd64 nodes.
docker build --platform linux/amd64 -t "${IMAGE_REPO}/api:${TAG}" "${ROOT}/app/api"
docker build --platform linux/amd64 -t "${IMAGE_REPO}/web:${TAG}" "${ROOT}/app/web"

echo
echo "==> Pushing"
docker push "${IMAGE_REPO}/api:${TAG}"
docker push "${IMAGE_REPO}/web:${TAG}"

echo
echo "==> Done. Deploy with:"
echo "    ./scripts/deploy.sh ${TAG}"
