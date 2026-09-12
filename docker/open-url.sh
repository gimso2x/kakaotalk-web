#!/usr/bin/env bash
set -euo pipefail

# Smart URL handler for KakaoTalk running under Wine/Docker
# Handles URLs clicked in chat messages, profiles, and dialogs.

URL="${1:-}"
CLEAN_URL=$(printf '%s' "$URL" | tr -d '\r\n')

if [ -z "$CLEAN_URL" ]; then
  exit 0
fi

LOG_FILE="/tmp/opened_urls.log"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

# Always log clicked URL to /tmp
printf '[%s] %s\n' "$TIMESTAMP" "$CLEAN_URL" >> "$LOG_FILE" 2>/dev/null || true

# If /share volume exists and is writable, record for host access
SHARE_LOG="/share/opened_urls.txt"
if [ -d /share ] && [ -w /share ]; then
  printf '[%s] %s\n' "$TIMESTAMP" "$CLEAN_URL" >> "$SHARE_LOG" 2>/dev/null || true
fi

# If Firefox is explicitly enabled, dispatch to browser
if [ "${ENABLE_FIREFOX:-false}" = "true" ] && [ -x /usr/local/bin/run-firefox ]; then
  printf '[%s] Dispatching to Firefox: %s\n' "$TIMESTAMP" "$CLEAN_URL" >> "$LOG_FILE" 2>/dev/null || true
  /usr/local/bin/run-firefox "$CLEAN_URL" &
else
  printf '[%s] URL recorded (Firefox disabled): %s\n' "$TIMESTAMP" "$CLEAN_URL" >> "$LOG_FILE" 2>/dev/null || true
fi

exit 0
