# AI-Enabled Blueprint End-to-End Test Guide (GCP Staging & Development)

> **Document ID:** `GUIDE-GCP-AI-BLUEPRINT-E2E`  
> **Target Environment:** Google Cloud Platform (GKE GPU Staging Cluster + Cloud Workstation)  
> **Companion Guides:**  
> - [AI-Enabled Blueprint E2E Deployment & Verification Guide (GDC-ag Production IaC)](./ai_enabled_e2e_gdc_production_iac_guide.md)  
> - [Zero-Tweak E2E Validation Runbook & IO/AO Upgrade Verification Suite](./e2e_zero_tweak_validation_runbook.md)  
> - [GUI Functional Walkthrough & Live Demo Playbook](./gui_demo_walkthrough_and_prompts.md)  
> **Integrated Stack:**  
> - **Inference & Routing Layer (`gemma-inference`):** Gemma 4 Gateway (`gdc_gemma_gw`), Dual-Model Serving (`gemma4:26b` MoE + `gemma4:31b` Dense), and Envoy `InferencePool` + `epp` (`blueprints/envoy-inference-pool`)  
> - **Mission & Chat Application Layer (`gemma-inference`):** Joint Intelligence E2E Synthesis Console + Integrated Standard Chat Client (`gemma-client`), Apache Kafka KRaft (`P4`), Resilient RAG (`P6`), Agentic SQL Analyst (`P7`), and Keycloak OIDC (`P12`) — exposed concurrently via **Kubernetes Gateway API (`8081`)** and **NGINX Ingress (`8082`)**  
> - **Developer Platform Layer (`gdc-dev`):** Sovereign Developer IDE (`8084`) & Admin Telemetry Console (`8083`) (`p13-gdc-dev`)

---

## 1. Architecture Overview & The Two Reference Tables

When developing and testing on GCP before packaging for Google Distributed Cloud air-gapped (**GDC-ag**), this unified E2E testbed validates **all AI-enabled blueprint capabilities simultaneously** without redundant deployments:
1. **Single Client Deployment for Both E2E Intelligence & Chat:** Deploying the Joint Intelligence E2E tutorial (`gemma-client`) automatically includes the **Standard Gemma Chat & Document Workspace Client**. You switch between the **Joint Intelligence Console** and the **Standard Gemma Client** using the mode switcher button in the top navigation bar—no separate chat client deployment is required.
2. **Simultaneous Ingress & Gateway API Validation:** Both **Kubernetes Gateway API** (`Port 8081`) and **NGINX Ingress** (`Port 8082`) run side-by-side in front of the E2E tutorial and chat client so you can test both traffic exposure patterns in the same session.
3. **Cross-Namespace AI Co-Pilot & Swarm Integration:** The `gdc-dev` Developer Platform (`Ports 8083 & 8084` in namespace `gdc-dev`) routes its Architect, Coder, Reviewer, and Swarm agents directly through `http://gemma-gateway.gemma-inference.svc.cluster.local/v1`.

### 1.1. Table 1: Cloud Workstation 5-Port Service, Ingress & Telemetry Mapping

| Workstation Port | Kubernetes Target (`Namespace`) | Container Port | Application / Interface | Traffic Data Plane & Telemetry Source |
| :--- | :--- | :--- | :--- | :--- |
| **Port `8080`** | `svc/gemma-gateway` (`gemma-inference`) | `80` $\rightarrow$ `8080` | **Gemma 4 Gateway Control Plane & Admin UI** | **Direct Service Tunnel.** Scrapes **live** inference engine state (`GET /api/ps` on `ollama-26b`/`31b` and `/metrics` on `vllm`), live token rate limits, classifier routing decisions, and active gateway sessions. |
| **Port `8081`** | `svc/gdc-gateway-tunnel` (`gemma-inference`) | `80` $\rightarrow$ `8080` | **Joint Intelligence E2E Console + Gemma Chat Client (via Gateway API)** | **Kubernetes Gateway API (`gdc-platform-gateway` + `HTTPRoute`).** Routes `/`, `/api/`, `/v1/`, and `/auth/` through the GKE Regional Internal Load Balancer VIP bridged via `socat`. Top navbar toggles between **Joint Intelligence Console** and **Standard Gemma Client**. |
| **Port `8082`** | `svc/gemma-ingress-gateway` (`gemma-inference`) | `80` $\rightarrow$ `8080` | **Joint Intelligence E2E Console + Gemma Chat Client (via NGINX Ingress)** | **NGINX Reverse Proxy Ingress.** Exposes the **exact same** `gemma-client` application as Port `8081` via standard Ingress rules so both Ingress and Gateway API can be tested side-by-side. |
| **Port `8083`** | `deploy/gdc-dev-landing-page` (`gdc-dev`) | `8081` | **`gdc-dev` Sovereign Admin & Telemetry Console** | **Isolated Admin Listener (`:8081`).** **Hybrid Telemetry:** Seeds `5` synthetic baseline events at pod startup so charts are non-empty, then records **live** disk/PVC usage (`/tmp/workspace`) and **live** IDE AI Swarm invocations, latencies, and session hibernate/terminate actions. |
| **Port `8084`** | `deploy/gdc-dev-landing-page` (`gdc-dev`) | `8080` | **`gdc-dev` Developer IDE & Multi-Agent Swarm Workspace** | **Isolated Developer Listener (`:8080`).** Serves the browser IDE (`/instances/default-workspace`), in-pod terminal sandbox, and AI Swarm dock (`Architect`, `Coder`, `Reviewer`, `Swarm`) backed by `gemma-gateway`. |

---

### 1.2. Table 2: Why OIDC Authentication Acts Differently Across the Interfaces

Because the stack combines the `gemma-inference` gateway/client patterns with the standalone `p13-gdc-dev` pattern in `gdc-dev`, each interface exercises a distinct OIDC integration pattern:

| Port(s) | Interface & Namespace | OIDC Authentication Mechanism | Credentials & Session Storage |
| :--- | :--- | :--- | :--- |
| **Port `8080`** | **Gemma 4 Gateway Control Plane** (`gemma-inference`) | **Server-Side Keycloak Token Exchange (ROPC) + Redirect SSO** (`gateway/proxy/main.py`). Submitting the login form on `/login/oidc` posts credentials to the FastAPI gateway, which exchanges them server-side against `http://keycloak-svc:8080/auth/realms/gdc-rag-realm/protocol/openid-connect/token` (`source: keycloak-jwt`) and sets `HttpOnly` HMAC-signed cookies (`gateway_oidc_token`, `gateway_auth_user`, `gateway_auth_role`). | **Keycloak Realm Users:**<br>• Admin: `charlie` / `password`<br>• Analyst: `alice` / `password` |
| **Ports `8081` & `8082`** | **Joint Intelligence E2E & Gemma Chat Client** (`gemma-inference`) | **Browser-Side OIDC Authorization Code Flow with PKCE (`S256`)** (`gemma-client/src/frontend/src/oidc.js`). Clicking **Sign In with Keycloak SSO** redirects the browser to Keycloak's native login screen (`/auth/realms/gdc-rag-realm/protocol/openid-connect/auth`), exchanges the authorization code in the browser for an RS256 JWT in `sessionStorage`, and attaches `Authorization: Bearer <jwt>` to API calls. | **Keycloak Realm Users:**<br>• Admin: `charlie` / `password`<br>• Analyst: `alice` / `password` |
| **Ports `8083` & `8084`** | **`gdc-dev` Admin Telemetry (`8083`) & Developer IDE (`8084`)** (`gdc-dev`) | **Self-Contained Pattern Simulated OIDC / Persona Portal** (`p13-gdc-dev/example-app/landing-page/app.py`). Because `p13-gdc-dev` is designed to run standalone in `gdc-dev` without requiring `gemma-inference`'s Keycloak service, its `/login/oidc` portal uses `ALLOW_SIMULATED_OIDC="true"` on GCP staging to issue port-isolated HMAC-signed cookies (`admin_auth_user` on `:8081` vs. `dev_auth_user` on `:8080`). | **1-Click Persona Buttons:**<br>• Port `8083`: `Sign in with Keycloak OIDC (Admin Account)` (`cluster-admin@gdc.local`)<br>• Port `8084`: `oidc-developer@gdc.local` |

---

