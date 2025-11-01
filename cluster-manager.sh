#!/bin/bash

set -euo pipefail


CONFIG_DIR="/root/config"

set_kubeconfig() {
    local cluster_name="$1"
    local region="${2:-us-east-1}"   # default region if not provided
    local kubeconfig_path="${3:-$HOME/.kube/config}"

    if [[ -z "$cluster_name" ]]; then
        echo "❌ Error: Cluster name is required."
        echo "Usage: set_kubeconfig <cluster_name> [region] [kubeconfig_path]"
        return 1
    fi

    echo "🔍 Checking if EKS cluster '$cluster_name' exists in region '$region'..."
    if ! aws eks describe-cluster --name "$cluster_name" --region "$region" >/dev/null 2>&1; then
        echo "❌ Cluster '$cluster_name' not found in region '$region'."
        return 1
    fi

    echo "⚙️ Updating kubeconfig for cluster '$cluster_name'..."
    aws eks update-kubeconfig \
        --name "$cluster_name" \
        --region "$region" \
        --kubeconfig "$kubeconfig_path" >/dev/null

    if [[ $? -eq 0 ]]; then
        echo "✅ kubeconfig set successfully for cluster '$cluster_name'."
        echo "📁 Config path: $kubeconfig_path"
        echo "🌐 Current context: $(kubectl config current-context)"
    else
        echo "❌ Failed to set kubeconfig."
        return 1
    fi
}

create-cluster(){

    config_file=""

    DRY_RUN=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -f)
                
                config_file="${CONFIG_DIR}/${2}"
                shift 2
                ;;
            --dry-run)
                if [ -n "$2" && "$2" != -*  ]; then
                    DRY_RUN="$2"
                else
                    DRY_RUN="true"
                fi
                ;;
            *)
                echo "Unknown option: $1"
                exit 1
                ;;
        esac
    done


    if [ ! - f "${config_file}" ]; then

        echo "Error : Usage create-cluster -f <config_file> --dry-run true/false"


    fi

    TEMP_FILE="${CONFIG_DIR}/eksctl-cluster.yaml"

    cp "$config_file" "${TEMP_FILE}"

    yq 'del(.extraAddons)' "$config_file" > "$TEMP_FILE"

    eksctl create cluster -f "$TEMP_FILE" --approve --dry-run "$DRY_RUN"

    rm -f "$TEMP_FILE"

}

delete-cluster(){

    config_file=""

    DRY_RUN=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -f)
                config_file="${CONFIG_DIR}/${2}"
                shift 2
                ;;
            --dry-run)
                if [ -n "$2" && "$2" != -*  ]; then
                    DRY_RUN="$2"
                else
                    DRY_RUN="true"
                fi
                ;;
            *)
                echo "Unknown option: $1"
                exit 1
                ;;
        esac
    done


    if [ ! - f "${config_file}" ]; then

        echo "Error : Usage create-cluster -f <config_file> --dry-run true/false"

    fi

    TEMP_FILE="${CONFIG_DIR}/eksctl-cluster.yaml"

    cp "$config_file" "${TEMP_FILE}"

    yq 'del(.extraAddons)' "$config_file" > "$TEMP_FILE"

    eksctl delete cluster -f "TEMP_FILE" --wait --approve

    rm -f "$TEMP_FILE"

}

update-cluster(){

}

get-node-groups(){

    config_file=""

    DRY_RUN=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -f)
                
                config_file="${CONFIG_DIR}/${2}"
                shift 2
                ;;
            --dry-run)
                if [ -n "$2" && "$2" != -*  ]; then
                    DRY_RUN="$2"
                else
                    DRY_RUN="true"
                fi
                ;;
            *)
                echo "Unknown option: $1"
                exit 1
                ;;
        esac
    done
    
    if [ ! -f "$config_file" ]; then
        echo "❌ Usage: get_nodegroups -f <config_file.yaml>"
        return 1
    fi

    cluster_name=$(yq ' .metadata.cluster ' "$config_file")
    region=$(yq ' .metadata.region ' "$config_file")



    echo "📋 Fetching nodegroups for cluster '$cluster_name' in region '$region'..."
    eksctl get nodegroup --cluster "$cluster_name" --region "$region" -o json | jq -r '.[].Name'

}

