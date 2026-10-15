#!/usr/bin/env bash
# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# ==============================================================================
# GDC Air-Gapped PA Shared Keycloak IdP Installer (deploy.sh)
# ==============================================================================
# Deploys a shared Keycloak Identity Provider into a platform organization
# (default: 'gdchservices', namespace: 'pa-demo-keycloak') across its Management
# Plane (MP) and Control Plane (CP), registers DNS across CustomerExternalNetwork
# (PA) and InfraExternalNetwork (IO), configures Web TLS + Istio ingress gateways,
# and seeds a shared realm with PA/AO groups and users.
#
# All Kubernetes Secrets are generated with cryptographically random values at
# runtime via 'openssl rand' (or preserved if already present on the cluster) and
# applied directly via 'kubectl create secret generic'. No secret material is
# ever stored in Git or written into rendered manifest files on disk.
#
# Usage:
#   sudo ./deploy.sh [options]
#
# Options:
#   --org <name>                IdP host organization (default: gdchservices)
#   --tenant-org <name>         Target tenant organization for SAML summary (auto-detected)
#   --namespace <ns>            Namespace for Keycloak in CP/MP (default: pa-demo-keycloak)
#   --fqdn-prefix <prefix>      DNS FQDN prefix (default: pa-demo-keycloak)
#   --realm <realm>             Shared realm to seed (default: pa-demo)
#   --admin-password <pw>       Keycloak admin password (default: auto-generated random)
#   --demo-user-password <pw>   Password for seeded PA/AO users (default: auto-generated random)
#   --registry <reg>            Override container image registry (auto-detected from cluster)
#   --repository <repo>         Override container image repository (auto-detected from cluster)
#   --keycloak-tag <tag>        Override tag for keycloak image
#   --pgchecker-tag <tag>       Override tag for bundledidp-pgchecker image
#   --verify-saml               Run verify-saml-e2e.sh after deploy (and clean up test objects)
#   --dry-run                   Render manifests to /tmp/pa-keycloak-demo-rendered and exit (READ-ONLY)
#   -h, --help                  Show this help message
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATTERN_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
MANIFEST_DIR="${PATTERN_DIR}/manifests"
RENDER_DIR="/tmp/pa-keycloak-demo-rendered"
CA_BUNDLE="${CA_BUNDLE:-/etc/ssl/certs/ca-certificates.crt}"

IDP_ORG="gdchservices"
TENANT_ORG=""
NAMESPACE="pa-demo-keycloak"
FQDN_PREFIX="pa-demo-keycloak"
DEMO_REALM="pa-demo"
ADMIN_PASSWORD=""
DEMO_USER_PASSWORD=""
DOCKER_REGISTRY=""
DOCKER_REPOSITORY=""
KEYCLOAK_TAG=""
PGCHECKER_TAG=""
VERIFY_SAML="false"
DRY_RUN="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --org) IDP_ORG="$2"; shift 2 ;;
    --tenant-org) TENANT_ORG="$2"; shift 2 ;;
    --namespace) NAMESPACE="$2"; shift 2 ;;
    --fqdn-prefix) FQDN_PREFIX="$2"; shift 2 ;;
    --realm) DEMO_REALM="$2"; shift 2 ;;
    --admin-password) ADMIN_PASSWORD="$2"; shift 2 ;;
    --demo-user-password) DEMO_USER_PASSWORD="$2"; shift 2 ;;
    --registry) DOCKER_REGISTRY="$2"; shift 2 ;;
    --repository) DOCKER_REPOSITORY="$2"; shift 2 ;;
    --keycloak-tag) KEYCLOAK_TAG="$2"; shift 2 ;;
    --pgchecker-tag) PGCHECKER_TAG="$2"; shift 2 ;;
    --verify-saml) VERIFY_SAML="true"; shift ;;
    --dry-run) DRY_RUN="true"; shift ;;
    -h|--help)
      sed -n '16,46p' "${BASH_SOURCE[0]}"
      exit 0
      ;;
    *)
      echo "ERROR: Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

