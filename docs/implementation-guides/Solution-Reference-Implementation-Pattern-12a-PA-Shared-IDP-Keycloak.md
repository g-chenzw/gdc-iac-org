Copyright 2026 Google. This software is provided as-is, without warranty or representation for any use or purpose. Your use of it is subject to your agreement with Google.

# **Solution Reference Implementation - Pattern 12a: PA Shared Identity Provider (Keycloak) on GDC air-gapped**

> **Version:** 1.0

## **Overview**

This document provides step-by-step instructions for deploying and configuring **Keycloak** as a portable, shared Identity Provider (IdP) in a platform service organization (such as `gdchservices`) on Google Distributed Cloud (GDC) air-gapped environments. Unlike Pattern 12 (`p12-keycloak`), which deploys an application-internal Keycloak instance inside a tenant GKE user cluster, **Pattern 12a (`p12a-pa-shared-idp`)** coordinates resources across the **Organization Management Plane (`infra-mp`)**, **Organization Control Plane (`infra-cp`)**, and **Target Organization Global API Server** to provide browser-mediated SAML 2.0 and OpenID Connect (OIDC) single sign-on (SSO) for GDC organization consoles (`IdentityProviderConfig` / `ais-core`) and tenant workloads.

## **Architecture**

Keycloak runs as a FIPS-enabled `StatefulSet` on the organization control plane (`infra-cp`) with a headless service for distributed Infinispan session caching, exposed across both PA (`CustomerExternalNetwork`) and IO (`InfraExternalNetwork`) ingress gateways, and backed by a managed PostgreSQL `DBCluster` provisioned on the organization management plane (`infra-mp`).

```text
                    [ External PA / AO Browser ]
                                 │
          ┌──────────────────────┴──────────────────────┐
          ▼ (HTTPS :443)                                ▼ (HTTPS :443 -> :8443)
[ Target Org: ais-core ]                      [ Shared IdP Org: Istio Gateways ]
(IdentityProviderConfig                       (infra-ingress-gateway &
 + IAMRoleBinding)                             dataplane-ingress-gateway)
                                                        │
                                                        ▼ (VirtualService: open-paths)
                                              [ keycloak-cp-headless (:8443) ]
                                                        │
                                                        ▼ (SIMPLE TLS / PKCS12)
                                              [ StatefulSet: keycloak-cp ]
                                              (Infinispan Cache + dbchecker)
                                                        │
                                                        ▼ (Port 5432: pg-keycloak-db-ilb)
                                              [ GDC Database: keycloak-db ]
                                              (Provisioned on infra-mp)
```

### **Key Solution Capabilities**

* **Zero External Image Dependencies**: Dynamically discovers and reuses the platform-verified `keycloak` and `bundledidp-pgchecker` container images already pre-seeded in the appliance's internal Harbor registry.
* **Cross-Organization Browser-Mediated SAML 2.0 Federation**: Exposes Keycloak on the shared `CustomerExternalNetwork` (`dataplane-ingress-gateway`) so administrators can authenticate into tenant organizations via SAML 2.0 HTTP-POST/Redirect bindings without requiring cross-organization pod-to-pod network peering.
* **Zero Committed Secrets**: No static `Secret` resources or hardcoded/base64 credentials exist in the manifests or Helm chart. Secrets are generated at runtime via `openssl rand` and mounted via `secretKeyRef`.
* **End-to-End TLS & 64-Byte ASN.1 Safeguard**: Issues external web TLS certificates via `pki.security.gdc.goog/v1` (`forward-to-cp: "true"`) and internal pod PKCS12 keystores via `cert-manager.io/v1` (`commonName: <fqdnPrefix>` $\le 64$ bytes with full FQDNs in `spec.dnsNames`).
* **Platform Authz Bypass (`open-paths`)**: Names the `VirtualService` HTTP route `open-paths` so GDC's `ais-ext-authz-session` `EnvoyFilter` allows unauthenticated users to reach `/keycloak`.
* **Automated Realm, Group, User, & Mapper Seeding**: Includes an idempotent Kubernetes `Job` (`kcadm.sh`) and end-to-end verification script (`verify-saml-e2e.sh`) that seeds the realm, RBAC groups, users, and SAML 2.0 `groups` protocol mapper (`single="true"`, `full.path="false"`).