apply-node-groups(){

    # Usage: ./apply-nodegroups.sh -f <config_file>
    # Example: ./apply-nodegroups.sh -f eks-cluster.yaml

    CONFIG_FILE=""

    # Parse arguments
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -f|--config-file)
            CONFIG_FILE="${CONFIG_DIR}/${2}"
            shift 2
            ;;
            *)
            echo "Unknown parameter: $1"
            echo "Usage: $0 -f <config_file>"
            exit 1
            ;;
        esac
    done

    if [ -z "$CONFIG_FILE" ]; then
        echo "Error: config file not specified."
        echo "Usage: $0 -f <config_file>"
        exit 1
    fi

    # Extract cluster name from config
    CLUSTER_NAME=$(yq e '.metadata.name' "$CONFIG_FILE")
    REGION=$(yq e '.metadata.region' "$CONFIG_FILE")

    if [ -z "$CLUSTER_NAME" ] || [ "$CLUSTER_NAME" = "null" ]; then
        echo "Error: Could not find cluster name in $CONFIG_FILE"
        exit 1
    fi

    echo "Cluster: $CLUSTER_NAME"
    echo "Region: ${REGION:-default}"

    # Get desired nodegroups from config
    DESIRED_NODEGROUPS=$(yq e '.nodeGroups[].name' "$CONFIG_FILE" | tr '\n' ' ')

    # Get existing nodegroups from cluster
    EXISTING_NODEGROUPS=$(eksctl get nodegroup --cluster "$CLUSTER_NAME" -o json | jq -r '.[].Name' | tr '\n' ' ')

    echo "Existing nodegroups: $EXISTING_NODEGROUPS"
    echo "Desired nodegroups:  $DESIRED_NODEGROUPS"

    # Find nodegroups to delete
    for NODEGROUP in $EXISTING_NODEGROUPS; do
        echo "$DESIRED_NODEGROUPS" | grep -qw "$NODEGROUP" || {
            echo "Deleting obsolete nodegroup: $NODEGROUP"
            eksctl delete nodegroup --cluster "$CLUSTER_NAME" --name "$NODEGROUP" --region "$REGION" --wait
        }
    done

    # Apply desired nodegroups (adds new or modifies existing)
    for NODEGROUP in $DESIRED_NODEGROUPS; do
        echo "Applying nodegroup: $NODEGROUP"
        NODEGROUP_EXITS=$(echo "$DESIRED_NODEGROUPS" | grep -qw "$NODEGROUP")
        if [ -z "$NODEGROUP_EXITS" ]; then
            eksctl create nodegroup -f "$CONFIG_FILE" --include "$NODEGROUP" --region "$REGION" --approve --wait
        else
            eksctl update nodegroup -f "$CONFIG_FILE" --include "$NODEGROUP" --region "$REGION" --approve --wait
        fi
    done

    echo "✅ Nodegroup synchronization complete for cluster '$CLUSTER_NAME'"

}

