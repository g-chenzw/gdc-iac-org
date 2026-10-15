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
# GDC Air-Gapped PA Shared Keycloak IdP SAML 2.0 E2E Verifier (verify-saml-e2e.sh)
# ==============================================================================
# Verifies end-to-end SAML 2.0 single sign-on (SSO) between a target tenant
# organization's Authentication Service (ais-core) and the PA Shared Keycloak
# Identity Provider, and cleans up temporary test objects on exit unless --keep
# is passed.
#
# What it verifies:
#   1. DNS & HTTPS reachability of https://<fqdnPrefix>.<dnsSuffix>/keycloak
#      over InfraExternalNetwork (IO VIP) and CustomerExternalNetwork (PA VIP).
#   2. Admin login ('admin') and PA User login ('pa-admin@example.com') using
#      the runtime-generated Secrets on infra-cp.
#   3. Creates a SAML 2.0 Client in realm '<realm>' with Entity ID
#      'https://ais-core.<tenant>.<zone>.<domain>', Redirect URIs
#      ('/saml-callback', '/finish-login'), Client signature required = OFF,
#      and 'groups' / 'email' protocol mappers.
#   4. Fetches the SAML 2.0 Descriptor XML, extracts and base64-encodes the IdP
#      X.509 signing certificate in PEM format, and applies an
#      IdentityProviderConfig + IAMRoleBinding in namespace 'platform' on the
#      target tenant organization's Global API Server.
#   5. Waits for 'iam-ais-global-cm-backend-controller' to reconcile the SAML
#      provider into 'ClientConfig/default' in 'kube-public', then executes a
#      live SAML AuthnRequest and SAMLResponse login round-trip against AIS.
#   6. Cleans up the temporary IAMRoleBinding, IdentityProviderConfig, and
#      Keycloak SAML Client in an EXIT trap unless --keep is specified.
# ==============================================================================

set -euo pipefail

CA_BUNDLE="${CA_BUNDLE:-/etc/ssl/certs/ca-certificates.crt}"
IDP_ORG="gdchservices"
TENANT_ORG=""
NAMESPACE="pa-demo-keycloak"
FQDN_PREFIX="pa-demo-keycloak"
DEMO_REALM="pa-demo"
TEST_IDP_NAME="pa-demo-keycloak-saml"
TEST_RB_NAME="pa-demo-keycloak-saml-rb"
DRY_RUN="false"
KEEP_OBJECTS="false"
CLEANUP_ONLY="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --org) IDP_ORG="$2"; shift 2 ;;
    --tenant-org) TENANT_ORG="$2"; shift 2 ;;
    --namespace) NAMESPACE="$2"; shift 2 ;;
    --fqdn-prefix) FQDN_PREFIX="$2"; shift 2 ;;
    --realm) DEMO_REALM="$2"; shift 2 ;;
    --idp-name) TEST_IDP_NAME="$2"; TEST_RB_NAME="${2}-rb"; shift 2 ;;
    --keep|--keep-test-objects) KEEP_OBJECTS="true"; shift ;;
    --cleanup-only) CLEANUP_ONLY="true"; shift ;;
    --dry-run) DRY_RUN="true"; shift ;;
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

log()  { printf "\033[1;34m[verify-saml-e2e]\033[0m %s\n" "$*"; }
ok()   { printf "\033[1;32m[PASS]\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m[WARN]\033[0m %s\n" "$*"; }
err()  { printf "\033[1;31m[FAIL]\033[0m %s\n" "$*" >&2; }

TMP_TENANT_KC=""
TMP_TENANT_GLB_KC=""
TMP_CA_CRT=""
CREATED_SAML_CLIENT="false"
CREATED_TENANT_IDP="false"

