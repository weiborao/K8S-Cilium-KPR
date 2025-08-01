#!/bin/bash

# --- Configuration ---
ANSIBLE_DIR="ansible_ssh_setup"
INVENTORY_FILE="${ANSIBLE_DIR}/hosts.ini"
PLAYBOOK_FILE="${ANSIBLE_DIR}/setup_ssh.yml"

# Kubernetes Node IPs
KUBE_NODE_1_IP="10.75.59.71"
KUBE_NODE_2_IP="10.75.59.72"
KUBE_NODE_3_IP="10.75.59.73"

# Common Ansible user and Python interpreter
ANSIBLE_USER="ubuntu"
ANSIBLE_PYTHON_INTERPRETER="/usr/bin/python3"

# --- Functions ---

# Function to check and install Ansible
install_ansible() {
    if ! command -v ansible &> /dev/null
    then
        echo "Ansible not found. Attempting to install Ansible..."
        if [ -f /etc/debian_version ]; then
            # Debian/Ubuntu
            sudo apt update
            sudo apt install -y software-properties-common
            sudo add-apt-repository --yes --update ppa:ansible/ansible
            sudo apt install -y ansible
        elif [ -f /etc/redhat-release ]; then
            # CentOS/RHEL/Fedora
            sudo yum install -y epel-release
            sudo yum install -y ansible
        else
            echo "Unsupported OS for automatic Ansible installation. Please install Ansible manually."
            exit 1
        fi
        if ! command -v ansible &> /dev/null; then
            echo "Ansible installation failed. Please install it manually and re-run this script."
            exit 1
        fi
        echo "Ansible installed successfully."
    else
        echo "Ansible is already installed."
    fi
}

# Function to create Ansible inventory file
create_inventory() {
    echo "Creating Ansible inventory file: ${INVENTORY_FILE}"
    mkdir -p "$ANSIBLE_DIR"
    cat <<EOF > "$INVENTORY_FILE"
[kubernetes_nodes]
kube-node-1 ansible_host=${KUBE_NODE_1_IP}
kube-node-2 ansible_host=${KUBE_NODE_2_IP}
kube-node-3 ansible_host=${KUBE_NODE_3_IP}

[all:vars]
ansible_user=${ANSIBLE_USER}
ansible_python_interpreter=${ANSIBLE_PYTHON_INTERPRETER}
EOF
    echo "Inventory file created."
}

# Function to create Ansible playbook file
create_playbook() {
    echo "Creating Ansible playbook file: ${PLAYBOOK_FILE}"
    mkdir -p "$ANSIBLE_DIR"
    cat <<'EOF' > "$PLAYBOOK_FILE"
---
- name: Generate SSH key on kube-node-1 and distribute to other nodes
  hosts: kubernetes_nodes
  become: yes

  tasks:
    - name: Generate SSH key on kube-node-1
      ansible.builtin.command:
        cmd: ssh-keygen -t rsa -b 4096 -N "" -f /root/.ssh/id_rsa
        creates: /root/.ssh/id_rsa
      when: inventory_hostname == 'kube-node-1'

    - name: Ensure .ssh directory exists on all nodes
      ansible.builtin.file:
        path: /root/.ssh
        state: directory
        mode: '0700'

    - name: Ensure authorized_keys file exists
      ansible.builtin.file:
        path: /root/.ssh/authorized_keys
        state: touch
        mode: '0600'

    - name: Fetch public key from kube-node-1
      ansible.builtin.slurp:
        src: /root/.ssh/id_rsa.pub
      register: ssh_public_key
      when: inventory_hostname == 'kube-node-1'

    - name: Distribute public key to kube-node-2 and kube-node-3
      ansible.builtin.lineinfile:
        path: /root/.ssh/authorized_keys
        line: "{{ hostvars['kube-node-1']['ssh_public_key']['content'] | b64decode }}"
        state: present
      when: inventory_hostname in ['kube-node-2', 'kube-node-3']
EOF
    echo "Playbook file created."
}

# --- Main Script Execution ---

echo "Starting Ansible SSH key setup process..."

# 1. Install Ansible if not present
install_ansible

# 2. Create Ansible inventory file
create_inventory

# 3. Create Ansible playbook file
create_playbook

echo "Setup complete. You can now run the Ansible playbook manually using:"
echo "ansible-playbook -i \"$INVENTORY_FILE\" \"$PLAYBOOK_FILE\" --ask-become-pass"
echo "You will be prompted for the 'sudo' password for the 'ubuntu' user on your VMs."
echo "Process complete."