#!/bin/bash

set -eou pipefail

GIT_USERNAME="${1:-}"
GIT_EMAIL="${2:-}"
KEY_NAME="${3:-}"

SSH_DIR="$HOME/.ssh"
CONFIG_DIR="/root/config"

cat "${CONFIG_DIR}/${KEY_NAME}" > "$HOME/.ssh/id_rsa"

chmod 600 "$HOME/.ssh/id_rsa"
chmod 700 "$HOME/.ssh"
KNOWN_HOSTS="$SSH_DIR/known_hosts"

ssh-keyscan github.com >> "$KNOWN_HOSTS" 2>/dev/null

chmod 644 "$KNOWN_HOSTS"

