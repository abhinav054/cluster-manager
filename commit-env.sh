#!/bin/bash
set -eou pipefail

# Usage: ./merge-env-to-configmap.sh <config_file> <configmap_name> <namespace>
# Example: ./merge-env-to-configmap.sh config.yaml my-configmap default

echo "starting to commit envs"

CONFIG_DIR="/root/config"

config_file="$1"
name="$2"
namespace="$3"
MODE="${4:-}"


if ! command -v yq >/dev/null 2>&1; then
  echo "Error: yq not installed"
  exit 1
fi

tmp_env="/tmp/merged_env_$$.env"
> "$tmp_env"

echo "Extracting env files from $config_file..."
env_files=$(name_y=$name namespace_y=$namespace yq " .namespaces[] | select( .name == strenv(namespace_y) ) | .services[] | select( .name == strenv(name_y)) | .envs "  "$config_file")

env_files=$(echo "$env_files" | tr ',' ' ')

if [ -z "$env_files" ]; then
  echo "No env files found in YAML."
  exit 1
else
  echo "Env files found $env_files"
fi

params="--from-literal=test__cm=true"

# --- Read all env files ---
for ENV_FILE in "$env_files"; do
  
  if [ ! -f "${CONFIG_DIR}/${ENV_FILE}" ]; then
    echo "⚠️  Skipping missing file: $ENV_FILE" >&2
    continue
  fi

  while IFS='=' read -r key value; do
    
    if [ -z "$key" ] && [ -z "$value" ]; then
        continue
    fi

    key=$(echo "$key" | xargs)
    value=$(echo "$value" | xargs)
    if echo "$value" | grep -Eq '^\{\{([a-zA-Z0-9_-]+)\}\}\.\{\{([a-zA-Z0-9_-]+)\}\}\:([0-9]+)$'; then
        value=$(echo "$value" | sed -E 's/^\{\{([a-zA-Z0-9_-]+)\}\}\.\{\{([a-zA-Z0-9_-]+)\}\}\:([0-9]+)$/\1.\2.svc.cluster.local:\3/')
    fi
    # data["$key"]="$value"
    escaped_key=$(printf '%s' "$key" | sed 's/[.[\*^$]/\\&/g')
    escaped_value=$(printf '%s' "$value" | sed 's/[&/\]/\\&/g')

    # Check if key exists
    if echo "$params" | grep -q -- "--from-literal=${escaped_key}="; then
        # Replace the value for the existing key
        value=$(echo "$params" | sed -E "s/(--from-literal=${escaped_key}=)[^,]*/\1${escaped_value}/")
    else

    echo "$key" "$value"
    # Append new key-value pair
    if [ -n "$params" ]; then
        params="${params} --from-literal=${key}=${value}"
    else
        params="--from-literal=${key}=${value}"
    fi
    fi
  done < "${CONFIG_DIR}/${ENV_FILE}"
done

CONFIGMAP_NAME="${name}-${namespace}-envs"

# --- Build kubectl command ---
# cmd="kubectl create configmap ${CONFIGMAP_NAME} ${params}"

# --- Execute ---
if [ "$MODE" = "--dry-run" ]; then
  kubectl create configmap "${CONFIGMAP_NAME}" -n "${namespace}" "${params}" --dry-run=client -o yaml
else
  echo "Creating ConfigMap '${CONFIGMAP_NAME}' from files: $env_files"
  kubectl create configmap "${CONFIGMAP_NAME}" -n "${namespace}" "${params}" --dry-run=client -o yaml | kubectl apply -f -
  echo "✅ ConfigMap '${CONFIGMAP_NAME}' created successfully."
fi




# echo "Merging environment variables..."
# for f in $env_files; do
#   if [ ! -f "${CONFIG_DIR}/${f}" ]; then
#     echo "Warning: env file $f not found, skipping..."
#     continue
#   fi
#   echo "# From $f" >> "$tmp_env"
#   cat "${CONFIG_DIR}/${f}" >> "$tmp_env"
#   echo "" >> "$tmp_env"
# done

# # # Remove comments and blank lines, handle duplicates (last one wins)
# # merged_env="/tmp/final_env_$$.env"
# # grep -v '^[[:space:]]*#' "$tmp_env" | grep -v '^[[:space:]]*$' | awk -F= '!seen[$1]++' > "$merged_env"

# echo "Creating/Updating ConfigMap '${name}-${namespace}' in namespace '$namespace'..."
# kubectl create configmap "${name}-${namespace}" \
#   --from-env-file="$tmp_env" \
#   -n "$namespace" \
#   --dry-run=client -o yaml | kubectl apply -f -

# echo "✅ ConfigMap '${name}-${namespace}' updated successfully."

# # Cleanup
# rm -f "$tmp_env"
