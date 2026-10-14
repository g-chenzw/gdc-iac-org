#!/usr/bin/env bash
# Non-Destructive E2E Workload Cleanup Script for GCP GKE Staging
# Tears down Kubernetes workloads, Helm releases, and namespaces (gemma-inference & gdc-dev)
# while strictly PRESERVING the running GKE cluster, GPU node pools, VPC subnets, and Artifact Registry.

set -euo pipefail

NAMESPACE="${NAMESPACE:-gemma-inference}"
GDC_DEV_NAMESPACE="${GDC_DEV_NAMESPACE:-gdc-dev}"

echo "=================================================================="
echo "🧹 Starting Non-Destructive E2E Workload Cleanup"
echo "   Target Namespaces : ${NAMESPACE}, ${GDC_DEV_NAMESPACE}"
echo "   GKE Cluster       : PRESERVED (Not Deleted)"
echo "   Artifact Registry : PRESERVED (Not Deleted)"
echo "=================================================================="

# 1. Stop background kubectl port-forward loops on the Cloud Workstation
echo "[1/5] Stopping background port-forward processes (8080-8084)..."
pkill -f "kubectl port-forward" 2>/dev/null || true

# 2. Uninstall Helm releases in gemma-inference and gdc-dev (if present)
echo "[2/5] Uninstalling Helm releases in ${NAMESPACE} and ${GDC_DEV_NAMESPACE}..."
for rel in gemma-envoy-pool vllm-26b vllm-31b ollama-26b ollama-31b gemma-gateway gemma-standalone gemma-client; do
  helm uninstall "${rel}" -n "${NAMESPACE}" 2>/dev/null || true
done
helm uninstall gdc-dev-platform -n "${GDC_DEV_NAMESPACE}" 2>/dev/null || true

# 3. Clear any PVC finalizers so namespace deletion never hangs
echo "[3/5] Clearing PVC protection finalizers in ${NAMESPACE} and ${GDC_DEV_NAMESPACE}..."
for ns in "${NAMESPACE}" "${GDC_DEV_NAMESPACE}"; do
  for pvc in $(kubectl get pvc -n "${ns}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true); do
    kubectl patch pvc "${pvc}" -n "${ns}" -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
  done
done

# 4. Delete cluster-scoped RBAC / GatewayClass objects created by p13-gdc-dev
echo "[4/5] Cleaning up p13-gdc-dev cluster-scoped RBAC & GatewayClass resources..."
kubectl delete clusterrolebinding gdc-dev-operator-binding --ignore-not-found
kubectl delete clusterrole gdc-dev-operator-role --ignore-not-found
kubectl delete gatewayclass gdc-dev-gateway-class --ignore-not-found

# 5. Delete application namespaces (gemma-inference and gdc-dev)
echo "[5/5] Deleting namespaces '${NAMESPACE}' and '${GDC_DEV_NAMESPACE}'..."
kubectl delete namespace "${NAMESPACE}" --ignore-not-found --wait=true
kubectl delete namespace "${GDC_DEV_NAMESPACE}" --ignore-not-found --wait=true

echo "=================================================================="
echo "✅ Workload cleanup complete!"
echo "   Active GKE cluster nodes remain online and ready for re-testing:"
kubectl get nodes -o wide
echo "=================================================================="