---

## **Before you Begin**

Ensure the following prerequisites are met on the GDC air-gapped bootstrapper or operator workstation:

* Access to the IdP host organization's **Management Plane (`infra-mp`)** and **Control Plane (`infra-cp`)** kubeconfigs (for example, `gdchservices`).
* Access to the target tenant organization's **Global API Server** kubeconfig to register `IdentityProviderConfig` and `IAMRoleBinding`.
* `kubectl`, `curl`, `openssl`, and `python3` installed.

---

## **Section 1: Environment Discovery & Stage 1 Database Provisioning (`infra-mp` & `infra-cp`)**

### 1.1 Automated Environment Discovery

`scripts/deploy.sh` automatically inspects the live `infra-cp` and `infra-mp` clusters to discover:
* Zonal DNS suffix (`DNS_SUFFIX`) and Global DNS suffix (`GLOBAL_DNS_SUFFIX`)
* Internal Harbor registry host, repository path, `keycloak` tag, and `bundledidp-pgchecker` tag

To preview the discovered values and rendered manifests without modifying any cluster state:

```bash
cd blueprints/patterns/p12a-pa-shared-idp/scripts
sudo ./deploy.sh --dry-run
```

### 1.2 Create Runtime Secrets & Provision PostgreSQL (`01-db-cp.yaml` & `02-db-mp.yaml`)

1. Create the namespace on `infra-cp` and `infra-mp`:
   ```bash
   kubectl --kubeconfig "${CP_KUBECONFIG}" apply -f ../manifests/cp/01-db-cp.yaml
   kubectl --kubeconfig "${MP_KUBECONFIG}" create ns pa-demo-keycloak --dry-run=client -o yaml | kubectl --kubeconfig "${MP_KUBECONFIG}" apply -f -
   ```
2. Generate a random database password and create `Secret/bundledidp-keycloak-database-pw` on `infra-cp` (with DBS operator annotations) and `Secret/db-pw-keycloak-db` on `infra-mp`:
   ```bash
   DB_PW="$(openssl rand -base64 24 | tr -d '=+/\n' | cut -c1-24)"
   kubectl --kubeconfig "${CP_KUBECONFIG}" -n pa-demo-keycloak create secret generic bundledidp-keycloak-database-pw \
     --from-literal=password="${DB_PW}" --dry-run=client -o yaml \
     | kubectl annotate --local -f - \
         iam.private.gdc.goog/pg-user-statefulset-name="keycloak-cp" \
         iam.private.gdc.goog/pg-user-statefulset-namespace="pa-demo-keycloak" \
         iam.private.gdc.goog/pg-user-pod-manager-type="statefulset" \
         iam.private.gdc.goog/pg-dbcluster-name="keycloak-db" -o yaml \
     | kubectl --kubeconfig "${CP_KUBECONFIG}" apply -f -

   kubectl --kubeconfig "${MP_KUBECONFIG}" -n pa-demo-keycloak create secret generic db-pw-keycloak-db \
     --from-literal=keycloak-db="${DB_PW}" --dry-run=client -o yaml | kubectl --kubeconfig "${MP_KUBECONFIG}" apply -f -
   ```
3. Apply `DBCluster/keycloak-db` on `infra-mp`:
   ```bash
   kubectl --kubeconfig "${MP_KUBECONFIG}" apply -f ../manifests/mp/02-db-mp.yaml
   ```
4. Wait for `DBCluster/keycloak-db` to report `DBClusterReady` on `infra-mp` and for `Service/pg-keycloak-db-ilb` (port `5432`) to appear in `pa-demo-keycloak` on `infra-cp`.

---

## **Section 2: Web TLS Certificate & Multi-Network DNS Registration (`infra-mp`)**

Apply `03-dns-cert-mp.yaml` on `infra-mp` to issue the web TLS certificate (with `pki.security.gdc.goog/forward-to-cp: "true"`) and register `pa-demo-keycloak` across all 4 network scopes (`InfraExternalNetwork`, `CustomerExternalNetwork`, `VPC: infra`, and `VPC: default`):

```bash
kubectl --kubeconfig "${MP_KUBECONFIG}" apply -f ../manifests/mp/03-dns-cert-mp.yaml
```

