Copyright 2026 Google. This software is provided as-is, without warranty or representation for any use or purpose. Your use of it is subject to your agreement with Google.

# Third-Party Dependency Security Review

**Scope:** The capacity-sizing toolkit and the workload patterns represented in this directory, including the browser form, calculator, presentation, CLI, catalog, and referenced blueprint families. This is a source review, not a live vulnerability scan of deployed images or services.

## Executive Summary

There are two confirmed third-party script dependencies in the browser artifacts: Tailwind CSS from `cdn.tailwindcss.com` and an additional script from a Google `.../web/dev/...` URL. They are loaded at runtime without a pinned release or Subresource Integrity (SRI). Because these scripts execute in the same page as intake data, compromise or unexpected upstream change can expose or alter customer inputs and calculator output. They also prevent the pages from being fully self-contained/offline as described by the project documentation.

The Python CLI imports only Python standard-library modules and is documented as having zero pip dependencies. The architecture patterns name many third-party products, but this workspace does not pin their versions or include their deployment manifests, lockfiles, or SBOMs. Therefore, no product-specific CVE can responsibly be confirmed or ruled out from these files. The product-specific items below are vulnerability classes to assess once deployed versions are inventoried, not claims that a particular CVE is present.

## Findings

### F-01: Mutable remote browser scripts execute alongside intake data

**Priority: High. Confirmed exposure; no specific CVE established.**

The calculator, its `index.html` mirror, and the slide deck load both `https://cdn.tailwindcss.com` and `https://www.gstatic.com/antigravity/web/dev/tailwindcss.min.js`. The interview form loads `https://cdn.tailwindcss.com`. None of these script elements pins an immutable version or uses SRI. A compromised publisher/CDN, DNS/TLS trust path, account, or upstream release can run arbitrary same-page JavaScript. The scripts can read and modify visible form fields, DOM content, URL fragments, and same-origin browser storage; where network connectivity exists, they could transmit intake data. A changed/broken upstream response can also disrupt page operation. The `/web/dev/` URL is especially unsuitable as a production dependency because it explicitly identifies a development path.