## 2. Step 1: Atomic GPU Cluster Provisioning (or Existing Cluster Detection) & Cross-Region Registry Setup

> [!IMPORTANT]
> **Dynamic Multi-Region GPU Allocation vs. Existing Artifact Registry Region:**  
> Because GPU capacity on GCP (`nvidia-l4`, `nvidia-tesla-a100`, `nvidia-rtx-6000`) can experience regional stockouts, Step 2.1 uses **Atomic Provisioning with Dynamic Hardware Mapping** across `("us-east4" "us-west4" "europe-west4" "asia-southeast1" "us-central1")` and automatically exports the winning `ZONE` (`CLUSTER_ZONE`) and `REGION` (`CLUSTER_REGION`).  
> * **Preserves Running Clusters:** If `gdc-gemma-cluster` is **already running**, Step 2.1 detects its zone immediately and skips provisioning so your running cluster is **never deleted**.  
> * **Cross-Region Artifact Registry Support:** Step 2.2 independently discovers your existing Artifact Registry repository (`AR_REGION` / `AR_REPO_NAME` / `REGISTRY_HOST`), because the region where your ~40 GB of baked images already live (e.g., `us-central1`) may differ from the region where the GPU cluster was allocated (e.g., `us-east4` or `us-west4`).

### 2.1. Detect Running Cluster or Run Atomic Multi-Region GPU Provisioning

> [!TIP]
> **Handling Dirty Working Trees Before `git pull`:**  
> Deployment scripts (`install-all.sh`, `deploy-e2e-solution.sh`, `configure-blueprints.sh`) and `chmod +x` commands modify tracked manifests in place (`01-gateway-ollama.yaml`, `backend.yaml`, `frontend.yaml`). Always run `git stash` before `git pull origin main` so Git never blocks on local file modifications.

Run this in your **Cloud Workstation** terminal (`~/GitHub/gdc_gemma_gw`):

```bash
cd ~/GitHub/gdc_gemma_gw
git stash 2>/dev/null || true
git pull origin main

export CLUSTER_NAME="gdc-gemma-cluster"
export PROJECT_ID=$(gcloud config get-value project)
export NAMESPACE="gemma-inference"
export GDC_DEV_NAMESPACE="gdc-dev"
export GSA_NAME="gemma-gateway-sa"

# Format: "GPU_TYPE:MACHINE_TYPE:REQUIRED_COUNT"
# Ensures we never send an "Invalid accelerator spec" error
GPU_CONFIGS=(
    "nvidia-l4:g2-standard-24:2"
    "nvidia-tesla-a100:a2-highgpu-1g:1"
    "nvidia-rtx-6000:g4-standard-24:1"
)

REGIONS=("us-east4" "us-west4" "europe-west4" "asia-southeast1" "us-central1")

# 1. Safeguard: Check if gdc-gemma-cluster is ALREADY running so we never delete an active cluster
EXISTING_ZONE=$(gcloud container clusters list \
    --project "$PROJECT_ID" \
    --filter="name=${CLUSTER_NAME} AND status=RUNNING" \
    --format="value(location)" 2>/dev/null | head -n 1)

if [ -n "$EXISTING_ZONE" ]; then
    export ZONE="$EXISTING_ZONE"
    export CLUSTER_ZONE="$EXISTING_ZONE"
    export REGION="${EXISTING_ZONE%-*}"
    export CLUSTER_REGION="$REGION"
    echo "------------------------------------------------"
    echo "EXISTING RUNNING CLUSTER DETECTED: $CLUSTER_NAME in $ZONE (REGION: $REGION)"
    echo "Skipping cluster creation to preserve running cluster."
    echo "------------------------------------------------"
else
    echo "Starting Atomic Provisioning with Dynamic Hardware Mapping..."
    CLUSTER_CREATED="false"

    for REGION_CANDIDATE in "${REGIONS[@]}"; do
        ZONES=$(gcloud compute zones list --project "$PROJECT_ID" --filter="region:$REGION_CANDIDATE" --format="value(name)")

        for ZONE_CANDIDATE in $ZONES; do
            for CONFIG in "${GPU_CONFIGS[@]}"; do
                GPU_TYPE=$(echo "$CONFIG" | cut -d: -f1)
                MACHINE=$(echo "$CONFIG" | cut -d: -f2)
                COUNT=$(echo "$CONFIG" | cut -d: -f3)

                echo "--- Checking $ZONE_CANDIDATE for $MACHINE ($COUNT x $GPU_TYPE) ---"

                if gcloud container clusters create "$CLUSTER_NAME" \
                    --project "$PROJECT_ID" \
                    --zone "$ZONE_CANDIDATE" \
                    --release-channel "regular" \
                    --machine-type "$MACHINE" \
                    --accelerator "type=$GPU_TYPE,count=$COUNT,gpu-driver-version=LATEST" \
                    --num-nodes 1 \
                    --enable-dataplane-v2 \
                    --gateway-api=standard \
                    --workload-pool "$PROJECT_ID.svc.id.goog" \
                    --disk-size=300 \
                    --node-labels="app=vllm-26b" \
                    --tags=gdc-emulation \
                    --quiet 2> error.log; then
                    export ZONE="$ZONE_CANDIDATE"
                    export CLUSTER_ZONE="$ZONE_CANDIDATE"
                    export REGION="${ZONE_CANDIDATE%-*}"
                    export CLUSTER_REGION="$REGION"
                    CLUSTER_CREATED="true"
                    echo "------------------------------------------------"
                    echo "SUCCESS: Cluster live in $ZONE (REGION: $REGION)"
                    echo "HARDWARE: $MACHINE with $COUNT x $GPU_TYPE"
                    echo "------------------------------------------------"
                    break 3
                else
                    ERR=$(cat error.log)
                    if [[ "$ERR" == *"ALREADY_EXISTS"* ]]; then
                        echo "RESULT: Cluster $CLUSTER_NAME already exists in $ZONE_CANDIDATE; preserving."
                        export ZONE="$ZONE_CANDIDATE"
                        export CLUSTER_ZONE="$ZONE_CANDIDATE"
                        export REGION="${ZONE_CANDIDATE%-*}"
                        export CLUSTER_REGION="$REGION"
                        CLUSTER_CREATED="true"
                        break 3
                    elif [[ "$ERR" == *"RESOURCES_EXHAUSTED"* || "$ERR" == *"STOCKOUT"* || "$ERR" == *"does not have"* ]]; then
                        echo "RESULT: Stockout for $GPU_TYPE in $ZONE_CANDIDATE. Trying next..."
                        gcloud container clusters delete "$CLUSTER_NAME" --zone "$ZONE_CANDIDATE" --project "$PROJECT_ID" --quiet > /dev/null 2>&1 || true
                    else
                        echo "RESULT: Unexpected Error: $ERR"
                        gcloud container clusters delete "$CLUSTER_NAME" --zone "$ZONE_CANDIDATE" --project "$PROJECT_ID" --quiet > /dev/null 2>&1 || true
                    fi
                fi
            done
        done
    done
fi

# 2. Connect kubectl credentials to the active cluster zone
gcloud container clusters get-credentials "$CLUSTER_NAME" --zone "$CLUSTER_ZONE" --project "$PROJECT_ID"

# 3. Ensure standard CPU node pool (client-pool) and Gateway API proxy-only subnet exist in $CLUSTER_REGION
if ! gcloud container node-pools describe client-pool --cluster "$CLUSTER_NAME" --zone "$CLUSTER_ZONE" --project "$PROJECT_ID" >/dev/null 2>&1; then
    gcloud container node-pools create client-pool \
        --cluster "$CLUSTER_NAME" \
        --project "$PROJECT_ID" \
        --zone "$CLUSTER_ZONE" \
        --machine-type "e2-standard-4" \
        --num-nodes 2 \
        --node-labels="app=client" \
        --quiet
fi

if [ -z "$(gcloud compute networks subnets list --filter="region:${CLUSTER_REGION} AND purpose:REGIONAL_MANAGED_PROXY" --format="value(name)" --project="${PROJECT_ID}")" ]; then
    gcloud compute networks subnets create "gke-gateway-proxy-${CLUSTER_REGION}" \
        --purpose=REGIONAL_MANAGED_PROXY \
        --role=ACTIVE \
        --region="${CLUSTER_REGION}" \
        --network=default \
        --range=172.16.2.0/23 \
        --project="${PROJECT_ID}" || true
fi

gcloud compute firewall-rules create allow-gateway-internal \
    --network=default \
    --direction=INGRESS \
    --priority=1000 \
    --action=ALLOW \
    --rules=tcp:80,tcp:443,tcp:8000,tcp:8080,tcp:8081 \
    --source-ranges=10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,35.191.0.0/16,130.211.0.0/22 \
    --project="${PROJECT_ID}" 2>/dev/null || \
gcloud compute firewall-rules update allow-gateway-internal \
    --rules=tcp:80,tcp:443,tcp:8000,tcp:8080,tcp:8081 \
    --source-ranges=10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,35.191.0.0/16,130.211.0.0/22 \
    --project="${PROJECT_ID}"

kubectl get nodes -o wide
```