Verify that `Secret/pa-demo-keycloak-mp-web-tls` is forwarded to `namespace: istio-system` on `infra-cp`:

```bash
kubectl --kubeconfig "${CP_KUBECONFIG}" -n istio-system get secret pa-demo-keycloak-mp-web-tls
```

---

## **Section 3: Deploy Keycloak StatefulSet & Istio Ingress (`infra-cp`)**

1. Create the runtime PKCS12 keystore, admin, and initial user secrets on `infra-cp`:
   ```bash
   for sec_key in "keycloak-cp-keystore-password:password" "bundledidp-local-admin-password:secret" "bundledidp-initial-user-password:secret"; do
     sec="${sec_key%%:*}"
     key="${sec_key##*:}"
     kubectl --kubeconfig "${CP_KUBECONFIG}" -n pa-demo-keycloak create secret generic "${sec}" \
       --from-literal="${key}=$(openssl rand -base64 24 | tr -d '=+/\n' | cut -c1-24)" \
       --dry-run=client -o yaml | kubectl --kubeconfig "${CP_KUBECONFIG}" apply -f -
   done
   ```
2. Apply `04-keycloak-cp.yaml` on `infra-cp` to provision the internal PKCS12 certificate (`commonName: pa-demo-keycloak`), `StatefulSet/keycloak-cp`, headless service, `DestinationRule`, dual-port Istio `Gateway`s (`443` and `8443`), and `VirtualService` (`name: open-paths`):
   ```bash
   kubectl --kubeconfig "${CP_KUBECONFIG}" apply -f ../manifests/cp/04-keycloak-cp.yaml
   kubectl --kubeconfig "${CP_KUBECONFIG}" -n pa-demo-keycloak rollout status statefulset/keycloak-cp --timeout=300s
   ```

---

## **Section 4: Bootstrap Realm & Federate Target Organization**

### 4.1 Seed the Shared Realm, Groups, and Users (`05-demo-realm-job-cp.yaml`)

```bash
kubectl --kubeconfig "${CP_KUBECONFIG}" apply -f ../manifests/cp/05-demo-realm-job-cp.yaml
kubectl --kubeconfig "${CP_KUBECONFIG}" -n pa-demo-keycloak wait --for=condition=complete job/keycloak-pa-demo-setup --timeout=180s
```

### 4.2 Connect a Target Organization (`verify-saml-e2e.sh`)

Run `verify-saml-e2e.sh --keep` to create the SAML 2.0 client (`https://ais-core.<TENANT_DNS_SUFFIX>`) and `groups` mapper in Keycloak, extract and base64-encode the realm's PEM signing certificate, apply `IdentityProviderConfig` and `IAMRoleBinding` on the target organization's Global API server, and verify the end-to-end SAML 2.0 login round-trip:

```bash
sudo ./verify-saml-e2e.sh --tenant-org <tenant-org> --keep
```

---

## **Section 5: Troubleshooting Common Failures**

| Symptom | Root Cause | Resolution |
| :--- | :--- | :--- |
| `cert-manager` `Certificate` fails with `asn1: structure error: length too large` | X.509 `commonName` exceeds the 64-byte RFC 5280 limit when using long GDC domain suffixes. | Set `spec.commonName` to `<fqdnPrefix>` (16 bytes) and place the full FQDNs in `spec.dnsNames`. |
| Browser receives `401 Unauthorized` or redirect to `gdchservices` login before reaching Keycloak | `VirtualService` HTTP route is intercepted by the platform `ais-ext-authz-session` `EnvoyFilter`. | Name the `VirtualService` HTTP route `name: open-paths`. |
| Connection timeout on `CustomerExternalNetwork` VIP port `443` | `g-svc-dataplane-ingress-gateway-internal` maps external port `443` to Envoy pod `targetPort: 8443`. | Configure both port `443` and port `8443` on `Gateway/keycloak-cp-customer-gateway`. |
| `IdentityProviderConfig` webhook rejects `idpCertificateDataList` | Raw XML base64 string from `/protocol/saml/descriptor` was passed instead of base64-encoded PEM. | Wrap the raw base64 string in `-----BEGIN CERTIFICATE-----` / `-----END CERTIFICATE-----` (64-char lines) and base64-encode the PEM text. |
