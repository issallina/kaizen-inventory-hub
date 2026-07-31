#!/bin/bash

set -euo pipefail

NODE_ROLE="${NODE_ROLE:?NODE_ROLE must be web or scheduler}"
AWS_REGION="${AWS_REGION:-us-east-1}"
SECRET_ID="${SECRET_ID:-kaizen-inventory/production}"

APP_USER="inventory"
APP_GROUP="inventory"
APP_DIR="/opt/kaizen-inventory-hub"
ENV_DIR="/etc/kaizen-inventory-hub"
ENV_FILE="${ENV_DIR}/inventory.env"

case "${NODE_ROLE}" in
  web|scheduler)
    ;;
  *)
    echo "Unsupported NODE_ROLE=${NODE_ROLE}"
    exit 1
    ;;
esac

ARCH="$(uname -m)"

case "${ARCH}" in
  x86_64)
    AWSCLI_ARCH="x86_64"
    ;;
  aarch64|arm64)
    AWSCLI_ARCH="aarch64"
    ;;
  *)
    echo "Unsupported architecture: ${ARCH}"
    exit 1
    ;;
esac

rm -rf /tmp/aws /tmp/awscliv2.zip

curl \
  --fail \
  --silent \
  --show-error \
  --location \
  "https://awscli.amazonaws.com/awscli-exe-linux-${AWSCLI_ARCH}.zip" \
  --output /tmp/awscliv2.zip

unzip -q /tmp/awscliv2.zip -d /tmp
/tmp/aws/install --update

rm -rf /tmp/aws /tmp/awscliv2.zip

if ! getent group "${APP_GROUP}" >/dev/null; then
  groupadd --system "${APP_GROUP}"
fi

if ! id "${APP_USER}" >/dev/null 2>&1; then
  useradd \
    --system \
    --gid "${APP_GROUP}" \
    --home-dir "${APP_DIR}" \
    --shell /usr/sbin/nologin \
    "${APP_USER}"
fi

python3 -m venv "${APP_DIR}/.venv"

"${APP_DIR}/.venv/bin/python" \
  -m pip install --upgrade pip

"${APP_DIR}/.venv/bin/python" \
  -m pip install \
  -r "${APP_DIR}/requirements.txt"

install \
  -d \
  -m 0750 \
  -o root \
  -g "${APP_GROUP}" \
  "${ENV_DIR}"

SECRET_JSON="$(
  aws secretsmanager get-secret-value \
    --secret-id "${SECRET_ID}" \
    --region "${AWS_REGION}" \
    --query SecretString \
    --output text
)"

export SECRET_JSON
export ENV_FILE

python3 <<'PYTHON'
import json
import os
import shlex
from pathlib import Path

keys = [
    "APP_NAME",
    "APP_ENV",
    "APP_VERSION",
    "SECRET_KEY",
    "HOST",
    "PORT",
    "LOG_LEVEL",
    "DATABASE_URL",
    "ALERT_BACKEND",
    "SNS_TOPIC_ARN",
    "AWS_REGION",
    "LOW_STOCK_COOLDOWN_MINUTES",
    "METRICS_ENABLED",
    "WEB_CONCURRENCY",
]

secret = json.loads(os.environ["SECRET_JSON"])

missing = [
    key
    for key in keys
    if str(secret.get(key, "")).strip() == ""
]

if missing:
    raise RuntimeError(
        "Missing required secret keys: " + ", ".join(missing)
    )

path = Path(os.environ["ENV_FILE"])

with path.open("w", encoding="utf-8") as file:
    for key in keys:
        file.write(
            f"{key}={shlex.quote(str(secret[key]))}\n"
        )
PYTHON

unset SECRET_JSON

chown "root:${APP_GROUP}" "${ENV_FILE}"
chmod 0640 "${ENV_FILE}"

ln -sfn \
  "${ENV_FILE}" \
  "${APP_DIR}/.env"

chown -R root:root "${APP_DIR}"
chmod -R a+rX "${APP_DIR}"

cat > /etc/systemd/system/kaizen-inventory-web.service <<'SERVICE'
[Unit]
Description=Kaizen Inventory Hub Web Service
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=inventory
Group=inventory
WorkingDirectory=/opt/kaizen-inventory-hub
EnvironmentFile=/etc/kaizen-inventory-hub/inventory.env

ExecStart=/opt/kaizen-inventory-hub/.venv/bin/gunicorn \
  -c /opt/kaizen-inventory-hub/gunicorn.conf.py \
  app.main:app

Restart=always
RestartSec=5
TimeoutStopSec=30

StandardOutput=journal
StandardError=journal

NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
SERVICE

cat > /etc/systemd/system/kaizen-inventory-low-stock.service <<'SERVICE'
[Unit]
Description=Kaizen Inventory Hub Low-Stock SNS Check
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
User=inventory
Group=inventory
WorkingDirectory=/opt/kaizen-inventory-hub
EnvironmentFile=/etc/kaizen-inventory-hub/inventory.env

ExecStart=/opt/kaizen-inventory-hub/.venv/bin/python \
  -m app.notify_low_stock

StandardOutput=journal
StandardError=journal

NoNewPrivileges=true
PrivateTmp=true
SERVICE

cat > /etc/systemd/system/kaizen-inventory-low-stock.timer <<'TIMER'
[Unit]
Description=Run Kaizen Inventory Low-Stock SNS Check Every 15 Minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=15min
Persistent=true
Unit=kaizen-inventory-low-stock.service

[Install]
WantedBy=timers.target
TIMER

systemctl daemon-reload

if [[ "${NODE_ROLE}" == "web" ]]; then
  systemctl disable --now \
    kaizen-inventory-low-stock.timer \
    >/dev/null 2>&1 || true

  systemctl enable --now \
    kaizen-inventory-web

  for attempt in $(seq 1 60); do
    if curl \
      --fail \
      --silent \
      http://127.0.0.1:8000/health \
      >/dev/null; then

      echo "Web node is healthy"
      exit 0
    fi

    echo "Web health attempt ${attempt}/60 failed"
    sleep 5
  done

  journalctl \
    -u kaizen-inventory-web \
    -n 100 \
    --no-pager || true

  exit 1
fi

systemctl disable --now \
  kaizen-inventory-web \
  >/dev/null 2>&1 || true

systemctl enable --now \
  kaizen-inventory-low-stock.timer

systemctl start \
  kaizen-inventory-low-stock.service

echo "Scheduler node configured"