**Evidence:** [gdc_ag_sizing_calculator.html](gdc_ag_sizing_calculator.html#L7), [index.html](index.html#L7), [gdc_ag_interview_form.html](gdc_ag_interview_form.html#L7), [presentation.html](presentation.html#L7), and the documented offline/self-contained workflow in [README.md](README.md#L1).

### F-02: No versioned inventory for software named by workload patterns

**Priority: High. Exposure and assurance gap; installed versions are unknown.**

The patterns describe Kafka, PostgreSQL/pgvector, Keycloak, Vault, vLLM, Ollama, MLflow, ADK, a `gemma-client`/Gemini GUI, developer IDE/build tooling, Harbor, and model/container bundles, but do not specify release versions, image digests, transitive dependencies, supported-version policy, or SBOM/provenance requirements. The `--catalog` facility is sizing data, not a software dependency inventory. An air gap reduces direct internet reachability but does not remove vulnerabilities in imported images, packages, plugins, model loaders, or update bundles.

**Evidence:** patterns in [gdc_ag_offline_interview_questionnaire.md](gdc_ag_offline_interview_questionnaire.md#L118), platform service names in [MAINTENANCE.md](MAINTENANCE.md#L106), and artifact sideloading described in [gdc_ag_workload_sizing_and_intake_framework.md](gdc_ag_workload_sizing_and_intake_framework.md#L174).

### F-03: Untrusted HTML data can reach `innerHTML` (adjacent first-party issue)

**Priority: High when loading untrusted intake/catalog data. This is not an upstream-library CVE.**

The interview form builds HTML from catalog values and inserts some intake-derived values into HTML summaries. The calculator also renders catalog descriptions as HTML and lets an operator apply edited catalog JSON. Crafted project names or catalog descriptions can therefore become script-capable markup. This is an independent cross-site scripting weakness, and it increases the impact of the remote-script exposure in F-01. Treat all imported JSON and editable catalog text as untrusted.

**Evidence:** dynamic catalog rendering and editing in [gdc_ag_sizing_calculator.html](gdc_ag_sizing_calculator.html#L859) and [gdc_ag_sizing_calculator.html](gdc_ag_sizing_calculator.html#L890); interview catalog rendering and summary rendering in [gdc_ag_interview_form.html](gdc_ag_interview_form.html#L789) and [gdc_ag_interview_form.html](gdc_ag_interview_form.html#L988).

## Pattern-by-Pattern Upstream Risk Register

These are the upstream components named or implied by the patterns in this workspace. Exact applicability depends on the implementation and version selected by the platform team.

| Blueprint / service | Upstream components to inventory | Vulnerability classes to check |
| --- | --- | --- |
| P1 Web / P3 Legacy VM | Managed PostgreSQL; guest OS and application runtime are unspecified | Database/OS/runtime CVEs, unsupported releases, web framework and parser RCE, application dependency supply-chain issues |
| P4 Event Pipeline | Apache Kafka, broker/client libraries, PostgreSQL | Broker/client RCE or DoS, authentication/authorization bypass, unsafe serializers, TLS/ACL misconfiguration, database and extension CVEs |
| P6 RAG / P_MULTI synthesis | PostgreSQL + pgvector, document parsers/OCR/embedding libraries, model runtime | Malformed-document parser RCE/DoS, vulnerable database extension, unsafe model/artifact loading, poisoned dependencies, prompt-injection-driven tool abuse (not necessarily a CVE) |
| P7 SQL Agent | ADK/agent SDK, model client, PostgreSQL | SDK/client CVEs; tool-call privilege escalation; generated SQL escaping the intended read-only scope. Prompt injection and unsafe tool permissions are application risks, not necessarily upstream CVEs. |
| P8 MLOps | MLflow and the selected ML/framework/CUDA/GPU software stack | Tracking-server/API exposure, authentication bypass, unsafe artifact/model deserialization, training package RCE, vulnerable GPU/container base images |
| P9/P10 Notebook and chat | `gemma-client`/Gemini GUI (identity and version unspecified), PostgreSQL, model/API client | Unknown/unmaintained package risk, web UI XSS/auth bypass, unsafe notebook execution, data leakage, model-client vulnerabilities |
| P2/P5 AI gateway | vLLM, Ollama, custom `gdc_gemma_gw` proxy, model-serving dependencies | Exposed unauthenticated management/inference APIs, RCE/DoS, unsafe model loading, parser vulnerabilities, vulnerable CUDA/base images, proxy auth and request-routing flaws |
| P11 Secrets / P12 Identity | HashiCorp Vault, Keycloak, PostgreSQL | Secret disclosure, auth bypass, privilege escalation, session/token flaws, plugin/extension vulnerabilities, insecure defaults and unsupported versions |
| P13 Developer workspaces | Browser IDE, build tools, extensions/plugins, container tooling (not identified by product/version) | Workspace or extension-triggered code execution, vulnerable build dependencies, credential exposure, malicious/tampered build inputs and images |
| All patterns / supply-chain path | Harbor and imported container images, Helm charts, OS packages, model files | Known vulnerable transitive packages, typosquatting, malicious/tampered artifacts, stale bases, missing signatures/provenance, unsafe model formats |

The shared C2 synthesis pattern composes the risks of P4, P6, P7, P2/P5, P9/P10, and P12; it needs one consolidated inventory and trust boundary review, not a separate exception from the component controls.

## Remediation Plan

### 1. Contain the confirmed browser exposure

1. Remove both runtime CDN scripts from the calculator, `index.html`, interview form, and presentation. Replace Tailwind CDN usage with generated, version-pinned static CSS committed or packaged with the toolkit; remove the unneeded development script after verifying its function.
2. Keep the HTML workflow functional with networking disabled. Add an offline smoke check that opens each page without remote requests and verifies styling and core interactions.
3. Where any remote asset must remain, use an immutable release URL plus verified SRI and a restrictive CSP. SRI alone does not make a mutable URL or development endpoint acceptable. Since these pages currently use inline scripts and handlers, CSP should be implemented with hashes/nonces or after moving code to local files, not with a policy that silently breaks functionality.
4. Do not enter real customer data into a copy of the tool that still loads unapproved remote scripts. Restrict outbound network access for the approved offline workflow.

### 2. Remove the adjacent HTML injection path

1. Render untrusted values with `textContent` and DOM element creation; do not concatenate imported fields/catalog strings into `innerHTML`.
2. If catalog descriptions intentionally support limited markup, define and apply a small allowlist sanitizer. Validate catalog schema and limits before applying it; HTML escaping of quotes alone is insufficient.
3. Add regression tests using a project name, intake JSON, and catalog description containing HTML/event-handler payloads. Verify they display as text and do not execute in either calculator or interview form.

### 3. Build the dependency inventory for every deployed pattern

1. For each selected pattern, record product, exact version, source, maintainer, deployment owner, support/EOL date, configuration owner, and whether it is a direct dependency, transitive library, platform-managed service, or custom component.
2. Require immutable image digests and SBOMs for every container; include OS packages, language packages, plugins/operators, GPU/CUDA stack, and model-serving dependencies. Record model file format and provenance separately from software SBOMs.
3. Resolve ambiguous names before adoption, especially `gemma-client`, Gemini GUI, ADK, `gdc_gemma_gw`, and the P13 IDE/build stack. Do not approve an unspecified or unmaintained component as a production dependency.
4. Select supported release trains for Kafka, PostgreSQL/pgvector, Keycloak, Vault, MLflow, vLLM, Ollama, and all agent/IDE libraries. The current workspace alone cannot determine which versions are affected by upstream advisories.

### 4. Gate air-gap imports and deployment on supply-chain evidence

1. Mirror approved artifacts through a controlled connected staging environment; scan source packages, container layers, IaC/manifests, and model artifacts with organization-approved scanners and advisory feeds.
2. Verify publisher signatures/provenance and image digests before transfer; rescan after import and before deployment. Reject unsigned, unknown-origin, unsupported, or policy-failing artifacts.
3. Enforce least privilege and network segmentation: Kafka TLS/authentication/ACLs; database least-privilege roles and patched extensions; Vault/Keycloak supported configurations and secured administration; authenticated, isolated model-serving APIs; isolated MLflow and notebook/IDE execution.
4. For P6/P7, sandbox file ingestion and restrict agent tools. The SQL agent must use a dedicated read-only database identity, schema/table allowlists, bounded queries, and no unrestricted shell or write-capable tools. Treat retrieved documents and model output as untrusted.
5. For P8/P9/P10/P13, prohibit unreviewed plugins/extensions and unsafe model/notebook execution; isolate build/training workspaces and credentials from production services.

### 5. Operate patching and exception handling for disconnected sites

1. Assign an owner and update cadence to each dependency family. Review upstream vendor security advisories continuously in the connected staging environment and re-run scans whenever an artifact changes.
2. Define remediation deadlines from the organization’s vulnerability policy, including an emergency path for actively exploited/critical issues, a documented risk acceptance with expiry, and a tested rollback procedure.
3. Publish signed, versioned offline update bundles with a manifest of included versions, SBOMs, advisories fixed, signatures, and checksums. Track delivery and installation status per enclave.
4. Make deployment approval conditional on supported versions, clean/policy-approved scans or an approved exception, verified provenance, security configuration checks, and recovery/rollback evidence.

## Validation Needed Before Assigning CVE IDs

This workspace has no package manifest, lockfile, container image references/digests, or SBOM for the described architecture. The source review confirms unpinned CDN script exposure and missing dependency governance, but it cannot establish whether a named server-side product is running a vulnerable release. After the inventory in Step 3 is assembled, scan those exact artifacts against current vendor advisories and the organization’s approved vulnerability databases; record CVE/GHSA IDs, affected/fixed versions, reachability, severity, and disposition in the deployment-specific register.

**Review limitation:** This workspace includes sizing and pattern summaries, not the referenced implementation-guide files themselves. This review covers every pattern named in the available local framework/catalog; implementation-specific manifests and configuration must be reviewed when they are available.