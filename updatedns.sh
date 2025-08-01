#!/bin/bash

# --- Configuration ---
ANSIBLE_DIR="ansible_dns_update"
INVENTORY_FILE="${ANSIBLE_DIR}/hosts.ini"
PLAYBOOK_FILE="${ANSIBLE_DIR}/update_dns.yml"

# Kubernetes Node IPs (ensure these match your actual VM IPs)
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
- name: Update DNS server on Kubernetes nodes to use local DNS only
  hosts: kubernetes_nodes
  become: yes # This allows Ansible to run commands with sudo privileges

  tasks:
    - name: Ensure netplan configuration directory exists
      ansible.builtin.file:
        path: /etc/netplan
        state: directory
        mode: '0755'

    - name: Get current network configuration file (e.g., 00-installer-config.yaml)
      ansible.builtin.find:
        paths: /etc/netplan
        patterns: '*.yaml'
        # We assume there's only one primary netplan config file for simplicity.
        # If there are multiple, you might need to specify which one.
      register: netplan_files

    - name: Set network config file variable
      ansible.builtin.set_fact:
        netplan_config_file: "{{ netplan_files.files[0].path }}"
      when: netplan_files.files | length > 0

    - name: Fail if no netplan config file found
      ansible.builtin.fail:
        msg: "No Netplan configuration file found in /etc/netplan. Cannot proceed."
      when: netplan_files.files | length == 0

    - name: Read current netplan configuration
      ansible.builtin.slurp:
        src: "{{ netplan_config_file }}"
      register: current_netplan_config

    - name: Parse current netplan configuration
      ansible.builtin.set_fact:
        parsed_netplan: "{{ current_netplan_config['content'] | b64decode | from_yaml }}"

    - name: Update nameservers in netplan configuration to local DNS only
      ansible.builtin.set_fact:
        updated_netplan: "{{ parsed_netplan | combine(
            {
              'network': {
                'ethernets': {
                  'enp1s0': {
                    'nameservers': {
                      'addresses': ['10.75.59.76'],
                      'search': ['cisco.com']
                    }
                  }
                }
              }
            }, recursive=True) }}"

    - name: Write updated netplan configuration
      ansible.builtin.copy:
        content: "{{ updated_netplan | to_yaml }}"
        dest: "{{ netplan_config_file }}"
        mode: '0600'
      notify: Apply Netplan Configuration

  handlers:
    - name: Apply Netplan Configuration
      ansible.builtin.command: netplan apply
      listen: "Apply Netplan Configuration"
EOF
    echo "Playbook file created."
}

# --- Main Script Execution ---

echo "Starting Ansible DNS update process..."

# 1. Install Ansible if not present
install_ansible

# 2. Create Ansible inventory file
create_inventory

# 3. Create Ansible playbook file
create_playbook

# 4. Run the Ansible playbook
echo "Running Ansible playbook to update DNS on Kubernetes nodes..."
echo "You will be prompted for the 'sudo' password for the 'ubuntu' user on your VMs."
ansible-playbook -i "$INVENTORY_FILE" "$PLAYBOOK_FILE" --ask-become-pass

if [ $? -eq 0 ]; then
    echo "Ansible playbook executed successfully."
    echo "Your Kubernetes nodes should now be configured to use 10.75.59.76 as their only DNS server."
else
    echo "Ansible playbook failed. Please check the output for errors."
fi

echo "Process complete."
