#!/usr/bin/env bash
# Starts the Jenkins controller. Idempotent: re-run to recreate with fresh config.
set -euo pipefail
cd "$(dirname "$0")"

NAME=jenkins
HTTP_PORT="${JENKINS_HTTP_PORT:-8090}"   # host port; container always listens on 8080
ADMIN_PASS="${JENKINS_ADMIN_PASSWORD:-admin}"   # demo only; see docs/security.md
SHARED_LIB_REPO="${SHARED_LIB_REPO:-https://github.com/ayushgupta07xx/cicd-pipeline-shared-library.git}"

[ -f secrets/kubeconfig-staging.yaml ] || { echo "missing secrets/kubeconfig-staging.yaml"; exit 1; }
[ -f secrets/kubeconfig-prod.yaml ]    || { echo "missing secrets/kubeconfig-prod.yaml"; exit 1; }

docker rm -f "${NAME}" 2>/dev/null || true
docker volume create jenkins_home >/dev/null

docker run -d --name "${NAME}" --restart=unless-stopped \
  --network kind \
  -p "${HTTP_PORT}":8080 -p 50000:50000 \
  -v jenkins_home:/var/jenkins_home \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$PWD/casc.yaml:/var/jenkins_home/casc.yaml:ro" \
  -e CASC_JENKINS_CONFIG=/var/jenkins_home/casc.yaml \
  -e JENKINS_ADMIN_ID=admin \
  -e JENKINS_ADMIN_PASSWORD="${ADMIN_PASS}" \
  -e SHARED_LIB_REPO="${SHARED_LIB_REPO}" \
  -e JENKINS_URL_EXTERNAL="http://localhost:${HTTP_PORT}/" \
  -e KUBECONFIG_STAGING_B64="$(base64 -w0 secrets/kubeconfig-staging.yaml)" \
  -e KUBECONFIG_PROD_B64="$(base64 -w0 secrets/kubeconfig-prod.yaml)" \
  finacplus/jenkins:local >/dev/null

echo ">> ${NAME} starting on http://localhost:${HTTP_PORT} (admin / ${ADMIN_PASS})"
echo ">> waiting for readiness..."
for i in $(seq 1 60); do
  if curl -sf -o /dev/null "http://localhost:${HTTP_PORT}/login"; then echo ">> up after ${i}s"; exit 0; fi
  sleep 1
done
echo ">> TIMEOUT — check: docker logs ${NAME}"; exit 1
