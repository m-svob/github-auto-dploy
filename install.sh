#!/bin/bash
set -e

####################################
# Base paths & config
####################################

BASE="$(cd "$(dirname "$0")" && pwd)"
WEBSITE_NAME="$(basename "$BASE")"

KEY="$BASE/.ssh/dploy-git"
STATE="$BASE/.last_commit"
LOG="$BASE/deploy.log"
LOCK="$BASE/.deploy.lock"

BRANCH="production"

# Leave empty to disable Discord
DISCORD_WEBHOOK=""

export PATH=/usr/local/bin:/usr/bin:/bin

####################################
# Discord embed sender (PURE BASH)
####################################

notify_discord() {
  [ -z "$DISCORD_WEBHOOK" ] && return 0

  local TITLE="$1"
  local DESCRIPTION="$2"
  local COLOR="$3"

  TITLE_ESCAPED=$(printf '%s' "$TITLE" | sed 's/\\/\\\\/g; s/"/\\"/g')
  DESC_ESCAPED=$(printf '%s' "$DESCRIPTION" | sed 's/\\/\\\\/g; s/"/\\"/g')

  curl -s -X POST "$DISCORD_WEBHOOK" \
    -H "Content-Type: application/json" \
    -d "{
      \"username\": \"DPLOY master\",
      \"avatar_url\": \"https://ps.w.org/clp-varnish-cache/assets/icon-256x256.png?rev=2825319\",
      \"embeds\": [
        {
          \"title\": \"$TITLE_ESCAPED\",
          \"description\": \"$DESC_ESCAPED\",
          \"color\": $COLOR
        }
      ]
    }" >/dev/null 2>&1 || true
}

####################################
# Read repository from YAML
####################################

REPO=$(grep 'git_repository:' "$BASE/.dploy/config.yml" \
  | head -n1 \
  | sed -E 's/^[[:space:]]*git_repository:[[:space:]]*//; s/^'\''//; s/'\''$//')

if [ -z "$REPO" ]; then
  MSG="ERROR: git_repository not found"
  echo "$(date '+%Y-%m-%d %H:%M:%S') $MSG" >> "$LOG"

  notify_discord \
    "[$WEBSITE_NAME] Deploy failed" \
    "$MSG" \
    13835549

  exit 1
fi

####################################
# Lock (prevents overlap)
####################################

exec 9>"$LOCK"
flock -n 9 || exit 0

####################################
# Notify: deployment started
####################################

notify_discord \
  "[$WEBSITE_NAME] Deployment started" \
  "Branch: \`$BRANCH\`" \
  16776960

####################################
# Git remote check
####################################

export GIT_SSH_COMMAND="ssh -i $KEY -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"

REMOTE=$(git ls-remote "$REPO" "refs/heads/$BRANCH" | awk '{print $1}')

if [ -z "$REMOTE" ]; then
  MSG="ERROR: git ls-remote failed"
  echo "$(date '+%Y-%m-%d %H:%M:%S') $MSG" >> "$LOG"

  notify_discord \
    "[$WEBSITE_NAME] Deploy failed" \
    "$MSG" \
    13835549

  exit 1
fi

LAST=$(cat "$STATE" 2>/dev/null || echo "")

[ "$REMOTE" = "$LAST" ] && exit 0

####################################
# Deploy
####################################

START=$(date +%s)
OUTPUT=$(dploy deploy "$BRANCH" 2>&1)
STATUS=$?
END=$(date +%s)

DURATION=$((END - START))
SHORT_COMMIT="${REMOTE:0:7}"

####################################
# Result
####################################

if [ $STATUS -eq 0 ]; then
  echo "$REMOTE" > "$STATE"
  echo "$(date '+%Y-%m-%d %H:%M:%S') $BRANCH deployed $SHORT_COMMIT (${DURATION}s)" >> "$LOG"

  notify_discord \
    "[$WEBSITE_NAME] Deploy successful" \
    "\`$BRANCH/$SHORT_COMMIT\` (${DURATION}s)" \
    5832563
else
  FIRST_LINE=$(echo "$OUTPUT" | head -n 1 | tr -d '\r')
  echo "$(date '+%Y-%m-%d %H:%M:%S') ERROR (${DURATION}s): $FIRST_LINE" >> "$LOG"

  notify_discord \
    "[$WEBSITE_NAME] Deploy failed" \
    "\`$BRANCH/$SHORT_COMMIT\` (${DURATION}s)\nERROR: $FIRST_LINE" \
    13835549

  exit 1
fi
