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

    helm uninstall "${name}-${namespace}" --namespace "$namespace"

    kubectl delete configmap "${name}-${namespace}" --namespace "$namespace"

    echo "service $name deleted !!!"

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
        helm upgrade --install "${service}-${namespace}" /root/config/cluster-services/cluster-service -n "$namespace" -f "/root/config/cluster-services/cluster-service/values.yaml"
    fi

    if [ "$DRY_RUN" = "true" ]; then
        helm upgrade --install "${service}-${namespace}" /root/config/cluster-services/cluster-service -n "$namespace" -f "/root/config/cluster-services/cluster-service/values.yaml" --dry-run
    fi



    # Print parsed value



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