ROOT_KUBECONFIG="${ROOT_KUBECONFIG:-/root/release/root-admin/root-admin-kubeconfig}"
CP_KUBECONFIG="${CP_KUBECONFIG:-/root/release/org-admin/${IDP_ORG}-admin-kubeconfig}"
MP_KUBECONFIG="${MP_KUBECONFIG:-/root/release/org-admin/${IDP_ORG}-mgmt-kubeconfig}"

log()  { printf "\033[1;34m[pa-shared-idp]\033[0m %s\n" "$*"; }
ok()   { printf "\033[1;32m[OK]\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m[WARN]\033[0m %s\n" "$*"; }
err()  { printf "\033[1;31m[ERROR]\033[0m %s\n" "$*" >&2; }

random_secret() {
  openssl rand -base64 24 | tr -d '=+/\n' | cut -c1-24
}

# ------------------------------------------------------------------------------
# 1. Pre-flight & Auto-Discovery (Read-Only)
# ------------------------------------------------------------------------------
log "Checking kubeconfigs for org '${IDP_ORG}'..."
for kc in "${ROOT_KUBECONFIG}" "${CP_KUBECONFIG}" "${MP_KUBECONFIG}"; do
  if [[ ! -r "${kc}" ]]; then
    err "Cannot read kubeconfig '${kc}'. Ensure you are running with access to org-admin kubeconfigs."
    exit 1
  fi
done

if [[ -z "${TENANT_ORG}" ]]; then
  TENANT_ORG="$(kubectl --kubeconfig="${ROOT_KUBECONFIG}" get organizations.org.gdc.goog -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -vE "^(${IDP_ORG}|root-admin)$" | head -n1 || true)"
  [[ -z "${TENANT_ORG}" ]] && TENANT_ORG="tenant-org"
fi

log "Auto-discovering DNS suffix, global DNS suffix, and container image registry..."
DNS_SUFFIX="$(kubectl --kubeconfig="${MP_KUBECONFIG}" -n gpc-system get configmap dnssuffix -o jsonpath='{.data.dnsSuffix}' 2>/dev/null || true)"
if [[ -z "${DNS_SUFFIX}" ]]; then
  DNS_SUFFIX="$(kubectl --kubeconfig="${CP_KUBECONFIG}" -n gpc-system get dnszone -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
fi
if [[ -z "${DNS_SUFFIX}" ]]; then
  err "Could not auto-discover dnsSuffix from ${MP_KUBECONFIG} or ${CP_KUBECONFIG}."
  exit 1
fi

BASE_DOMAIN="$(echo "${DNS_SUFFIX}" | cut -d. -f3-)"
GLOBAL_DNS_SUFFIX="${IDP_ORG}.${BASE_DOMAIN}"

# Auto-detect registry, repository, and image tags from running platform pods on CP
KC_SYS_IMG="$(kubectl --kubeconfig="${CP_KUBECONFIG}" get pods -A -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{end}' 2>/dev/null | grep -E '/(managed-)?keycloak[^:]*:' | head -n1 || true)"
if [[ -n "${KC_SYS_IMG}" ]]; then
  DETECTED_REG="$(echo "${KC_SYS_IMG}" | cut -d/ -f1)"
  DETECTED_REPO="$(echo "${KC_SYS_IMG}" | cut -d: -f1 | cut -d/ -f2- | sed -E 's|/[^/]+$||')"
  DETECTED_KC_TAG="$(echo "${KC_SYS_IMG}" | cut -d: -f2)"
  [[ -z "${DOCKER_REGISTRY}" ]] && DOCKER_REGISTRY="${DETECTED_REG}"
  [[ -z "${DOCKER_REPOSITORY}" ]] && DOCKER_REPOSITORY="${DETECTED_REPO}"
  [[ -z "${KEYCLOAK_TAG}" ]] && KEYCLOAK_TAG="${DETECTED_KC_TAG}"