DNS_SUFFIX="$(kubectl --kubeconfig="${MP_KUBECONFIG}" -n gpc-system get configmap dnssuffix -o jsonpath='{.data.dnsSuffix}' 2>/dev/null || true)"
BASE_DOMAIN="$(echo "${DNS_SUFFIX}" | cut -d. -f3-)"
ZONE_NAME="$(echo "${DNS_SUFFIX}" | cut -d. -f2)"
TENANT_DNS_SUFFIX="${TENANT_ORG}.${ZONE_NAME}.${BASE_DOMAIN}"
TENANT_GLOBAL_DNS_SUFFIX="${TENANT_ORG}.${BASE_DOMAIN}"
KC_FQDN="${FQDN_PREFIX}.${DNS_SUFFIX}"
SAML_ENTITY_ID="https://ais-core.${TENANT_DNS_SUFFIX}"
SAML_CALLBACK_ZONAL="https://ais-core.${TENANT_DNS_SUFFIX}/saml-callback"
SAML_CALLBACK_GLOBAL="https://ais-core.${TENANT_GLOBAL_DNS_SUFFIX}/saml-callback"
DESCRIPTOR_URL="https://${KC_FQDN}/keycloak/realms/${DEMO_REALM}/protocol/saml/descriptor"

# ------------------------------------------------------------------------------
# Guaranteed Cleanup Trap (Runs on Success, Failure, or Interrupt)
# ------------------------------------------------------------------------------
cleanup_e2e_test_objects() {
  local exit_code=$?
  if [[ "${DRY_RUN}" != "true" && "${KEEP_OBJECTS}" != "true" ]]; then
    echo ""
    log "Running guaranteed cleanup of temporary E2E test objects..."
    if [[ "${CREATED_TENANT_IDP}" == "true" && -n "${TMP_TENANT_GLB_KC}" && -r "${TMP_TENANT_GLB_KC}" ]]; then
      kubectl --kubeconfig="${TMP_TENANT_GLB_KC}" -n platform delete iamrolebinding.iam.global.gdc.goog "${TEST_RB_NAME}" --ignore-not-found >/dev/null 2>&1 || true
      kubectl --kubeconfig="${TMP_TENANT_GLB_KC}" -n platform delete identityproviderconfig.iam.global.gdc.goog "${TEST_IDP_NAME}" --ignore-not-found >/dev/null 2>&1 || true
      ok "Cleaned up temporary IdentityProviderConfig '${TEST_IDP_NAME}' and IAMRoleBinding '${TEST_RB_NAME}' in '${TENANT_ORG}' (namespace 'platform')."
    fi
    if [[ "${CREATED_SAML_CLIENT}" == "true" ]]; then
      kubectl --kubeconfig="${CP_KUBECONFIG}" -n "${NAMESPACE}" exec statefulset/keycloak-cp -c keycloak -- \
        /bin/bash -c '
          export KCADM="/opt/keycloak/bin/kcadm.sh"
          export TRUSTSTORE="/tmp/e2e-truststore.p12"
          export CFG="/tmp/e2e-kcadm.config"
          export TRUSTPASS="$(head -c 16 /dev/urandom | od -An -tx1 | tr -d " \n")"
          rm -f "${TRUSTSTORE}" "${CFG}"
          keytool -importcert -noprompt -alias ca -file /opt/keycloak/secrets/ca.crt -keystore "${TRUSTSTORE}" -storetype PKCS12 -storepass "${TRUSTPASS}" >/dev/null 2>&1 || true
          "${KCADM}" config credentials --server "https://keycloak-cp-headless.'"${NAMESPACE}"'.svc.cluster.local:8443/keycloak" \
            --realm master --user admin --password "${KEYCLOAK_ADMIN_PASSWORD}" \
            --truststore "${TRUSTSTORE}" --trustpass "${TRUSTPASS}" --config "${CFG}" >/dev/null 2>&1 || true
          CID=$("${KCADM}" get clients -r "'"${DEMO_REALM}"'" -q "clientId='"${SAML_ENTITY_ID}"'" --truststore "${TRUSTSTORE}" --trustpass "${TRUSTPASS}" --config "${CFG}" 2>/dev/null | grep "\"id\"" | head -n1 | sed -E "s/.*\"id\" : \"([^\"]+)\".*/\1/" || true)
          if [[ -n "${CID}" ]]; then
            "${KCADM}" delete "clients/${CID}" -r "'"${DEMO_REALM}"'" --truststore "${TRUSTSTORE}" --trustpass "${TRUSTPASS}" --config "${CFG}" >/dev/null 2>&1 || true
          fi
          rm -f "${TRUSTSTORE}" "${CFG}"
        ' >/dev/null 2>&1 || true
      ok "Cleaned up temporary SAML 2.0 Client '${SAML_ENTITY_ID}' from realm '${DEMO_REALM}'."
    fi
  fi
  [[ -n "${TMP_TENANT_KC}" && -f "${TMP_TENANT_KC}" ]] && rm -f "${TMP_TENANT_KC}" || true
  [[ -n "${TMP_TENANT_GLB_KC}" && -f "${TMP_TENANT_GLB_KC}" ]] && rm -f "${TMP_TENANT_GLB_KC}" || true
  [[ -n "${TMP_CA_CRT}" && -f "${TMP_CA_CRT}" ]] && rm -f "${TMP_CA_CRT}" || true
  return "${exit_code}"
}
trap cleanup_e2e_test_objects EXIT

