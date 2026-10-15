Copyright 2026 Google. This software is provided as-is, without warranty or representation for any use or purpose. Your use of it is subject to your agreement with Google.

# Pattern 12a: PA Shared Identity Provider (Keycloak Multi-Cluster & SAML 2.0 Federation)

**Use Case:** Portable, organization-level Keycloak Identity Provider (IdP) hosted in a shared platform service organization (such as `gdchservices`) on a Google Distributed Cloud (GDC) air-gapped environment to provide browser-mediated SAML 2.0 and OpenID Connect (OIDC) federation for Platform Administrator (PA) and Application Operator (AO) console/CLI sign-in (`IdentityProviderConfig` / `ais-core`) across tenant organizations.

> **Relationship to Pattern 12 (`p12-keycloak`):**
> - **[`p12-keycloak`](../p12-keycloak/README.md)** is an **Application Operator (AO)** pattern that deploys an application-internal Keycloak instance inside a single tenant GKE User Cluster (`Stage 5: 5-workload-factory`).
> - **`p12a-pa-shared-idp`** is a **Platform Administrator (PA) / Infrastructure Operator (IO)** pattern that coordinates resources across the **Organization Management Plane (`infra-mp`)**, **Organization Control Plane (`infra-cp`)**, and **Target Tenant Organization Global API Server** to expose a shared, multi-network Keycloak IdP with zero external internet image dependencies.

## Architecture Schematic

```text
+-------------------------------------------------------------------------+
| External Administrator / Operator Browser (Shared External Network)     |
+-------------------------------------------------------------------------+
                   |                                     |
   1. Console Login| (HTTPS :443)        2. SAML Redirect| (HTTPS :443 -> :8443)
                   v                                     v
+-----------------------------------+   +---------------------------------+
| Target Tenant Org Control Plane   |   | Shared IdP Org (gdchservices)   |
| (e.g. tenant-org)                 |   | Control Plane (infra-cp)        |
|                                   |   |                                 |
| - IdentityProviderConfig (SAML)   |   | - Istio Gateways (443 & 8443)   |
| - IAMRoleBinding (pa-kc-pa-admins)|   | - VirtualService (open-paths)   |
| - ais-core (/select-provider,     |   | - DestinationRule (SIMPLE TLS)  |
|   /start-login, /finish-login)    |   | - StatefulSet/keycloak-cp       |
+-----------------------------------+   | - Job/keycloak-pa-demo-setup    |
                                        +---------------------------------+
                                                         |
                                                         | (JDBC :5432 via pg-keycloak-db-ilb)
                                                         v
                                        +---------------------------------+
                                        | Shared IdP Org Management Plane |
                                        | (infra-mp)                      |
                                        |                                 |
                                        | - DBCluster/keycloak-db         |
                                        | - Certificate (forward-to-cp)   |
                                        | - 4x DNSRegistration            |
                                        +---------------------------------+
```

## Multi-Cluster Platform Integration Contract

