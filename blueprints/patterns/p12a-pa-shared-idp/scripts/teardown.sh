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
# GDC Air-Gapped PA Shared Keycloak IdP Teardown (teardown.sh)
# ==============================================================================
# Cleanly removes the PA Shared Keycloak IdP resources from CP and MP.
# By default, preserves the DBCluster ('keycloak-db') so re-deploying is fast
# (~30s instead of ~8m). Pass --delete-db to also delete the PostgreSQL
# DBCluster and namespace.
# ==============================================================================

set -euo pipefail

IDP_ORG="gdchservices"
NAMESPACE="pa-demo-keycloak"
FQDN_PREFIX="pa-demo-keycloak"
DELETE_DB="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --org) IDP_ORG="$2"; shift 2 ;;
    --namespace) NAMESPACE="$2"; shift 2 ;;
    --fqdn-prefix) FQDN_PREFIX="$2"; shift 2 ;;
    --delete-db) DELETE_DB="true"; shift ;;
    *) shift ;;
  esac
done

CP_KUBECONFIG="${CP_KUBECONFIG:-/root/release/org-admin/${IDP_ORG}-admin-kubeconfig}"
MP_KUBECONFIG="${MP_KUBECONFIG:-/root/release/org-admin/${IDP_ORG}-mgmt-kubeconfig}"

echo "[pa-shared-idp] Removing Keycloak setup Job, VirtualService, Gateways, DestinationRule, and StatefulSet on CP (namespace: ${NAMESPACE})..."
kubectl --kubeconfig="${CP_KUBECONFIG}" -n "${NAMESPACE}" delete job keycloak-pa-demo-setup --ignore-not-found
kubectl --kubeconfig="${CP_KUBECONFIG}" -n "${NAMESPACE}" delete virtualservice keycloak-cp-virtualservice --ignore-not-found
kubectl --kubeconfig="${CP_KUBECONFIG}" -n "${NAMESPACE}" delete gateway keycloak-cp-gateway keycloak-cp-customer-gateway --ignore-not-found
kubectl --kubeconfig="${CP_KUBECONFIG}" -n "${NAMESPACE}" delete destinationrule keycloak-cp-headless-destination-rule --ignore-not-found
kubectl --kubeconfig="${CP_KUBECONFIG}" -n "${NAMESPACE}" delete statefulset keycloak-cp --ignore-not-found
kubectl --kubeconfig="${CP_KUBECONFIG}" -n "${NAMESPACE}" delete service keycloak-cp-headless keycloak-cp-http --ignore-not-found

echo "[pa-shared-idp] Removing DNSRegistrations ('${FQDN_PREFIX}*') and PKI Certificate ('${FQDN_PREFIX}-mp-cert') on MP..."
kubectl --kubeconfig="${MP_KUBECONFIG}" -n "${NAMESPACE}" delete dnsregistrations.network.private.gdc.goog \
  "${FQDN_PREFIX}" "${FQDN_PREFIX}-infra-internal" "${FQDN_PREFIX}-customer-internal" "${FQDN_PREFIX}-customer-external" --ignore-not-found
kubectl --kubeconfig="${MP_KUBECONFIG}" -n istio-system delete certificate.pki.security.gdc.goog "${FQDN_PREFIX}-mp-cert" --ignore-not-found

if [[ "${DELETE_DB}" == "true" ]]; then
  echo "[pa-shared-idp] --delete-db specified: deleting DBCluster 'keycloak-db' on MP and namespace '${NAMESPACE}'..."
  kubectl --kubeconfig="${MP_KUBECONFIG}" -n "${NAMESPACE}" delete dbclusters.postgresql.dbadmin.gdc.goog keycloak-db --ignore-not-found
  kubectl --kubeconfig="${MP_KUBECONFIG}" delete namespace "${NAMESPACE}" --ignore-not-found
  kubectl --kubeconfig="${CP_KUBECONFIG}" delete namespace "${NAMESPACE}" --ignore-not-found
else
  echo "[pa-shared-idp] Preserved DBCluster 'keycloak-db' in namespace '${NAMESPACE}' for fast re-runs (pass --delete-db to remove)."
fi

echo "[OK] Teardown complete."