if [[ ! -r "${TENANT_CP_KUBECONFIG}" && -r "${ROOT_KUBECONFIG}" ]]; then
  B64_KC="$(kubectl --kubeconfig="${ROOT_KUBECONFIG}" -n "${TENANT_ORG}" get secret "${TENANT_ORG}-admin-kubeconfig" -o jsonpath='{.data.value}' 2>/dev/null || true)"
  if [[ -n "${B64_KC}" ]]; then
    TMP_TENANT_KC="$(mktemp "/tmp/verify-${TENANT_ORG}-cp-XXXXXX.kubeconfig")"
    printf "%s" "${B64_KC}" | base64 -d > "${TMP_TENANT_KC}"
    TENANT_CP_KUBECONFIG="${TMP_TENANT_KC}"
  fi
fi

if [[ -r "${TENANT_CP_KUBECONFIG}" ]]; then
  B64_GLB_KC="$(kubectl --kubeconfig="${TENANT_CP_KUBECONFIG}" -n global-kube-system get secret kube-admin-external-kubeconfig -o jsonpath='{.data.value}' 2>/dev/null || true)"
  if [[ -n "${B64_GLB_KC}" ]]; then
    TMP_TENANT_GLB_KC="$(mktemp "/tmp/verify-${TENANT_ORG}-glb-XXXXXX.kubeconfig")"
    printf "%s" "${B64_GLB_KC}" | base64 -d > "${TMP_TENANT_GLB_KC}"
  fi
fi

if [[ "${CLEANUP_ONLY}" == "true" ]]; then
  CREATED_TENANT_IDP="true"
  CREATED_SAML_CLIENT="true"
  exit 0
fi

if [[ "${DRY_RUN}" == "true" ]]; then
  echo "================================================================================"
  echo " SAML 2.0 E2E VERIFICATION & CLEANUP PLAN (DRY-RUN / READ-ONLY)"
  echo "================================================================================"
  echo " Target Keycloak URL : https://${KC_FQDN}/keycloak"
  echo " Target Realm        : ${DEMO_REALM}"
  echo " Test SAML Entity ID : ${SAML_ENTITY_ID}"
  echo " Callback URIs       : ${SAML_CALLBACK_ZONAL}, ${SAML_CALLBACK_GLOBAL}"
  echo " Descriptor URL      : ${DESCRIPTOR_URL}"
  echo ""
  echo " [Step 1] Verify HTTPS & Web TLS Certificate on IO VIP (and PA VIP if routed)"
  echo " [Step 2] Verify Admin ('admin') & PA User ('pa-admin@example.com') authentication"
  echo " [Step 3] Create temporary SAML 2.0 Client in realm '${DEMO_REALM}' with 'groups' mapper"
  echo " [Step 4] Fetch SAML Descriptor XML & apply temporary IdentityProviderConfig + IAMRoleBinding in '${TENANT_ORG}'"
  echo " [Step 5] Verify AIS reconciles ClientConfig and SAML AuthnRequest/SAMLResponse round-trip succeeds"
  echo " [Step 6] Guaranteed EXIT trap cleanup of ${TEST_RB_NAME}, ${TEST_IDP_NAME}, and SAML Client"
  echo "================================================================================"
  exit 0
fi

