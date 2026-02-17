# Ansible Role: Kubernetes Common

This role performs the common setup tasks required on all nodes (both master and workers) before they can be part of a Kubernetes cluster.

## Tasks

- Disables swap on the node.
- Configures kernel parameters for Kubernetes (`net.ipv4.ip_forward`).
- Sets SELinux to `permissive` mode.
- Installs required packages: `kubelet`, `kubeadm`, and `kubectl`.
- Installs and configures a container runtime via a role dependency.

## Requirements

- A RHEL-based distribution (e.g., CentOS, Rocky Linux).
- The `community.kubernetes` Ansible collection is required for some modules that could be used to improve this role.

## Role Variables

It is recommended to define these in a `group_vars/all.yml` file.

| Variable      | Default | Description                                 |
|---------------|---------|---------------------------------------------|
| `k8s_version` | `1.35`  | The minor version of Kubernetes to install. |

## Dependencies

- `geerlingguy.containerd`: This role is used to install and configure the `containerd` container runtime. It is installed automatically via `ansible-galaxy`.

## Example Playbook

```yaml
- hosts: all
  roles:
    - role: common
```