### 2.2. Configure Artifact Registry Repository (Enter Known Details or Auto-Detect Cross-Region)

Because the atomic GPU loop in Step 2.1 may place your GKE cluster in `us-east4`, `us-west4`, `europe-west4`, `asia-southeast1`, or `us-central1`, your existing Artifact Registry repository (holding the ~40 GB of baked `ollama-gemma-26b` and `ollama-gemma-31b` images) may reside in a different region from `CLUSTER_REGION`.

Use **Option A** if you already know your Artifact Registry region and repository name, or **Option B** to list and auto-detect existing repositories across your GCP project.

#### Option A: Enter Known Artifact Registry Details Directly

Edit `AR_REGION` and `AR_REPO_NAME` (or set `REGISTRY_HOST` directly) and run:

```bash
# Enter your known Artifact Registry region and repository name:
export AR_REGION="us-east4"          # e.g., us-east4, us-west4, or us-central1
export AR_REPO_NAME="gemma-repo"     # e.g., gemma-repo
export REPO_REGION="${AR_REGION}"
export REGISTRY_HOST="${AR_REGION}-docker.pkg.dev/${PROJECT_ID}/${AR_REPO_NAME}"

# Ensure the repository exists (no-op if it already exists) and authenticate Docker
gcloud services enable artifactregistry.googleapis.com --project="${PROJECT_ID}"
gcloud artifacts repositories describe "${AR_REPO_NAME}" --location="${AR_REGION}" --project="${PROJECT_ID}" >/dev/null 2>&1 || \
gcloud artifacts repositories create "${AR_REPO_NAME}" \
  --repository-format=docker \
  --location="${AR_REGION}" \
  --project="${PROJECT_ID}"

gcloud auth configure-docker "${AR_REGION}-docker.pkg.dev" --quiet

echo "=================================================================="
echo "GKE Cluster Location : ZONE=${CLUSTER_ZONE} (CLUSTER_REGION=${CLUSTER_REGION})"
echo "Artifact Registry    : REGISTRY_HOST=${REGISTRY_HOST} (AR_REGION=${AR_REGION})"
echo "Namespaces           : ${NAMESPACE} (AI/E2E) | ${GDC_DEV_NAMESPACE} (Dev IDE)"
echo "=================================================================="
```

#### Option B: List & Auto-Detect Existing Artifact Registry Repository (If Details Are Not Known)

If you want to inspect all Docker repositories across your project and automatically bind to your existing `gemma-repo` repository across any region:

```bash
# 1. Clear any stale registry variables from previous runs and list all Docker repositories
unset REGISTRY_HOST AR_REGION AR_REPO_NAME REPO_REGION
gcloud services enable artifactregistry.googleapis.com --project="${PROJECT_ID}"
echo "Existing Docker repositories in project ${PROJECT_ID}:"
gcloud artifacts repositories list \
  --project="${PROJECT_ID}" \
  --filter="format:DOCKER" \
  --format="table(name.basename():label=REPOSITORY,format:label=FORMAT,name.segment(3):label=LOCATION)"

# 2. Auto-detect existing registry:
#    (a) Image path from a currently running gemma-gateway deployment (if present)
#    (b) Any existing Docker repository across the project that already contains 'ollama-gemma-26b'
#    (c) First existing Docker repository matching 'gemma', or fallback to $CLUSTER_REGION/gemma-repo
EXISTING_GW_IMG=$(kubectl get deploy gemma-gateway -n "${NAMESPACE}" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)

if [[ "${EXISTING_GW_IMG}" == *"-docker.pkg.dev/"* ]]; then
  export REGISTRY_HOST="${EXISTING_GW_IMG%/gemma-*}"
  export AR_REGION="${REGISTRY_HOST%%-docker.pkg.dev*}"
  export AR_REPO_NAME="${REGISTRY_HOST##*/}"
else
  DETECTED_LOC=""
  DETECTED_NAME=""
  while read -r CAND_LOC CAND_NAME; do
    [ -z "${CAND_LOC}" ] && continue
    if gcloud artifacts docker images list "${CAND_LOC}-docker.pkg.dev/${PROJECT_ID}/${CAND_NAME}" \
         --format="value(package)" 2>/dev/null | grep -q "ollama-gemma-26b"; then
      DETECTED_LOC="${CAND_LOC}"
      DETECTED_NAME="${CAND_NAME}"
      break
    fi
  done < <(gcloud artifacts repositories list \
    --project="${PROJECT_ID}" \
    --filter="format:DOCKER" \
    --format="value(name.segment(3),name.basename())")

  if [ -z "${DETECTED_LOC}" ]; then
    GEMMA_REPO_LINE=$(gcloud artifacts repositories list \
      --project="${PROJECT_ID}" \
      --filter="format:DOCKER AND name~gemma" \
      --format="value(name.segment(3),name.basename())" | head -n 1)
    if [ -z "${GEMMA_REPO_LINE}" ]; then
      GEMMA_REPO_LINE=$(gcloud artifacts repositories list \
        --project="${PROJECT_ID}" \
        --filter="format:DOCKER" \
        --format="value(name.segment(3),name.basename())" | head -n 1)
    fi
    DETECTED_LOC=$(echo "${GEMMA_REPO_LINE}" | awk '{print $1}')
    DETECTED_NAME=$(echo "${GEMMA_REPO_LINE}" | awk '{print $2}')
  fi

  export AR_REGION="${DETECTED_LOC:-$CLUSTER_REGION}"
  export AR_REPO_NAME="${DETECTED_NAME:-gemma-repo}"
  export REGISTRY_HOST="${AR_REGION}-docker.pkg.dev/${PROJECT_ID}/${AR_REPO_NAME}"
fi

export REPO_REGION="${AR_REGION}"

gcloud artifacts repositories describe "${AR_REPO_NAME}" --location="${AR_REGION}" --project="${PROJECT_ID}" >/dev/null 2>&1 || \
gcloud artifacts repositories create "${AR_REPO_NAME}" \
  --repository-format=docker \
  --location="${AR_REGION}" \
  --project="${PROJECT_ID}"

# 3. Authenticate Docker to the Artifact Registry region (AR_REGION)
gcloud auth configure-docker "${AR_REGION}-docker.pkg.dev" --quiet

echo "=================================================================="
echo "GKE Cluster Location : ZONE=${CLUSTER_ZONE} (CLUSTER_REGION=${CLUSTER_REGION})"
echo "Artifact Registry    : REGISTRY_HOST=${REGISTRY_HOST} (AR_REGION=${AR_REGION})"
echo "Namespaces           : ${NAMESPACE} (AI/E2E) | ${GDC_DEV_NAMESPACE} (Dev IDE)"
echo "=================================================================="
```

---

## 3. Step 2: Deploy Gemma 4 Gateway, Dual-Model Serving (`26B` + `31B`) & Envoy `InferencePool`