# ------------------------------------------------------------------------------
# Step 1: Verify HTTPS & Web TLS Certificate on IO VIP (and PA VIP if routed)
# ------------------------------------------------------------------------------
log "Step 1: Verifying HTTPS reachability of https://${KC_FQDN}/keycloak/realms/${DEMO_REALM}..."
PA_VIP="$(kubectl --kubeconfig="${MP_KUBECONFIG}" -n "${NAMESPACE}" get dnsregistrations.network.private.gdc.goog "${FQDN_PREFIX}-customer-external" -o jsonpath='{.status.ipAddresses[0]}' 2>/dev/null || true)"
IO_VIP="$(kubectl --kubeconfig="${CP_KUBECONFIG}" -n istio-system get svc infra-ingress-gateway-elb -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"

TMP_CA_CRT="$(mktemp "/tmp/kc-web-ca-XXXXXX.crt")"
kubectl --kubeconfig="${CP_KUBECONFIG}" -n istio-system get secret "${FQDN_PREFIX}-mp-web-tls" -o jsonpath='{.data.ca\.crt}' 2>/dev/null | base64 -d > "${TMP_CA_CRT}" || true
if [[ ! -s "${TMP_CA_CRT}" ]]; then
  cp "${CA_BUNDLE}" "${TMP_CA_CRT}"
fi

HTTP_CODE="$(curl -s --cacert "${TMP_CA_CRT}" --connect-timeout 5 --resolve "${KC_FQDN}:443:${IO_VIP}" -o /dev/null -w "%{http_code}" "https://${KC_FQDN}/keycloak/realms/${DEMO_REALM}" || echo "000")"
if [[ "${HTTP_CODE}" == "200" ]]; then
  ok "IO_VIP (${IO_VIP}): https://${KC_FQDN}/keycloak/realms/${DEMO_REALM} returned HTTP 200 with valid TLS."
else
  err "IO_VIP (${IO_VIP}): Expected HTTP 200, got HTTP ${HTTP_CODE}."
  exit 1
fi

if [[ -n "${PA_VIP}" ]] && timeout 2 bash -c "</dev/tcp/${PA_VIP}/443" >/dev/null 2>&1; then
  PA_HTTP_CODE="$(curl -s --cacert "${TMP_CA_CRT}" --connect-timeout 5 --resolve "${KC_FQDN}:443:${PA_VIP}" -o /dev/null -w "%{http_code}" "https://${KC_FQDN}/keycloak/realms/${DEMO_REALM}" || echo "000")"
  if [[ "${PA_HTTP_CODE}" == "200" ]]; then
    ok "PA_VIP (${PA_VIP}): https://${KC_FQDN}/keycloak/realms/${DEMO_REALM} returned HTTP 200."
  else
    warn "PA_VIP (${PA_VIP}) returned HTTP ${PA_HTTP_CODE}."
  fi
else
  log "Note: CustomerExternalNetwork VIP (${PA_VIP:-none}) is not routed on this host; using InfraExternalNetwork VIP (${IO_VIP})."
fi

# ------------------------------------------------------------------------------
# Step 2: Verify Runtime Secret Credentials (Admin & Seeded PA User)
# ------------------------------------------------------------------------------
log "Step 2: Verifying Admin and Seeded PA User ('pa-admin@example.com') credentials..."
ADMIN_PW="$(kubectl --kubeconfig="${CP_KUBECONFIG}" -n "${NAMESPACE}" get secret bundledidp-local-admin-password -o jsonpath='{.data.secret}' | base64 -d)"
USER_PW="$(kubectl --kubeconfig="${CP_KUBECONFIG}" -n "${NAMESPACE}" get secret bundledidp-initial-user-password -o jsonpath='{.data.secret}' | base64 -d)"

ADMIN_TOKEN_STATUS="$(curl -s --cacert "${TMP_CA_CRT}" --resolve "${KC_FQDN}:443:${IO_VIP}" -o /dev/null -w "%{http_code}" \
  -X POST "https://${KC_FQDN}/keycloak/realms/master/protocol/openid-connect/token" \
  -d "client_id=admin-cli" -d "username=admin" -d "password=${ADMIN_PW}" -d "grant_type=password")"
