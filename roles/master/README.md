# Ansible Role: Kubernetes Master

This role initializes the Kubernetes control plane on the designated master node.

## Tasks

- Configures the firewall (`firewalld`) to open ports required for the control plane.
- Initializes the cluster using `kubeadm init`.
- Copies the `admin.conf` file to the connecting user's home directory (`~/.kube/config`) so they can immediately use `kubectl`.
- Deploys the Calico CNI for pod networking.
- Creates and exports the `kubeadm join` command for worker nodes to use.

## Requirements

- This role must be run on a node that has already had the `common` role applied to it.
- A RHEL-based distribution (e.g., CentOS, Rocky Linux).

## Role Variables

Variables used by this role, with their default values from `defaults/main.yml`:

| Variable                | Default Value             | Description                                            |
| ----------------------- | ------------------------- | ------------------------------------------------------ |
| `control_node_fw_ports` | (see `defaults/main.yml`) | A list of ports to open on the master node's firewall. |
| `tigera_operator_url`   | `https://.../v3.27.2/...` | URL for the Tigera Operator manifest for Calico.       |
| `custom_resources_url`  | `https://.../v3.27.2/...` | URL for the Calico custom resources manifest.          |

_Note: It is highly recommended to manage the Calico manifest URLs as variables._

## Example Playbook

```yaml
- hosts: master
  roles:
    - role: master
```
