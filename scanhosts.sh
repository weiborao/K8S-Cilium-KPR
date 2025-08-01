#!/bin/bash

# This script prepares the Ansible control node by adding the SSH host keys
# of the target nodes to the ~/.ssh/known_hosts file.
# It first removes any outdated keys for the specified hosts before scanning
# for the new ones, preventing "REMOTE HOST IDENTIFICATION HAS CHANGED" errors.

# --- Configuration ---
# List of hosts (IPs or FQDNs) to scan.
# These should be the same hosts you have in your Ansible inventory.
HOSTS=(
    "10.75.59.71"
    "10.75.59.72"
    "10.75.59.73"
)

# The location of your known_hosts file.
KNOWN_HOSTS_FILE=~/.ssh/known_hosts

# --- Main Logic ---
echo "Starting SSH host key scan to update ${KNOWN_HOSTS_FILE}..."
echo ""

# Ensure the .ssh directory exists with the correct permissions.
mkdir -p ~/.ssh
chmod 700 ~/.ssh

# Loop through each host defined in the HOSTS array.
for host in "${HOSTS[@]}"; do
    echo "--- Processing host: ${host} ---"

    # 1. Remove the old host key (if it exists).
    # This is the key step to ensure we replace outdated entries.
    # The command is silent if no key is found.
    echo "Step 1: Removing any old key for ${host}..."
    ssh-keygen -R "${host}"

    # 2. Scan for the new host key and append it.
    # The -H flag hashes the hostname, which is a security best practice.
    echo "Step 2: Scanning for new key and adding it to known_hosts..."
    ssh-keyscan -H "${host}" >> "${KNOWN_HOSTS_FILE}"

    echo "Successfully updated key for ${host}."
    echo ""
done

# Set the correct permissions for the known_hosts file, as SSH is strict about this.
chmod 600 "${KNOWN_HOSTS_FILE}"

echo "✅ All hosts have been scanned and keys have been updated."
echo "You can now run your Ansible playbook without host key verification prompts."
