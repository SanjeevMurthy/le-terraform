#!/usr/bin/env bash
# Hammer a short link so the HorizontalPodAutoscaler has something to react to.
#
#   ./scripts/loadgen.sh http://34.120.0.1/r/ab12cd3          # 60s, 20 workers
#   ./scripts/loadgen.sh http://34.120.0.1/r/ab12cd3 120 40   # 120s, 40 workers
#
# Runs from your laptop on purpose. Generating load from inside the cluster
# would compete with the very Pods you are trying to measure, and the nodes in
# this lab have no route to the public internet anyway.

set -euo pipefail

URL="${1:?usage: loadgen.sh URL [DURATION_SECONDS] [WORKERS]}"
DURATION="${2:-60}"
WORKERS="${3:-20}"

echo "==> ${WORKERS} workers hitting ${URL} for ${DURATION}s"
echo "    Watch it work in another terminal:"
echo "      kubectl get hpa api -n linkforge --watch"
echo

END=$(( $(date +%s) + DURATION ))
for _ in $(seq 1 "${WORKERS}"); do
  (
    while [[ $(date +%s) -lt ${END} ]]; do
      # -o /dev/null discards the body, -w prints nothing; we only care that
      # the request happened. Redirects are NOT followed: we are load testing
      # LinkForge, not whatever site the link points at.
      curl -s -o /dev/null "${URL}" || true
    done
  ) &
done
wait

echo "==> Load finished. Scale-down takes ~3 minutes (see the HPA's"
echo "    scaleDown.stabilizationWindowSeconds)."