```bash
cd ~/GitHub/gdc_gemma_gw
# Stash any local manifest or file-mode edits (from sed -i / chmod +x) before pulling
git stash 2>/dev/null || true
git pull origin main

# 1. Create target namespace
kubectl apply -f standalone/manifests/00-namespace.yaml

# 2. Check if baked Ollama model images already exist in REGISTRY_HOST;
#    if not, run ./scripts/build-and-push.sh to build & push proxy + 26B + 31B images:
if ! gcloud artifacts docker images list "${REGISTRY_HOST}" --format="value(package)" 2>/dev/null | grep -q "ollama-gemma-26b"; then
  echo "Building and pushing gemma-proxy + ollama-gemma-26b + ollama-gemma-31b to ${REGISTRY_HOST}..."
  chmod +x scripts/build-and-push.sh
  ./scripts/build-and-push.sh
else
  echo "Baked Ollama model images already exist in ${REGISTRY_HOST}; building updated gemma-proxy only..."
  export IMAGE_TAG="envoy-pool-$(date +%s)"
  docker build -t "${REGISTRY_HOST}/gemma-proxy:${IMAGE_TAG}" -t "${REGISTRY_HOST}/gemma-proxy:latest" gateway/proxy
  docker push "${REGISTRY_HOST}/gemma-proxy:${IMAGE_TAG}"
  docker push "${REGISTRY_HOST}/gemma-proxy:latest"
fi

# 3. Deploy side-by-side Ollama 26B + 31B and Gemma 4 Gateway
export INFERENCE_ENGINE="ollama"
export OLLAMA_MODEL_VARIANT="26b"
chmod +x standalone/install-all.sh
./standalone/install-all.sh

# 4. Ensure Admin OIDC and Envoy InferencePool environment variables are set on gemma-gateway
#    (ENABLE_OIDC="false" + ADMIN_REQUIRE_OIDC="true" enforces Keycloak OIDC on Port 8080 Admin UI
#     while allowing in-cluster backends on Ports 8081/8082/8084 to forward X-User-ID identities)
kubectl set env deployment/gemma-gateway -n "${NAMESPACE}" \
  ENABLE_OIDC="false" \
  ADMIN_REQUIRE_OIDC="true" \
  KEYCLOAK_URL="http://keycloak-svc:8080/auth/realms/gdc-rag-realm" \
  ENVOY_INFERENCE_POOL_ENABLED="false" \
  ENVOY_INFERENCE_POOL_URL="http://gemma-envoy-ai-gateway.${NAMESPACE}.svc.cluster.local/v1"

kubectl rollout status deployment/ollama-26b -n "${NAMESPACE}" --timeout=300s
kubectl rollout status deployment/ollama-31b -n "${NAMESPACE}" --timeout=300s
kubectl rollout status deployment/gemma-gateway -n "${NAMESPACE}" --timeout=120s
```

---

## 4. Step 3: Deploy the Joint Intelligence E2E Tutorial (Includes Chat Client) on Both Ingress & Gateway API

> [!NOTE]
> **No Separate Chat Client Deployment Needed:**  
> Running `deploy-e2e-solution.sh` deploys `gemma-client` (`deployment/frontend` and `deployment/backend`), which powers **both** the **Joint Intelligence E2E Synthesis Console** and the **Standard Gemma Chat & RAG Client**. Below, we first ensure PostgreSQL (`postgres-0`) and Keycloak (`keycloak-svc`) are running in `gemma-inference`, and then enable **both** the NGINX Staging Ingress (`svc/gemma-ingress-gateway` on Port `8082`) and the Kubernetes Gateway API (`svc/gdc-gateway-tunnel` on Port `8081`) so you can test both ingress architectures side-by-side.

```bash
cd ~/GitHub/gdc_gemma_gw

# 1. Verify or create GCS Object Storage bucket (gs://gemma-client-files-${PROJECT_ID})
#    and bind GKE Workload Identity for serviceaccount/gemma-client-sa:
export BUCKET_NAME="gs://gemma-client-files-${PROJECT_ID}"
export GSA_NAME="gemma-client-sa"
export KSA_NAME="gemma-client-sa"

gcloud storage buckets describe "${BUCKET_NAME}" --project="${PROJECT_ID}" >/dev/null 2>&1 || \
gcloud storage buckets create "${BUCKET_NAME}" \
  --project="${PROJECT_ID}" \
  --location="${CLUSTER_REGION}" \
  --uniform-bucket-level-access

gcloud iam service-accounts describe "${GSA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com" --project="${PROJECT_ID}" >/dev/null 2>&1 || \
gcloud iam service-accounts create "${GSA_NAME}" --project="${PROJECT_ID}"

gcloud storage buckets add-iam-policy-binding "${BUCKET_NAME}" \
  --member="serviceAccount:${GSA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com" \
  --role="roles/storage.objectAdmin" --quiet >/dev/null

gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${GSA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com" \
  --role="roles/storage.objectAdmin" \
  --condition=None --quiet >/dev/null || true

gcloud iam service-accounts add-iam-policy-binding "${GSA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com" \
  --project="${PROJECT_ID}" \
  --role="roles/iam.workloadIdentityUser" \
  --member="serviceAccount:${PROJECT_ID}.svc.id.goog[${NAMESPACE}/${KSA_NAME}]" --quiet >/dev/null

kubectl create serviceaccount "${KSA_NAME}" -n "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
kubectl annotate serviceaccount "${KSA_NAME}" -n "${NAMESPACE}" \
  "iam.gke.io/gcp-service-account=${GSA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com" --overwrite

# 2. Ensure PostgreSQL (postgres-0) and Keycloak OIDC (keycloak) are running in gemma-inference
kubectl create secret generic gemma-client-db-credentials \
  --from-literal=username=postgres \
  --from-literal=password=password \
  --from-literal=db_name=postgres \
  --from-literal=connection_string="postgresql://postgres:password@postgres-svc.gemma-inference.svc.cluster.local:5432/postgres" \
  -n "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f gemma-client/manifests/gcp/postgres-configmap.yaml -n "${NAMESPACE}"
kubectl apply -f gemma-client/manifests/gcp/statefulset-postgres.yaml -n "${NAMESPACE}"
kubectl rollout status statefulset/postgres -n "${NAMESPACE}" --timeout=120s

kubectl apply -f gemma-client/manifests/gcp/keycloak-realm-import.yaml -n "${NAMESPACE}"
kubectl apply -f gemma-client/manifests/gcp/keycloak-staging.yaml -n "${NAMESPACE}"
kubectl rollout status deployment/keycloak -n "${NAMESPACE}" --timeout=180s

# 3. Build and push telemetry-consumer to REGISTRY_HOST
docker build -t "${REGISTRY_HOST}/telemetry-consumer:latest" glue-code/telemetry-consumer
docker push "${REGISTRY_HOST}/telemetry-consumer:latest"

# 4. Build gemma-client (Frontend + Backend) and deploy E2E Solution with NGINX Ingress (Port 8082)
chmod +x scripts/deploy-e2e-solution.sh
INGRESS_MODE=nginx ./scripts/deploy-e2e-solution.sh

# 5. Also enable Kubernetes Gateway API + L4 Tunnel (Port 8081) concurrently
kubectl apply -f gemma-client/manifests/gcp/gateway-api-staging.yaml -n "${NAMESPACE}"
kubectl apply -f gemma-client/manifests/gdc/security/production-gateway-routing.yaml -n "${NAMESPACE}"

echo "Waiting for GKE Gateway API (gdc-platform-gateway) VIP allocation..."
for i in {1..30}; do
  GATEWAY_VIP=$(kubectl get gateway gdc-platform-gateway -n "${NAMESPACE}" -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)
  if [ -n "${GATEWAY_VIP}" ]; then
    echo "Allocated GATEWAY_VIP: ${GATEWAY_VIP}"
    break
  fi
  sleep 5
done

if [ -n "${GATEWAY_VIP}" ]; then
  kubectl set env deployment/gdc-gateway-tunnel GATEWAY_VIP="${GATEWAY_VIP}" -n "${NAMESPACE}"
  kubectl rollout status deployment/gdc-gateway-tunnel -n "${NAMESPACE}" --timeout=60s
fi
```

---

## 5. Step 4: Deploy `p13-gdc-dev` (Sovereign Developer Platform & Telemetry Console)

Deploy `p13-gdc-dev` into the `gdc-dev` namespace, wired directly to `http://gemma-gateway.gemma-inference.svc.cluster.local/v1`:

