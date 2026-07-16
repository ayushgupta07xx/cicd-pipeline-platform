#!/usr/bin/env bash
# Adopts the existing platform resources into Terraform state.
#
# The namespaces, RBAC and token secrets were originally created with kubectl.
# Rather than destroy and recreate them, Terraform imports them — the same
# path a real migration takes when bringing existing infrastructure under IaC.
# A subsequent `terraform plan` proving "no changes" is the evidence that the
# code matches what is actually running.
set -euo pipefail
cd "$(dirname "$0")"

import_env () {
  local MOD="$1" NS="$2"
  echo ">> importing module.${MOD} (namespace ${NS})"
  terraform import -input=false "module.${MOD}.kubernetes_namespace.this"           "${NS}"                            2>&1 | tail -1
  terraform import -input=false "module.${MOD}.kubernetes_service_account.deployer" "${NS}/jenkins-deployer"           2>&1 | tail -1
  terraform import -input=false "module.${MOD}.kubernetes_role.deployer"            "${NS}/jenkins-deployer"           2>&1 | tail -1
  terraform import -input=false "module.${MOD}.kubernetes_role_binding.deployer"    "${NS}/jenkins-deployer"           2>&1 | tail -1
  terraform import -input=false "module.${MOD}.kubernetes_secret.deployer_token"    "${NS}/jenkins-deployer-token"     2>&1 | tail -1
}

import_env staging demo
import_env prod    demo

echo ">> done. Run: terraform plan"
