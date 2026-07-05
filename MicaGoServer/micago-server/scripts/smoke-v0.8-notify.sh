#!/bin/zsh
set -euo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:3000}"
CONFIG_PATH="${HOME}/.micago/config.yaml"
TOKEN="$(sed -n 's/^  token: "\(.*\)"$/\1/p' "$CONFIG_PATH" | head -n 1)"
WEBHOOK_URL="$(sed -n 's/^  url: "\(.*\)"$/\1/p' "$CONFIG_PATH" | head -n 1)"
AUTH_HEADER="Authorization: Bearer $TOKEN"

if [[ -z "$TOKEN" ]]; then
  echo "failed to read token from $CONFIG_PATH"
  exit 1
fi

echo "== register none-provider device =="
REGISTER_RESPONSE="$(curl -sS -H "$AUTH_HEADER" -H 'Content-Type: application/json' \
  -d '{"name":"Notify Smoke","platform":"android","clientType":"flutter","pushProvider":"none","pushEnabled":false}' \
  "$BASE_URL/api/devices/register")"
echo "$REGISTER_RESPONSE"
DEVICE_ID="$(printf '%s' "$REGISTER_RESPONSE" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p' | head -n 1)"

echo
echo "== notification test with no FCM device =="
curl -sS -i -H "$AUTH_HEADER" -X POST "$BASE_URL/api/server/notifications/test"
echo

if [[ -n "$WEBHOOK_URL" ]]; then
  echo
  echo "Webhook URL is configured in config.yaml:"
  echo "  ${WEBHOOK_URL}"
  echo "Register a webhook-backed device and point the webhook receiver somewhere safe before live testing."
fi
