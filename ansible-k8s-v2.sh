#!/bin/bash

# This script automates the setup of an Ansible environment for Kubernetes cluster deployment.
# It installs Ansible, creates the project directory, inventory, configuration,
# and defines common Kubernetes setup tasks.
# This version stops after installing Kubernetes components, allowing manual kubeadm init/join.
# Includes a robust fix for Containerd's SystemdCgroup configuration and CRI plugin enabling,
# defines the necessary handler for restarting Containerd, dynamically adds host entries to /etc/hosts,
# and updates the pause image version in the manual instructions.
# This update also addresses the runc runtime root configuration in containerd and fixes
# YAML escape character issues in the hosts file regex, and updates the sandbox image in containerd config.

# --- Configuration ---
PROJECT_DIR="k8s_cluster_setup"
MASTER_NODE_IP="10.75.59.71" # Based on your previous script's IP assignment for kube-node-1
WORKER_NODE_IP_1="10.75.59.72" # Based on your previous script's IP assignment for kube-node-2
WORKER_NODE_IP_2="10.75.59.73" # Based on your previous script's IP address for kube-node-3
ANSIBLE_USER="ubuntu" # The user created by cloud-init on your VMs
SSH_PRIVATE_KEY_PATH="~/.ssh/id_rsa" # Path to your SSH private key on the Ansible control machine

# --- Functions ---

# Function to install Ansible
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
    mkdir -p "${PROJECT_DIR}"
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
host_key_checking = False # WARNING: Disable host key checking for convenience during initial setup. Re-enable for production!
EOF
    echo "ansible.cfg created."
}

# Function to create inventory.ini (UPDATED with IP variables)
create_inventory() {
    echo "--- Creating inventory.ini ---"
    cat <<EOF > inventory.ini
[master]
kube-node-1 ansible_host=${MASTER_NODE_IP}

[workers]
kube-node-2 ansible_host=${WORKER_NODE_IP_1}
kube-node-3 ansible_host=${WORKER_NODE_IP_2}

[all:vars]
ansible_user=${ANSIBLE_USER}
ansible_ssh_private_key_file=${SSH_PRIVATE_KEY_PATH}
ansible_python_interpreter=/usr/bin/python3
# These variables are now primarily for documentation/script clarity,
# as the hosts file task will dynamically read from inventory groups.
master_node_ip=${MASTER_NODE_IP}
worker_node_ip_1=${WORKER_NODE_IP_1}
worker_node_ip_2=${WORKER_NODE_IP_2}
EOF
    echo "inventory.ini created."
}

# Function to create main playbook.yml (Modified to only include common setup)
create_playbook() {
    echo "--- Creating playbook.yml ---"
    cat <<EOF > playbook.yml
---
- name: Common Kubernetes Setup for all nodes
  hosts: all
  become: yes
  roles:
    - common_k8s_setup
EOF
    echo "playbook.yml created (only common setup included)."
}

