#!/bin/bash

# --- Configuration for Ansible and DNSmasq ---
VM_IP="10.75.59.76"
SSH_USER="ubuntu"
SSH_PRIVATE_KEY_PATH="~/.ssh/id_rsa" # Ensure this path is correct for your setup
FORWARD_NAMESERVER1="64.104.76.247"
FORWARD_NAMESERVER2="64.104.14.184"
SEARCH_DOMAIN="cisco.com"
ANSIBLE_DIR="ansible_dnsmasq_setup"

echo "--- Setting up Ansible environment and configuring DNSmasq on ${VM_IP} ---"

# Create a directory for Ansible files
mkdir -p "$ANSIBLE_DIR"
cd "$ANSIBLE_DIR" || exit 1

# --- Install Ansible if not already installed ---
if ! command -v ansible &> /dev/null
then
    echo "Ansible not found. Installing Ansible..."
    # Check OS and install accordingly
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        if [[ "$ID" == "ubuntu" || "$ID" == "debian" ]]; then
            sudo apt update
            sudo apt install -y software-properties-common
            sudo apt-add-repository --yes --update ppa:ansible/ansible
            sudo apt install -y ansible
        elif [[ "$ID" == "centos" || "$ID" == "rhel" || "$ID" == "fedora" ]]; then
            sudo yum install -y epel-release
            sudo yum install -y ansible
        else
            echo "Unsupported OS for automatic Ansible installation. Please install Ansible manually."
            exit 1
        fi
    else
        echo "Could not determine OS for automatic Ansible installation. Please install Ansible manually."
        exit 1
    fi
else
    echo "Ansible is already installed."
fi

# --- Create Ansible Inventory File ---
echo "Creating Ansible inventory file: inventory.ini"
cat <<EOF > inventory.ini
[dns_server]
${VM_IP} ansible_user=${SSH_USER} ansible_ssh_private_key_file=${SSH_PRIVATE_KEY_PATH} ansible_python_interpreter=/usr/bin/python3
EOF

# --- Create Ansible Playbook (setup-dnsmasq.yml) ---
echo "Creating Ansible playbook: setup-dnsmasq.yml"
cat <<EOF > setup-dnsmasq.yml
---
- name: Configure DNSmasq Server on Ubuntu VM
  hosts: dns_server
  become: yes # Run tasks with sudo privileges
  vars:
    dns_forwarder_1: "${FORWARD_NAMESERVER1}"
    dns_forwarder_2: "${FORWARD_NAMESERVER2}"
    vm_ip: "${VM_IP}"
    search_domain: "${SEARCH_DOMAIN}"

  tasks:
    - name: Ensure apt cache is updated
      ansible.builtin.apt:
        update_cache: yes
        cache_valid_time: 3600 # Cache for 1 hour

    - name: Install dnsmasq package
      ansible.builtin.apt:
        name: dnsmasq
        state: present

    - name: Stop dnsmasq service before configuration
      ansible.builtin.systemd:
        name: dnsmasq
        state: stopped
      ignore_errors: yes # Ignore if it's not running initially

    - name: Backup original dnsmasq.conf
      ansible.builtin.command: mv /etc/dnsmasq.conf /etc/dnsmasq.conf.bak
      args:
        removes: /etc/dnsmasq.conf # Only run if dnsmasq.conf exists
      ignore_errors: yes

    - name: Configure dnsmasq for forwarding
      ansible.builtin.template:
        src: dnsmasq.conf.j2
        dest: /etc/dnsmasq.conf
        owner: root
        group: root
        mode: '0644'
      notify: Restart dnsmasq

    - name: Set VM's /etc/resolv.conf to point to itself (local DNS)
      ansible.builtin.template:
        src: resolv.conf.j2
        dest: /etc/resolv.conf
        owner: root
        group: root
        mode: '0644'
      vars:
        local_dns_ip: "127.0.0.1" # dnsmasq listens on 127.0.0.1
        # Removed: search_domain: "{{ search_domain }}" - it's already available from play vars
      notify: Restart systemd-resolved # Or NetworkManager, depending on Ubuntu version

  handlers:
    - name: Restart dnsmasq
      ansible.builtin.systemd:
        name: dnsmasq
        state: restarted
        enabled: yes # Ensure it's enabled to start on boot

    - name: Restart systemd-resolved
      ansible.builtin.systemd:
        name: systemd-resolved
        state: restarted
      ignore_errors: yes # systemd-resolved might not be used on server installs
EOF

# --- Create dnsmasq.conf.j2 template ---
echo "Creating dnsmasq.conf.j2 template"
cat <<EOF > dnsmasq.conf.j2
# This file is managed by Ansible. Do not edit manually.

# Do not read /etc/resolv.conf, use the servers below
no-resolv

# Specify upstream DNS servers for forwarding
server={{ dns_forwarder_1 }}
server={{ dns_forwarder_2 }}

# Listen on localhost and the VM's primary IP
listen-address=127.0.0.1,{{ vm_ip }}

# Allow queries from any interface
interface={{ ansible_default_ipv4.interface }} # Listen on the primary network interface

# Bind to the interfaces to prevent dnsmasq from listening on all interfaces
bind-interfaces

# Cache DNS results
cache-size=150
EOF

# --- Create resolv.conf.j2 template ---
echo "Creating resolv.conf.j2 template"
cat <<EOF > resolv.conf.j2
# This file is managed by Ansible. Do not edit manually.
nameserver {{ local_dns_ip }}
search {{ search_domain }}
EOF

# --- Run the Ansible Playbook ---
echo "Running Ansible playbook to configure DNSmasq..."
ansible-playbook -i inventory.ini setup-dnsmasq.yml -K

# --- Final Instructions ---
echo "--------------------------------------------------------"
echo "DNSmasq configuration complete on ${VM_IP}."
echo "You can now test the DNS server from the VM or from another machine."
echo "From the VM, run: dig @127.0.0.1 www.cisco.com"
echo "From another machine on the same network, configure its DNS to ${VM_IP} and run: dig www.cisco.com"
echo "Remember to exit the '${ANSIBLE_DIR}' directory when done (cd ..)."
