#!/bin/bash
set -e

# Load Doppler Service Token
if [ -f "/run/secrets/dp_ansible_token" ]; then
    export DOPPLER_TOKEN=$(cat /run/secrets/dp_ansible_token)
else
    echo "Error: dp_ansible_token secret not found."
    exit 1
fi

# Prepare SSH keys
mkdir -p ~/.ssh
doppler run --command='printenv $ANSIBLE_SSH_KEY' > ~/.ssh/id_ansible
chmod 600 ~/.ssh/id_ansible

# Handle Inventory Override
HAS_INVENTORY=false
for arg in "$@"; do
    if [[ "$arg" == "-i" ]] || [[ "$arg" == "--inventory" ]] || [[ "$arg" == "--inventory-file" ]]; then
        HAS_INVENTORY=true
        break
    fi
done

# Execute Ansible with Proxmox Dynamic Inventory Default
if [ "$HAS_INVENTORY" = true ]; then
    echo "Executing playbook with user-supplied inventory target..."
    exec doppler run -- ansible-playbook "$@"
else
    echo "Executing playbook with Proxmox dynamic inventory..."
    exec doppler run -- ansible-playbook -i proxmox.yml "$@"
fi