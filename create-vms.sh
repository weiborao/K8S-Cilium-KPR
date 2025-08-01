#!/bin/bash

# --- Configuration ---
BASE_IMAGE_PATH="/home/ois/data/vmimages/noble-server-cloudimg-amd64.img"
VM_IMAGE_DIR="/home/ois/data/k8s/nodevms"
VM_CONFIG_DIR="/home/ois/data/k8s/nodevm_cfg"
RAM_MB=8192
VCPUS=4
DISK_SIZE_GB=20 # <--- ADDED: Increased disk size to 20 GB
BRIDGE_INTERFACE="br0"
BASE_IP="10.75.59"
NETWORK_PREFIX="/24"
GATEWAY="10.75.59.1"
NAMESERVER1="64.104.76.247"
NAMESERVER2="64.104.14.184"
SEARCH_DOMAIN="cisco.com"
VNC_PORT_START=5905 # VNC ports will be 5905, 5906, 5907
PASSWORD_HASH='$6$rounds=4096$LD===============================================================unw372/TVfst1'
SSH_PUB_KEY=$(cat ~/.ssh/id_rsa.pub)


# --- Loop to create 3 VMs ---
for i in {1..3}; do
    VM_NAME="kube-node-$i"
    VM_IP="${BASE_IP}.$((70 + i))" # IPs will be 10.75.59.71, 10.75.59.72, 10.75.59.73
    VM_IMAGE_PATH="${VM_IMAGE_DIR}/${VM_NAME}.qcow2"
    VM_VNC_PORT=$((VNC_PORT_START + i - 1)) # VNC ports will be 5905, 5906, 5907

    echo "--- Preparing for $VM_NAME (IP: $VM_IP) ---"

    # Create directories if they don't exist
    mkdir -p "$VM_IMAGE_DIR"
    mkdir -p "$VM_CONFIG_DIR"

    # Create a fresh image for each VM
    if [ -f "$VM_IMAGE_PATH" ]; then
        echo "Removing existing image for $VM_NAME..."
        rm "$VM_IMAGE_PATH"
    fi
    echo "Copying base image to $VM_IMAGE_PATH..."
    cp "$BASE_IMAGE_PATH" "$VM_IMAGE_PATH"

    # --- NEW: Resize the copied image before virt-install ---
    echo "Resizing VM image to ${DISK_SIZE_GB}GB..."
    qemu-img resize "$VM_IMAGE_PATH" "${DISK_SIZE_GB}G"
    # --- END NEW ---

    # Generate user-data for the current VM
    USER_DATA_FILE="${VM_CONFIG_DIR}/${VM_NAME}_user-data"
    cat <<EOF > "$USER_DATA_FILE"
#cloud-config

locale: en_US
keyboard:
  layout: us
timezone: Asia/Shanghai
hostname: ${VM_NAME}
create_hostname_file: true

ssh_pwauth: yes

groups:
  - ubuntu

users:
  - name: ubuntu
    gecos: ubuntu
    primary_group: ubuntu
    groups: sudo, cdrom
    sudo: ALL=(ALL:ALL) ALL
    shell: /bin/bash
    lock_passwd: false
    passwd: ${PASSWORD_HASH}
    ssh_authorized_keys:
      - "${SSH_PUB_KEY}"

apt:
  primary:
    - arches: [default]
      uri: http://us.archive.ubuntu.com/ubuntu/

packages:
  - openssh-server
  - net-tools
  - iftop
  - htop
  - iperf3
  - vim
  - curl
  - wget
  - cloud-guest-utils # Ensure growpart is available

ntp:
  servers: ['ntp.esl.cisco.com']

runcmd:
  - echo "Attempting to resize root partition and filesystem..."
  - growpart /dev/vda 1 # Expand the first partition on /dev/vda
  - resize2fs /dev/vda1 # Expand the ext4 filesystem on /dev/vda1
  - echo "Disk resize commands executed. Verify with 'df -h' after boot."
EOF

    # Generate network-config for the current VM
    NETWORK_CONFIG_FILE="${VM_CONFIG_DIR}/${VM_NAME}_network-config"
    cat <<EOF > "$NETWORK_CONFIG_FILE"
network:
  version: 2
  ethernets:
    enp1s0:
      addresses:
      - "${VM_IP}${NETWORK_PREFIX}"
      nameservers:
        addresses:
        - ${NAMESERVER1}
        - ${NAMESERVER2}
        search:
        - ${SEARCH_DOMAIN}
      routes:
      - to: "default"
        via: "${GATEWAY}"
EOF

    # Generate meta-data (can be static for now)
    META_DATA_FILE="${VM_CONFIG_DIR}/${VM_NAME}_meta-data"
    cat <<EOF > "$META_DATA_FILE"
instance-id: ${VM_NAME}
local-hostname: ${VM_NAME}
EOF

    echo "--- Installing $VM_NAME ---"
    virt-install --name "${VM_NAME}" --ram "${RAM_MB}" --vcpus "${VCPUS}" --noreboot \
        --os-variant ubuntu24.04 \
        --network bridge="${BRIDGE_INTERFACE}" \
        --graphics vnc,listen=0.0.0.0,port="${VM_VNC_PORT}" \
        --disk path="${VM_IMAGE_PATH}",format=qcow2 \
        --console pty,target_type=serial \
        --cloud-init user-data="${USER_DATA_FILE}",meta-data="${META_DATA_FILE}",network-config="${NETWORK_CONFIG_FILE}" \
        --import \
        --wait 0

    echo "Successfully initiated creation of $VM_NAME."
    echo "You can connect to VNC on port ${VM_VNC_PORT} to monitor installation (optional)."
    echo "Wait a few minutes for the VM to boot and cloud-init to run."
    echo "--------------------------------------------------------"
done

echo "All 3 VMs have been initiated. Please wait for them to fully provision."
echo "You can SSH into them using 'ssh ubuntu@<IP_ADDRESS>' where IP addresses are 10.75.59.71, 10.75.59.72, 10.75.59.73."
