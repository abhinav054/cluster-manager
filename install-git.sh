#!/bin/bash

set -eou pipefail


config_file="$1"

GIT_USERNAME=$(yq " .metadata.git.username " "$config_file")
GIT_EMAIL=$(yq " .metadata.git.email " "$config_file")
KEY_NAME=$(yq " .metadata.git.key_path " "$config_file")

SSH_DIR="$HOME/.ssh"
CONFIG_DIR="/root/config"

mkdir -p "$SSH_DIR"

if [[ ! -f "${CONFIG_DIR}/${KEY_NAME}" ]]; then

    echo "Git key file not found ..."
    exit 1

fi

cat "${CONFIG_DIR}/${KEY_NAME}" > "$HOME/.ssh/id_rsa"

chmod 600 "$HOME/.ssh/id_rsa"
chmod 700 "$HOME/.ssh"
KNOWN_HOSTS="$SSH_DIR/known_hosts"

ssh-keyscan github.com >> "$KNOWN_HOSTS" 2>/dev/null

chmod 644 "$KNOWN_HOSTS"

