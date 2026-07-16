#!/usr/bin/env bash
# Mints a kubeconfig authenticating as the least-privilege jenkins-deployer SA.
# Usage: ./gen-kubeconfig.sh <cluster-name> <namespace> <out-file>
set -euo pipefail
CLUSTER="$1"; NS="$2"; OUT="$3"
CTX="kind-${CLUSTER}"
SERVER="https://${CLUSTER}-control-plane:6443"   # reachable on the 'kind' docker network

TOKEN=$(kubectl --context "${CTX}" -n "${NS}" get secret jenkins-deployer-token \
          -o jsonpath='{.data.token}' | base64 -d)
CA=$(kubectl --context "${CTX}" -n "${NS}" get secret jenkins-deployer-token \
          -o jsonpath='{.data.ca\.crt}')

[ -n "${TOKEN}" ] || { echo "ERROR: empty token for ${CTX}"; exit 1; }

cat > "${OUT}" <<CFG
apiVersion: v1
kind: Config
clusters:
- name: ${CLUSTER}
  cluster:
    server: ${SERVER}
    certificate-authority-data: ${CA}
contexts:
- name: ${CLUSTER}
  context:
    cluster: ${CLUSTER}
    namespace: ${NS}
    user: jenkins-deployer
current-context: ${CLUSTER}
users:
- name: jenkins-deployer
  user:
    token: ${TOKEN}
CFG
chmod 600 "${OUT}"
echo ">> wrote ${OUT} (server=${SERVER}, sa=jenkins-deployer, ns=${NS})"