apply-extra-addons(){

    CONFIG_FILE=""

    # Parse arguments
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -f|--config-file)
            CONFIG_FILE="${CONFIG_DIR}/${2}"
            shift 2
            ;;
            *)
            echo "Unknown parameter: $1"
            echo "Usage: $0 -f <config_file>"
            exit 1
            ;;
        esac
    done

    if [ -z "$CONFIG_FILE" ]; then
        echo "Error: config file not specified."
        echo "Usage: $0 -f <config_file>"
        exit 1
    fi

    addonhelpers="/app/cluster-addon-helper.sh"

    CLUSTER_NAME=$(yq e '.metadata.name' "$CONFIG_FILE")
    REGION=$(yq e '.metadata.region' "$CONFIG_FILE")

    set_kubeconfig "$CLUSTER_NAME" "$REGION"

    addons=$(yq ' .extraAddons[].name ' "$CONFIG_FILE")

    alladdons="aws-lb-controller cluster-autoscaler monitoring kube-watch"

    for addon in $alladdons; do
        
        addon_exists=$(echo "$addons" | grep -wq "$addon")

        if [ -z "$addon_exists" ]; then

            if [ "$addon"="aws-lb-controller" ]; then
                sh "$addonhelpers" delete_lb_controller "$CONFIG_FILE"
            fi

            if [ "$addon"="cluster-autoscaler" ]; then
                sh "$addonhelpers" uninstall_autoscaler "$CONFIG_FILE"
            fi

            if [ "$addon"="kube-watch" ]; then
                sh "$addonhelpers" uninstall_kubewatch "$CONFIG_FILE"
            fi

            if [ "$addon"="monitoring" ]; then
                sh "$addonhelpers" uninstall_kube_prometheus
            fi

        else

            if [ "$addon"="aws-lb-controller" ]; then
                sh "$addonhelpers" install_lb_controller "$CONFIG_FILE"
            fi

            if [ "$addon"="cluster-autoscaler" ]; then
                sh "$addonhelpers" install_autoscaler "$CONFIG_FILE"
            fi

            if [ "$addon"="kube-watch" ]; then
                sh "$addonhelpers" install_kubewatch "$CONFIG_FILE"
            fi

            if [ "$addon"="monitoring" ]; then
                sh "$addonhelpers" install_kube_prometheus
            fi

        fi
    done

}

get-services(){

    config_file=""
    namespace=""

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -f)
                config_file="${CONFIG_DIR}/${2}"
                shift 2
                ;;
            -n)
                namespace="$2"
                shift 2
                ;;
            *)
                echo "Unknown option: $1"
                exit 1
                ;;
        esac
    done

    cluster=$(yq " .metadata.cluster " "$config_file")
    region=$(yq " .metadata.region " "$config_file")

    set_kubeconfig "$cluster" "$region"

    kubectl get svc -n "$namespace"

}

delete-service(){

    config_file=""
    namespace=""
    service=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -f)
                config_file="${CONFIG_DIR}/${2}"
                shift 2
                ;;
            -n)
                namespace="$2"
                shift 2
                ;;
            -s)
                service="$2"
                shift 2
               ;;
            *)
                echo "Unknown option: $1"
                exit 1
                ;;
        esac
    done

    cluster=$(yq " .metadata.cluster " "$config_file")
    region=$(yq " .metadata.region " "$config_file")

    set_kubeconfig "$cluster" "$region"

    helm uninstall "${service}-${namespace}" --namespace "$namespace"

    kubectl delete configmap "${service}-${namespace}-envs" --namespace "$namespace"

    echo "service $service deleted !!!"

}

apply-service(){


    config_file=""
    namespace=""
    service=""
    DRY_RUN="false"

    BUILD_CMD="/app/build-and-push.sh"

    COMMIT_ENVS_CMD="/app/commit-env.sh"

    MODIFY_VAL_CMD="/app/modify-val.sh"

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -f)
                config_file="${CONFIG_DIR}/${2}"
                shift 2
                ;;
            -n)
                namespace="$2"
                shift 2
                ;;
            -s)
                service="$2"
                shift 2
                ;;
            --dry-run)
                if [ -n "$2" && "$2" != -*  ]; then
                    DRY_RUN="$2"
                else
                    DRY_RUN="true"
                fi
                ;;
            *)
                echo "Unknown option: $1"
                exit 1
                ;;
        esac
    done

    echo "Config file: $config_file"
    echo "Name: $namespace"
    echo "Service: $service"

    cluster=$(yq " .metadata.cluster " "$config_file")
    region=$(yq " .metadata.region " "$config_file")

    set_kubeconfig "$cluster" "$region"

    sh "$BUILD_CMD" "$config_file" "$service" "$namespace"
    sh "$COMMIT_ENVS_CMD" "$config_file" "$service" "$namespace"
    sh "$MODIFY_VAL_CMD" "$config_file" "$service" "$namespace"

    if [ "$DRY_RUN" = "false" ]; then
        helm upgrade --install "${service}-${namespace}" /helm/cluster-services/cluster-service -n "$namespace" -f "/helm/cluster-services/cluster-service/values.yaml"
    fi

    if [ "$DRY_RUN" = "true" ]; then
        helm upgrade --install "${service}-${namespace}" /helm/cluster-services/cluster-service -n "$namespace" -f "/helm/cluster-services/cluster-service/values.yaml" --dry-run
    fi



    # Print parsed values


}