fi

PG_POD_IMG="$(kubectl --kubeconfig="${CP_KUBECONFIG}" get pods -A -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{range .spec.initContainers[*]}{.image}{"\n"}{end}{end}' 2>/dev/null | grep 'bundledidp-pgchecker:' | head -n1 || true)"
if [[ -n "${PG_POD_IMG}" ]]; then
  [[ -z "${DOCKER_REGISTRY}" ]] && DOCKER_REGISTRY="$(echo "${PG_POD_IMG}" | cut -d/ -f1)"
  [[ -z "${DOCKER_REPOSITORY}" ]] && DOCKER_REPOSITORY="$(echo "${PG_POD_IMG}" | cut -d: -f1 | cut -d/ -f2- | sed -E 's|/[^/]+$||')"
  [[ -z "${PGCHECKER_TAG}" ]] && PGCHECKER_TAG="${PG_POD_IMG##*:}"
fi

[[ -z "${DOCKER_REGISTRY}" ]] && DOCKER_REGISTRY="harbor.root-admin.${BASE_DOMAIN}"

# Fallback discovery via Harbor v2 search API if not running as pods yet
if [[ -z "${DOCKER_REPOSITORY}" || -z "${KEYCLOAK_TAG}" ]]; then
  SEARCH_JSON="$(curl -s --cacert "${CA_BUNDLE}" "https://${DOCKER_REGISTRY}/api/v2.0/search?q=keycloak" 2>/dev/null || true)"
  if [[ -z "${DOCKER_REPOSITORY}" ]]; then
    DOCKER_REPOSITORY="$(echo "${SEARCH_JSON}" | grep -oE '"repository_name":"[^"]+/keycloak"' | head -n1 | cut -d'"' -f4 | sed 's|/keycloak$||' || true)"
  fi
fi

[[ -z "${DOCKER_REPOSITORY}" ]] && DOCKER_REPOSITORY="gpc-system"
[[ -z "${PGCHECKER_TAG}" ]] && PGCHECKER_TAG="${KEYCLOAK_TAG:-latest}"
[[ -z "${KEYCLOAK_TAG}" ]] && KEYCLOAK_TAG="${PGCHECKER_TAG}"

ok "Discovered:"
echo "  - IDP_ORG           : ${IDP_ORG}"
echo "  - TENANT_ORG        : ${TENANT_ORG}"
echo "  - NAMESPACE         : ${NAMESPACE}"
echo "  - FQDN              : ${FQDN_PREFIX}.${DNS_SUFFIX}"
echo "  - GLOBAL_FQDN       : ${FQDN_PREFIX}.${GLOBAL_DNS_SUFFIX}"
echo "  - DOCKER_REGISTRY   : ${DOCKER_REGISTRY}"
echo "  - DOCKER_REPOSITORY : ${DOCKER_REPOSITORY}"
echo "  - KEYCLOAK_TAG      : ${KEYCLOAK_TAG}"
echo "  - PGCHECKER_TAG     : ${PGCHECKER_TAG}"

# ------------------------------------------------------------------------------
# 2. Render Manifest Templates (Zero Secrets in Rendered Files)
# ------------------------------------------------------------------------------
mkdir -p "${RENDER_DIR}"
log "Rendering manifests into ${RENDER_DIR}..."
for tpl in "${MANIFEST_DIR}"/*.yaml.tpl; do
  out="${RENDER_DIR}/$(basename "${tpl%.tpl}")"
  sed \
    -e "s|__NAMESPACE__|${NAMESPACE}|g" \
    -e "s|__FQDN_PREFIX__|${FQDN_PREFIX}|g" \
    -e "s|__DNS_SUFFIX__|${DNS_SUFFIX}|g" \
    -e "s|__GLOBAL_DNS_SUFFIX__|${GLOBAL_DNS_SUFFIX}|g" \
    -e "s|__DOCKER_REGISTRY__|${DOCKER_REGISTRY}|g" \
    -e "s|__DOCKER_REPOSITORY__|${DOCKER_REPOSITORY}|g" \
    -e "s|__KEYCLOAK_TAG__|${KEYCLOAK_TAG}|g" \
    -e "s|__PGCHECKER_TAG__|${PGCHECKER_TAG}|g" \
    -e "s|__DEMO_REALM__|${DEMO_REALM}|g" \
    "${tpl}" > "${out}"
done
ok "Rendered $(ls -1 "${RENDER_DIR}"/*.yaml | wc -l) manifest files in ${RENDER_DIR} (zero secrets written to disk)."

if [[ "${DRY_RUN}" == "true" ]]; then
  ok "Dry-run complete (zero cluster modifications performed). Inspect rendered manifests in: ${RENDER_DIR}"
  exit 0
fi

# ------------------------------------------------------------------------------
# 3. Create Namespaces & Runtime Kubernetes Secrets (MP & CP)
# ------------------------------------------------------------------------------
log "Stage 1: Creating namespaces and runtime Secrets on MP and CP..."
kubectl --kubeconfig="${CP_KUBECONFIG}" apply -f "${RENDER_DIR}/01-db-cp.yaml"
kubectl --kubeconfig="${MP_KUBECONFIG}" create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl --kubeconfig="${MP_KUBECONFIG}" apply -f -

# 3a. Database password (shared between MP DBCluster and CP Keycloak)
EXISTING_DB_PW="$(kubectl --kubeconfig="${CP_KUBECONFIG}" -n "${NAMESPACE}" get secret bundledidp-keycloak-database-pw -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || true)"
if [[ -z "${EXISTING_DB_PW}" ]]; then
  DB_PW="$(random_secret)"
else
  DB_PW="${EXISTING_DB_PW}"
fi

kubectl --kubeconfig="${CP_KUBECONFIG}" -n "${NAMESPACE}" create secret generic bundledidp-keycloak-database-pw \
  --from-literal=password="${DB_PW}" --dry-run=client -o yaml \
  | kubectl annotate --local -f - \
      iam.private.gdc.goog/pg-user-statefulset-name="keycloak-cp" \
      iam.private.gdc.goog/pg-user-statefulset-namespace="${NAMESPACE}" \
      iam.private.gdc.goog/pg-user-pod-manager-type="statefulset" \
      iam.private.gdc.goog/pg-dbcluster-name="keycloak-db" \
      lcm.private.gdc.goog/claim-by-force="true" -o yaml \
  | kubectl --kubeconfig="${CP_KUBECONFIG}" apply -f -

kubectl --kubeconfig="${MP_KUBECONFIG}" -n "${NAMESPACE}" create secret generic db-pw-keycloak-db \
  --from-literal=keycloak-db="${DB_PW}" --dry-run=client -o yaml \
  | kubectl annotate --local -f - lcm.private.gdc.goog/claim-by-force="true" -o yaml \
  | kubectl --kubeconfig="${MP_KUBECONFIG}" apply -f -

# 3b. Internal PKCS12 Keystore password on CP
if ! kubectl --kubeconfig="${CP_KUBECONFIG}" -n "${NAMESPACE}" get secret keycloak-cp-keystore-password >/dev/null 2>&1; then
  KEYSTORE_PW="$(random_secret)"
  kubectl --kubeconfig="${CP_KUBECONFIG}" -n "${NAMESPACE}" create secret generic keycloak-cp-keystore-password \
    --from-literal=password="${KEYSTORE_PW}" --dry-run=client -o yaml \
    | kubectl annotate --local -f - lcm.private.gdc.goog/claim-by-force="true" -o yaml \
    | kubectl --kubeconfig="${CP_KUBECONFIG}" apply -f -
fi

# 3c. Keycloak Admin password on CP
if [[ -n "${ADMIN_PASSWORD}" ]]; then
  kubectl --kubeconfig="${CP_KUBECONFIG}" -n "${NAMESPACE}" create secret generic bundledidp-local-admin-password \
    --from-literal=secret="${ADMIN_PASSWORD}" --dry-run=client -o yaml \
    | kubectl annotate --local -f - lcm.private.gdc.goog/claim-by-force="true" -o yaml \
    | kubectl --kubeconfig="${CP_KUBECONFIG}" apply -f -
elif ! kubectl --kubeconfig="${CP_KUBECONFIG}" -n "${NAMESPACE}" get secret bundledidp-local-admin-password >/dev/null 2>&1; then
  ADMIN_PW_GEN="$(random_secret)"
  kubectl --kubeconfig="${CP_KUBECONFIG}" -n "${NAMESPACE}" create secret generic bundledidp-local-admin-password \
    --from-literal=secret="${ADMIN_PW_GEN}" --dry-run=client -o yaml \
    | kubectl annotate --local -f - lcm.private.gdc.goog/claim-by-force="true" -o yaml \
    | kubectl --kubeconfig="${CP_KUBECONFIG}" apply -f -
fi

# 3d. Seeded PA/AO User password on CP
if [[ -n "${DEMO_USER_PASSWORD}" ]]; then
  kubectl --kubeconfig="${CP_KUBECONFIG}" -n "${NAMESPACE}" create secret generic bundledidp-initial-user-password \
    --from-literal=secret="${DEMO_USER_PASSWORD}" --dry-run=client -o yaml \
    | kubectl annotate --local -f - lcm.private.gdc.goog/claim-by-force="true" -o yaml \
    | kubectl --kubeconfig="${CP_KUBECONFIG}" apply -f -
elif ! kubectl --kubeconfig="${CP_KUBECONFIG}" -n "${NAMESPACE}" get secret bundledidp-initial-user-password >/dev/null 2>&1; then
  USER_PW_GEN="$(random_secret)"
  kubectl --kubeconfig="${CP_KUBECONFIG}" -n "${NAMESPACE}" create secret generic bundledidp-initial-user-password \
    --from-literal=secret="${USER_PW_GEN}" --dry-run=client -o yaml \
    | kubectl annotate --local -f - lcm.private.gdc.goog/claim-by-force="true" -o yaml \
    | kubectl --kubeconfig="${CP_KUBECONFIG}" apply -f -
fi

# ------------------------------------------------------------------------------
# 4. Apply PostgreSQL DBCluster (MP)
# ------------------------------------------------------------------------------
EXISTING_DB_PHASE="$(kubectl --kubeconfig="${MP_KUBECONFIG}" -n "${NAMESPACE}" get dbclusters.postgresql.dbadmin.gdc.goog keycloak-db -o jsonpath='{.status.phase}' 2>/dev/null || true)"
if [[ "${EXISTING_DB_PHASE}" == "DBClusterReady" ]]; then
  ok "DBCluster 'keycloak-db' in '${NAMESPACE}' is already DBClusterReady; skipping DBCluster re-apply."
else
  kubectl --kubeconfig="${MP_KUBECONFIG}" apply -f "${RENDER_DIR}/02-db-mp.yaml"
fi

# ------------------------------------------------------------------------------
# 5. Apply Stage 2: PKI Web TLS Certificate & 4x DNSRegistration (MP)
# ------------------------------------------------------------------------------
log "Stage 2: Applying Web TLS Certificate and DNSRegistrations on MP..."
kubectl --kubeconfig="${MP_KUBECONFIG}" apply -f "${RENDER_DIR}/03-dns-cert-mp.yaml"

log "Waiting for PKI controller to forward Secret '${FQDN_PREFIX}-mp-web-tls' to istio-system on CP..."
for i in {1..60}; do
  if kubectl --kubeconfig="${CP_KUBECONFIG}" -n istio-system get secret "${FQDN_PREFIX}-mp-web-tls" >/dev/null 2>&1; then
    ok "Secret '${FQDN_PREFIX}-mp-web-tls' is present in istio-system on CP."
    break
  fi
  sleep 5
done

# ------------------------------------------------------------------------------
# 6. Wait for DBClusterReady & Apply Stage 3: Keycloak Server + Istio Routing (CP)
# ------------------------------------------------------------------------------
log "Waiting for DBCluster 'keycloak-db' on MP to reach DBClusterReady (takes ~3-5m on first run)..."
for i in {1..120}; do
  PHASE="$(kubectl --kubeconfig="${MP_KUBECONFIG}" -n "${NAMESPACE}" get dbclusters.postgresql.dbadmin.gdc.goog keycloak-db -o jsonpath='{.status.phase}' 2>/dev/null || echo "Pending")"
  if [[ "${PHASE}" == "DBClusterReady" ]] && kubectl --kubeconfig="${CP_KUBECONFIG}" -n "${NAMESPACE}" get svc pg-keycloak-db-ilb >/dev/null 2>&1; then
    ok "DBCluster 'keycloak-db' is Ready and Service 'pg-keycloak-db-ilb' is live on CP."
    break
  fi
  printf "  [%02d/120] DBCluster phase: %s ...\n" "${i}" "${PHASE:-Initializing}"
  sleep 10
done

log "Stage 3: Applying Keycloak StatefulSet, internal PKCS12 certs, and Istio Gateways/VirtualService on CP..."
kubectl --kubeconfig="${CP_KUBECONFIG}" apply -f "${RENDER_DIR}/04-keycloak-cp.yaml"

log "Waiting for internal Certificate 'keycloak-cp-keycloak-https' and StatefulSet 'keycloak-cp' to become Ready..."
kubectl --kubeconfig="${CP_KUBECONFIG}" -n "${NAMESPACE}" wait --for=condition=Ready certificate/keycloak-cp-keycloak-https --timeout=180s
kubectl --kubeconfig="${CP_KUBECONFIG}" -n "${NAMESPACE}" rollout status statefulset/keycloak-cp --timeout=600s
ok "Keycloak StatefulSet is Ready."

# ------------------------------------------------------------------------------
# 7. Apply Stage 4: Seed Shared Realm, PA/AO Groups & Users
# ------------------------------------------------------------------------------
log "Stage 4: Running Job 'keycloak-pa-demo-setup' to seed realm '${DEMO_REALM}' and PA/AO users/groups..."
kubectl --kubeconfig="${CP_KUBECONFIG}" -n "${NAMESPACE}" delete job keycloak-pa-demo-setup --ignore-not-found
kubectl --kubeconfig="${CP_KUBECONFIG}" apply -f "${RENDER_DIR}/05-demo-realm-job-cp.yaml"
kubectl --kubeconfig="${CP_KUBECONFIG}" -n "${NAMESPACE}" wait --for=condition=complete job/keycloak-pa-demo-setup --timeout=300s
ok "Realm '${DEMO_REALM}' and PA/AO users/groups seeded."

# ------------------------------------------------------------------------------
# 8. Print Deployment Summary (+ Optional E2E SAML Verification)
# ------------------------------------------------------------------------------
"${SCRIPT_DIR}/status.sh" --org "${IDP_ORG}" --tenant-org "${TENANT_ORG}" --namespace "${NAMESPACE}" --fqdn-prefix "${FQDN_PREFIX}" --realm "${DEMO_REALM}"

if [[ "${VERIFY_SAML}" == "true" ]]; then
  log "Running E2E SAML 2.0 Verification & Cleanup (verify-saml-e2e.sh)..."
  "${SCRIPT_DIR}/verify-saml-e2e.sh" --org "${IDP_ORG}" --tenant-org "${TENANT_ORG}" --namespace "${NAMESPACE}" --fqdn-prefix "${FQDN_PREFIX}" --realm "${DEMO_REALM}"
fi
