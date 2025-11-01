#!/bin/bash

set -euo pipefail

config_file="$1"

name="$2"

namespace="$3"

values_file="/root/config/cluster-services/cluster-service/values.yaml"

cluster_name=$(yq " .metadata.cluster " "$config_file")

AWS_REGION=$(yq ' .metadata.region ' "$config_file")   # default region if not set
SECRET_NAME="${SECRET_NAME:-ecr-pull-secret}"

# === GET ACCOUNT ID & LOGIN SERVER ===
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_SERVER="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"


echo "Using AWS Account: ${ACCOUNT_ID}"
echo "Region: ${AWS_REGION}"
echo "Namespace: ${namespace}"

# === GET DOCKER LOGIN PASSWORD ===
echo "Fetching ECR credentials..."
PASSWORD=$(aws ecr get-login-password --region "${AWS_REGION}")


# === CREATE SECRET ===
echo "Creating Kubernetes secret: ${SECRET_NAME}"
kubectl create secret docker-registry "${SECRET_NAME}" \
  --docker-server="${ECR_SERVER}" \
  --docker-username="AWS" \
  --docker-password="${PASSWORD}" \
  --namespace "${namespace}" --dry-run=client -o yaml | kubectl apply -f -

echo "✅ ECR pull secret '${SECRET_NAME}' cSECRET_NAME_yreated successfully in namespace '${namespace}'."

# === OPTIONAL: PATCH DEFAULT SERVICE ACCOUNT ===
# Uncomment below if you want all pods in this namespace to use the secret automatically.
# kubectl patch serviceaccount default -n "${NAMESPACE}" \
#   -p "{\"imagePullSecrets\": [{\"name\": \"${SECRET_NAME}\"}]}"

type=$(name_y=$name namespace_y=$namespace yq " .namespaces[] | select( .name == strenv(namespace_y) ) | .services[] | select( .name == strenv(name_y)) | .type "  "$config_file")

mem_requests=$(name_y=$name namespace_y=$namespace yq " .namespaces[] | select( .name == strenv(namespace_y)) | .services[] | select( .name == strenv(name_y)) | .mem_requests " "$config_file")

mem_requests_y=$mem_requests yq -i ' .resources.requests.memory=strenv(mem_requests_y) ' "$values_file"

mem_limits=$(name_y=$name namespace_y=$namespace yq " .namespaces[] | select( .name == strenv(namespace_y)) | .services[] | select( .name == strenv(name_y)) | .mem_limits " "$config_file")

mem_limits_y=$mem_limits yq -i ' .resources.limits.memory=strenv(mem_limits_y) ' "$values_file"

cpu_requests=$(name_y=$name namespace_y=$namespace yq " .namespaces[] | select( .name == strenv(namespace_y)) | .services[] | select( .name == strenv(name_y)) | .cpu_requests " "$config_file")

cpu_requests_y=$cpu_requests yq -i ' .resources.requests.cpu=strenv(cpu_requests_y) ' "$values_file"

cpu_limits=$(name_y=$name namespace_y=$namespace yq " .namespaces[] | select( .name == strenv(namespace_y)) | .services[] | select( .name == strenv(name_y)) | .cpu_limits " "$config_file")

cpu_limits_y=$cpu_limits yq -i ' .resources.limits.cpu=strenv(cpu_limits_y) ' "$values_file"

pod_limits=$(name_y=$name namespace_y=$namespace yq " .namespaces[] | select( .name == strenv(namespace_y)) | .services[] | select( .name == strenv(name_y)) | .pod_limits " "$config_file")

pod_limits_y=$pod_limits yq -i ' .autoscaling.minReplicas=strenv(pod_limits_y) ' "$values_file"

pod_requests=$(name_y=$name namespace_y=$namespace yq " .namespaces[] | select( .name == strenv(namespace_y)) | .services[] | select( .name == strenv(name_y)) | .pod_requests " "$config_file")

pod_requests_y=$pod_limits yq -i ' .autoscaling.maxReplicas=strenv(pod_requests_y) ' "$values_file"

public_lb=$(name_y=$name namespace_y=$namespace yq " .namespaces[] | select( .name == strenv(namespace_y)) | .services[] | select( .name == strenv(name_y)) | .public_lb " "$config_file")

