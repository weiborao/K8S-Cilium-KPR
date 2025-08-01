#!/bin/bash

# ==============================================================================
# Idempotent Kubernetes and Cilium Setup Script
#
# This script can be run multiple times. It checks the current state
# at each step and only performs actions if necessary.
# It must be run as root on the primary control-plane node.
# ==============================================================================

# --- Configuration ---
CONTROL_PLANE_ENDPOINT="kube-node-1"
CONTROL_PLANE_IP="10.75.59.71"
WORKER_NODES=("10.75.59.72" "10.75.59.73")
POD_CIDR="172.16.0.0/20"
SERVICE_CIDR="172.16.32.0/20"
BGP_PEER_IP="10.75.59.76"
LOCAL_ASN=65000
PEER_ASN=65000
CILIUM_VERSION="1.17.6"
HUBBLE_UI_VERSION="1.3.6"

# ==============================================================================
# Helper Function
# ==============================================================================
print_header() { echo -e "\n### $1 ###"; }

# ==============================================================================
# STEP 1: Initialize Kubernetes Control-Plane
# ==============================================================================
print_header "STEP 1: Initializing Kubernetes Control-Plane"

if kubectl get nodes &> /dev/null; then
  echo "✅ Kubernetes cluster is already running. Skipping kubeadm init."
else
  echo "--> Kubernetes cluster not found. Initializing..."
  kubeadm config images pull
  kubeadm init \
    --control-plane-endpoint=${CONTROL_PLANE_ENDPOINT} \
    --pod-network-cidr=${POD_CIDR} \
    --service-cidr=${SERVICE_CIDR} \
    --skip-phases=addon/kube-proxy
  mkdir -p /root/.kube
  cp -i /etc/kubernetes/admin.conf /root/.kube/config
  echo "✅ Control-Plane initialization complete."
fi

# ==============================================================================
# STEP 2: Install or Upgrade Cilium CNI
# ==============================================================================
print_header "STEP 2: Installing or Upgrading Cilium CNI"

helm repo add cilium https://helm.cilium.io/ &> /dev/null
helm repo add isovalent https://helm.isovalent.com/ &> /dev/null
helm repo update > /dev/null

cat > cilium-values.yaml <<EOF
hubble:
  enabled: true
  relay:
    enabled: true
  ui:
    enabled: false
ipam:
  mode: kubernetes
ipv4NativeRoutingCIDR: ${POD_CIDR}
k8s:
  requireIPv4PodCIDR: true
routingMode: native
autoDirectNodeRoutes: true
enableIPv4Masquerade: true
bgpControlPlane:
  enabled: true
  announce:
    podCIDR: true
kubeProxyReplacement: true
bpf:
  masquerade: true
  lb:
    externalClusterIP: true
    sock: true
EOF

if helm status cilium -n kube-system &> /dev/null; then
  echo "--> Cilium is already installed. Upgrading to apply latest configuration..."
  helm upgrade cilium isovalent/cilium --version ${CILIUM_VERSION} --namespace kube-system --set k8sServiceHost=${CONTROL_PLANE_IP},k8sServicePort=6443 -f cilium-values.yaml
else
  echo "--> Cilium not found. Installing..."
  helm install cilium isovalent/cilium --version ${CILIUM_VERSION} --namespace kube-system --set k8sServiceHost=${CONTROL_PLANE_IP},k8sServicePort=6443 -f cilium-values.yaml
fi
echo "--> Waiting for Cilium pods to become ready..."
kubectl -n kube-system wait --for=condition=Ready pod -l k8s-app=cilium --timeout=5m
echo "✅ Cilium is configured."

# ==============================================================================
# STEP 3: Join Worker Nodes to the Cluster
# ==============================================================================
print_header "STEP 3: Joining Worker Nodes"

for NODE_IP in "${WORKER_NODES[@]}"; do
  if kubectl get nodes -o wide | grep -q "$NODE_IP"; then
    echo "✅ Node ${NODE_IP} is already in the cluster. Skipping join."
  else
    echo "--> Node ${NODE_IP} not found in cluster. Attempting to join..."
    JOIN_COMMAND=$(kubeadm token create --print-join-command)
    ssh -o StrictHostKeyChecking=no root@${NODE_IP} "${JOIN_COMMAND}"
    if [ $? -ne 0 ]; then
      echo "❌ Failed to join node ${NODE_IP}. Please check SSH connectivity and logs." >&2
      exit 1
    fi
    echo "✅ Node ${NODE_IP} joined successfully."
  fi
done

# ==============================================================================
# STEP 4: Install Cilium CLI
# ==============================================================================
print_header "STEP 4: Installing Cilium CLI"

if command -v cilium &> /dev/null; then
  echo "✅ Cilium CLI is already installed. Skipping."