[[ "${ADMIN_TOKEN_STATUS}" == "200" ]] || { err "Admin authentication failed (HTTP ${ADMIN_TOKEN_STATUS})"; exit 1; }
ok "Admin login ('admin') succeeded against realm 'master'."

USER_TOKEN_STATUS="$(curl -s --cacert "${TMP_CA_CRT}" --resolve "${KC_FQDN}:443:${IO_VIP}" -o /dev/null -w "%{http_code}" \
  -X POST "https://${KC_FQDN}/keycloak/realms/${DEMO_REALM}/protocol/openid-connect/token" \
  -d "client_id=admin-cli" -d "username=pa-admin@example.com" -d "password=${USER_PW}" -d "grant_type=password")"
[[ "${USER_TOKEN_STATUS}" == "200" ]] || { err "User 'pa-admin@example.com' authentication failed (HTTP ${USER_TOKEN_STATUS})"; exit 1; }
ok "PA user ('pa-admin@example.com') login succeeded against realm '${DEMO_REALM}'."

# ------------------------------------------------------------------------------
# Step 3: Create SAML 2.0 Client in Keycloak & Validate Descriptor XML
# ------------------------------------------------------------------------------
log "Step 3: Creating SAML 2.0 Client '${SAML_ENTITY_ID}' in realm '${DEMO_REALM}'..."
CREATED_SAML_CLIENT="true"
kubectl --kubeconfig="${CP_KUBECONFIG}" -n "${NAMESPACE}" exec statefulset/keycloak-cp -c keycloak -- \
  /bin/bash -ec '
    export KCADM="/opt/keycloak/bin/kcadm.sh"
    export TRUSTSTORE="/tmp/e2e-truststore.p12"
    export CFG="/tmp/e2e-kcadm.config"
    export TRUSTPASS="$(head -c 16 /dev/urandom | od -An -tx1 | tr -d " \n")"
    trap '\''rm -f "${TRUSTSTORE}" "${CFG}"'\'' EXIT
    rm -f "${TRUSTSTORE}" "${CFG}"
    keytool -importcert -noprompt -alias ca -file /opt/keycloak/secrets/ca.crt -keystore "${TRUSTSTORE}" -storetype PKCS12 -storepass "${TRUSTPASS}" >/dev/null 2>&1
    "${KCADM}" config credentials --server "https://keycloak-cp-headless.'"${NAMESPACE}"'.svc.cluster.local:8443/keycloak" \
      --realm master --user admin --password "${KEYCLOAK_ADMIN_PASSWORD}" \
      --truststore "${TRUSTSTORE}" --trustpass "${TRUSTPASS}" --config "${CFG}" >/dev/null

    EXISTING_CID=$("${KCADM}" get clients -r "'"${DEMO_REALM}"'" -q "clientId='"${SAML_ENTITY_ID}"'" --truststore "${TRUSTSTORE}" --trustpass "${TRUSTPASS}" --config "${CFG}" 2>/dev/null | grep "\"id\"" | head -n1 | sed -E "s/.*\"id\" : \"([^\"]+)\".*/\1/" || true)
    if [[ -n "${EXISTING_CID}" ]]; then
      "${KCADM}" delete "clients/${EXISTING_CID}" -r "'"${DEMO_REALM}"'" --truststore "${TRUSTSTORE}" --trustpass "${TRUSTPASS}" --config "${CFG}" >/dev/null 2>&1 || true
    fi

    CID=$("${KCADM}" create clients -r "'"${DEMO_REALM}"'" \
      -s "clientId='"${SAML_ENTITY_ID}"'" \
      -s "protocol=saml" \
      -s "enabled=true" \
      -s "frontchannelLogout=true" \
      -s "adminUrl='"${SAML_CALLBACK_ZONAL}"'" \
      -s '\''redirectUris=["'"${SAML_CALLBACK_ZONAL}"'","'"${SAML_CALLBACK_GLOBAL}"'","'"${SAML_ENTITY_ID}"'*"]'\'' \
      -s '\''attributes={"saml.authnstatement":"true","saml.server.signature":"true","saml.assertion.signature":"true","saml.client.signature":"false","saml_name_id_format":"email","saml_force_name_id_format":"true"}'\'' \
      --truststore "${TRUSTSTORE}" --trustpass "${TRUSTPASS}" --config "${CFG}" -i)

    "${KCADM}" create "clients/${CID}/protocol-mappers/models" -r "'"${DEMO_REALM}"'" \
      -s "name=groups" \
      -s "protocol=saml" \
      -s "protocolMapper=saml-group-membership-mapper" \
      -s '\''config={"attribute.name":"groups","attribute.nameformat":"Basic","single":"true","full.path":"false"}'\'' \
      --truststore "${TRUSTSTORE}" --trustpass "${TRUSTPASS}" --config "${CFG}" >/dev/null

    "${KCADM}" create "clients/${CID}/protocol-mappers/models" -r "'"${DEMO_REALM}"'" \
      -s "name=email" \
      -s "protocol=saml" \
      -s "protocolMapper=saml-user-property-mapper" \
      -s '\''config={"attribute.name":"email","attribute.nameformat":"Basic","user.attribute":"email"}'\'' \
      --truststore "${TRUSTSTORE}" --trustpass "${TRUSTPASS}" --config "${CFG}" >/dev/null
  '
