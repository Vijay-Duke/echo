#!/usr/bin/env bash
# Seed API keys into the macOS keychain for Echo.
# Reads from ../.env so you don't have to retype keys.
set -euo pipefail

ENV_FILE="$(dirname "$0")/../.env"
SERVICE="com.echo"

source "$ENV_FILE"

set_key () {
  local provider="$1" value="$2"
  [ -z "$value" ] && return 0
  local account="apiKey.$provider"
  security delete-generic-password -s "$SERVICE" -a "$account" >/dev/null 2>&1 || true
  security add-generic-password -s "$SERVICE" -a "$account" -w "$value" -U
  echo "seeded $provider"
}

set_key gemini "${GEMINI_API_KEY:-}"
set_key grok   "${XAI_API_KEY:-}"
set_key openai "${OPENAI_API_KEY:-}"

echo "done"