else
  echo "--> Installing Cilium CLI..."
  curl -L --silent --remote-name-all https://github.com/isovalent/cilium-cli-releases/releases/latest/download/cilium-linux-amd64.tar.gz{,.sha256sum}
  sha256sum --check cilium-linux-amd64.tar.gz.sha256sum > /dev/null
  tar xzvfC cilium-linux-amd64.tar.gz /usr/local/bin > /dev/null
  rm cilium-linux-amd64.tar.gz cilium-linux-amd64.tar.gz.sha256sum
  echo "✅ Cilium CLI installed."
fi

# ==============================================================================
# STEP 5: Configure Cilium BGP Peering
# ==============================================================================
print_header "STEP 5: Configuring Cilium BGP Peering"

echo "--> Applying BGP configuration. 'unchanged' means it's already correct."
# CORRECTION: Using the correct schema with matchLabels.
cat > cilium-bgp.yaml << EOF
---
apiVersion: cilium.io/v2alpha1
kind: CiliumBGPAdvertisement
metadata:
  name: bgp-advertisements
  labels:
    advertise: bgp
spec:
  advertisements:
    - advertisementType: "PodCIDR"              # Only for Kubernetes or ClusterPool IPAM cluster-pool
    - advertisementType: "Service"
      service:
        addresses:
          - ClusterIP
          - ExternalIP
          #- LoadBalancerIP
      selector:
        matchExpressions:
        - {key: somekey, operator: NotIn, values: ['never-used-value']} 

---
apiVersion: cilium.io/v2alpha1
kind: CiliumBGPPeerConfig
metadata:
  name: cilium-peer
spec:
  timers:
    holdTimeSeconds: 30             #default 90s
    keepAliveTimeSeconds: 10  #default 30s
    connectRetryTimeSeconds: 40  #default 120s
  gracefulRestart:
    enabled: true
    restartTimeSeconds: 120        #default 120s
  #transport:
  #  peerPort: 179
  families:
    - afi: ipv4
      safi: unicast
      advertisements:
        matchLabels:
          advertise: "bgp"

---
apiVersion: cilium.io/v2alpha1
kind: CiliumBGPClusterConfig
metadata:
  name: cilium-bgp-default
spec:
  bgpInstances:
  - name: "instance-65000"
    localASN: ${LOCAL_ASN}
    peers:
    - name: "FRR_BGP"
      peerASN: ${PEER_ASN}
      peerAddress: ${BGP_PEER_IP}
      peerConfigRef:
        name: "cilium-peer"
EOF

# Apply the configuration and check for errors
kubectl apply -f cilium-bgp.yaml
if [ $? -ne 0 ]; then
  echo "❌ Failed to apply BGP configuration. Please check the errors above." >&2
  exit 1
fi
echo "✅ BGP configuration applied."

# ==============================================================================
# STEP 6: Install or Upgrade Hubble UI
# ==============================================================================
print_header "STEP 6: Installing or Upgrading Hubble UI"

cat > hubble-ui-values.yaml << EOF
relay:
  address: "hubble-relay.kube-system.svc.cluster.local"
EOF

if helm status hubble-ui -n kube-system &> /dev/null; then
  echo "--> Hubble UI is already installed. Upgrading..."
  helm upgrade hubble-ui isovalent/hubble-ui --version ${HUBBLE_UI_VERSION} --namespace kube-system --values hubble-ui-values.yaml --wait
else
  echo "--> Hubble UI not found. Installing..."
  helm install hubble-ui isovalent/hubble-ui --version ${HUBBLE_UI_VERSION} --namespace kube-system --values hubble-ui-values.yaml --wait
fi

SERVICE_TYPE=$(kubectl get service hubble-ui -n kube-system -o jsonpath='{.spec.type}')
if [ "$SERVICE_TYPE" != "NodePort" ]; then
  echo "--> Patching Hubble UI service to NodePort..."
  kubectl patch service hubble-ui -n kube-system -p '{"spec": {"type": "NodePort"}}'
else
  echo "--> Hubble UI service is already of type NodePort."
fi
echo "✅ Hubble UI is configured."

# ==============================================================================
# STEP 7: Final Verification
# ==============================================================================
print_header "STEP 7: Final Verification"
echo "--> Waiting for all nodes to be ready..."
kubectl wait --for=condition=Ready node --all --timeout=5m
echo "--> Checking Cilium status..."
cilium status --wait

HUBBLE_UI_PORT=$(kubectl get service hubble-ui -n kube-system -o jsonpath='{.spec.ports[0].nodePort}')
echo -e "\n----------------------------------------------------------------"
echo "🚀 Cluster setup is complete and verified!"
echo "Access Hubble UI at: http://${CONTROL_PLANE_IP}:${HUBBLE_UI_PORT}"
echo "----------------------------------------------------------------"