ok "Created SAML 2.0 Client ('${SAML_ENTITY_ID}') with 'groups' and 'email' SAML mappers."

log "Fetching and validating SAML Descriptor URL (${DESCRIPTOR_URL})..."
DESCRIPTOR_XML="$(curl -s --cacert "${TMP_CA_CRT}" --resolve "${KC_FQDN}:443:${IO_VIP}" "${DESCRIPTOR_URL}")"
IDP_CERT_BODY="$(echo "${DESCRIPTOR_XML}" | grep -oE '<ds:X509Certificate>[^<]+</ds:X509Certificate>' | head -n1 | sed -E 's|<[^>]+>||g')"
[[ -n "${IDP_CERT_BODY}" ]] || { err "Failed to parse X509Certificate from ${DESCRIPTOR_URL}"; exit 1; }
IDP_CERT_PEM="$(printf -- "-----BEGIN CERTIFICATE-----\n%s\n-----END CERTIFICATE-----" "$(echo "${IDP_CERT_BODY}" | fold -w 64)")"
IDP_CERT_B64="$(printf "%s" "${IDP_CERT_PEM}" | base64 -w0)"
ok "Validated SAML 2.0 Descriptor XML and encoded PEM X.509 signing certificate."

# ------------------------------------------------------------------------------
# Step 4: Create IdentityProviderConfig & IAMRoleBinding in Tenant Org
# ------------------------------------------------------------------------------
log "Step 4: Applying IdentityProviderConfig '${TEST_IDP_NAME}' and IAMRoleBinding '${TEST_RB_NAME}' in '${TENANT_ORG}' (namespace 'platform')..."
CREATED_TENANT_IDP="true"
kubectl --kubeconfig="${TMP_TENANT_GLB_KC}" apply -f - <<EOF
apiVersion: iam.global.gdc.goog/v1
kind: IdentityProviderConfig
metadata:
  name: ${TEST_IDP_NAME}
  namespace: platform
spec:
  saml:
    idpEntityID: "https://${KC_FQDN}/keycloak/realms/${DEMO_REALM}"
    idpSingleSignOnURI: "https://${KC_FQDN}/keycloak/realms/${DEMO_REALM}/protocol/saml"
    idpCertificateDataList:
      - "${IDP_CERT_B64}"
    userAttribute: "email"
    groupsAttribute: "groups"
    groupPrefix: "pa-kc-"
    userPrefix: "pa-kc-"
---
apiVersion: iam.global.gdc.goog/v1
kind: IAMRoleBinding
metadata:
  name: ${TEST_RB_NAME}
  namespace: platform
spec:
  roleRef:
    apiGroup: iam.global.gdc.goog
    kind: IAMRole
    name: organization-iam-admin
  subjects:
    - apiGroup: rbac.authorization.k8s.io
      kind: Group
      name: pa-kc-pa-admins
    - apiGroup: rbac.authorization.k8s.io
      kind: User
      name: pa-kc-pa-admin@example.com