| Component | Target Cluster | API Group & Kind | Key Configuration Contract |
| :--- | :--- | :--- | :--- |
| **Managed PostgreSQL** | Management Plane (`infra-mp`) | `postgresql.dbadmin.gdc.goog/v1`<br>`DBCluster` | Provision with `spec.primarySpec.version: "14"` and annotation `fleet.dbadmin.goog/retain-admin-password-secret: "true"`. Reconciles `Service/pg-keycloak-db-ilb:5432` on `infra-cp`. |
| **External Web TLS Certificate** | Management Plane (`infra-mp`) | `pki.security.gdc.goog/v1`<br>`Certificate` | Create in `namespace: istio-system` with `secretTemplate.annotations.pki.security.gdc.goog/forward-to-cp: "true"` so the platform PKI controller forwards `pa-demo-keycloak-mp-web-tls` to `infra-cp`. |
| **Multi-Network DNS Records** | Management Plane (`infra-mp`) | `network.private.gdc.goog/v1alpha1`<br>`DNSRegistration` | Register 4 `DNSRegistration` resources (`InfraExternalNetwork`, `CustomerExternalNetwork`, `VPC: infra`, `VPC: default`) so `<fqdnPrefix>` resolves across both PA/IO external networks and internal VPCs. |
| **Internal Pod PKCS12 Keystore** | Control Plane (`infra-cp`) | `cert-manager.io/v1`<br>`Certificate` | Set `commonName: <fqdnPrefix>` ($\le 64$ bytes to prevent ASN.1 overflow on long GDC domain suffixes), place full zonal, global, and headless service FQDNs in `spec.dnsNames`, and enable `pkcs12`. |
| **Keycloak StatefulSet & Cache** | Control Plane (`infra-cp`) | `apps/v1`<br>`StatefulSet` | Gate startup with `dbchecker` init container waiting for `pg-keycloak-db-ilb:5432`. Run FIPS-enabled Keycloak with `KC_HTTP_RELATIVE_PATH="/keycloak"`, `KC_CACHE="ispn"`, and `KC_CACHE_STACK="kubernetes"`. |
| **Dual-Port Ingress Gateways** | Control Plane (`infra-cp`) | `networking.istio.io/v1alpha3`<br>`Gateway` | Bind both `443` and `8443` on `infra-ingress-gateway` and `dataplane-ingress-gateway` (where `g-svc-dataplane-ingress-gateway-internal` maps external port `443` to Envoy `targetPort: 8443`). |
| **Unauthenticated Route Bypass** | Control Plane (`infra-cp`) | `networking.istio.io/v1alpha3`<br>`VirtualService` & `DestinationRule` | Name the HTTP route **`name: open-paths`** so GDC's `ais-ext-authz-session` `EnvoyFilter` exempts `/keycloak` from pre-authentication checks. |
| **Organization SAML 2.0 Federation** | Target Org Global API | `iam.global.gdc.goog/v1`<br>`IdentityProviderConfig` & `IAMRoleBinding` | Seed SAML client `https://ais-core.<TENANT_DNS_SUFFIX>` with redirect URIs `/saml-callback` and `/finish-login` and a `saml-group-membership-mapper` (`single="true"`, `full.path="false"`). |

## Secret Management & Security Posture

No real or placeholder passwords or certificates are stored in Git. All credentials are referenced via Kubernetes `Secret` names (`secretKeyRef`):
- `db-pw-keycloak-db` (on `infra-mp`, key `keycloak-db`)
- `bundledidp-keycloak-database-pw` (on `infra-cp`, key `password`, with `iam.private.gdc.goog/pg-*` annotations)
- `keycloak-cp-keystore-password` (on `infra-cp`, key `password`, used by `cert-manager` PKCS12 keystore and `KC_HTTPS_KEY_STORE_PASSWORD`)
- `bundledidp-local-admin-password` (on `infra-cp`, key `secret`)
- `bundledidp-initial-user-password` (on `infra-cp`, key `secret`)

`scripts/deploy.sh` generates cryptographically random 24-character secrets at runtime via `openssl rand` (when the `Secret`s do not already exist) and creates them directly via `kubectl create secret generic`.

## Quickstart

### Option A: Automated Turnkey Script (Recommended on Bootstrapper)

```bash
cd blueprints/patterns/p12a-pa-shared-idp/scripts

# 1. Dry-run environment discovery and manifest rendering (read-only)
sudo ./deploy.sh --dry-run

# 2. Deploy the PA Shared Keycloak IdP across infra-mp and infra-cp
sudo ./deploy.sh

# 3. Connect a tenant organization and verify E2E SAML 2.0 login
#    Pass --keep to leave IdentityProviderConfig active for browser testing
sudo ./verify-saml-e2e.sh --tenant-org <tenant-org> --keep

# 4. Clean up test IdentityProviderConfig or tear down the entire IdP
sudo ./verify-saml-e2e.sh --tenant-org <tenant-org> --cleanup-only
sudo ./teardown.sh
```

