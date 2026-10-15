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
# GDC Air-Gapped PA Shared Keycloak IdP Status & SAML Summary (status.sh)
# ==============================================================================
# Strictly READ-ONLY health check and SAML 2.0 federation summary generator.
# Inspects DBCluster, DNSRegistrations, PKI certs, Keycloak pods, and prints the
# live URLs, runtime-generated Secret credentials, and SAML 2.0 client parameters.
# ==============================================================================

set -euo pipefail

IDP_ORG="gdchservices"
TENANT_ORG=""
NAMESPACE="pa-demo-keycloak"
FQDN_PREFIX="pa-demo-keycloak"
DEMO_REALM="pa-demo"
IDP_CONFIG_NAME="pa-demo-keycloak-saml"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --org) IDP_ORG="$2"; shift 2 ;;
    --tenant-org) TENANT_ORG="$2"; shift 2 ;;
    --namespace) NAMESPACE="$2"; shift 2 ;;
    --fqdn-prefix) FQDN_PREFIX="$2"; shift 2 ;;
    --realm) DEMO_REALM="$2"; shift 2 ;;
    --idp-name) IDP_CONFIG_NAME="$2"; shift 2 ;;
    *) shift ;;
  esac
done

ROOT_KUBECONFIG="${ROOT_KUBECONFIG:-/root/release/root-admin/root-admin-kubeconfig}"
CP_KUBECONFIG="${CP_KUBECONFIG:-/root/release/org-admin/${IDP_ORG}-admin-kubeconfig}"
MP_KUBECONFIG="${MP_KUBECONFIG:-/root/release/org-admin/${IDP_ORG}-mgmt-kubeconfig}"

if [[ -z "${TENANT_ORG}" ]]; then
  TENANT_ORG="$(kubectl --kubeconfig="${ROOT_KUBECONFIG}" get organizations.org.gdc.goog -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -vE "^(${IDP_ORG}|root-admin)$" | head -n1 || true)"
  [[ -z "${TENANT_ORG}" ]] && TENANT_ORG="tenant-org"
fi

TENANT_CP_KUBECONFIG="${TENANT_CP_KUBECONFIG:-/root/release/org-admin/${TENANT_ORG}-admin-kubeconfig}"

TMP_TENANT_KC=""
cleanup() {
  [[ -n "${TMP_TENANT_KC}" && -f "${TMP_TENANT_KC}" ]] && rm -f "${TMP_TENANT_KC}" || true
  return 0
}
trap cleanup EXIT

if [[ ! -r "${TENANT_CP_KUBECONFIG}" && -r "${ROOT_KUBECONFIG}" ]]; then
  B64_KC="$(kubectl --kubeconfig="${ROOT_KUBECONFIG}" -n "${TENANT_ORG}" get secret "${TENANT_ORG}-admin-kubeconfig" -o jsonpath='{.data.value}' 2>/dev/null || true)"
  if [[ -n "${B64_KC}" ]]; then
    TMP_TENANT_KC="$(mktemp "/tmp/status-${TENANT_ORG}-cp-XXXXXX.kubeconfig")"
    printf "%s" "${B64_KC}" | base64 -d > "${TMP_TENANT_KC}"
    TENANT_CP_KUBECONFIG="${TMP_TENANT_KC}"
  fi
fi

DNS_SUFFIX="$(kubectl --kubeconfig="${MP_KUBECONFIG}" -n gpc-system get configmap dnssuffix -o jsonpath='{.data.dnsSuffix}' 2>/dev/null || true)"
BASE_DOMAIN="$(echo "${DNS_SUFFIX}" | cut -d. -f3-)"
ZONE_NAME="$(echo "${DNS_SUFFIX}" | cut -d. -f2)"
TENANT_DNS_SUFFIX="${TENANT_ORG}.${ZONE_NAME}.${BASE_DOMAIN}"
TENANT_GLOBAL_DNS_SUFFIX="${TENANT_ORG}.${BASE_DOMAIN}"

echo "================================================================================"
echo " GDC AIR-GAPPED PA SHARED KEYCLOAK IDP STATUS & SAML SUMMARY (READ-ONLY)"
echo "================================================================================"
echo " IdP Host Org    : ${IDP_ORG} (${DNS_SUFFIX})"
echo " Target Org      : ${TENANT_ORG} (${TENANT_DNS_SUFFIX})"
echo " Namespace       : ${NAMESPACE}"
echo " Keycloak FQDN   : ${FQDN_PREFIX}.${DNS_SUFFIX}"
echo "--------------------------------------------------------------------------------"

echo "[1] MP DBCluster & DNS Registrations (${MP_KUBECONFIG}):"
kubectl --kubeconfig="${MP_KUBECONFIG}" -n "${NAMESPACE}" get dbclusters.postgresql.dbadmin.gdc.goog keycloak-db 2>/dev/null || echo "  (DBCluster 'keycloak-db' in '${NAMESPACE}' not deployed yet)"
kubectl --kubeconfig="${MP_KUBECONFIG}" -n "${NAMESPACE}" get dnsregistrations.network.private.gdc.goog 2>/dev/null || echo "  (DNSRegistrations in '${NAMESPACE}' not deployed yet)"

echo ""
echo "[2] CP Keycloak Pods & Gateways (${CP_KUBECONFIG}):"
kubectl --kubeconfig="${CP_KUBECONFIG}" -n "${NAMESPACE}" get pods,svc,gateway,virtualservice 2>/dev/null || echo "  (Keycloak CP resources in '${NAMESPACE}' not deployed yet)"

