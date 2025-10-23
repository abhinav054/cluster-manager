#!/bin/bash
set -eou pipefail

# Usage: ./merge-env-to-configmap.sh <yaml_file> <configmap_name> <namespace>
# Example: ./merge-env-to-configmap.sh config.yaml my-configmap default

yaml_file="$1"
configmap_name="$2"
namespace="$3"

if [[ -z "$yaml_file" || -z "$configmap_name" || -z "$namespace" ]]; then
  echo "Usage: $0 <yaml_file> <configmap_name> <namespace>"
  exit 1
fi

if ! command -v yq >/dev/null 2>&1; then
  echo "Error: yq not installed"
  exit 1
fi

tmp_env="/tmp/merged_env_$$.env"
> "$tmp_env"

echo "Extracting env files from $yaml_file..."
env_files=$(yq -r '.envFiles[]?' "$yaml_file")

if [[ -z "$env_files" ]]; then
  echo "No env files found in YAML."
  exit 1
fi

echo "Merging environment variables..."
for f in $env_files; do
  if [[ ! -f "$f" ]]; then
    echo "Warning: env file $f not found, skipping..."
    continue
  fi
  echo "# From $f" >> "$tmp_env"
  cat "$f" >> "$tmp_env"
  echo "" >> "$tmp_env"
done

# # Remove comments and blank lines, handle duplicates (last one wins)
# merged_env="/tmp/final_env_$$.env"
# grep -v '^[[:space:]]*#' "$tmp_env" | grep -v '^[[:space:]]*$' | awk -F= '!seen[$1]++' > "$merged_env"

echo "Creating/Updating ConfigMap '$configmap_name' in namespace '$namespace'..."
kubectl create configmap "$configmap_name" \
  --from-env-file="$merged_env" \
  -n "$namespace" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "✅ ConfigMap '$configmap_name' updated successfully."

# Cleanup
rm -f "$tmp_env" "$merged_env"
