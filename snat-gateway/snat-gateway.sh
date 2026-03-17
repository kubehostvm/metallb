#!/bin/bash
# MetalLB SNAT Gateway
#
# Watches LoadBalancer services and creates iptables SNAT rules so that
# pods' outbound traffic uses the service's External IP (EIP) as source.
#
# Data flow:
#   Pod (src=PodIP) -> POSTROUTING SNAT -> (src=EIP) -> eth0 -> external
#   Return traffic relies on conntrack to reverse the SNAT.
#
# NOTE on L2 mode:
#   In MetalLB L2 mode, only the elected node responds to ARP for the EIP.
#   SNAT return traffic will only reach the elected node. Therefore, for L2
#   mode to work correctly, target pods MUST be scheduled on the same node
#   as the EIP owner (use nodeSelector/affinity). In BGP mode, each node
#   can advertise the EIP independently.
#
# Required capabilities: NET_ADMIN, NET_RAW
# Required: hostNetwork=true (operates on host iptables)

set -uo pipefail

EXTERNAL_INTERFACE=${EXTERNAL_INTERFACE:-eth0}
NODE_NAME=${NODE_NAME:?"NODE_NAME must be set (use downward API: spec.nodeName)"}
SYNC_INTERVAL=${SYNC_INTERVAL:-10}
CHAIN_NAME="METALLB_SNAT"

log_info()  { echo "$(date +'%Y-%m-%d %H:%M:%S') [INFO]  $*"; }
log_error() { echo "$(date +'%Y-%m-%d %H:%M:%S') [ERROR] $*" >&2; }

# ---- iptables chain management ----

init_iptables() {
    iptables -t nat -N "$CHAIN_NAME" 2>/dev/null || true
    if ! iptables -t nat -C POSTROUTING -j "$CHAIN_NAME" 2>/dev/null; then
        iptables -t nat -I POSTROUTING -j "$CHAIN_NAME"
        log_info "Initialized chain $CHAIN_NAME in nat/POSTROUTING"
    fi
}

cleanup() {
    log_info "Shutting down, cleaning up iptables rules..."
    iptables -t nat -F "$CHAIN_NAME" 2>/dev/null || true
    iptables -t nat -D POSTROUTING -j "$CHAIN_NAME" 2>/dev/null || true
    iptables -t nat -X "$CHAIN_NAME" 2>/dev/null || true
    log_info "Cleanup complete"
    exit 0
}

trap cleanup SIGTERM SIGINT

# ---- SNAT rule operations ----

add_snat() {
    local pod_ip=$1 eip=$2
    if ! iptables -t nat -C "$CHAIN_NAME" -s "$pod_ip/32" -o "$EXTERNAL_INTERFACE" \
         -j SNAT --to-source "$eip" 2>/dev/null; then
        iptables -t nat -A "$CHAIN_NAME" -s "$pod_ip/32" -o "$EXTERNAL_INTERFACE" \
            -j SNAT --to-source "$eip"
        log_info "Added SNAT: $pod_ip -> $eip"
    fi
}

del_snat() {
    local pod_ip=$1 eip=$2
    if iptables -t nat -C "$CHAIN_NAME" -s "$pod_ip/32" -o "$EXTERNAL_INTERFACE" \
         -j SNAT --to-source "$eip" 2>/dev/null; then
        iptables -t nat -D "$CHAIN_NAME" -s "$pod_ip/32" -o "$EXTERNAL_INTERFACE" \
            -j SNAT --to-source "$eip"
        log_info "Deleted SNAT: $pod_ip -> $eip"
    fi
}

# ---- Kubernetes state queries ----

# Compute desired SNAT rules from the Kubernetes API.
# For every LoadBalancer Service with an External IP, find pod endpoints
# on THIS node and output "podIP externalIP" lines (sorted, unique).
get_desired_rules() {
    local svc_json eps_json

    svc_json=$(kubectl get svc -A -o json 2>/dev/null) || {
        log_error "Failed to list services"; return 1
    }
    eps_json=$(kubectl get endpointslices -A -o json 2>/dev/null) || {
        log_error "Failed to list endpointslices"; return 1
    }

    # Step 1: Build map  { "namespace/name": "externalIP" }
    echo "$svc_json" | jq -c '
        [ .items[] |
          select(.spec.type == "LoadBalancer") |
          select((.status.loadBalancer.ingress // []) | length > 0) |
          select(.status.loadBalancer.ingress[0].ip != null) |
          { key:   "\(.metadata.namespace)/\(.metadata.name)",
            value: .status.loadBalancer.ingress[0].ip }
        ] | from_entries
    ' > /tmp/.svc_eip_map.json

    # Step 2: For each endpointslice whose parent service is in the map,
    #         select ready endpoints on this node.
    echo "$eps_json" | jq -r \
        --arg node "$NODE_NAME" \
        --slurpfile svcMap /tmp/.svc_eip_map.json '
        ($svcMap[0] // {}) as $map |
        .items[] |
        "\(.metadata.namespace)/\(.metadata.labels["kubernetes.io/service-name"] // "")" as $svcKey |
        select($map[$svcKey] != null) |
        $map[$svcKey] as $eip |
        .endpoints[]? |
        select((.conditions.ready // false) == true) |
        select(.nodeName == $node) |
        .addresses[]? |
        "\(.) \($eip)"
    ' 2>/dev/null | sort -u
}

# Parse current METALLB_SNAT chain rules.
# Output: sorted lines of "podIP externalIP"
get_current_rules() {
    iptables-save -t nat 2>/dev/null | grep -- "-A $CHAIN_NAME" | \
        sed -n 's/.*-s \([0-9.]*\)\(\/32\)\{0,1\} .* --to-source \([0-9.]*\).*/\1 \3/p' | \
        sort -u
}

# ---- Reconciliation loop ----

reconcile() {
    local desired current
    desired=$(get_desired_rules) || return 1
    current=$(get_current_rules)

    # Add missing rules
    if [[ -n "$desired" ]]; then
        while IFS=' ' read -r pod_ip eip; do
            [[ -z "$pod_ip" ]] && continue
            echo "$current" | grep -qxF "$pod_ip $eip" || add_snat "$pod_ip" "$eip"
        done <<< "$desired"
    fi

    # Remove stale rules
    if [[ -n "$current" ]]; then
        while IFS=' ' read -r pod_ip eip; do
            [[ -z "$pod_ip" ]] && continue
            echo "$desired" | grep -qxF "$pod_ip $eip" || del_snat "$pod_ip" "$eip"
        done <<< "$current"
    fi
}

# ---- Main ----

log_info "Starting MetalLB SNAT Gateway"
log_info "NODE=$NODE_NAME  INTERFACE=$EXTERNAL_INTERFACE  INTERVAL=${SYNC_INTERVAL}s"

init_iptables

while true; do
    reconcile || log_error "Reconciliation failed, will retry"
    sleep "$SYNC_INTERVAL"
done