PA_EXT_VIP="$(kubectl --kubeconfig="${MP_KUBECONFIG}" -n "${NAMESPACE}" get dnsregistrations.network.private.gdc.goog "${FQDN_PREFIX}-customer-external" -o jsonpath='{.status.ipAddresses[0]}' 2>/dev/null || true)"
if [[ -z "${PA_EXT_VIP}" ]]; then
  PA_EXT_VIP="$(kubectl --kubeconfig="${MP_KUBECONFIG}" -n ui-system get resourcerecordsets.network.private.gdc.goog console-customer-external-a -o jsonpath='{.spec.records[0]}' 2>/dev/null || true)"
fi
[[ -z "${PA_EXT_VIP}" ]] && PA_EXT_VIP="<not-routed / use IO External VIP>"
IO_EXT_VIP="$(kubectl --kubeconfig="${CP_KUBECONFIG}" -n istio-system get svc infra-ingress-gateway-elb -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "<pending>")"

TENANT_VIP="<pending>"
if [[ -r "${TENANT_CP_KUBECONFIG}" ]]; then
  TENANT_VIP="$(kubectl --kubeconfig="${TENANT_CP_KUBECONFIG}" -n istio-system get svc infra-ingress-gateway-elb -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
fi

ADMIN_PW="$(kubectl --kubeconfig="${CP_KUBECONFIG}" -n "${NAMESPACE}" get secret bundledidp-local-admin-password -o jsonpath='{.data.secret}' 2>/dev/null | base64 -d || true)"
[[ -z "${ADMIN_PW}" ]] && ADMIN_PW="<not-created-yet>"
USER_PW="$(kubectl --kubeconfig="${CP_KUBECONFIG}" -n "${NAMESPACE}" get secret bundledidp-initial-user-password -o jsonpath='{.data.secret}' 2>/dev/null | base64 -d || true)"
[[ -z "${USER_PW}" ]] && USER_PW="<not-created-yet>"

echo ""
echo "================================================================================"
echo " PA SHARED KEYCLOAK IDP ACCESS & SAML 2.0 FEDERATION REFERENCE"
echo "================================================================================"
echo " 1. KEYCLOAK ACCESS & RUNTIME CREDENTIALS"
echo "    - Keycloak Admin Console : https://${FQDN_PREFIX}.${DNS_SUFFIX}/keycloak/admin"
echo "    - IO External VIP (Infra): ${IO_EXT_VIP} (InfraExternalNetwork)"
echo "    - PA External VIP (Data) : ${PA_EXT_VIP} (CustomerExternalNetwork)"
echo "    - Admin Username         : admin"
echo "    - Admin Password         : ${ADMIN_PW}"
echo ""
echo " 2. SEEDED REALM, GROUPS & USERS"
echo "    - Realm Name             : ${DEMO_REALM}"
echo "    - Seeded Users Password  : ${USER_PW}"
echo "    - Seeded Users & Groups  :"
echo "        * pa-admin@example.com     (groups: pa-admins, iam-admins)"
echo "        * pa-auditor@example.com   (groups: pa-admins)"
echo "        * ao-developer@example.com (groups: ao-users)"
echo ""
echo " 3. SAML 2.0 CLIENT PARAMETERS IN KEYCLOAK ('${DEMO_REALM}' REALM)"
echo "    - Client Type            : SAML"
echo "    - Client ID (Entity ID)  : https://ais-core.${TENANT_DNS_SUFFIX}"
echo "    - Valid Redirect URIs    :"
echo "        * https://ais-core.${TENANT_DNS_SUFFIX}/finish-login"
echo "        * https://ais-core.${TENANT_DNS_SUFFIX}/saml-callback"
echo "        * https://ais-core.${TENANT_GLOBAL_DNS_SUFFIX}/finish-login"
echo "        * https://ais-core.${TENANT_GLOBAL_DNS_SUFFIX}/saml-callback"
echo "    - Name ID Format         : email"
echo "    - Sign Assertions        : ON (RSA_SHA256)"
echo "    - Keys -> Client signature required : OFF"
echo "    - Client Scopes -> Dedicated Scope -> Add Mapper -> By configuration -> Group list:"
echo "        * Name                   : groups"
echo "        * Group attribute name   : groups"
echo "        * SAML Attribute NameFmt : Basic"
echo "        * Single Group Attribute : ON (true)"
echo "        * Full group path        : OFF (false)"
echo "    - SAML Descriptor URL    : https://${FQDN_PREFIX}.${DNS_SUFFIX}/keycloak/realms/${DEMO_REALM}/protocol/saml/descriptor"
echo ""
echo " 4. TARGET TENANT ORG ('${TENANT_ORG}') IDENTITYPROVIDERCONFIG & ENDPOINTS"
echo "    - Tenant Console URL     : https://console.${TENANT_DNS_SUFFIX}"
echo "    - Tenant AIS URL         : https://ais-core.${TENANT_DNS_SUFFIX}"
echo "    - Tenant Ingress VIP     : ${TENANT_VIP}"
echo "    - IdentityProviderConfig (applied to '${TENANT_ORG}' Global API Server in namespace 'platform'):"
echo "        idpEntityID        : https://${FQDN_PREFIX}.${DNS_SUFFIX}/keycloak/realms/${DEMO_REALM}"
echo "        idpSingleSignOnURI : https://${FQDN_PREFIX}.${DNS_SUFFIX}/keycloak/realms/${DEMO_REALM}/protocol/saml"
echo "        groupsAttribute    : groups"
echo "        groupPrefix        : pa-kc-"
echo "        userPrefix         : pa-kc-"
echo "================================================================================"