```bash
cd ~/GitHub/GDC-blueprints 2>/dev/null || cd ~/GitHub/gdc-iac-org/blueprints/patterns
git stash 2>/dev/null || true
git pull origin main 2>/dev/null || true

# 1. Build and push gdc-dev-landing-page and gdc-dev-operator to REGISTRY_HOST
docker build -t "${REGISTRY_HOST}/gdc-dev-landing-page:latest" p13-gdc-dev/example-app/landing-page
docker push "${REGISTRY_HOST}/gdc-dev-landing-page:latest"

docker build -t "${REGISTRY_HOST}/gdc-dev-operator:latest" p13-gdc-dev/example-app/operator
docker push "${REGISTRY_HOST}/gdc-dev-operator:latest"

# 2. Apply Namespace, Operator, OIDC Config, AI Gateway Config, and Phase 3 Agentic Deployment
kubectl apply -f p13-gdc-dev/manifests/gdc/namespace.yaml
kubectl apply -f p13-gdc-dev/manifests/gdc/gdc-dev-operator.yaml
kubectl apply -f p13-gdc-dev/manifests/gdc/oidc-auth-configmap.yaml
kubectl apply -f p13-gdc-dev/manifests/gdc/ai-gateway-configmap.yaml
kubectl apply -f p13-gdc-dev/manifests/gdc/gdc-dev-agent-configmap.yaml
kubectl apply -f p13-gdc-dev/manifests/gdc/gdc-dev-phase3-deployment.yaml

# 3. Enable GCP Staging port-forward OIDC login & X-User-ID propagation on gdc-dev-oidc-auth-config
#    (Prevents '{"error": "Missing verified OIDC identity header", "status": 401}' when connecting via kubectl port-forward)
kubectl patch configmap gdc-dev-oidc-auth-config -n "${GDC_DEV_NAMESPACE}" \
  --type merge -p '{"data":{"ALLOW_SIMULATED_OIDC":"true","HEADER_USER_KEY":"X-User-ID"}}'

# 4. Point deployments to REGISTRY_HOST, restart to pick up ConfigMap, and wait for rollout
kubectl set image deployment/gdc-dev-landing-page landing-page="${REGISTRY_HOST}/gdc-dev-landing-page:latest" -n "${GDC_DEV_NAMESPACE}"
kubectl set image deployment/gdc-dev-operator operator="${REGISTRY_HOST}/gdc-dev-operator:latest" -n "${GDC_DEV_NAMESPACE}"
kubectl rollout restart deployment/gdc-dev-landing-page deployment/gdc-dev-operator -n "${GDC_DEV_NAMESPACE}"
kubectl rollout status deployment/gdc-dev-landing-page -n "${GDC_DEV_NAMESPACE}" --timeout=90s
kubectl rollout status deployment/gdc-dev-operator -n "${GDC_DEV_NAMESPACE}" --timeout=90s

# 5. Return to gdc_gemma_gw working directory
cd ~/GitHub/gdc_gemma_gw
```

---

## 6. Step 5: Start the 5-Port Workstation Port-Forwards & Run E2E Verification

### 6.1. Start Persistent Port-Forwards (`8080`–`8084`) & Verify Pod Health

```bash
# 1. Check all pods across both namespaces
kubectl get pods -n "${NAMESPACE}"
kubectl get pods -n "${GDC_DEV_NAMESPACE}"

# 2. Restart persistent port-forward loops on 0.0.0.0 for Cloud Workstation preview
pkill -f "kubectl port-forward" || true
sleep 2

# Port 8080 -> Gemma 4 Gateway Control Plane (svc/gemma-gateway:80)
nohup bash -c "while true; do kubectl port-forward --address 0.0.0.0 svc/gemma-gateway 8080:80 -n ${NAMESPACE} >> /tmp/pf-8080.log 2>&1; sleep 1; done" >/dev/null 2>&1 &

# Port 8081 -> Joint Intelligence E2E & Chat Client via Gateway API (svc/gdc-gateway-tunnel:80)
nohup bash -c "while true; do kubectl port-forward --address 0.0.0.0 svc/gdc-gateway-tunnel 8081:80 -n ${NAMESPACE} >> /tmp/pf-8081.log 2>&1; sleep 1; done" >/dev/null 2>&1 &

# Port 8082 -> Joint Intelligence E2E & Chat Client via NGINX Ingress (svc/gemma-ingress-gateway:80)
nohup bash -c "while true; do kubectl port-forward --address 0.0.0.0 svc/gemma-ingress-gateway 8082:80 -n ${NAMESPACE} >> /tmp/pf-8082.log 2>&1; sleep 1; done" >/dev/null 2>&1 &

# Port 8083 (gdc-dev Admin Telemetry :8081) & Port 8084 (gdc-dev Developer IDE :8080)
nohup bash -c "while true; do kubectl port-forward --address 0.0.0.0 deployment/gdc-dev-landing-page 8084:8080 8083:8081 -n ${GDC_DEV_NAMESPACE} >> /tmp/pf-8083-8084.log 2>&1; sleep 1; done" >/dev/null 2>&1 &

sleep 3
for p in 8080 8081 8082 8083 8084; do
  code=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:${p}/")
  echo "Port ${p} -> HTTP ${code}"
done
```

### 6.2. Automated 17-Check CLI Verification Suite (`scripts/verify-e2e-gcp-staging.py`)

Run the standalone 17-check IO/AO verification suite (`scripts/verify-e2e-gcp-staging.py`), which validates Kubernetes pod health, OIDC login, live telemetry, Tier 1 (`26B MoE`) and Tier 2 (`31B Dense`) routing, system-role flattening, runtime parameter hot-swap, session blocklist enforcement, Gateway API (`8081`) vs. Ingress (`8082`) parity, Kafka sensor telemetry, SITREP RAG, Agentic SQL + Security Gate (`DROP TABLE` rejection), GCS document upload/readback, source-grounded RAG $\rightarrow$ general chat toggle, and `gdc-dev` Admin/IDE Swarm (`8083`/`8084`) with `[PASS]` / `[FAIL]` flags:

```bash
chmod +x ~/GitHub/gdc_gemma_gw/scripts/verify-e2e-gcp-staging.py
~/GitHub/gdc_gemma_gw/scripts/verify-e2e-gcp-staging.py --json-report /tmp/gcp-staging-e2e-report.json

# Inspect filtered gateway routing logs (excluding 2-second UI polling noise)
kubectl logs -n "${NAMESPACE}" deploy/gemma-gateway --tail=300 | grep -E "Classifier|Routing|completions|OIDC|ERROR"
```

### 6.3. Interactive Browser Test Matrix Across All 5 Ports

> [!TIP]
> **Full Demo Script & Copy-Paste Prompts:**  
> For a complete click-by-click walkthrough with copy-pasteable prompts, sample RAG upload files, and expected UI badges for live demonstrations, see [GUI Functional Walkthrough & Live Demo Playbook](./gui_demo_walkthrough_and_prompts.md).

1. **Port `8080` (`🧠 Gemma 4 Gateway Control Plane`)**:
   * **OIDC Authentication Bar (Top Strip)**: Click **`🛡️ One-Click Admin (charlie)`** or **`🔑 Keycloak SSO Login (/auth)`** (`charlie` / `password`) to sign in (`Role: ADMIN`).
   * **Card 1 — `⚡ Live System Performance & Telemetry`**: Verify live `CPU Load` and `GPU Core Load` gauges, `Tokens Out/Sec`, `Active DB Pools`, and the `VRAM Consumption` progress bar.
   * **Card 2 — `🎛️ Gateway Parameters Override`**: Adjust `Temperature`, `Top-P`, `Max Vision Tokens (Vision Budgets)`, or **`Model Variant Hot-Swap`** (`Gemma 4 26B A4B (MoE)` vs. `Gemma 4 31B (Dense)`), then click **`Save Gateway Configuration`**.
   * **Card 3 — `🕵️ Active User Session Oversight & Kill-Switch`**: Displays `User ID`, `Client IP`, `Status`, `Last Active`, and the **`Kill Session`** button.
     > **Note on When Users Appear in `Active User Session Oversight & Kill-Switch`:** Logging into Keycloak on Port `8081` (`alice`) or Port `8082` (`charlie`) authenticates the browser with the frontend, but `gemma-gateway` records a session in this table **only when that user submits an AI inference request** (`/v1/chat/completions`) via **Tactical Chat**, **All-Source Intel (RAG)**, **Operational Readiness (SQL)**, or the **GDC Dev AI Swarm**.
   * **Card 4 — `👥 User Access Blocklist Management`**: Enter a `User ID` (e.g., `alice`) and click **`Block User`** to test instant `403 Forbidden` revocation, then click **`Unblock`** to restore access.

