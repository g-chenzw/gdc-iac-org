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

# Stage 2: Applied to Organization Management Plane (infra-mp)
# 1. Issues Web TLS Certificate in istio-system and forwards Secret '__FQDN_PREFIX__-mp-web-tls' to infra-cp.
# 2. Registers '__FQDN_PREFIX__.<org>.<zone>.<domain>' across CustomerExternalNetwork (PA),
#    InfraExternalNetwork (IO), and internal VPCs.
apiVersion: pki.security.gdc.goog/v1
kind: Certificate
metadata:
  name: __FQDN_PREFIX__-mp-cert
  namespace: istio-system
  annotations:
    lcm.private.gdc.goog/claim-by-force: "true"
    helm.sh/resource-policy: keep
spec:
  dnsNames:
    - __FQDN_PREFIX__.__DNS_SUFFIX__
    - __FQDN_PREFIX__.__GLOBAL_DNS_SUFFIX__
  duration: 8760h
  renewBefore: 2160h
  secretConfig:
    secretName: __FQDN_PREFIX__-mp-web-tls
    secretTemplate:
      annotations:
        pki.security.gdc.goog/forward-to-cp: "true"
    privateKeyConfig:
      algorithm: RSA
      size: 3072
---
# Exposes __FQDN_PREFIX__.<org>.<zone>.<domain> on InfraExternalNetwork (IO External VIP)
apiVersion: network.private.gdc.goog/v1alpha1
kind: DNSRegistration
metadata:
  name: __FQDN_PREFIX__
  namespace: __NAMESPACE__
  annotations:
    lcm.private.gdc.goog/claim-by-force: "true"
spec:
  fqdnPrefix: __FQDN_PREFIX__
  resolutionConfig:
    exposeToNetwork: InfraExternalNetwork
    resolveTo:
      useDefaultIstioGateway:
        owningCluster: InfraCluster
        ingressLabel: infra
---
# Exposes __FQDN_PREFIX__.<org>.<zone>.<domain> on internal Infra VPC
apiVersion: network.private.gdc.goog/v1alpha1
kind: DNSRegistration
metadata:
  name: __FQDN_PREFIX__-infra-internal
  namespace: __NAMESPACE__
  annotations:
    lcm.private.gdc.goog/claim-by-force: "true"
spec:
  fqdnPrefix: __FQDN_PREFIX__
  resolutionConfig:
    exposeToNetwork: VPC
    vpcIdentifier: infra
    resolveTo:
      useDefaultIstioGateway:
        owningCluster: InfraCluster
        ingressLabel: infra
---
# Exposes __FQDN_PREFIX__.<org>.<zone>.<domain> on internal Default (Customer) VPC
apiVersion: network.private.gdc.goog/v1alpha1
kind: DNSRegistration
metadata:
  name: __FQDN_PREFIX__-customer-internal
  namespace: __NAMESPACE__
  annotations:
    lcm.private.gdc.goog/claim-by-force: "true"
spec:
  fqdnPrefix: __FQDN_PREFIX__
  resolutionConfig:
    exposeToNetwork: VPC
    vpcIdentifier: default
    resolveTo:
      useDefaultIstioGateway:
        owningCluster: InfraCluster
        ingressLabel: data
---
# Exposes __FQDN_PREFIX__.<org>.<zone>.<domain> on CustomerExternalNetwork (shared PA network VIP)
apiVersion: network.private.gdc.goog/v1alpha1
kind: DNSRegistration
metadata:
  name: __FQDN_PREFIX__-customer-external
  namespace: __NAMESPACE__
  annotations:
    lcm.private.gdc.goog/claim-by-force: "true"
spec:
  fqdnPrefix: __FQDN_PREFIX__
  resolutionConfig:
    exposeToNetwork: CustomerExternalNetwork
    resolveTo:
      useDefaultIstioGateway:
        owningCluster: InfraCluster
        ingressLabel: data
