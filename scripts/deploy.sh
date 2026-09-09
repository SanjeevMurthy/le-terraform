#!/usr/bin/env bash
# Render the Kubernetes manifests and apply them.
#
#   source scripts/env.sh
#   ./scripts/deploy.sh                 # deploy the current git short SHA
#   ./scripts/deploy.sh v1              # deploy a specific tag
#   RENDER_ONLY=1 ./scripts/deploy.sh   # print the rendered YAML, apply nothing
#   SKIP_INGRESS=1 ./scripts/deploy.sh  # skip the Ingress (the billable part)
#
# The manifests in k8s/ contain __PLACEHOLDERS__ instead of real image names,
# because an image tag changes on every commit and a project ID differs per
# person. Substituting at deploy time keeps the manifests in git generic and
# readable. (Kustomize or Helm do the same job with more features; this is the
# zero-dependency version so you can see exactly what is happening.)

set -euo pipefail

: "${PROJECT_ID:?run: source scripts/env.sh}"
: "${IMAGE_REPO:?run: source scripts/env.sh}"
: "${NAMESPACE:?run: source scripts/env.sh}"
: "${API_GSA_EMAIL:?run: source scripts/env.sh}"

TAG="${1:-$(git rev-parse --short HEAD)}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RENDER_DIR="$(mktemp -d)"
trap 'rm -rf "${RENDER_DIR}"' EXIT

for manifest in "${ROOT}"/k8s/*.yaml; do
  name="$(basename "${manifest}")"
  if [[ -n "${SKIP_INGRESS:-}" && "${name}" == *ingress* ]]; then
    echo "==> Skipping ${name} (SKIP_INGRESS set)"
    continue
  fi
  sed \
    -e "s|__API_IMAGE__|${IMAGE_REPO}/api:${TAG}|g" \
    -e "s|__WEB_IMAGE__|${IMAGE_REPO}/web:${TAG}|g" \
    -e "s|__GCP_PROJECT_ID__|${PROJECT_ID}|g" \
    -e "s|__API_GSA_EMAIL__|${API_GSA_EMAIL}|g" \
    -e "s|__APP_VERSION__|${TAG}|g" \
    "${manifest}" > "${RENDER_DIR}/${name}"
done

# Fail loudly rather than shipping a manifest with a literal "__API_IMAGE__"
# in it, which Kubernetes would accept and then fail to pull.
if grep -rq '__[A-Z_]*__' "${RENDER_DIR}"; then
  echo "ERROR: unsubstituted placeholders remain:" >&2
  grep -rn '__[A-Z_]*__' "${RENDER_DIR}" >&2
  exit 1
fi

if [[ -n "${RENDER_ONLY:-}" ]]; then
  # Separate each file with "---". kubectl apply -f DIR reads files one at a
  # time so it does not care, but a bare concatenation is not valid YAML and
  # would break anything you piped this into.
  for rendered in "${RENDER_DIR}"/*.yaml; do
    echo "---"
    echo "# source: k8s/$(basename "${rendered}")"
    cat "${rendered}"
  done
  exit 0
fi

echo "==> Applying tag ${TAG} to namespace ${NAMESPACE}"
kubectl apply -f "${RENDER_DIR}"

echo
echo "==> Waiting for rollouts"
kubectl rollout status deployment/api -n "${NAMESPACE}" --timeout=180s
kubectl rollout status deployment/web -n "${NAMESPACE}" --timeout=180s

echo
echo "==> Deployed. Current state:"
kubectl get pods,svc,ingress -n "${NAMESPACE}"
