#!/bin/bash
set -eo pipefail
shopt -s nullglob

if [ "${DEBUG}" = "true" ]; then
    set -o xtrace
fi

function get_synced_count() {
    IPS=$(curl "$DISCOVERY_SERVICE/v2/keys/pxc-cluster/$CLUSTER_NAME/?quorum=true" | jq -r '.node.nodes[]?.key' | awk -F'/' '{print $(NF)}')
    for i in $IPS; do
        echo "$i" | /usr/bin/get-pxc-state \
            | grep -c wsrep_ready:ON:wsrep_connected:ON:wsrep_local_state_comment:Synced:wsrep_cluster_status:Primary
    done
}


while true; do
    if hostname -f | grep -- '-0'; then
        if grep 'safe_to_bootstrap: 1' "${grastate_loc}"; then
            break
        fi
    fi
    
    count=$(get_synced_count | awk '{print NF}')
    if (( "$count" == 0 )) ; then
        ansi success "There are healthy nodes in the cluster, which are about to join the cluster automatically."
        break
    fi

    NODE_IP=$(hostname -I | awk ' { print $1 } ')
    if (( "$seqno" == -1 )); then
        curl "$DISCOVERY_SERVICE/v2/keys/pxc-cluster/pxc-seqno/$NODE_IP" -XPUT -d value="$seqno_nu"
        seqno_value=$seqno_nu
    else
        curl "$DISCOVERY_SERVICE/v2/keys/pxc-cluster/pxc-seqno/$NODE_IP" -XPUT -d value="$seqno"
        seqno_value=$seqno
    fi
    
    seqnoList=$(curl "$DISCOVERY_SERVICE/v2/keys/pxc-cluster/pxc-seqno/?recursive=true" | jq -r '.node.nodes[]?.value')
    seqnoNum=$(echo "$seqnoList" | awk '{print NF}')
    if [ "$seqnoNum" -eq 3 ]; then
        seq1=$(echo "$seqnoList" | awk '{print $1}')
        seq2=$(echo "$seqnoList" | awk '{print $2}')
        seq3=$(echo "$seqnoList" | awk '{print $3}')
        if [ "$seq1" -eq "$seq2" ] && [ "$seq2" -eq "$seq3" ]; then
            if hostname -f | grep -- '-0'; then
                if grep 'safe_to_bootstrap: 0' "${grastate_loc}"; then
                    if [ "$count" -eq 0 ]; then
                        ansi success "Cluster is normal, ${SERVICE_NAME}-0 is being set as the primary node"
                        mysqld --wsrep-recover --tc-heuristic-recover=COMMIT
                        sed "s^safe_to_bootstrap: 0^safe_to_bootstrap: 1^" "${grastate_loc}" 1<> "${grastate_loc}"
                        break
                    fi
                fi
            fi
        else
            seqno_file="/seqnovalue"
            if [ ! -f "$seqno_file" ]; then
                touch $seqno_file
            fi

            if [ -s "$seqno_file" ]; then
                seqno_status=$(< $seqno_file awk '{print $1}' | sed -n 1p)
                if [ "${seqno_status}" = "true" ]; then
                    if grep 'safe_to_bootstrap: 0' "${grastate_loc}"; then
                        ansi success "Setting ${HOSTNAME} as the primary node"
                        mysqld --wsrep-recover --tc-heuristic-recover=COMMIT
                        sed "s^safe_to_bootstrap: 0^safe_to_bootstrap: 1^" "${grastate_loc}" 1<> "${grastate_loc}"
                        break
                    fi
                else
                    ansi error "The file content of $seqno_file is incorrect. It should be true."
                fi 
            else
                ansi error "You have the situation of a full PXC cluster crash. In order to restore your PXC cluster, please check the log
                   from all pods/nodes to find the node with the most recent data (the one with the highest sequence number (seqno).
                   It is ${HOSTNAME} node with sequence number (seqno): $seqno_value
                   If you want to recover from this node you need to execute the following command:
                   echo 'true' > /seqnovalue"
            fi
        fi
    else
        ansi error "Wait for the pxc node to be ready"
    fi
    sleep 5
done



