#!/bin/bash

# ==============================================================================
# Kubernetes and Cilium Health Check Script
#
# This script gathers key information about the overall cluster state,
# with a focus on Cilium CNI, Hubble, and BGP status.
# It should be run on a control-plane node with kubectl access.
# ==============================================================================

# Helper function for printing section headers
print_header() {
  echo -e "\n================================================================================="
  echo "### $1"
  echo "================================================================================="
}

# --- SCRIPT START ---

print_header "SECTION 1: OVERALL CLUSTER HEALTH"

echo -e "\n--- Checking Node Status ---"
kubectl get nodes -o wide

echo -e "\n--- Checking All Pods in All Namespaces ---"
kubectl get pods -A -o wide

echo -e "\n--- Checking All Deployments in All Namespaces ---"
kubectl get deployments -A -o wide


print_header "SECTION 2: CORE KUBE-SYSTEM COMPONENTS"

echo -e "\n--- Checking Pods in kube-system ---"
kubectl get pods -n kube-system -o wide

echo -e "\n--- Checking Services in kube-system ---"
kubectl get services -n kube-system -o wide

echo -e "\n--- Checking Endpoints in kube-system (especially kube-dns) ---"
kubectl get endpoints -n kube-system


print_header "SECTION 3: CILIUM STATUS & HEALTH"

echo -e "\n--- Checking Cilium DaemonSet Status ---"
kubectl get daemonset -n kube-system cilium

echo -e "\n--- Checking Cilium and Hubble Pods ---"
kubectl get pods -n kube-system -l k8s-app=cilium,k8s-app=hubble-ui,k8s-app=hubble-relay -o wide

echo -e "\n--- Running Cilium CLI Status (High-Level Summary) ---"
# This command provides an excellent overview of the entire Cilium deployment
cilium status --wait

echo -e "\n--- Running Hubble CLI Status ---"
# This command checks if the CLI can connect to the Hubble Relay
cilium hubble status


print_header "SECTION 4: DETAILED CILIUM AGENT DIAGNOSTICS (FROM ONE AGENT)"

# Get the name of one Cilium pod to run exec commands against it
CILIUM_POD_NAME=$(kubectl -n kube-system get pods -l k8s-app=cilium -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

if [ -z "$CILIUM_POD_NAME" ]; then
  echo "Could not find a Cilium pod. Skipping agent-level diagnostics."
else
  echo "Running diagnostics from agent pod: ${CILIUM_POD_NAME}"

  echo -e "\n--- [AGENT] Cilium Status (Verbose) ---"
  kubectl -n kube-system exec "$CILIUM_POD_NAME" -- cilium status --verbose

  echo -e "\n--- [AGENT] BGP Peering Status (CRITICAL FOR BGP) ---"
  # This command shows the status of BGP sessions with your router
  kubectl -n kube-system exec "$CILIUM_POD_NAME" -- cilium-dbg bgp control-plane

  echo -e "\n--- [AGENT] Cilium Service List (eBPF Service Handling) ---"
  # This shows which K8s services are being managed by Cilium in eBPF
  kubectl -n kube-system exec "$CILIUM_POD_NAME" -- cilium service list

  echo -e "\n--- [AGENT] Cilium IP Masquerade List (eBPF NAT) ---"
  # This shows which CIDRs are being NAT'd by Cilium
  kubectl -n kube-system exec "$CILIUM_POD_NAME" -- cilium-dbg bpf ipmasq list
fi


print_header "SECTION 5: CILIUM CONFIGURATION"

echo -e "\n--- Dumping cilium-config ConfigMap ---"
# This shows the complete configuration Cilium is running with
kubectl -n kube-system get configmap cilium-config -o yaml


print_header "SECTION 6: RECOMMENDED NEXT STEPS"
echo "If you are experiencing issues, consider the following commands:"
echo ""
echo "1. To run a full connectivity test between all nodes and pods:"
echo "   cilium connectivity test"
echo ""
echo "2. To describe a specific pod that is failing (e.g., stuck in 'Pending' or 'CrashLoopBackOff'):"
echo "   kubectl describe pod <POD_NAME> -n <NAMESPACE>"
echo ""
echo "3. To view the logs of a specific pod:"
echo "   kubectl logs <POD_NAME> -n <NAMESPACE>"
echo ""
echo "4. To follow the logs of a Cilium agent in real-time:"
echo "   kubectl -n kube-system logs -f <CILIUM_POD_NAME>"
echo ""

echo "================================================================================="
echo "### DIAGNOSTIC SCRIPT COMPLETE ###"
echo "================================================================================="