# Function to create roles and their tasks
create_roles() {
    echo "--- Creating Ansible roles and tasks ---"

    # common_k8s_setup role
    mkdir -p roles/common_k8s_setup/tasks
    # UPDATED: main.yml to include the new hosts entry task first
    cat <<EOF > roles/common_k8s_setup/tasks/main.yml
---
- name: Include add hosts entries task
  ansible.builtin.include_tasks: 00_add_hosts_entries.yml

- name: Include disable swap task
  ansible.builtin.include_tasks: 01_disable_swap.yml

- name: Include containerd setup task
  ansible.builtin.include_tasks: 02_containerd_setup.yml

- name: Include kernel modules and sysctl task
  ansible.builtin.include_tasks: 03_kernel_modules_sysctl.yml

- name: Include kube repo, install, and hold task
  ansible.builtin.include_tasks: 04_kube_repo_install_hold.yml

- name: Include initial apt upgrade task
  ansible.builtin.include_tasks: 05_initial_upgrade.yml

- name: Include configure weekly updates task
  ansible.builtin.include_tasks: 06_configure_weekly_updates.yml
EOF

    # NEW FILE: 00_add_hosts_entries.yml (Dynamically adds hosts from inventory, FIXED: Escaped backslashes in regex)
    cat <<EOF > roles/common_k8s_setup/tasks/00_add_hosts_entries.yml
---
- name: Add all inventory hosts to /etc/hosts on each node
  ansible.builtin.lineinfile:
    path: /etc/hosts
    regexp: "^{{ hostvars[item]['ansible_host'] }}\\\\s+{{ item }}" # Fixed: \\\\s for escaped backslash in regex
    line: "{{ hostvars[item]['ansible_host'] }} {{ item }}"
    state: present
    create: yes
    mode: '0644'
    owner: root
    group: root
  loop: "{{ groups['all'] }}" # Loop over all hosts defined in the inventory
EOF

    # Create handlers directory and file
    mkdir -p roles/common_k8s_setup/handlers
    cat <<EOF > roles/common_k8s_setup/handlers/main.yml
---
- name: Restart containerd service
  ansible.builtin.systemd:
    name: containerd
    state: restarted
    daemon_reload: yes
EOF

    # 01_disable_swap.yml
    cat <<EOF > roles/common_k8s_setup/tasks/01_disable_swap.yml
---
- name: Check if swap is active
  ansible.builtin.command: swapon --show
  register: swap_check_result
  changed_when: false # This command itself doesn't change state
  failed_when: false  # Don't fail if swapon --show returns non-zero (e.g., no swap enabled)

- name: Disable swap
  ansible.builtin.command: swapoff -a
  when: swap_check_result.rc == 0 # Only run if swapon --show indicated swap is active

- name: Persistently disable swap (comment out swapfile in fstab)
  ansible.builtin.replace:
    path: /etc/fstab
    regexp: '^(/swapfile.*)$'
    replace: '#\1'
  when: swap_check_result.rc == 0 # Only run if swap was found to be active
EOF

    # 02_containerd_setup.yml (UPDATED for sandbox_image)
    cat <<EOF > roles/common_k8s_setup/tasks/02_containerd_setup.yml
---
- name: Install required packages for Containerd
  ansible.builtin.apt:
    name:
      - ca-certificates
      - curl
      - gnupg
      - lsb-release
      - apt-transport-https
      - software-properties-common
    state: present
    update_cache: yes

- name: Add Docker GPG key
  ansible.builtin.apt_key:
    url: https://download.docker.com/linux/ubuntu/gpg
    state: present
    keyring: /etc/apt/keyrings/docker.gpg # Use keyring for modern apt

- name: Add Docker APT repository
  ansible.builtin.apt_repository:
    repo: "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu {{ ansible_distribution_release }} stable"
    state: present
    filename: docker

- name: Install Containerd
  ansible.builtin.apt:
    name: containerd.io
    state: present
    update_cache: yes

- name: Create containerd configuration directory
  ansible.builtin.file:
    path: /etc/containerd
    state: directory
    mode: '0755'

- name: Generate default containerd configuration directly to final path
  ansible.builtin.shell: containerd config default > /etc/containerd/config.toml
  changed_when: true # Always report change as we're ensuring a default state

- name: Ensure CRI plugin is enabled (remove any disabled_plugins line containing "cri")
  ansible.builtin.lineinfile:
    path: /etc/containerd/config.toml
    regexp: '^\s*disabled_plugins = \[.*"cri".*\]' # More general regexp
    state: absent
    backup: yes
  notify: Restart containerd service

- name: Remove top-level systemd_cgroup from CRI plugin section
  ansible.builtin.lineinfile:
    path: /etc/containerd/config.toml
    regexp: '^\s*systemd_cgroup = (true|false)' # Matches the 'systemd_cgroup' directly under [plugins."io.containerd.grpc.v1.cri"]
    state: absent # Remove this line
    backup: yes
  notify: Restart containerd service

- name: Remove old runtime_root from runc runtime section
  ansible.builtin.lineinfile:
    path: /etc/containerd/config.toml
    regexp: '^\s*runtime_root = ".*"' # Matches runtime_root line
    state: absent
    backup: yes
  notify: Restart containerd service

- name: Configure runc runtime to use SystemdCgroup = true
  ansible.builtin.lineinfile:
    path: /etc/containerd/config.toml
    regexp: '^\s*#?\s*SystemdCgroup = (true|false)' # Matches the 'SystemdCgroup' under runc.options
    line: '            SystemdCgroup = true' # Ensure correct indentation
    insertafter: '^\s*\[plugins\."io\.containerd\.grpc\.v1\.cri"\.containerd\.runtimes\.runc\.options\]'
    backup: yes
  notify: Restart containerd service

- name: Add Root path to runc options
  ansible.builtin.lineinfile:
    path: /etc/containerd/config.toml
    regexp: '^\s*Root = ".*"' # Matches existing Root line if any
    line: '            Root = "/run/containerd/runc"' # New Root path
    insertafter: '^\s*\[plugins\."io\.containerd\.grpc\.v1\.cri"\.containerd\.runtimes\.runc\.options\]'
    backup: yes
  notify: Restart containerd service

- name: Update sandbox_image to pause:3.10
  ansible.builtin.lineinfile:
    path: /etc/containerd/config.toml
    regexp: '^\s*sandbox_image = "registry.k8s.io/pause:.*"'
    line: '    sandbox_image = "registry.k8s.io/pause:3.10"'
    insertafter: '^\s*\[plugins\."io\.containerd\.grpc\.v1\.cri"\]' # Insert after the CRI plugin section start
    backup: yes
  notify: Restart containerd service
EOF

    # 03_kernel_modules_sysctl.yml
    cat <<EOF > roles/common_k8s_setup/tasks/03_kernel_modules_sysctl.yml
---
- name: Load overlay module
  ansible.builtin.command: modprobe overlay
  args:
    creates: /sys/module/overlay # Check if module is loaded
  changed_when: false

- name: Load br_netfilter module
  ansible.builtin.command: modprobe br_netfilter
  args:
    creates: /sys/module/br_netfilter # Check if module is loaded
  changed_when: false

- name: Add modules to /etc/modules-load.d/k8s.conf
  ansible.builtin.copy:
    dest: /etc/modules-load.d/k8s.conf
    content: |
      overlay
      br_netfilter

- name: Configure sysctl parameters for Kubernetes networking
  ansible.builtin.copy:
    dest: /etc/sysctl.d/k8s.conf
    content: |
      net.bridge.bridge-nf-call-iptables = 1
      net.bridge.bridge-nf-call-ip6tables = 1
      net.ipv4.ip_forward = 1

- name: Apply sysctl parameters
  ansible.builtin.command: sysctl --system
  changed_when: false
EOF

    # 04_kube_repo_install_hold.yml
    cat <<EOF > roles/common_k8s_setup/tasks/04_kube_repo_install_hold.yml
---
- name: Create Kubernetes apt keyring directory
  ansible.builtin.file:
    path: /etc/apt/keyrings
    state: directory
    mode: '0755'

- name: Download Kubernetes GPG key and dearmor
  ansible.builtin.shell: |
    curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.33/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
  args:
    creates: /etc/apt/keyrings/kubernetes-apt-keyring.gpg
  changed_when: false # This command is idempotent enough for our purposes

- name: Add Kubernetes APT repository source list
  ansible.builtin.copy:
    dest: /etc/apt/sources.list.d/kubernetes.list
    content: "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.33/deb/ /\n"
    mode: '0644'
    backup: yes

- name: Update apt cache after adding Kubernetes repo
  ansible.builtin.apt:
    update_cache: yes

- name: Install kubelet, kubeadm, kubectl
  ansible.builtin.apt:
    name:
      - kubelet
      - kubeadm
      - kubectl
    state: present
    update_cache: yes # Ensure apt cache is updated after adding repo.

- name: Hold kubelet, kubeadm, kubectl packages
  ansible.builtin.dpkg_selections:
    name: "{{ item }}"
    selection: hold
  loop:
    - kubelet
    - kubeadm
    - kubectl

- name: Enable and start kubelet service
  ansible.builtin.systemd:
    name: kubelet
    state: started
    enabled: yes
EOF

    # NEW FILE: 05_initial_upgrade.yml
    cat <<EOF > roles/common_k8s_setup/tasks/05_initial_upgrade.yml
---
- name: Perform initial apt update and upgrade
  ansible.builtin.apt:
    update_cache: yes
    upgrade: yes
    autoremove: yes
    purge: yes
EOF

    # NEW FILE: 06_configure_weekly_updates.yml
    cat <<EOF > roles/common_k8s_setup/tasks/06_configure_weekly_updates.yml
---
- name: Configure weekly apt update and upgrade cron job
  ansible.builtin.cron:
    name: "weekly apt update and upgrade"
    weekday: "0" # Sunday
    hour: "3"    # 3 AM
    minute: "0"
    job: "/usr/bin/apt update && /usr/bin/apt upgrade -y && /usr/bin/apt autoremove -y && /usr/bin/apt clean"
    user: root
    state: present
EOF

    # Master and Worker roles are still created for structure, but not called by playbook.yml
    mkdir -p roles/k8s-master/tasks
    cat <<EOF > roles/k8s-master/tasks/main.yml
---
- name: This role is intentionally skipped by the main playbook for manual setup.
  ansible.builtin.debug:
    msg: "This master role is not executed by default. Run 'kubeadm init' manually on the master node."
EOF

    mkdir -p roles/k8s-worker/tasks
    cat <<EOF > roles/k8s-worker/tasks/main.yml
---
- name: This role is intentionally skipped by the main playbook for manual setup.
  ansible.builtin.debug:
    msg: "This worker role is not executed by default. Run 'kubeadm join' manually on worker nodes."
EOF

    echo "Ansible roles and tasks created."
}