klogs(){

    config_file=""
    namespace=""
    service=""
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -f)
                config_file="${CONFIG_DIR}/${2}"
                shift 2
                ;;
            -n)
                namespace="$2"
                shift 2
                ;;
            -s)
                service="$2"
                shift 2
                ;;
            *)
                echo "Unknown option: $1"
                exit 1
                ;;
        esac
    done

    echo "Config file: $config_file"
    echo "Name: $namespace"
    echo "Service: $service"

    cluster=$(yq " .metadata.cluster " "$config_file")
    region=$(yq " .metadata.region " "$config_file")

    set_kubeconfig "$cluster" "$region"

    deployment_name="${service}-${namespace}"

    kubectl logs -l "app.kubernetes.io/instance=$deployment_name" --all-containers=true --prefix=true

}

get-monitoring(){

    config_file=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -f)
                
                config_file="${CONFIG_DIR}/${2}"
                shift 2
                ;;
            *)
                echo "Unknown option: $1"
                exit 1
                ;;
        esac
    done


    if [ ! - f "${config_file}" ]; then

        echo "Error : Usage create-cluster -f <config_file> --dry-run true/false"


    fi


    kind=$(yq "" "$config_file")
    cluster=$(yq " .metadata.cluster " "$config_file")

    region=$(yq " .metadata.region " "$config_file")

    set_kubeconfig "$cluster" "$region"

    NAMESPACE="monitoring"
    RELEASE_NAME="kube-prometheus"

    kubectl port-forward -n "$NAMESPACE" "svc/${RELEASE_NAME}-grafana" 3000:3000

}

get-shell(){

    config_file=""
    namespace=""
    service=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -f)
                config_file="${CONFIG_DIR}/${2}"
                shift 2
                ;;
            -n)
                namespace="$2"
                shift 2
                ;;
            -s)
                service="$2"
                shift 2
                ;;
            *)
                echo "Unknown option: $1"
                exit 1
                ;;
        esac
    done

    echo "Config file: $config_file"
    echo "Name: $namespace"
    echo "Service: $service"

    cluster=$(yq " .metadata.cluster " "$config_file")
    region=$(yq " .metadata.region " "$config_file")

    set_kubeconfig "$cluster" "$region"

    PODS=$(kubectl get pods -n "$namespace" -l "app.kubernetes.io/instance=${service}-${namespace}" -o name)

    if [ -z "$PODS" ]; then
        echo "⚠️  No pods found for service $service in namespace $namespace"
        exit 0
    fi

    POD=$(echo "$PODS" | awk 'NF' | head -n1)

    if kubectl -n "$namespace" exec "$POD" -- bash -c 'command -v bash >/dev/null 2>&1' >/dev/null 2>&1; then
        SHELL_CMD="bash"
    else $KUBECTL -n "$namespace" exec "$POD" -- sh -c 'command -v sh >/dev/null 2>&1' >/dev/null 2>&1; then
        SHELL_CMD="sh"
    fi

    echo "Opening interactive shell ($SHELL_CMD) in pod $POD ..."

    kubectl -n "$namespace" exec -it "$POD" -- $SHELL_CMD

}




run_func() {


    echo "$@"

    if [ $# -lt 1 ]; then
        echo "Usage: call_func <function_name> [args...]"
        return 1
    fi

    func_name="$1"
    shift  # remove the first argument (function name)

    # Check if the function exists
    if ! declare -f "$func_name" >/dev/null; then
        echo "Error: function '$func_name' not found"
        return 1
    fi

    # Call the function with the rest of the arguments
    "$func_name" "$@"
}



run_func "$@"