#!/usr/bin/env bash
# Bootstraps a shared local registry + two kind clusters (staging, prod).
# Idempotent: safe to re-run.
set -euo pipefail

REG_NAME='kind-registry'
REG_PORT='5001'
CLUSTERS=("staging" "prod")

# 1. Shared registry container
if [ "$(docker inspect -f '{{.State.Running}}' "${REG_NAME}" 2>/dev/null || true)" != 'true' ]; then
  echo ">> Creating registry ${REG_NAME} on :${REG_PORT}"
  docker run -d --restart=always -p "127.0.0.1:${REG_PORT}:5000" \
    --network bridge --name "${REG_NAME}" registry:2
else
  echo ">> Registry ${REG_NAME} already running"
fi

# 2. Clusters
for CLUSTER in "${CLUSTERS[@]}"; do
  if kind get clusters 2>/dev/null | grep -qx "${CLUSTER}"; then
    echo ">> Cluster ${CLUSTER} already exists"
  else
    echo ">> Creating cluster ${CLUSTER}"
    cat <<CFG | kind create cluster --name "${CLUSTER}" --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
containerdConfigPatches:
- |-
  [plugins."io.containerd.grpc.v1.cri".registry]
    config_path = "/etc/containerd/certs.d"
nodes:
- role: control-plane
CFG
  fi

  # 3. Point each node's containerd at the shared registry
  REG_DIR="/etc/containerd/certs.d/localhost:${REG_PORT}"
  for NODE in $(kind get nodes --name "${CLUSTER}"); do
    docker exec "${NODE}" mkdir -p "${REG_DIR}"
    cat <<HOSTS | docker exec -i "${NODE}" cp /dev/stdin "${REG_DIR}/hosts.toml"
[host."http://${REG_NAME}:5000"]
HOSTS
  done
done

# 4. Attach registry to kind network so nodes can resolve it
if [ "$(docker inspect -f='{{json .NetworkSettings.Networks.kind}}' "${REG_NAME}")" = 'null' ]; then
  echo ">> Connecting ${REG_NAME} to kind network"
  docker network connect "kind" "${REG_NAME}"
fi

echo ">> Done. Contexts:"
kubectl config get-contexts -o name | grep kind- || true
