#!/usr/bin/env bash
# Undoes setup-infra.sh by deleting the kind cluster: its node containers and everything in it
# (GPU Operator, traefik, workloads, the nodes' image caches) plus its kubeconfig entry.
# Kept: install-deps.sh tools, Docker's nvidia runtime config, and PVC data in ${STORAGE_DIR}.
# The model weights use a fixed folder (model-weights/, see deploy/overlays/local-kind) that the
# next cluster reuses; dynamic PVCs get new pvc-<uid> folders, delete old ones by hand.
# Safe to re-run: a missing cluster is skipped. Rebuild with setup-infra.sh.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

delete_cluster() {
  if ! cluster_exists; then log "Cluster ${CLUSTER_NAME} not found, skipping"; return; fi
  log "Deleting kind cluster ${CLUSTER_NAME}"
  kind delete cluster --name "${CLUSTER_NAME}"
}

main() {
  delete_cluster
  log "PVC data left in ${STORAGE_DIR}:"
  sudo ls -la "${STORAGE_DIR}" 2>/dev/null || echo "    (none)"
}

main "$@"
