#!/bin/bash

##############################################
#### Used to support scripts written by rainbond,zq revised it in 2021-11-18
##############################################

set -eo pipefail
shopt -s nullglob
set -o xtrace

function get_synced_count() {
    peer-list -on-start=/usr/bin/get-pxc-state -service="$PXC_SERVICE" 2>&1 \
        | grep -c wsrep_ready:ON:wsrep_connected:ON:wsrep_local_state_comment:Synced:wsrep_cluster_status:Primary
}


while true; do
    GRA=/var/lib/mysql/grastate.dat
    if grep 'safe_to_bootstrap: 1' "${GRA}"; then
        break
    fi
    
    if [[ "$(get_synced_count)" != "0" ]]; then
        ansi info "There are healthy nodes in the cluster, which are about to join the cluster automatically."
        break
    fi

    seqno_value_file="/usr/local/bin/seqno-value"
    seqno_value=$(< $seqno_value_file awk '{print $1}' | sed -n 1p)

    NODE_IP=$(hostname -I | awk ' { print $1 } ')
    curl "http://$ETCD_HOST:$ETCD_PORT/v2/keys/pxc-cluster/pxc-seqno/$NODE_IP" -XPUT -d value="$seqno_value"
    
    
    seqnoList=$(curl "http://$ETCD_HOST:$ETCD_PORT/v2/keys/pxc-cluster/pxc-seqno/?recursive=true" | jq -r '.node.nodes[]?.value')
    seqnoNum=$(echo "$seqnoList" | awk '{print NF}')
    if [[ "$seqnoNum" != "3" ]]; then
        seq1=$(echo "$seqnoList" | awk '{print $1}')
        seq2=$(echo "$seqnoList" | awk '{print $2}')
        seq3=$(echo "$seqnoList" | awk '{print $3}')
        if [[ "$seq1" == "$seq2" ]] && [[ "$seq2" == "$seq3" ]]; then
            if hostname -f | grep -- '-0'; then
                if grep 'safe_to_bootstrap: 0' "${GRA}"; then
                    if [[ "$(get_synced_count)" != "0" ]]; then
                        ansi info "Cluster is normal, ${SERVICE_NAME}-0 is being set as the primary node"
                        mysqld --wsrep-recover --tc-heuristic-recover=COMMIT
                        sed "s^safe_to_bootstrap: 0^safe_to_bootstrap: 1^" "${GRA}" 1<> "${GRA}"
                        break
                    fi
                fi
            fi
        else
            seqno_file="/usr/local/bin/seqno_status"
            if [ -s "$seqno_file" ]; then
                if grep 'true' "$seqno_file"; then
                    if grep 'safe_to_bootstrap: 0' "${GRA}"; then
                        ansi info "Setting ${HOSTNAME} as the primary node"
                        mysqld --wsrep-recover --tc-heuristic-recover=COMMIT
                        sed "s^safe_to_bootstrap: 0^safe_to_bootstrap: 1^" "${GRA}" 1<> "${GRA}"
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



