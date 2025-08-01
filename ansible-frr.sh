#!/bin/bash

# This script automates the setup of an Ansible environment for installing and configuring FRRouting (FRR).
# It creates the project directory, inventory, configuration, and the playbook
# with an idempotent role to install and configure FRR.

# --- Configuration ---
PROJECT_DIR="ansible-frr-setup" # Changed project directory name
FRR_NODE_IP="10.75.59.76" # IP address of your FRR VM (frr-server-vm)
ANSIBLE_USER="ubuntu" # The user created by cloud-init on your VMs
SSH_PRIVATE_KEY_PATH="~/.ssh/id_rsa" # Path to your SSH private key on the Ansible control machine

# FRR specific configuration
FRR_AS=64513 # The Autonomous System number for this FRR node (example AS, choose your own)
K8S_MASTER_IP="10.75.59.71" # From your create-vms.sh script
K8S_WORKER_1_IP="10.75.59.72" # From your create-vms.sh script
K8S_WORKER_2_IP="10.75.59.73" # From your create-vms.sh script
CILIUM_BGP_AS=65000 # AS for Cilium as per your CiliumBGPClusterConfig

# --- Functions ---

# Function to install Ansible (if not already installed)
install_ansible() {
    echo "--- Installing Ansible ---"
    if ! command -v ansible &> /dev/null; then
        sudo apt update -y
        sudo apt install -y ansible
        echo "Ansible installed successfully."
    else
        echo "Ansible is already installed."
    fi
}

# Function to create project directory and navigate into it
create_project_dir() {
    echo "--- Creating project directory: ${PROJECT_DIR} ---"
    # Check if directory exists, if so, just navigate, otherwise create and navigate
    if [ ! -d "${PROJECT_DIR}" ]; then
        mkdir -p "${PROJECT_DIR}"
        echo "Created new directory: ${PROJECT_DIR}"
    else
        echo "Directory ${PROJECT_DIR} already exists."
    fi
    cd "${PROJECT_DIR}" || { echo "Failed to change directory to ${PROJECT_DIR}. Exiting."; exit 1; }
    echo "Changed to directory: $(pwd)"
}

# Function to create ansible.cfg
create_ansible_cfg() {
    echo "--- Creating ansible.cfg ---"
    cat <<EOF > ansible.cfg
[defaults]
inventory = inventory.ini
roles_path = ./roles
host_key_checking = False # WARNING: Disable host key checking for convenience. Re-enable for production!
EOF
    echo "ansible.cfg created."
}

# Function to create inventory.ini
create_inventory() {
    echo "--- Creating inventory.ini ---"
    cat <<EOF > inventory.ini
[frr_nodes]
frr-node-1 ansible_host=${FRR_NODE_IP}

[all:vars]
ansible_user=${ANSIBLE_USER}
ansible_ssh_private_key_file=${SSH_PRIVATE_KEY_PATH}
ansible_python_interpreter=/usr/bin/python3
FRR_AS=${FRR_AS}
K8S_MASTER_IP=${K8S_MASTER_IP}
K8S_WORKER_1_IP=${K8S_WORKER_1_IP}
K8S_WORKER_2_IP=${K8S_WORKER_2_IP}
CILIUM_BGP_AS=${CILIUM_BGP_AS}
EOF
    echo "inventory.ini created."
}

# Function to create the main playbook.yml
create_playbook() {
    echo "--- Creating playbook.yml ---"
    cat <<EOF > playbook.yml
---
- name: Install and Configure FRRouting (FRR)
  hosts: frr_nodes
  become: yes
  roles:
    - frr_setup # Changed role name to frr_setup
EOF
    echo "playbook.yml created."
}

# Function to create the FRR installation and configuration role
create_frr_role() { # Changed function name from create_gobgp_role
    echo "--- Creating Ansible role for FRR setup ---"
    mkdir -p roles/frr_setup/tasks
    cat <<EOF > roles/frr_setup/tasks/main.yml
---
- name: Install FRRouting (FRR)
  ansible.builtin.apt:
    name: frr
    state: present
    update_cache: yes

- name: Configure FRR daemons (enable zebra and bgpd)
  ansible.builtin.lineinfile:
    path: /etc/frr/daemons
    regexp: '^(zebra|bgpd)='
    line: '\1=yes'
    state: present
    backrefs: yes # Required to make regexp work for replacement
  notify: Restart FRR service

- name: Configure frr.conf
  ansible.builtin.copy:
    dest: /etc/frr/frr.conf
    content: |
      !
      hostname {{ ansible_hostname }}
      password zebra
      enable password zebra
      !
      log syslog informational
      !
      router bgp {{ FRR_AS }}
       bgp router-id {{ ansible_host }}
       !
       neighbor {{ K8S_MASTER_IP }} remote-as {{ CILIUM_BGP_AS }}
       neighbor {{ K8S_WORKER_1_IP }} remote-as {{ CILIUM_BGP_AS }}
       neighbor {{ K8S_WORKER_2_IP }} remote-as {{ CILIUM_BGP_AS }}
       !
       address-family ipv4 unicast
        # Crucial: Redistribute BGP learned routes into the kernel
        redistribute connected
        redistribute static
        redistribute kernel
       exit-address-family
      !
      line vty
      !
    mode: '0644'
  notify: Restart FRR service # Handler only runs if file content changes

- name: Set permissions for frr.conf
  ansible.builtin.file:
    path: /etc/frr/frr.conf
    owner: frr
    group: frr
    mode: '0640'

- name: Enable and start FRR service
  ansible.builtin.systemd:
    name: frr
    state: started
    enabled: yes
    daemon_reload: yes # Ensure systemd reloads unit files if service file changed

EOF

    mkdir -p roles/frr_setup/handlers
    cat <<EOF > roles/frr_setup/handlers/main.yml
---
- name: Restart FRR service
  ansible.builtin.systemd:
    name: frr
    state: restarted
EOF
    echo "FRR Ansible role created."
}

# --- Main execution ---
install_ansible
create_project_dir
create_ansible_cfg
create_inventory
create_playbook
create_frr_role # Changed function call

echo ""
echo "--- Ansible setup for FRR installation is complete! ---"
echo "Navigate to the new project directory:"
echo "cd ${PROJECT_DIR}"
echo ""
echo "Then, run the Ansible playbook to install and configure FRR on your VM:"
echo "ansible-playbook playbook.yml -K"
echo ""
echo "After the playbook finishes, FRR should be running and configured on ${FRR_NODE_IP}."
echo "You can SSH into the VM and verify with 'sudo vtysh -c \"show ip bgp summary\"' and 'sudo ip route show'."