2. **Port `8081` (Gateway API) & Port `8082` (NGINX Ingress) — `Joint Intelligence & Readiness Console` / `Gemma Client`**:
   * Open Port `8081` (log in via **Sign In with Keycloak SSO** as `alice` / `password`) and Port `8082` (log in as `charlie` / `password`) to verify identical behavior across **Kubernetes Gateway API** (`HTTPRoute`) and **NGINX Ingress**.
   * **Top Navigation Bar Controls**:
     * **Mode Switcher (`🛡️ Intel Console` | `💬 Gemma Client`)**: Click **`🛡️ Intel Console`** for the 4-tab Joint Intelligence Console, or click **`💬 Gemma Client`** to switch to the standard multi-turn chat and document RAG upload view without redeploying any pods.
     * **Model Routing Dropdown**: Select **`Gemma 4 Gateway (Auto)`** (automatic Tier 1 / Tier 2 complexity routing), **`Gemma 4 26B A4B (MoE)`** (manual Tier 1 pin), or **`Gemma 4 31B (Dense)`** (manual Tier 2 pin). When **`Gemma 4 Gateway (Auto)`** is active, after a response completes, a routing badge (`→ gemma4:26b` or `→ gemma4:31b`) appears next to the dropdown showing which model tier executed the prompt.
     * **`🧠 CoT` Checkbox**: Toggle Chain-of-Thought reasoning traces on or off.
   * **The 4 Tabs in `🛡️ Intel Console`**:
     * **Tab 1 — `Tactical Feeds (Kafka)` (`Live Stream`)**: Inspect multi-domain telemetry (`LAND`, `AIR`, `SEA`, `SPACE`, `CYBER`) and click **`⚡ Ingest Sensor Pings`** to inject fresh Kafka sensor frames.
     * **Tab 2 — `All-Source Intel (RAG)` (`SITREPs`)**: Click one of the **`Suggested Inquiries`** pills (or type a custom query) and click **`Synthesize`** to execute pgvector semantic retrieval and generate a **`Tactical Intelligence Synthesis`** with `[SITREP-...]` citations and a `Model: ...` badge.
     * **Tab 3 — `Operational Readiness (SQL)` (`Agentic`)**: Click a **`Command Questions`** pill (or enter a readiness question) and click **`Audit`** to generate and execute a read-only PostgreSQL query and executive readiness summary. Verify SQL guardrails by submitting `DROP TABLE military_units;` and confirming it returns **`Rejected by Security Gate`**.
     * **Tab 4 — `Tactical Chat` (`Gemma 4`)**: Submit a chat prompt as `alice` on Port `8081` and a chat prompt as `charlie` on Port `8082`. Then return to **Port `8080`** and confirm that **both `alice` and `charlie` now appear** in the **`🕵️ Active User Session Oversight & Kill-Switch`** table.

3. **Port `8083` (`gdc-dev` Sovereign Admin & Telemetry Console)**:
   * Click **Sign in with Keycloak OIDC (Admin Account)**.
   * Observe the initial 5 seeded baseline events, publish a real-time **Cluster Broadcast Banner**, and leave the tab open while using Port `8084` to watch live AI Swarm telemetry and workspace disk usage update every 3 seconds.

