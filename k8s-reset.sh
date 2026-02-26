#!/usr/bin/env bash
# =============================================================================
# k8s-reset.sh — Full Kubernetes & Network Reset for Rocky Linux 9
# Preserves container images in containerd image store
# Run as root on EACH node (master and workers)
# =============================================================================
set -euo pipefail

RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

log()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
warn()   { echo -e "${YELLOW}[WARN]${NC}  $*"; }
ok()     { echo -e "${GREEN}[ OK ]${NC}  $*"; }
fail()   { echo -e "${RED}[FAIL]${NC}  $*"; exit 1; }
header() { echo -e "\n${CYAN}==============================${NC}"; echo -e "${CYAN} $*${NC}"; echo -e "${CYAN}==============================${NC}"; }

[[ $EUID -ne 0 ]] && fail "Must be run as root. Use: sudo $0"

# Detect node role
NODE_ROLE="worker"
[[ -f /etc/kubernetes/admin.conf ]] && NODE_ROLE="master"
log "Detected node role: ${NODE_ROLE}"

# =============================================================================
# 1. KUBEADM RESET
# =============================================================================
header "Step 1: kubeadm reset"

if command -v kubeadm &>/dev/null; then
    log "Running kubeadm reset..."
    kubeadm reset -f --cleanup-tmp-dir 2>/dev/null || warn "kubeadm reset exited non-zero (may be partially uninitialised)"
    ok "kubeadm reset complete"
else
    warn "kubeadm not found, skipping"
fi

# =============================================================================
# 2. STOP KUBERNETES SERVICES
# =============================================================================
header "Step 2: Stop Kubernetes services"

K8S_SERVICES=(kubelet kube-proxy kube-apiserver kube-controller-manager kube-scheduler etcd)

for svc in "${K8S_SERVICES[@]}"; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        log "Stopping $svc..."
        systemctl stop "$svc" 2>/dev/null || true
    fi
    systemctl disable "$svc" 2>/dev/null || true
done
ok "Kubernetes services stopped"

# =============================================================================
# 3. CLEAN UP KUBERNETES STATE FILES
# =============================================================================
header "Step 3: Remove Kubernetes state & config"

