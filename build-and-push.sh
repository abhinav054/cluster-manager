#!/bin/bash

set -euo pipefail

config_file="$1"

name="$2"

namespace="$3"

cluster=$(yq " .metadata.cluster " "$config_file")

# --- CONFIG ---
AWS_REGION=$(yq " .metadata.region " "$config_file")   # Default region if not provided

ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
ECR_REGISTRY="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

REPO_NAME="${name}-${namespace}-${cluster}"                      # Pass repo name as first argument
DOCKER_CONFIG_PATH="${HOME}/.docker/config.json"

CONFIG_DIR="/app/config"

local dockerfiles_dir="/dockerfiles"

local repo_url=$(name_y=$name namespace_y=$namespace yq " .namespaces[] | select( .name == strenv(namespace_y) ) | .services[] | select( .name == strenv(name_y)) | .repo "  "$config_file")
local commit=$(name_y=$name namespace_y=$namespace yq " .namespaces[] | select( .name == strenv(namespace_y) ) | .services[] | select( .name == strenv(name_y)) | .type "  "$config_file")            # commit hash or "latest"
local container_type=$(name_y=$name namespace_y=$namespace yq " .namespaces[] | select( .name == strenv(namespace_y) ) | .services[] | select( .name == strenv(name_y)) | .container "  "$config_file")    # docker | python | javascript
local build_cmd=$(name_y=$name namespace_y=$namespace yq " .namespaces[] | select( .name == strenv(namespace_y) ) | .services[] | select( .name == strenv(name_y)) | .buildCmd "  "$config_file")         # optional
local run_cmd=$(name_y=$name namespace_y=$namespace yq " .namespaces[] | select( .name == strenv(namespace_y) ) | .services[] | select( .name == strenv(name_y)) | .cmd "  "$config_file")           # optional
# path where python/js Dockerfiles are stored

# --- GET ECR CREDENTIALS ---


echo "Fetching ECR password..."
PASSWORD=$(aws ecr get-login-password --region "$AWS_REGION")

# --- CREATE DOCKER CONFIG MANUALLY ---
echo "Creating Docker config for ECR at ${DOCKER_CONFIG_PATH}..."

mkdir -p "$(dirname "$DOCKER_CONFIG_PATH")"

# Generate base64 encoded credentials
AUTH=$(echo -n "AWS:${PASSWORD}" | base64 | tr -d '\n')

# Create JSON config manually
cat > "$DOCKER_CONFIG_PATH" <<EOF
{
  "auths": {
    "${ECR_REGISTRY}": {
      "auth": "${AUTH}"
    }
  }
}
EOF

chmod 600 "$DOCKER_CONFIG_PATH"

# --- CHECK AND CREATE REPO ---
echo "Checking if ECR repository '$REPO_NAME' exists in region '$AWS_REGION'..."

REPO_URI=$(aws ecr describe-repositories \
    --repository-names "$REPO_NAME" \
    --region "$AWS_REGION" \
    --query "repositories[0].repositoryUri" \
    --output text 2>/dev/null || true)

if [[ "$REPO_URI" == "None" || -z "$REPO_URI" ]]; then
    echo "Repository does not exist. Creating..."
    aws ecr create-repository \
        --repository-name "$REPO_NAME" \
        --region "$AWS_REGION" \
        --query "repository.repositoryUri" \
        --output text
else
    echo "Repository already exists: $REPO_URI"
fi


echo "✅ Docker config created successfully at $DOCKER_CONFIG_PATH"
echo "You can now push to ${ECR_REGISTRY}/${REPO_NAME}"


tmp_dir="/repo/${name}"

mkdir -p "$tmp_dir"

echo "=== Cloning repository: $repo_url ==="
git clone "$repo_url" "$tmp_dir" || {
    echo "❌ Failed to clone repository"
    return 1
}

cd "$tmp_dir" || exit 1

if [[ "$commit" == "latest" ]]; then
    commit=$(git rev-parse HEAD)
    echo "Using latest commit: $commit"
else
    echo "Checking out commit: $commit"
    git checkout "$commit" || {
        echo "❌ Failed to checkout commit"
        return 1
    }
fi

# Select Dockerfile based on container type
case "$container_type" in
    docker)
        dockerfile_path="$tmp_dir/Dockerfile"
        if [[ ! -f "$dockerfile_path" ]]; then
            echo "❌ Dockerfile not found in repo root"
            return 1
        fi
        ;;
    python|javascript)
        dockerfile_path="$tmp_dir/Dockerfile"
        src_dockerfile="$dockerfiles_dir/Dockerfile.$container_type"
        if [[ ! -f "$src_dockerfile" ]]; then
            echo "❌ Dockerfile for $container_type not found in $dockerfiles_dir"
            return 1
        fi
        cp "$src_dockerfile" "$dockerfile_path"
        ;;
    *)
        echo "❌ Invalid container type: $container_type"
        return 1
        ;;
esac

# Add optional build and run commands
if [[ -n "$build_cmd" ]]; then
    echo "RUN $build_cmd" >> "$dockerfile_path"
fi
if [[ -n "$run_cmd" ]]; then
    echo "CMD [\"/bin/sh\", \"-c\", \"$run_cmd\"]" >> "$dockerfile_path"
fi

echo "=== Dockerfile ready ==="
cat "$dockerfile_path"

# Run Kaniko build
echo "=== Building image with Kaniko ==="
/kaniko/executor \
    --context "$tmp_dir" \
    --dockerfile "$dockerfile_path" \
    --destination "$image_name" \
    --snapshotMode=redo \
    --verbosity=info

echo "✅ Build complete: $image_name"
