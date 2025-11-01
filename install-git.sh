#!/bin/bash

set -eou pipefail

config_file="$1"

GIT_USERNAME=$(yq " .metadata.git.username " "$config_file")
GIT_EMAIL=$(yq " .metadata.git.email " "$config_file")
KEY_NAME=$(yq " .metadata.git.key_path " "$config_file")

echo "Configuring username to $GIT_USERNAME"

echo "Configuring email to $GIT_EMAIL"

echo "Configuring ssh key to $KEY_NAME"

SSH_DIR="$HOME/.ssh"
CONFIG_DIR="/root/config"

mkdir -p "$SSH_DIR"

if [[ ! -f "${CONFIG_DIR}/${KEY_NAME}" ]]; then

    echo "Git key file not found ..."
    exit 1

fi

echo "Copying key ${KEY_NAME} to ${HOME}/.ssh/id_rsa"
cat "${CONFIG_DIR}/${KEY_NAME}" > "$HOME/.ssh/id_rsa"

chmod 600 "$HOME/.ssh/id_rsa"
chmod 700 "$HOME/.ssh"

KNOWN_HOSTS="$SSH_DIR/known_hosts"

echo "Adding github host to known hosts"

knwh=$(ssh-keyscan github.com)



if [ -z "$knwh" ]; then
    echo "Failed generating host verfication keys exiting"
    exit 1
else
    echo "$knwh" >> "$KNOWN_HOSTS"
fi

echo "Changing the host permission to ${KNOWN_HOSTS}"
chmod 644 "$KNOWN_HOSTS"