# --- Main execution ---
install_ansible
create_project_dir
create_ansible_cfg
create_inventory
create_playbook
create_roles

echo ""
echo "--- Ansible setup for Kubernetes installation is complete! ---"
echo "Navigate to the project directory:"
echo "cd ${PROJECT_DIR}"
echo ""
echo "Then, run the Ansible playbook to install Kubernetes components on all nodes:"
echo "ansible-playbook playbook.yml -K"
echo ""
echo "After the playbook finishes, you will need to manually initialize the Kubernetes cluster:"
echo "1. SSH into the master node (kube-node-1):"
echo "   ssh ubuntu@${MASTER_NODE_IP}"
echo ""
echo "2. Initialize the Kubernetes control plane on the master node:"
echo "   sudo kubeadm init --pod-network-cidr=192.168.0.0/16 --upload-certs --pod-infra-container-image=registry.k8s.io/pause:3.10"
echo ""
echo "3. After 'kubeadm init' completes, it will print instructions to set up kubectl and the 'kubeadm join' command."
echo "   Follow the instructions to set up kubectl for the 'ubuntu' user:"
echo "   mkdir -p \$HOME/.kube"
echo "   sudo cp -i /etc/kubernetes/admin.conf \$HOME/.kube/config"
echo "   sudo chown \$(id -u):\$(id -g) \$HOME/.kube/config"
echo ""
echo "4. Copy the 'kubeadm join' command (including the token and discovery-token-ca-cert-hash) printed by 'kubeadm init'."
echo "   It will look something like: 'kubeadm join <master-ip>:6443 --token <token> --discovery-token-ca-cert-hash sha256:<hash>'"
echo ""
echo "5. SSH into each worker node (kube-node-2, kube-node-3) and run the join command:"
echo "   ssh ubuntu@${WORKER_NODE_IP_1} (for kube-node-2)"
echo "   sudo <PASTE_YOUR_KUBEADM_JOIN_COMMAND_HERE>"
echo ""
echo "   ssh ubuntu@${WORKER_NODE_IP_2} (for kube-node-3)"
echo "   sudo <PASTE_YOUR_KUBEADM_JOIN_COMMAND_HERE>"
echo ""
echo "6. Verify your cluster status from the master node:"
echo "   ssh ubuntu@${MASTER_NODE_IP}"
echo "   kubectl get nodes"
echo "   kubectl get pods --all-namespaces"