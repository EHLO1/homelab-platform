# Doppler Secrets Manager CLI
FROM dopplerhq/cli:latest AS dpcli_image
# HashiCorp Packer
FROM hashicorp/packer:latest AS pkr_image

# Main Image
FROM python:3.14-slim

ENV DEBIAN_FRONTEND=noninteractive

# Install Dependencies
RUN apt-get update && apt-get install -y \
    openssh-client \
    git \
    curl \
    jq \
    && rm -rf /var/lib/apt/lists/*

# Install Ansible and Proxmox API dependencies
RUN pip install --no-cache-dir ansible proxmoxer requests

# Install Required Ansible Collection for Proxmox
RUN ansible-galaxy collection install community.proxmox

# Copy Ansible CFG and set the ENV
COPY ansible.cfg /opt/ansible.cfg
ENV ANSIBLE_CONFIG=/opt/ansible/ansible.cfg

# Copy the doppler binary
COPY --from=dpcli_image /bin/doppler /usr/local/bin/doppler

# Copy the packer binary
COPY --from=pkr_image /bin/packer /usr/local/bin/packer
ENV PACKER_PLUGIN_PATH=/opt/packer/plugins
RUN packer plugins install github.com/hashicorp/proxmox

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]