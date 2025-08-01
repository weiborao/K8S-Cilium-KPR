#!/bin/bash

# This script automates the setup of an Ansible environment for installing Helm.
# It creates the project directory, inventory, configuration, and the playbook
# with an idempotent role to install Helm.

# --- Configuration ---
PROJECT_DIR="ansible-helm"
MASTER_NODE_IP="10.75.59.71" # IP address of your Kubernetes master node (kube-node-1)
ANSIBLE_USER="ubuntu" # The user created by cloud-init on your VMs
SSH_PRIVATE_KEY_PATH="~/.ssh/id_rsa" # Path to your SSH private key on the Ansible control machine

# Helm version to install
HELM_VERSION="v3.18.4" # You can change this to a desired stable version

# --- Functions ---

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
[kubernetes_master]
kube-node-1 ansible_host=${MASTER_NODE_IP}

[all:vars]
ansible_user=${ANSIBLE_USER}
ansible_ssh_private_key_file=${SSH_PRIVATE_KEY_PATH}
ansible_python_interpreter=/usr/bin/python3
HELM_VERSION=${HELM_VERSION}
EOF
    echo "inventory.ini created."
}

# Function to create the main playbook.yml
create_playbook() {
    echo "--- Creating playbook.yml ---"
    cat <<EOF > playbook.yml
---
- name: Install Helm on Kubernetes Master Node
  hosts: kubernetes_master
  become: yes
  environment: # Ensure KUBECONFIG is set for helm commands run with become
    KUBECONFIG: /etc/kubernetes/admin.conf # Use the admin kubeconfig on the master
  roles:
    - helm_install
EOF
    echo "playbook.yml created."
}

# Function to create the Helm installation role (with idempotent check)
create_helm_role() {
    echo "--- Creating Ansible role for Helm installation ---"
    mkdir -p roles/helm_install/tasks
    cat <<EOF > roles/helm_install/tasks/main.yml
---
- name: Check if Helm is installed and get version
  ansible.builtin.command: helm version --short
  register: helm_version_raw
  ignore_errors: yes
  changed_when: false

- name: Set installed Helm version fact
  ansible.builtin.set_fact:
    installed_helm_version: "{{ (helm_version_raw.stdout | default('') | regex_findall('^(v[0-9]+\\\\.[0-9]+\\\\.[0-9]+)') | first | default('') | trim) }}"
  changed_when: false

- name: Debug installed Helm version
  ansible.builtin.debug:
    msg: "Current installed Helm version: {{ installed_helm_version | default('Not installed') }}"

- name: Debug raw Helm version output
  ansible.builtin.debug:
    msg: "Raw Helm version output: {{ helm_version_raw.stdout | default('No output') }}"
  when: helm_version_raw.stdout is defined and helm_version_raw.stdout | length > 0

- name: Check if Helm binary exists
  ansible.builtin.stat:
    path: /usr/local/bin/helm
  register: helm_binary_stat
  when: installed_helm_version == HELM_VERSION

- name: Download Helm tarball
  ansible.builtin.get_url:
    url: "https://get.helm.sh/helm-{{ HELM_VERSION }}-linux-amd64.tar.gz"
    dest: "/tmp/helm-{{ HELM_VERSION }}-linux-amd64.tar.gz"
    mode: '0644'
    checksum: "sha256:{{ lookup('url', 'https://get.helm.sh/helm-{{ HELM_VERSION }}-linux-amd64.tar.gz.sha256sum', wantlist=True)[0].split(' ')[0] }}"
  register: download_helm_result
  until: download_helm_result is success
  retries: 5
  delay: 5
  when: installed_helm_version != HELM_VERSION or not helm_binary_stat.stat.exists

- name: Create Helm installation directory
  ansible.builtin.file:
    path: /usr/local/bin
    state: directory
    mode: '0755'
  when: installed_helm_version != HELM_VERSION or not helm_binary_stat.stat.exists

- name: Extract Helm binary
  ansible.builtin.unarchive:
    src: "/tmp/helm-{{ HELM_VERSION }}-linux-amd64.tar.gz"
    dest: "/tmp"
    remote_src: yes
    creates: "/tmp/linux-amd64/helm"
  when: installed_helm_version != HELM_VERSION or not helm_binary_stat.stat.exists

- name: Move Helm binary to /usr/local/bin
  ansible.builtin.copy:
    src: "/tmp/linux-amd64/helm"
    dest: "/usr/local/bin/helm"
    mode: '0755'
    remote_src: yes
    owner: root
    group: root
  when: installed_helm_version != HELM_VERSION or not helm_binary_stat.stat.exists

- name: Clean up Helm tarball and extracted directory
  ansible.builtin.file:
    path: "{{ item }}"
    state: absent
  loop:
    - "/tmp/helm-{{ HELM_VERSION }}-linux-amd64.tar.gz"
    - "/tmp/linux-amd64"
  when: installed_helm_version != HELM_VERSION or not helm_binary_stat.stat.exists

- name: Verify Helm installation
  ansible.builtin.command: helm version --client
  register: helm_version_output
  changed_when: false

- name: Display Helm version
  ansible.builtin.debug:
    msg: "{{ helm_version_output.stdout }}"
EOF
    echo "Helm installation role created."
}

# --- Main execution ---
create_project_dir
create_ansible_cfg
create_inventory
create_playbook
create_helm_role

echo ""
echo "--- Ansible setup for Helm installation is complete! ---"
echo "Navigate to the new project directory:"
echo "cd ${PROJECT_DIR}"
echo ""
echo "Then, run the Ansible playbook to install only Helm on your master node:"
echo "ansible-playbook playbook.yml -K"
echo ""
echo "After Helm is installed, you can SSH into your master node (kube-node-1) and manage Cilium Enterprise installation directly using Helm."
echo "Remember to use the correct Cilium chart version and your custom values file."
echo "Example steps for manual Cilium installation via Helm:"
echo "ssh ubuntu@${MASTER_NODE_IP}"
echo "sudo helm repo add cilium https://helm.cilium.io/"
echo "sudo helm repo add isovalent https://helm.isovalent.com"
echo "sudo helm repo update"
echo "sudo helm install cilium isovalent/cilium --version 1.17.5 --namespace kube-system -f <path_to_your_cilium_values_file.yaml> --wait"
echo "Example content for /tmp/cilium-enterprise-values.yaml:"
echo "hubble:"
echo "  enabled: true"
echo "  relay:"
echo "    enabled: true"
echo "  ui:"
echo "    enabled: false"
echo "kubeProxyReplacement: strict"
echo "ipam:"
echo "  mode: kubernetes"
echo "ipv4NativeRoutingCIDR: 0.0.0.0/0"
echo "k8s:"
echo "  requireIPv4PodCIDR: true"
echo "routingMode: native"
echo "autoDirectNodeRoutes: false"
echo "bgpControlPlane:"
echo "  enabled: true"