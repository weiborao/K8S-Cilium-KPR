#!/bin/bash

# --- Configuration ---
BASE_IMAGE_PATH="/home/ois/data/vmimages/noble-server-cloudimg-amd64.img"
VM_IMAGE_DIR="/home/ois/data/k8s/nodevms"
VM_CONFIG_DIR="/home/ois/data/k8s/nodevm_cfg"
RAM_MB=8192
VCPUS=4
DISK_SIZE_GB=20
BRIDGE_INTERFACE="br0"
# Specific IP for the single VM
VM_IP="10.75.59.76"
NETWORK_PREFIX="/24"
GATEWAY="10.75.59.1"
# DNS servers for the VM's initial resolution (for internet access)
VM_NAMESERVER1="64.104.76.247"
VM_NAMESERVER2="64.104.14.184"
SEARCH_DOMAIN="cisco.com"
VNC_PORT=5909 # Fixed VNC port for the single VM
PASSWORD_HASH='$6$rounds=4096$LDu9pSdV5c7S==============================================7hOh/Iunw372/TVfst1'
SSH_PUB_KEY=$(cat ~/.ssh/id_rsa.pub)

# --- VM Details ---
VM_NAME="dns-server-vm"
VM_IMAGE_PATH="${VM_IMAGE_DIR}/${VM_NAME}.qcow2"

echo "--- Preparing for $VM_NAME (IP: $VM_IP) ---"

# Create directories if they don't exist
mkdir -p "$VM_IMAGE_DIR"
mkdir -p "$VM_CONFIG_DIR"

# Create a fresh image for the VM
if [ -f "$VM_IMAGE_PATH" ]; then
    echo "Removing existing image for $VM_NAME..."
    rm "$VM_IMAGE_PATH"
fi
echo "Copying base image to $VM_IMAGE_PATH..."
cp "$BASE_IMAGE_PATH" "$VM_IMAGE_PATH"

# Resize the copied image before virt-install
echo "Resizing VM image to ${DISK_SIZE_GB}GB..."
qemu-img resize "$VM_IMAGE_PATH" "${DISK_SIZE_GB}G"

# Generate user-data for the VM (installing dnsmasq, no UFW, no dnsmasq config here)
USER_DATA_FILE="${VM_CONFIG_DIR}/${VM_NAME}_user-data"
cat <<EOF > "$USER_DATA_FILE"
#cloud-config

locale: en_US
keyboard:
  layout: us
timezone: Asia/Tokyo
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
  - dnsmasq # Install dnsmasq for DNS server functionality

ntp:
  servers: ['ntp.esl.cisco.com']

runcmd:
  - echo "Attempting to resize root partition and filesystem..."
  - growpart /dev/vda 1 # Expand the first partition on /dev/vda
  - resize2fs /dev/vda1 # Expand the ext4 filesystem on /dev/vda1
  - echo "Disk resize commands executed. Verify with 'df -h' after boot."
EOF

# Generate network-config for the VM (pointing to external DNS for initial connectivity)
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
        - ${VM_NAMESERVER1} # Point VM to external DNS for initial internet access
        - ${VM_NAMESERVER2}
        search:
        - ${SEARCH_DOMAIN}
      routes:
      - to: "default"
        via: "${GATEWAY}"
EOF

# Generate meta-data
META_DATA_FILE="${VM_CONFIG_DIR}/${VM_NAME}_meta-data"
cat <<EOF > "$META_DATA_FILE"
instance-id: ${VM_NAME}
local-hostname: ${VM_NAME}
EOF

echo "--- Installing $VM_NAME ---"
virt-install --name "${VM_NAME}" --ram "${RAM_MB}" --vcpus "${VCPUS}" --noreboot \
    --os-variant ubuntu24.04 \
    --network bridge="${BRIDGE_INTERFACE}" \
    --graphics vnc,listen=0.0.0.0,port="${VNC_PORT}" \
    --disk path="${VM_IMAGE_PATH}",format=qcow2 \
    --console pty,target_type=serial \
    --cloud-init user-data="${USER_DATA_FILE}",meta-data="${META_DATA_FILE}",network-config="${NETWORK_CONFIG_FILE}" \
    --import \
    --wait 0

echo "Successfully initiated creation of $VM_NAME."
echo "You can connect to VNC on port ${VNC_PORT} to monitor installation (optional)."
echo "Wait a few minutes for the VM to boot and cloud-init to run."
echo "--------------------------------------------------------"

echo "The DNS server VM has been initiated. Please wait for it to fully provision."
echo "You can SSH into it using 'ssh ubuntu@${VM_IP}'."
echo "Once provisioned, proceed to use the 'setup-dnsmasq-ansible.sh' script to configure DNS using Ansible."