4. **Port `8084` (`gdc-dev` Developer IDE & Multi-Agent Swarm)**:
   * Click **Sign in with Keycloak OIDC** and open `/instances/default-workspace`. Verify that the broadcast banner published on Port `8083` appears at the top of the IDE.
   * In the **`🤖 GDC Dev AI Swarm`** panel, select **`💻 Coder`** or **`🐝 Swarm`**, submit a coding prompt, approve the surgical diff preview (`✓ Approve & Execute`), run the code in the integrated terminal, and verify that the invocation is logged in real time on Port `8083` (and `oidc-developer@gdc.local` appears in Port `8080`'s Active User Sessions table).

---

## 7. Step 6: Live Serving Engine Flip (`Ollama` $\rightarrow$ `vLLM` $\rightarrow$ Verify $\rightarrow$ `Ollama`)

Before running the cleanup stage, validate that `gemma-gateway` can hot-swap its downstream serving engine from **Ollama** (`ollama-26b-service:11434` / `ollama-31b-service:11434`) to **vLLM** (`vllm-26b-vllm-gke-service:8000` / `vllm-31b-vllm-gke-service:8000`), pass end-to-end Tier 1 and Tier 2 completion tests (including automatic `system` role message flattening), and cleanly flip back to **Ollama**.

> [!NOTE]
> **Why We Scale Ollama to `0` During the Swap on 2x L4 GKE Clusters:**  
> Your `g2-standard-24` node pool has **2x NVIDIA L4 GPUs (24 GB VRAM each)**. Scaling `ollama-26b` and `ollama-31b` to `0` replicas frees both GPUs immediately without deleting the Ollama deployments or cached node images, allowing the flip back to Ollama in Step 6C to complete in seconds.

### 7.1. Phase 6A: Flip from `Ollama` to `vLLM` (`vllm-26b` & `vllm-31b`)

```bash
cd ~/GitHub/gdc_gemma_gw

# 1. Determine vLLM test model:
#    - Uses 'google/gemma-2b-it' if secret/hf-token-secret (or $HF_TOKEN) is present.
#    - Automatically falls back to ungated 'Qwen/Qwen2.5-1.5B-Instruct' if no HF token is configured,
#      preventing 401 GatedRepoError while still advertising servedModelName='gemma4:26b' & 'gemma4:31b'.
if [ -n "${HF_TOKEN:-}" ]; then
  kubectl create secret generic hf-token-secret \
    --from-literal=token="${HF_TOKEN}" \
    -n "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
fi

if kubectl get secret hf-token-secret -n "${NAMESPACE}" >/dev/null 2>&1; then
  export VLLM_TEST_MODEL="${VLLM_TEST_MODEL:-google/gemma-2b-it}"
  echo "Found hf-token-secret in ${NAMESPACE}; using VLLM_TEST_MODEL=${VLLM_TEST_MODEL}"
else
  export VLLM_TEST_MODEL="${VLLM_TEST_MODEL:-Qwen/Qwen2.5-1.5B-Instruct}"
  echo "No hf-token-secret found; using ungated VLLM_TEST_MODEL=${VLLM_TEST_MODEL} with --served-model-name gemma4:26b / gemma4:31b"
fi

# 2. Scale Ollama 26B & 31B down to 0 replicas to release both L4 GPUs
kubectl scale deployment ollama-26b ollama-31b -n "${NAMESPACE}" --replicas=0
kubectl wait --for=delete pod -l app.kubernetes.io/name=ollama -n "${NAMESPACE}" --timeout=90s || true

# 3. Deploy vllm-26b (GPU #1) and vllm-31b (GPU #2) via the vllm-gke Helm chart
helm upgrade --install vllm-26b ./blueprints/vllm-gke -n "${NAMESPACE}" \
  --set model.name="${VLLM_TEST_MODEL}" \
  --set model.servedModelName="gemma4:26b" \
  --set persistence.enabled=false \
  --set resources.limits.gpu=1 \
  --set resources.requests.cpu="2000m" \
  --set resources.requests.memory="12Gi" \
  --set resources.limits.memory="24Gi"

helm upgrade --install vllm-31b ./blueprints/vllm-gke -n "${NAMESPACE}" \
  --set model.name="${VLLM_TEST_MODEL}" \
  --set model.servedModelName="gemma4:31b" \
  --set persistence.enabled=false \
  --set resources.limits.gpu=1 \
  --set resources.requests.cpu="2000m" \
  --set resources.requests.memory="12Gi" \
  --set resources.limits.memory="24Gi"

# 4. Wait for both vLLM engine pods to load weights and pass readiness checks (~60-120s)
kubectl rollout status deployment/vllm-26b-vllm-gke -n "${NAMESPACE}" --timeout=240s
kubectl rollout status deployment/vllm-31b-vllm-gke -n "${NAMESPACE}" --timeout=240s

# 5. Flip gemma-gateway to ACTIVE_FRAMEWORK="vllm" (preserving OIDC and custom image)
kubectl set env deployment/gemma-gateway -n "${NAMESPACE}" \
  ACTIVE_FRAMEWORK="vllm" \
  MODEL_ROUTING_CONFIG='{"gemma4:26b":"http://vllm-26b-vllm-gke-service:8000","gemma4:31b":"http://vllm-31b-vllm-gke-service:8000","*":"http://vllm-26b-vllm-gke-service:8000"}'

kubectl rollout status deployment/gemma-gateway -n "${NAMESPACE}" --timeout=90s
kubectl get pods -n "${NAMESPACE}" -l app.kubernetes.io/name=vllm-gke -o wide
```

### 7.2. Phase 6B: Verify `vLLM` Serving, Tiered Routing & System-Role Flattener

Run this verification test against Port `8080` to confirm that `gemma-gateway` reports `framework: "vllm"` and routes Tier 1 (`gemma4:26b`) and Tier 2 (`gemma4:31b`, including a `system` role directive) through the live vLLM pods:

```bash
python3 -c '
import urllib.request, http.cookiejar, json

cj = http.cookiejar.CookieJar()
opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(cj))

# 1. Verify /api/metrics reports active framework == vllm
with opener.open("http://127.0.0.1:8080/api/metrics", timeout=15) as m_resp:
    metrics = json.loads(m_resp.read().decode("utf-8"))
    fw = metrics.get("framework")
    print("Active Gateway Framework:", fw, "| Engine Status:", metrics.get("status"))
    assert fw == "vllm", f"Expected framework=vllm, got {fw}"

# 2. Authenticate via Keycloak OIDC (/login/oidc) using charlie / password
login_req = urllib.request.Request(
    "http://127.0.0.1:8080/login/oidc",
    data=json.dumps({"username": "charlie", "password": "password", "role": "admin"}).encode("utf-8"),
    headers={"Content-Type": "application/json"}
)
with opener.open(login_req, timeout=15) as login_resp:
    login_data = json.loads(login_resp.read().decode("utf-8"))
    print("OIDC Auth:", login_resp.status, "User:", login_data.get("user"), "Source:", login_data.get("source"))

# 3. Test Tier 1 (vllm-26b) conversational query
req_vllm_26b = urllib.request.Request(
    "http://127.0.0.1:8080/v1/chat/completions",
    data=json.dumps({
        "model": "gemma4",
        "max_tokens": 96,
        "messages": [{"role": "user", "content": "What is Google Distributed Cloud in one sentence?"}]
    }).encode("utf-8"),
    headers={"Content-Type": "application/json"}
)
with opener.open(req_vllm_26b, timeout=120) as resp:
    body = json.loads(resp.read().decode("utf-8"))
    print("\n[vLLM Tier 1] Status:", resp.status, "| X-Model-Used:", resp.headers.get("X-Model-Used"), "| X-Model-Tier:", resp.headers.get("X-Model-Tier"))
    print("Reply:", body["choices"][0]["message"]["content"][:160].replace("\n", " "))

# 4. Test Tier 2 (vllm-31b) code query + System Role Flattener
req_vllm_31b = urllib.request.Request(
    "http://127.0.0.1:8080/v1/chat/completions",
    data=json.dumps({
        "model": "gemma4",
        "max_tokens": 96,
        "messages": [
            {"role": "system", "content": "You are a concise Python coding assistant."},
            {"role": "user", "content": "Write a Python function to compute Fibonacci numbers."}
        ]
    }).encode("utf-8"),
    headers={"Content-Type": "application/json"}
)
with opener.open(req_vllm_31b, timeout=120) as resp:
    body = json.loads(resp.read().decode("utf-8"))
    print("\n[vLLM Tier 2] Status:", resp.status, "| X-Model-Used:", resp.headers.get("X-Model-Used"), "| X-Model-Tier:", resp.headers.get("X-Model-Tier"))
    print("Reply:", body["choices"][0]["message"]["content"][:160].replace("\n", " "))
'

# Confirm vLLM routing in gemma-gateway pod logs
kubectl logs -n "${NAMESPACE}" deploy/gemma-gateway --tail=200 | grep -E "Classifier|Routing|vllm|flattening|System role"
```

### 7.3. Phase 6C: Flip Back from `vLLM` to `Ollama` (`26B` & `31B`) & Verify

Now restore the baked `ollama-26b` and `ollama-31b` deployments as the final test stage before cleanup:

```bash
# 1. Uninstall vLLM Helm releases and wait for both L4 GPUs to be released
helm uninstall vllm-26b vllm-31b -n "${NAMESPACE}"
kubectl delete pod -n "${NAMESPACE}" -l app.kubernetes.io/name=vllm-gke --grace-period=0 --force --ignore-not-found

# 2. Scale Ollama 26B and 31B back to 1 replica each
kubectl scale deployment ollama-26b ollama-31b -n "${NAMESPACE}" --replicas=1
kubectl rollout status deployment/ollama-26b -n "${NAMESPACE}" --timeout=180s
kubectl rollout status deployment/ollama-31b -n "${NAMESPACE}" --timeout=180s

# 3. Flip gemma-gateway back to ACTIVE_FRAMEWORK="ollama"
kubectl set env deployment/gemma-gateway -n "${NAMESPACE}" \
  ACTIVE_FRAMEWORK="ollama" \
  MODEL_ROUTING_CONFIG='{"gemma4:26b":"http://ollama-26b-service:11434","gemma4:31b":"http://ollama-31b-service:11434","*":"http://ollama-26b-service:11434"}'

kubectl rollout status deployment/gemma-gateway -n "${NAMESPACE}" --timeout=90s

# 4. Verify /api/metrics reports framework=="ollama" and test completion routing
python3 -c '
import urllib.request, http.cookiejar, json

cj = http.cookiejar.CookieJar()
opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(cj))

with opener.open("http://127.0.0.1:8080/api/metrics", timeout=15) as m_resp:
    metrics = json.loads(m_resp.read().decode("utf-8"))
    fw = metrics.get("framework")
    print("Restored Gateway Framework:", fw, "| Engine Status:", metrics.get("status"))
    assert fw == "ollama", f"Expected framework=ollama, got {fw}"

login_req = urllib.request.Request(
    "http://127.0.0.1:8080/login/oidc",
    data=json.dumps({"username": "charlie", "password": "password", "role": "admin"}).encode("utf-8"),
    headers={"Content-Type": "application/json"}
)
opener.open(login_req, timeout=15).close()

req = urllib.request.Request(
    "http://127.0.0.1:8080/v1/chat/completions",
    data=json.dumps({
        "model": "gemma4",
        "max_tokens": 96,
        "messages": [{"role": "user", "content": "Confirm in one sentence that Ollama serving is restored."}]
    }).encode("utf-8"),
    headers={"Content-Type": "application/json"}
)
with opener.open(req, timeout=180) as resp:
    body = json.loads(resp.read().decode("utf-8"))
    print("[Ollama Restored Test] Status:", resp.status, "| X-Model-Used:", resp.headers.get("X-Model-Used"), "| X-Model-Tier:", resp.headers.get("X-Model-Tier"))
    print("Reply:", body["choices"][0]["message"]["content"][:160].replace("\n", " "))
'

kubectl logs -n "${NAMESPACE}" deploy/gemma-gateway --tail=150 | grep -E "Classifier|Routing|ollama"
```

---

## 8. Step 7: Non-Destructive Workload Cleanup Script & Guidance (Preserves Running GKE Cluster)

> [!IMPORTANT]
> **GKE Cluster & Artifact Registry Preservation Guarantee:**  
> The cleanup script below (`scripts/cleanup-e2e-gcp.sh`) **never deletes your running GKE cluster (`gdc-gemma-cluster`), GPU node pools, VPC proxy-only subnet, firewall rules, or Artifact Registry images.**  
> It only removes the Kubernetes application workloads, Helm releases, PVCs, and namespaces (`gemma-inference` and `gdc-dev`) so you can re-run the E2E deployment from Step 2 on the warm cluster in minutes.

### 8.1. What `scripts/cleanup-e2e-gcp.sh` Cleans Up vs. What It Preserves

| Resource Category | Action Taken by `cleanup-e2e-gcp.sh` | Why |
| :--- | :--- | :--- |
| **Workstation Port-Forwards (`8080`–`8084`)** | **Stopped (`pkill -f "kubectl port-forward"`)** | Frees local ports `8080`–`8084` cleanly before next run. |
| **Helm Releases & Workloads in `gemma-inference`** | **Deleted** (`gemma-envoy-pool`, `vllm-26b`, `vllm-31b`, `ollama-26b`, `ollama-31b`, `gemma-gateway`, `gemma-client`, `kafka`, `postgres`, `keycloak`, `gdc-platform-gateway`) | Resets all AI gateway, serving, Ingress, Gateway API, and E2E tutorial pods/PVCs. |
| **Workloads & RBAC in `gdc-dev`** | **Deleted** (`gdc-dev-landing-page`, `gdc-dev-operator`, `ClusterRole/Binding`, `gdc-dev` namespace) | Resets the Developer IDE and Telemetry Console cleanly. |
| **Cloud Storage RAG Bucket (`gs://gemma-client-files-${PROJECT_ID}`)** | **Preserved by default**; `--empty-bucket` deletes objects only; `--delete-bucket` removes the bucket completely | Lets you choose whether to keep uploaded files, wipe objects while keeping the bucket, or remove the bucket entirely. |
| **GKE Cluster (`gdc-gemma-cluster`) & GPU Node Pools** | **PRESERVED (Never Deleted)** | Avoids 15-minute GKE cluster recreation and preserves your allocated NVIDIA L4 GPU capacity in `${CLUSTER_ZONE}`. |
| **Artifact Registry (`${REGISTRY_HOST}`) & Node Image Cache** | **PRESERVED (Never Deleted)** | Keeps the ~40 GB of baked `ollama-gemma-26b`, `ollama-gemma-31b`, `vllm`, `gemma-proxy`, and `gemma-client` images ready for instant pulls. |

### 8.2. Run the Non-Destructive Workload Cleanup Script

Run `./scripts/cleanup-e2e-gcp.sh` (with optional `--empty-bucket` or `--delete-bucket` flags):

```bash
cat << 'EOF' > ~/GitHub/gdc_gemma_gw/scripts/cleanup-e2e-gcp.sh
#!/usr/bin/env bash
# Non-Destructive E2E Workload Cleanup Script for GCP GKE Staging
# Tears down Kubernetes workloads, Helm releases, and namespaces (gemma-inference & gdc-dev)
# while strictly PRESERVING the running GKE cluster, GPU node pools, VPC subnets, and Artifact Registry.
#
# Optional Bucket Cleanup Flags:
#   (default)        Preserves gs://gemma-client-files-${PROJECT_ID} and its objects
#   --empty-bucket   Deletes all objects inside gs://gemma-client-files-${PROJECT_ID} while keeping the bucket
#   --delete-bucket  Completely removes gs://gemma-client-files-${PROJECT_ID} and all objects inside it

set -euo pipefail

NAMESPACE="${NAMESPACE:-gemma-inference}"
GDC_DEV_NAMESPACE="${GDC_DEV_NAMESPACE:-gdc-dev}"
PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null || true)}"
BUCKET_NAME="${BUCKET_NAME:-gemma-client-files-${PROJECT_ID}}"
BUCKET_URI="gs://${BUCKET_NAME#gs://}"
BUCKET_ACTION="${BUCKET_ACTION:-preserve}"

for arg in "$@"; do
  case "${arg}" in
    --empty-bucket)
      BUCKET_ACTION="empty"
      ;;
    --delete-bucket)
      BUCKET_ACTION="delete"
      ;;
    -h|--help)
      echo "Usage: $0 [--empty-bucket | --delete-bucket]"
      echo "  (default)        Preserves ${BUCKET_URI} and its objects"
      echo "  --empty-bucket   Deletes all objects from ${BUCKET_URI} but keeps the bucket"
      echo "  --delete-bucket  Completely deletes ${BUCKET_URI} and all its objects"
      exit 0
      ;;
    *)
      echo "Unknown option: ${arg}" >&2
      echo "Usage: $0 [--empty-bucket | --delete-bucket]" >&2
      exit 1
      ;;
  esac
done

echo "=================================================================="
echo "🧹 Starting Non-Destructive E2E Workload Cleanup"
echo "   Target Namespaces : ${NAMESPACE}, ${GDC_DEV_NAMESPACE}"
echo "   GCS RAG Bucket    : ${BUCKET_URI} (Action: ${BUCKET_ACTION})"
echo "   GKE Cluster       : PRESERVED (Not Deleted)"
echo "   Artifact Registry : PRESERVED (Not Deleted)"
echo "=================================================================="

# 1. Stop background kubectl port-forward loops on the Cloud Workstation
echo "[1/6] Stopping background port-forward processes (8080-8084)..."
pkill -f "kubectl port-forward" 2>/dev/null || true

# 2. Uninstall Helm releases in gemma-inference and gdc-dev (if present)
echo "[2/6] Uninstalling Helm releases in ${NAMESPACE} and ${GDC_DEV_NAMESPACE}..."
for rel in gemma-envoy-pool vllm-26b vllm-31b ollama-26b ollama-31b gemma-gateway gemma-standalone gemma-client; do
  helm uninstall "${rel}" -n "${NAMESPACE}" 2>/dev/null || true
done
helm uninstall gdc-dev-platform -n "${GDC_DEV_NAMESPACE}" 2>/dev/null || true

# 3. Clear any PVC finalizers so namespace deletion never hangs
echo "[3/6] Clearing PVC protection finalizers in ${NAMESPACE} and ${GDC_DEV_NAMESPACE}..."
for ns in "${NAMESPACE}" "${GDC_DEV_NAMESPACE}"; do
  for pvc in $(kubectl get pvc -n "${ns}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true); do
    kubectl patch pvc "${pvc}" -n "${ns}" -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
  done
done

# 4. Delete cluster-scoped RBAC / GatewayClass objects created by p13-gdc-dev
echo "[4/6] Cleaning up p13-gdc-dev cluster-scoped RBAC & GatewayClass resources..."
kubectl delete clusterrolebinding gdc-dev-operator-binding --ignore-not-found
kubectl delete clusterrole gdc-dev-operator-role --ignore-not-found
kubectl delete gatewayclass gdc-dev-gateway-class --ignore-not-found

# 5. Delete application namespaces (gemma-inference and gdc-dev)
echo "[5/6] Deleting namespaces '${NAMESPACE}' and '${GDC_DEV_NAMESPACE}'..."
kubectl delete namespace "${NAMESPACE}" --ignore-not-found --wait=true
kubectl delete namespace "${GDC_DEV_NAMESPACE}" --ignore-not-found --wait=true

# 6. Optional Cloud Storage bucket cleanup (--empty-bucket or --delete-bucket)
if [ "${BUCKET_ACTION}" = "empty" ]; then
  echo "[6/6] Emptying all objects from ${BUCKET_URI} (keeping bucket)..."
  if gcloud storage buckets describe "${BUCKET_URI}" >/dev/null 2>&1; then
    gcloud storage rm "${BUCKET_URI}/**" 2>/dev/null || echo "   Bucket ${BUCKET_URI} is already empty."
  else
    echo "   Bucket ${BUCKET_URI} does not exist; skipping."
  fi
elif [ "${BUCKET_ACTION}" = "delete" ]; then
  echo "[6/6] Completely removing bucket ${BUCKET_URI} and all its objects..."
  if gcloud storage buckets describe "${BUCKET_URI}" >/dev/null 2>&1; then
    gcloud storage rm --recursive "${BUCKET_URI}"
  else
    echo "   Bucket ${BUCKET_URI} does not exist; skipping."
  fi
else
  echo "[6/6] Preserving Cloud Storage bucket ${BUCKET_URI} (pass --empty-bucket or --delete-bucket to clean up)."
fi

echo "=================================================================="
echo "✅ Workload cleanup complete!"
echo "   Active GKE cluster nodes remain online and ready for re-testing:"
kubectl get nodes -o wide
echo "=================================================================="
EOF

chmod +x ~/GitHub/gdc_gemma_gw/scripts/cleanup-e2e-gcp.sh

# Option A (Default): Clean up workloads while preserving gs://gemma-client-files-${PROJECT_ID} and its objects
~/GitHub/gdc_gemma_gw/scripts/cleanup-e2e-gcp.sh

# Option B: Clean up workloads AND delete all objects inside gs://gemma-client-files-${PROJECT_ID} (keeping the bucket)
# ~/GitHub/gdc_gemma_gw/scripts/cleanup-e2e-gcp.sh --empty-bucket

# Option C: Clean up workloads AND completely remove gs://gemma-client-files-${PROJECT_ID}
# ~/GitHub/gdc_gemma_gw/scripts/cleanup-e2e-gcp.sh --delete-bucket
```
