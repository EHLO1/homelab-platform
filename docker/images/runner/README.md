# Ansible

## Overview
This is a purpose-built ansible image that includes all playbooks that I currently use in my homelab environment. Secrets are passed via Doppler Secrets Manager using the doppler CLI, pulled at runtime, from within the container. Secret Zero is a Doppler Service Token, made available to the container using a Docker secret.

Default host inventory uses the dynamic host file feature offered in the `community.proxmox` Ansible Galaxy Collection. This allows targeting of VMs running on Proxmox VE by their tags.

The image is built using `python:3.X-slim`(Debian).

**Current Functions:**
- Update OS (Ubuntu, Debian)
- Install Docker Engine (Ubuntu Debian)

## Dependencies

**Standard Dependencies** 
`openssh-client`
`doppler`

**Ansible Dependencies (pip)** 
`ansible`
`proxmoxer`
`requests`

**Ansible Galaxy Collections** 
`community.proxmox`

## Requirements

### Docker Secret (Ansible Doppler Service Token)
1. Create a new Service Token in Doppler Secrets Manager  
<br>
2. Save the Ansible DOPPLER_TOKEN to a file and secure it
    ```shell
    sudo mkdir -p /opt/secrets && \
    echo "doppler-service-token" | sudo tee /opt/secrets/dp_ansible_token && \
    sudo chmod 600 /opt/secrets/dp_ansible_token
    ```
<br>

3. Mount it as a Docker Secret
    ```yaml
    secrets:
      dp_ansible_token:
        file: /opt/secrets/dp_ansible_token
    ```

### Proxmox
**Ansible User Login & Role**

1. Create Role for Inventory Discovery
    ```shell
    pveum role add ansible_inventory -privs "VM.Audit,Sys.Audit,SDN.Audit,Pool.Audit"
    ```
<br>

2. Create User (for API login, no password because this account can't login locally)
    ```shell
    pveum user add ansible@pve --comment "Ansible Dynamic Inventory"
    ```
<br>

3. Assign the ansible_inventory Role
    ```shell
    pveum acl modify / -user ansible@pve -role ansible_inventory
    ```
<br>

4. Create the API Token
    ```shell
    pveum user token add ansible@pve inventory --privsep 0 --comment "Ansible Inventory Token"
    ```
<br>

**Tags**  
Ensure each VM to be managed has a tag like 'docker', 'ubuntu', 'debian', etc..

**Template with Cloud-Init (Optional)**
Build a VM template and use cloud-init to configure the ansible user login and required configuration.

### Hosts / Inventory
- Ensure `ansible` account exists that can `sudo` (NOPASSWD, or use `--ask-become-pass`).
- Ensure the ansible ssh public key exists in `/home/ansible/.ssh/authorized_keys`.

## Usage & Examples

### Default
If no host inventory is specified with `-i` or `--inventory` then the container will use the Dynamic Proxmox Inventory by default.

```yaml
command: ["site.yml"]
```
*Translates to: `ansible-playbook site.yml` and uses the default inventory/homelab.proxmox.yml*

### Host List Override
```yaml
command: ["-i", "192.168.1.150,", "site.yml"]
```
*Translates to: `ansible-playbook -i 192.168.1.150, site.yml`*

### Inventory File Override
```yaml
command: ["-i", "local-docker-nodes.yml", "site.yml"]
```
*Translates to: `ansible-playbook -i local-docker-nodes.yml site.yml`*


## Development

Use the `compose.yaml` file to add bind-mounts `playbooks/`, `roles/`, and `inventory/`
to mount over the directories in the image.
