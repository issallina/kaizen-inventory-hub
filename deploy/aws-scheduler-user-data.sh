#!/bin/bash

set -euo pipefail

exec > >(
  tee /var/log/kaizen-inventory-bootstrap.log |
  logger -t kaizen-inventory-user-data -s 2>/dev/console
) 2>&1

APP_DIR="/opt/kaizen-inventory-hub"
REPO_URL="https://github.com/YOUR_GITHUB_USERNAME/kaizen-inventory-hub.git"
GIT_BRANCH="main"

export DEBIAN_FRONTEND=noninteractive

apt-get update

apt-get install -y \
  python3 \
  python3-venv \
  python3-pip \
  git \
  curl \
  unzip

rm -rf "${APP_DIR}"

git clone \
  --branch "${GIT_BRANCH}" \
  --depth 1 \
  "${REPO_URL}" \
  "${APP_DIR}"

NODE_ROLE="scheduler" \
AWS_REGION="us-east-1" \
SECRET_ID="kaizen-inventory/production" \
"${APP_DIR}/deploy/bootstrap-node.sh"