service_type="ClusterIP"

if [ "$public_lb" = true ]; then

    service_type="LoadBalancer"
    sourceRanges=$(name_y=$name namespace_y=$namespace yq " .namespaces[] | select( .name == strenv(namespace_y)) | .services[] | select( .name == strenv(name_y)) | .sourceRanges " "$config_file")
    
    if [ -n "$sourceRanges" ]; then
        newsourceranges=""
        for sourceRange in $sourceRanges; do
            if [ -z "$newsourceranges" ]; then
                newsourceranges=$sourceRange
            else
                newsourceranges="$newsourceranges,$sourceRange"
            fi
        done
        sourceRanges_y=$newsourceranges yq -i " .service.sourceRanges=strenv(sourceRanges_y) " "$values_file"
    fi
    

    echo "Getting subnets for cluster $cluster_name";
    # 1. Get the VPC ID of the EKS cluster
    VPC_ID=$(aws eks describe-cluster \
    --name $cluster_name \
    --query "cluster.resourcesVpcConfig.vpcId" \
    --output text)

    # 2. Get all subnet IDs for the cluster
    SUBNET_IDS=$(aws eks describe-cluster \
    --name $cluster_name \
    --query "cluster.resourcesVpcConfig.subnetIds[]" \
    --output text)


    subnets=""
    # 3. Filter public subnets (those with a route to an Internet Gateway)
    for subnet in $SUBNET_IDS; do
        RT_ID=$(aws ec2 describe-route-tables \
            --filters "Name=association.subnet-id,Values=$subnet" \
            --query "RouteTables[].RouteTableId" \
            --output text)
        
        HAS_IGW=$(aws ec2 describe-route-tables \
            --route-table-ids $RT_ID \
            --query "RouteTables[].Routes[].GatewayId" \
            --output text | grep igw- || true)

        if [ -n "$HAS_IGW" ]; then
            if [ -z "$subnets" ]; then
                subnets="$subnet"
            else
                subnets="$subnets,$subnet"
            fi
        fi
    done

    subnets_y=$subnets yq -i " .service.subnets=strenv(subnets_y) " "$values_file"

fi

servicePort=$(name_y=$name namespace_y=$namespace yq " .namespaces[] | select( .name == strenv(namespace_y)) | .services[] | select( .name == strenv(name_y)) | .servicePort " "$config_file")

servicePort_y=$servicePort yq -i " .service.port=strenv(servicePort_y) " "$values_file"

exposePort=$(name_y=$name namespace_y=$namespace yq " .namespaces[] | select( .name == strenv(namespace_y)) | .services[] | select( .name == strenv(name_y)) | .exposePort " "$config_file")

servicePort_y=$servicePort yq -i " .service.targetPort=strenv(servicePort_y) " "$values_file"

service_type_y=$service_type yq -i " .service.type=strenv(service_type_y) " "$values_file"

# # set liveness port
# servicePort_y=$servicePort yq -i " .livenessProbe.httpGet.port=strenv(servicePort_y) " "$values_file"

# # set readiness port
# servicePort_y=$servicePort yq -i " .readinessProbe.httpGet.port=strenv(servicePort_y) " "$values_file"

# set envconfimap
configmap_name="${name}-${namespace}-envs" yq -i " .envConfigMap=strenv(configmap_name) " "$values_file"

HASH=$(kubectl get configmap "${name}-${namespace}-envs" -n "$namespace" -o jsonpath='{.data}' | sha256sum | awk '{print $1}')

tmp_dir="/repo/${name}"

cd "$tmp_dir"

COMMIT=$(git rev-parse HEAD)

deployment_hash="${COMMIT}-${HASH}" yq -i " .deploymentHash=strenv(deployment_hash) " "$values_file"

SECRET_NAME_y=$SECRET_NAME yq -i " .imagePullSecrets=strenv(SECRET_NAME_y) " "$values_file"

image="${ECR_SERVER}/${name}-${namespace}-${cluster_name}:${COMMIT}" yq -i " .image.repository=strenv(image) " "$values_file"


# things to set
# resources
# hpa
# servicetype
# service ports
# health check ports
# envconfigmap
# deployment hash
# image
# image pull secrets