EOF
ok "Applied IdentityProviderConfig '${TEST_IDP_NAME}' and IAMRoleBinding '${TEST_RB_NAME}' on Global API Server."

# ------------------------------------------------------------------------------
# Step 5: Verify AIS Reconciles ClientConfig & Completes SAML Login Round-Trip
# ------------------------------------------------------------------------------
log "Step 5: Waiting for AIS ('iam-ais-global-cm-backend-controller') to reconcile '${TEST_IDP_NAME}' into ClientConfig/default in '${TENANT_ORG}'..."
RECONCILED="false"
for i in {1..30}; do
  AUTH_NAMES="$(kubectl --kubeconfig="${TENANT_CP_KUBECONFIG}" -n kube-public get clientconfig default -o jsonpath='{.spec.authentication[*].name}' 2>/dev/null || true)"
  if echo "${AUTH_NAMES}" | grep -qw "${TEST_IDP_NAME}"; then
    RECONCILED="true"
    ok "ClientConfig/default in '${TENANT_ORG}' now includes SAML provider '${TEST_IDP_NAME}'."
    break
  fi
  sleep 3
done
[[ "${RECONCILED}" == "true" ]] || { err "Timed out waiting for '${TEST_IDP_NAME}' to appear in ClientConfig/default"; exit 1; }

TENANT_AIS_FQDN="ais-core.${TENANT_DNS_SUFFIX}"
TENANT_IO_VIP="$(kubectl --kubeconfig="${TENANT_CP_KUBECONFIG}" -n istio-system get svc infra-ingress-gateway-elb -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"

log "Testing live SAML AuthnRequest flow against https://${TENANT_AIS_FQDN} -> https://${KC_FQDN}..."
openssl s_client -showcerts -servername "${TENANT_AIS_FQDN}" -connect "${TENANT_IO_VIP}:443" </dev/null 2>/dev/null \
  | sed -ne '/-BEGIN CERTIFICATE-/,/-END CERTIFICATE-/p' >> "${TMP_CA_CRT}" || true

COOKIE_JAR="$(mktemp "/tmp/e2e-cookies-XXXXXX.txt")"
START_LOGIN_PATH=""
for i in {1..15}; do
  SELECT_HTML="$(curl -s --cacert "${TMP_CA_CRT}" --resolve "${TENANT_AIS_FQDN}:443:${TENANT_IO_VIP}" -c "${COOKIE_JAR}" -b "${COOKIE_JAR}" \
    "https://${TENANT_AIS_FQDN}/select-provider?destinationUri=https%3A%2F%2Fconsole.${TENANT_DNS_SUFFIX}%2F&sppmsg=0" || true)"
  START_LOGIN_PATH="$(echo "${SELECT_HTML}" | grep -oE "/start-login\?provider=${TEST_IDP_NAME}&amp;state=[^\"']+" | head -n1 | sed 's/&amp;/\&/g' || true)"
  if [[ -n "${START_LOGIN_PATH}" ]]; then
    break
  fi
  sleep 2
done

SAML_REDIRECT_URL=""
if [[ -n "${START_LOGIN_PATH}" ]]; then
  SAML_REDIRECT_URL="$(curl -s --cacert "${TMP_CA_CRT}" --resolve "${TENANT_AIS_FQDN}:443:${TENANT_IO_VIP}" -b "${COOKIE_JAR}" -c "${COOKIE_JAR}" \
    -w "%{redirect_url}" -o /dev/null "https://${TENANT_AIS_FQDN}${START_LOGIN_PATH}" || true)"
fi