K8S_DIRS=(
    /etc/kubernetes
    /var/lib/kubelet
    /var/lib/etcd
    /var/lib/kube-proxy
    /var/run/kubernetes
    /run/kubernetes
    /etc/cni/net.d          # CNI config — critical to remove for Calico reset
    /var/lib/cni
    /opt/cni/bin            # optional: remove CNI binaries (kubeadm reinstalls)
    /var/log/pods
    /var/log/containers
    ~/.kube
    /root/.kube
    /home/*/.kube
)

for d in "${K8S_DIRS[@]}"; do
    if [[ -e "$d" ]]; then
        log "Removing $d"
        rm -rf "$d" || warn "Could not fully remove $d"
    fi
done

# Clean up leftover kubeadm temp dirs
rm -rf /tmp/kubeadm-* /tmp/kubernetes-* 2>/dev/null || true

ok "Kubernetes state removed"

# =============================================================================
# 4. NETWORK INTERFACES — REMOVE CNI / OVERLAY INTERFACES
# =============================================================================
header "Step 4: Remove virtual network interfaces"

# Interfaces created by Calico, flannel, weave, kube-proxy, etc.
IFACE_PATTERNS=(
    "cali*"       # Calico per-pod veth pairs
    "tunl*"       # Calico IP-in-IP tunnel
    "vxlan*"      # Calico VXLAN
    "wireguard*"  # Calico WireGuard
    "flannel*"    # Flannel
    "cni*"        # Generic CNI
    "weave"       # Weave
    "datapath"    # OVS/OVN
    "veth*"       # Pod veth pairs
    "kube-ipvs*"  # IPVS dummy interface
    "nodelocaldns"
    "docker*"
)

for pattern in "${IFACE_PATTERNS[@]}"; do
    for iface in $(ip link show 2>/dev/null | grep -oP "(?<=\d: )${pattern}(?=[@:])" 2>/dev/null || true); do
        log "Removing interface: $iface"
        ip link set "$iface" down 2>/dev/null || true
        ip link delete "$iface" 2>/dev/null || warn "Could not delete $iface (may be already gone)"
    done
done

# Explicitly handle tunl0 — often persists as a module-managed interface
if ip link show tunl0 &>/dev/null; then
    log "Removing tunl0"
    ip link set tunl0 down 2>/dev/null || true
    ip link delete tunl0 2>/dev/null || true
fi

ok "Virtual interfaces cleaned"

# =============================================================================
# 5. FLUSH IPTABLES / NFTABLES
# =============================================================================
header "Step 5: Flush iptables & nftables rules"

# Kubernetes / Calico write heavily to iptables
if command -v iptables &>/dev/null; then
    log "Flushing iptables (all tables)..."
    for table in filter nat mangle raw; do
        iptables -t "$table" -F 2>/dev/null || true
        iptables -t "$table" -X 2>/dev/null || true
        iptables -t "$table" -Z 2>/dev/null || true
    done

    # Reset default policies
    iptables -P INPUT   ACCEPT
    iptables -P FORWARD ACCEPT
    iptables -P OUTPUT  ACCEPT

    log "Flushing ip6tables..."
    for table in filter nat mangle raw; do
        ip6tables -t "$table" -F 2>/dev/null || true
        ip6tables -t "$table" -X 2>/dev/null || true
    done
    ip6tables -P INPUT   ACCEPT
    ip6tables -P FORWARD ACCEPT
    ip6tables -P OUTPUT  ACCEPT

    ok "iptables flushed"
fi

if command -v nft &>/dev/null; then
    log "Flushing nftables ruleset..."
    nft flush ruleset 2>/dev/null || warn "nft flush failed (may be empty)"
    ok "nftables flushed"
fi

# Remove persisted iptables rules
rm -f /etc/iptables/rules.v4 /etc/iptables/rules.v6 2>/dev/null || true

# =============================================================================
# 6. FLUSH IP ROUTES ADDED BY CALICO / KUBE-PROXY
# =============================================================================
header "Step 6: Clean up IP routes & rules"

log "Removing pod/service subnet routes..."

# Flush routes in tables added by kube-router / Calico
for table in 252 253 254; do
    ip route flush table "$table" 2>/dev/null || true
done

# Remove specific blackhole/unreachable routes left by Calico
ip route show | grep -E 'blackhole|192\.168\.0\.0|10\.96\.0\.0|10\.244\.' | while read -r route; do
    ip route del $route 2>/dev/null || true
done

# Flush ip rules added by kube-proxy IPVS
ip rule list | awk '/^[0-9]+:.*lookup (local|main|default|253|254|255)/ {next} /^[0-9]+:/ {print $1}' | \
    sed 's/://' | while read -r prio; do
    ip rule del pref "$prio" 2>/dev/null || true
done

ok "Routes cleaned"

# =============================================================================
# 7. RESET MTU ON REAL INTERFACES
# =============================================================================
header "Step 7: Reset MTU on physical interfaces"

# Calico and other CNIs sometimes set tunnel/pod interface MTU that can
# bleed into host NIC configuration via wrong jumbo frame assumptions.
# Rocky 9 default: 1500 for Ethernet. Adjust REAL_IFACES if your NICs differ.

REAL_IFACES=()
while IFS= read -r line; do
    iface=$(echo "$line" | awk '{print $2}' | tr -d ':')
    # Skip loopback, virtual, already-deleted interfaces
    if [[ "$iface" =~ ^(lo|veth|cali|tunl|flannel|cni|docker|kube) ]]; then
        continue
    fi
    REAL_IFACES+=("$iface")
done < <(ip link show | grep -E '^[0-9]+: ' | grep -v 'LOOPBACK')

for iface in "${REAL_IFACES[@]}"; do
    CURRENT_MTU=$(ip link show "$iface" 2>/dev/null | grep -oP 'mtu \K[0-9]+' || echo "unknown")
    if [[ "$CURRENT_MTU" != "1500" && "$CURRENT_MTU" != "unknown" ]]; then
        log "Resetting MTU on $iface: ${CURRENT_MTU} → 1500"
        ip link set "$iface" mtu 1500 2>/dev/null || warn "Could not reset MTU on $iface"
    else
        log "MTU on $iface already $CURRENT_MTU, skipping"
    fi
done

ok "MTU reset complete"

# =============================================================================
# 8. RESET IPVS STATE (kube-proxy IPVS mode)
# =============================================================================
header "Step 8: Clear IPVS tables"

if command -v ipvsadm &>/dev/null; then
    log "Clearing IPVS tables..."
    ipvsadm --clear 2>/dev/null || true
    ok "IPVS cleared"
else
    log "ipvsadm not installed, skipping"
fi

# =============================================================================
# 9. RESET SYSCTL PARAMS SET BY KUBERNETES
# =============================================================================
header "Step 9: Reset sysctl networking params"

log "Removing k8s sysctl config..."
rm -f /etc/sysctl.d/k8s.conf /etc/sysctl.d/99-kubernetes*.conf 2>/dev/null || true
rm -f /etc/modules-load.d/k8s.conf 2>/dev/null || true

# Reset the params live (don't reload entire sysctl — too broad)
SYSCTL_RESETS=(
    "net.bridge.bridge-nf-call-iptables=0"
    "net.bridge.bridge-nf-call-ip6tables=0"
    "net.ipv4.ip_forward=0"
    "net.ipv4.conf.all.rp_filter=1"
    "net.ipv4.conf.default.rp_filter=1"
)

for param in "${SYSCTL_RESETS[@]}"; do
    sysctl -w "$param" 2>/dev/null || warn "Could not reset sysctl $param"
done

ok "sysctl params reset"

# =============================================================================
# 10. UNLOAD KERNEL MODULES LOADED BY KUBERNETES/CALICO
# =============================================================================
header "Step 10: Unload Kubernetes kernel modules"

MODULES=(
    ip_vs ip_vs_rr ip_vs_wrr ip_vs_sh
    nf_conntrack
    br_netfilter
    overlay
    ipip          # Calico IP-in-IP
    vxlan         # Calico VXLAN
    wireguard     # Calico WireGuard
    dummy         # kube-ipvs0
)

for mod in "${MODULES[@]}"; do
    if lsmod | grep -q "^${mod} "; then
        log "Unloading module: $mod"
        modprobe -r "$mod" 2>/dev/null || warn "Could not unload $mod (may be in use)"
    fi
done

ok "Kernel modules unloaded"

# =============================================================================
# 11. RESET FIREWALLD TO DEFAULT STATE
# =============================================================================
header "Step 11: Reset firewalld"

if systemctl is-active --quiet firewalld 2>/dev/null; then
    log "Resetting firewalld to default zone settings..."

    # Remove all rich rules, ports, services added by k8s
    ACTIVE_ZONE=$(firewall-cmd --get-default-zone 2>/dev/null || echo "public")
    log "Active zone: $ACTIVE_ZONE"

    # Get and remove all added ports
    PORTS=$(firewall-cmd --zone="$ACTIVE_ZONE" --list-ports 2>/dev/null || true)
    for port in $PORTS; do
        firewall-cmd --zone="$ACTIVE_ZONE" --remove-port="$port" --permanent 2>/dev/null || true
    done

    # Remove rich rules
    firewall-cmd --zone="$ACTIVE_ZONE" --list-rich-rules 2>/dev/null | while IFS= read -r rule; do
        [[ -n "$rule" ]] && firewall-cmd --zone="$ACTIVE_ZONE" --remove-rich-rule="$rule" --permanent 2>/dev/null || true
    done

    # Remove masquerade
    firewall-cmd --zone="$ACTIVE_ZONE" --remove-masquerade --permanent 2>/dev/null || true

    # Remove any trusted zone entries added for pod subnets
    firewall-cmd --zone=trusted --list-sources 2>/dev/null | tr ' ' '\n' | while read -r src; do
        [[ -n "$src" ]] && firewall-cmd --zone=trusted --remove-source="$src" --permanent 2>/dev/null || true
    done

    firewall-cmd --reload 2>/dev/null || warn "firewalld reload failed"
    ok "firewalld reset"
else
    warn "firewalld not running, skipping"
fi

# =============================================================================
# 12. PRESERVE CONTAINERD IMAGES — ONLY CLEAN STATE, NOT IMAGES
# =============================================================================
header "Step 12: Reset containerd state (preserve images)"

if systemctl is-active --quiet containerd 2>/dev/null; then
    log "Stopping containerd temporarily..."
    systemctl stop containerd 2>/dev/null || true
fi

# Remove running container state, sandboxes, and snapshots used by k8s pods
# BUT preserve the content store (images)
CONTAINERD_CLEAN_DIRS=(
    /run/containerd/io.containerd.runtime.v2.task   # running task state
    /var/lib/containerd/io.containerd.snapshotter.v1.overlayfs/snapshots  # layer snapshots for dead containers
    /var/lib/containerd/io.containerd.metadata.v1.bolt/meta.db           # metadata db (will be rebuilt)
    /run/containerd/containerd.sock.ttrpc
)

# Safer approach: use ctr to remove only non-image resources if containerd is available
log "Restarting containerd to use ctr for safe cleanup..."
systemctl start containerd 2>/dev/null || true
sleep 2

if command -v ctr &>/dev/null; then
    log "Removing all containers (not images)..."
    ctr -n k8s.io containers list -q 2>/dev/null | xargs -r ctr -n k8s.io containers delete 2>/dev/null || true

    log "Removing all tasks/running processes..."
    ctr -n k8s.io tasks list -q 2>/dev/null | xargs -r -I{} sh -c 'ctr -n k8s.io tasks kill {} 2>/dev/null; ctr -n k8s.io tasks delete {} 2>/dev/null' || true

    log "Removing snapshots (not image content)..."
    ctr -n k8s.io snapshots list 2>/dev/null | tail -n+2 | awk '{print $1}' | \
        xargs -r -I{} ctr -n k8s.io snapshots remove {} 2>/dev/null || true

    # Verify images are still present
    IMAGE_COUNT=$(ctr -n k8s.io images list -q 2>/dev/null | wc -l || echo 0)
    ok "containerd cleaned. Images preserved: ${IMAGE_COUNT} image(s)"
else
    warn "ctr not found, skipping containerd container cleanup"
    systemctl restart containerd 2>/dev/null || true
fi

# =============================================================================
# 13. RE-ENABLE KUBELET (disabled, clean — ready for kubeadm init/join)
# =============================================================================
header "Step 13: Prepare kubelet for fresh start"

if command -v kubelet &>/dev/null; then
    log "Enabling kubelet service (will start properly after kubeadm init/join)..."
    systemctl enable kubelet 2>/dev/null || true
    # Do NOT start it — kubeadm init/join will manage this
    ok "kubelet enabled (not started)"
fi

# =============================================================================
# 14. SWAP — RE-DISABLE (in case it re-enabled after reboot)
# =============================================================================
header "Step 14: Disable swap"

if swapon --show | grep -q .; then
    log "Swap is active, disabling..."
    swapoff -a
    ok "Swap disabled"
else
    log "Swap already off"
fi

# =============================================================================
# SUMMARY
# =============================================================================
header "Reset Complete"

echo ""
echo -e "${GREEN}Node has been fully reset. Summary:${NC}"
echo "  ✓ kubeadm reset"
echo "  ✓ Kubernetes services stopped & disabled"
echo "  ✓ K8s state dirs removed (/etc/kubernetes, /var/lib/kubelet, etc.)"
echo "  ✓ CNI config removed (/etc/cni/net.d)"
echo "  ✓ Virtual interfaces removed (cali*, tunl*, veth*, etc.)"
echo "  ✓ iptables/nftables flushed"
echo "  ✓ IP routes & rules cleaned"
echo "  ✓ MTU reset to 1500 on physical interfaces"
echo "  ✓ IPVS tables cleared"
echo "  ✓ sysctl networking params reset"
echo "  ✓ Kernel modules unloaded"
echo "  ✓ firewalld reset to default"
echo "  ✓ containerd containers/tasks/snapshots removed (IMAGES PRESERVED)"
echo "  ✓ swap disabled"
echo ""

if [[ "$NODE_ROLE" == "master" ]]; then
    echo -e "${YELLOW}This was a MASTER node. Run your Ansible playbook from the control node:${NC}"
    echo "    ansible-playbook playbook.yml"
else
    echo -e "${YELLOW}This was a WORKER node. Re-run the Ansible playbook from the control node.${NC}"
    echo "  Or reset ALL nodes at once using the companion Ansible reset playbook."
fi

echo ""
echo -e "${CYAN}Recommended: reboot the node before re-running Ansible for a clean kernel state.${NC}"
echo "    reboot"
echo ""