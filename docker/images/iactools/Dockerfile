# Doppler Secrets Manager CLI
FROM dopplerhq/cli:latest AS dpcli_image

# Main Image
FROM python:3.14-slim

ENV DEBIAN_FRONTEND=noninteractive

# Install Dependencies
RUN apt-get update && apt-get install -y \
    openssh-client \
    && rm -rf /var/lib/apt/lists/*

# Install Ansible and Proxmox API dependencies
RUN pip install --no-cache-dir ansible proxmoxer requests

# Install Required Ansible Collection for Proxmox
RUN ansible-galaxy collection install community.proxmox

# Copy the doppler binary
COPY --from=dpcli_image /bin/doppler /usr/local/bin/doppler
RUN chmod +x /usr/local/bin/doppler

COPY ./ansible-data /opt/ansible
WORKDIR /opt/ansible

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]