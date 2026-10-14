#!/usr/bin/env bash
# Declarative IaC E2E Workload Cleanup Script for Google Distributed Cloud Air-Gapped (GDC-ag)
# Tears down Stage 5 (5-workload-factory) AI-enabled blueprint releases via Helmfile
# while strictly PRESERVING Stage 3 GPU Clusters, Stage 2 Harbor/SAN Model Weights, and Stage 1 Projects.

set -euo pipefail

ENV="${ENV:-prd}"
INCLUDE_ZONAL_RESOURCES="${1:-}"
NAMESPACE="${NAMESPACE:-gemma-inference}"
GDC_DEV_NAMESPACE="${GDC_DEV_NAMESPACE:-gdc-dev}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}/foundations"

echo "=================================================================="
echo "🧹 Starting Declarative GDC-ag IaC Cleanup (Environment: ${ENV})"
echo "   Stage 5 Workloads (AI Gateway, vLLM, E2E, gdc-dev) : DESTROY"
echo "   Stage 3 Shared GPU Cluster (gpu-moe / gpu-dense)   : PRESERVED"
echo "   Stage 2 Harbor Registry & SAN Model Weight PVCs    : PRESERVED"
echo "=================================================================="

# 1. Destroy all Stage 5 (5-workload-factory) Helmfile releases across gemma-inference & gdc-dev
echo "[1/4] Running helmfile destroy for stage=5-workload-factory..."
helmfile -e "${ENV}" -l stage=5-workload-factory destroy

# 2. Clean up dynamic per-developer IDE workspace PVCs in gdc-dev (preserving shared SAN model weights in gemma-inference)
echo "[2/4] Cleaning up dynamic developer workspace PVCs in ${GDC_DEV_NAMESPACE}..."
for pvc in $(kubectl get pvc -n "${GDC_DEV_NAMESPACE}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true); do
  kubectl patch pvc "${pvc}" -n "${GDC_DEV_NAMESPACE}" -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
  kubectl delete pvc "${pvc}" -n "${GDC_DEV_NAMESPACE}" --ignore-not-found
done

# 3. Clean up cluster-scoped RBAC & GatewayClass created by p13-gdc-dev
echo "[3/4] Removing cluster-scoped p13-gdc-dev RBAC & GatewayClass..."
kubectl delete clusterrolebinding gdc-dev-operator-binding --ignore-not-found
kubectl delete clusterrole gdc-dev-operator-role --ignore-not-found
kubectl delete gatewayclass gdc-dev-gateway-class --ignore-not-found

# 4. Optional: Tear down Stage 2 Zonal Resources only if '--include-zonal-resources' flag is explicitly passed
if [ "${INCLUDE_ZONAL_RESOURCES}" = "--include-zonal-resources" ]; then
  echo "[4/4] Flag --include-zonal-resources detected: destroying stage=2-resources..."
  helmfile -e "${ENV}" -l stage=2-resources destroy
else
  echo "[4/4] Skipping Stage 2 (Harbor, DBCluster, Buckets) & Stage 3 (GPU Clusters) to preserve air-gap assets."
fi

echo "=================================================================="
echo "✅ GDC-ag Stage 5 workload cleanup complete!"
echo "   To re-deploy the full AI-enabled E2E stack, run:"
echo "   cd ${REPO_ROOT}/foundations && helmfile -e ${ENV} -l stage=5-workload-factory apply"
echo "=================================================================="