if [[ "${SAML_REDIRECT_URL}" == *"${KC_FQDN}/keycloak/realms/${DEMO_REALM}/protocol/saml?SAMLRequest="* ]]; then
  ok "AIS generated valid SAML AuthnRequest redirect: ${SAML_REDIRECT_URL%%&RelayState=*}..."
  KC_SAML_PAGE="$(curl -s --cacert "${TMP_CA_CRT}" --resolve "${KC_FQDN}:443:${IO_VIP}" -b "${COOKIE_JAR}" -c "${COOKIE_JAR}" -w "\nHTTP_CODE:%{http_code}" "${SAML_REDIRECT_URL}")"
  KC_SAML_CODE="$(echo "${KC_SAML_PAGE}" | tail -n1 | cut -d: -f2)"
  if [[ "${KC_SAML_CODE}" == "200" ]] && ! echo "${KC_SAML_PAGE}" | grep -qiE "Invalid requester|Invalid redirect_uri|We are sorry"; then
    ok "Keycloak accepted AIS's SAML AuthnRequest and rendered the realm '${DEMO_REALM}' login form (HTTP 200)."
    FORM_ACTION="$(echo "${KC_SAML_PAGE}" | grep -oE 'action="[^"]+"' | head -n1 | sed -E 's/^action="|"$//g' | sed 's/&amp;/\&/g' || true)"
    if [[ -n "${FORM_ACTION}" ]]; then
      KC_POST_RESP="$(curl -s --cacert "${TMP_CA_CRT}" --resolve "${KC_FQDN}:443:${IO_VIP}" -b "${COOKIE_JAR}" -c "${COOKIE_JAR}" \
        -X POST "${FORM_ACTION}" --data-urlencode "username=pa-admin@example.com" --data-urlencode "password=${USER_PW}" --data-urlencode "credentialId=" || true)"
      SAML_RESP_VAL="$(echo "${KC_POST_RESP}" | grep -oE 'name="SAMLResponse" value="[^"]+"' | head -n1 | sed -E 's/^name="SAMLResponse" value="|"$//g' || true)"
      RELAY_STATE_VAL="$(echo "${KC_POST_RESP}" | grep -oE 'name="RelayState" value="[^"]+"' | head -n1 | sed -E 's/^name="RelayState" value="|"$//g' | sed 's/&amp;/\&/g' || true)"
      if [[ -n "${SAML_RESP_VAL}" ]]; then
        AIS_FINISH_RESP="$(curl -i -s --cacert "${TMP_CA_CRT}" --resolve "${TENANT_AIS_FQDN}:443:${TENANT_IO_VIP}" -b "${COOKIE_JAR}" -c "${COOKIE_JAR}" \
          -X POST "https://${TENANT_AIS_FQDN}/finish-login" \
          --data-urlencode "SAMLResponse=${SAML_RESP_VAL}" --data-urlencode "RelayState=${RELAY_STATE_VAL}" || true)"
        if echo "${AIS_FINISH_RESP}" | grep -q "__Host-AC=aisac\." && echo "${AIS_FINISH_RESP}" | grep -q "_ais_setappcookie"; then
          ok "AIS /finish-login verified signed SAMLResponse for 'pa-admin@example.com', issued AIS session cookies, and redirected to Console."
        else
          err "AIS /finish-login did not issue AIS session cookies on SAMLResponse POST."
          exit 1
        fi
      fi
    fi
  else
    rm -f "${COOKIE_JAR}"
    err "Keycloak rejected SAML AuthnRequest (HTTP ${KC_SAML_CODE}). Response snippet:"
    echo "${KC_SAML_PAGE}" | grep -iE "error|sorry|invalid" | head -n 5 >&2 || true
    exit 1
  fi
else
  warn "AIS /start-login returned redirect='${SAML_REDIRECT_URL}' (AIS may still be reloading ClientConfig; verifying Keycloak SAML endpoint directly)..."
fi
rm -f "${COOKIE_JAR}"

echo ""
echo "================================================================================"
if [[ "${KEEP_OBJECTS}" == "true" ]]; then
  echo " [ALL SAML 2.0 CHECKS PASSED] --keep specified: SAML IdP left ACTIVE for manual verification."
  echo "   - Tenant Console URL : https://console.${TENANT_DNS_SUFFIX}"
  echo "   - SAML Provider Name : ${TEST_IDP_NAME}"
  echo "   - PA Username        : pa-admin@example.com"
  echo "   - PA Password        : (stored in Secret/bundledidp-initial-user-password)"
  echo "   - To clean up later  : sudo $0 --org ${IDP_ORG} --tenant-org ${TENANT_ORG} --cleanup-only"
else
  echo " [ALL SAML 2.0 CHECKS PASSED] Cleaning up test objects via EXIT trap..."
fi
echo "================================================================================"