### Option B: Multi-Context Helm Chart Deployment

```bash
CHART_DIR="blueprints/patterns/p12a-pa-shared-idp/chart"
NS="pa-demo-keycloak"

# Pre-step: Create runtime Secrets with random passwords on infra-mp and infra-cp
DB_PW="$(openssl rand -base64 24 | tr -d '=+/\n' | cut -c1-24)"
kubectl --kubeconfig "${MP_KUBECONFIG}" create ns "${NS}" --dry-run=client -o yaml | kubectl --kubeconfig "${MP_KUBECONFIG}" apply -f -
kubectl --kubeconfig "${CP_KUBECONFIG}" create ns "${NS}" --dry-run=client -o yaml | kubectl --kubeconfig "${CP_KUBECONFIG}" apply -f -

kubectl --kubeconfig "${MP_KUBECONFIG}" -n "${NS}" create secret generic db-pw-keycloak-db \
  --from-literal=keycloak-db="${DB_PW}" --dry-run=client -o yaml | kubectl --kubeconfig "${MP_KUBECONFIG}" apply -f -
kubectl --kubeconfig "${CP_KUBECONFIG}" -n "${NS}" create secret generic bundledidp-keycloak-database-pw \
  --from-literal=password="${DB_PW}" --dry-run=client -o yaml \
  | kubectl annotate --local -f - \
      iam.private.gdc.goog/pg-user-statefulset-name="keycloak-cp" \
      iam.private.gdc.goog/pg-user-statefulset-namespace="${NS}" \
      iam.private.gdc.goog/pg-user-pod-manager-type="statefulset" \
      iam.private.gdc.goog/pg-dbcluster-name="keycloak-db" -o yaml \
  | kubectl --kubeconfig "${CP_KUBECONFIG}" apply -f -
kubectl --kubeconfig "${CP_KUBECONFIG}" -n "${NS}" create secret generic keycloak-cp-keystore-password \
  --from-literal=password="$(openssl rand -base64 24 | tr -d '=+/\n' | cut -c1-24)" --dry-run=client -o yaml | kubectl --kubeconfig "${CP_KUBECONFIG}" apply -f -
kubectl --kubeconfig "${CP_KUBECONFIG}" -n "${NS}" create secret generic bundledidp-local-admin-password \
  --from-literal=secret="$(openssl rand -base64 24 | tr -d '=+/\n' | cut -c1-24)" --dry-run=client -o yaml | kubectl --kubeconfig "${CP_KUBECONFIG}" apply -f -
kubectl --kubeconfig "${CP_KUBECONFIG}" -n "${NS}" create secret generic bundledidp-initial-user-password \
  --from-literal=secret="$(openssl rand -base64 24 | tr -d '=+/\n' | cut -c1-24)" --dry-run=client -o yaml | kubectl --kubeconfig "${CP_KUBECONFIG}" apply -f -

# Stage 1: Management Plane (infra-mp)
helm upgrade --install pa-shared-idp-mp "${CHART_DIR}" \
  --kubeconfig "${MP_KUBECONFIG}" \
  -n "${NS}" \
  --set managementPlane.enabled=true \
  --set controlPlane.enabled=false

# Stage 2: Control Plane (infra-cp)
helm upgrade --install pa-shared-idp-cp "${CHART_DIR}" \
  --kubeconfig "${CP_KUBECONFIG}" \
  -n "${NS}" \
  --set managementPlane.enabled=false \
  --set controlPlane.enabled=true

# Stage 3: Target Tenant Organization Federation (Global API Server)
helm upgrade --install pa-shared-idp-federation "${CHART_DIR}" \
  --kubeconfig "${TENANT_GLOBAL_KUBECONFIG}" \
  -n platform \
  --set managementPlane.enabled=false \
  --set controlPlane.enabled=false \
  --set tenantFederation.enabled=true \
  --set tenantFederation.idpCertificateDataBase64Pem="${BASE64_PEM_CERT}"
```
