#!/bin/bash
set -e

echo "======================================"
echo "  DPLOY Auto-Deploy Installer"
echo "======================================"
echo

############################
# Defaults
############################

DEFAULT_BASE="$(pwd)"
DEFAULT_BRANCH="production"
DEFAULT_KEY_NAME="dploy-git"

############################
# User input
############################

read -p "Base directory for deployment [${DEFAULT_BASE}]: " BASE
BASE="${BASE:-$DEFAULT_BASE}"

read -p "Git branch to deploy [${DEFAULT_BRANCH}]: " BRANCH
BRANCH="${BRANCH:-$DEFAULT_BRANCH}"

read -p "SSH key filename inside .ssh [${DEFAULT_KEY_NAME}]: " KEY_NAME
KEY_NAME="${KEY_NAME:-$DEFAULT_KEY_NAME}"

read -p "Discord webhook URL (optional, press Enter to skip): " DISCORD_WEBHOOK

############################
# Paths
############################

CFG="$BASE/.dploy/config.yml"
KEY="$BASE/.ssh/$KEY_NAME"
SCRIPT="$BASE/deploy.sh"
STATE="$BASE/.last_commit"
LOG="$BASE/deploy.log"

WEBSITE_NAME="$(basename "$BASE")"

############################
# Summary
############################

echo
echo "Configuration summary:"
echo "  Website:   $WEBSITE_NAME"
echo "  Base dir:  $BASE"
echo "  Branch:    $BRANCH"
echo "  SSH key:   $KEY"
echo "  Config:    $CFG"
echo "  Discord:   ${DISCORD_WEBHOOK:-disabled}"
echo

############################
# Sanity checks
############################

[ ! -d "$BASE" ] && { echo "❌ Base directory does not exist: $BASE"; exit 1; }
[ ! -f "$CFG" ] && { echo "❌ Missing $CFG"; exit 1; }
[ ! -f "$KEY" ] && { echo "❌ Missing SSH key $KEY"; exit 1; }

############################
# Create deploy.sh
############################

cat > "$SCRIPT" <<'EOF'
#!/bin/bash
set -e

####################################
# Base paths & config
####################################

BASE="$(cd "$(dirname "$0")" && pwd)"
WEBSITE_NAME="$(basename "$BASE")"

KEY="$BASE/.ssh/KEY_NAME_PLACEHOLDER"
STATE="$BASE/.last_commit"
LOG="$BASE/deploy.log"
LOCK="$BASE/.deploy.lock"

BRANCH="BRANCH_PLACEHOLDER"
DISCORD_WEBHOOK="DISCORD_WEBHOOK_PLACEHOLDER"

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

[ -z "$REPO" ] && {
  MSG="ERROR: git_repository not found in config.yml"
  echo "$(date '+%Y-%m-%d %H:%M:%S') $MSG" >> "$LOG"
  notify_discord "[$WEBSITE_NAME] Deploy failed" "$MSG" 13835549
  exit 1
}

####################################
# Lock (prevents overlap)
####################################

exec 9>"$LOCK"
flock -n 9 || exit 0

####################################
# Git remote check (Silent & Fast)
####################################

export GIT_SSH_COMMAND="ssh -i $KEY -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15"

# Try to get the hash. If it fails (network/timeout), just exit 0.
# No retries, no Discord pings, no log spam.
REMOTE=$(git ls-remote "$REPO" "refs/heads/$BRANCH" 2>/dev/null | awk '{print $1}')

# If we can't reach Git, just stop and wait for the next cron minute.
[ -z "$REMOTE" ] && exit 0

SHORT_COMMIT="${REMOTE:0:7}"
LAST=$(cat "$STATE" 2>/dev/null || echo "")

####################################
# NO CHANGES → EXIT QUIETLY
####################################

[ "$REMOTE" = "$LAST" ] && exit 0

####################################
# Deployment really starts here
####################################

notify_discord \
  "[$WEBSITE_NAME] Deployment started" \
  "\`$BRANCH/$SHORT_COMMIT\`" \
  16776960

####################################
# Deploy (set -e SAFE)
####################################

START=$(date +%s)

set +e
OUTPUT=$(dploy deploy "$BRANCH" 2>&1)
STATUS=$?
set -e

END=$(date +%s)
DURATION=$((END - START))

####################################
# Result handling
####################################

if [ $STATUS -eq 0 ]; then
  echo "$REMOTE" > "$STATE"
  echo "$(date '+%Y-%m-%d %H:%M:%S') $BRANCH deployed $SHORT_COMMIT (${DURATION}s)" >> "$LOG"

  notify_discord \
    "[$WEBSITE_NAME] Deploy successful" \
    "\`$BRANCH/$SHORT_COMMIT\` (${DURATION}s)" \
    5832563
else
  FIRST_LINE=$(echo "$OUTPUT" | grep -m1 -E "npm ERR!|ERR!|ERROR" | tr -d '\r')
  [ -z "$FIRST_LINE" ] && FIRST_LINE=$(echo "$OUTPUT" | head -n 1)

  echo "$(date '+%Y-%m-%d %H:%M:%S') ERROR (${DURATION}s): $FIRST_LINE" >> "$LOG"

  notify_discord \
    "[$WEBSITE_NAME] Deploy failed" \
    "\`$BRANCH/$SHORT_COMMIT\` ERROR: $FIRST_LINE" \
    13835549

  exit 1
fi
EOF

############################
# Replace placeholders
############################

sed -i "s|KEY_NAME_PLACEHOLDER|$KEY_NAME|" "$SCRIPT"
sed -i "s|BRANCH_PLACEHOLDER|$BRANCH|" "$SCRIPT"
sed -i "s|DISCORD_WEBHOOK_PLACEHOLDER|$DISCORD_WEBHOOK|" "$SCRIPT"

chmod +x "$SCRIPT"
touch "$STATE" "$LOG"

############################
# Cron (idempotent)
############################

CRON_DEPLOY_TAG="# dploy-auto-deploy"
CRON_LOG_TAG="# dploy-auto-logrotate"

(
  crontab -l 2>/dev/null \
    | grep -v "$CRON_DEPLOY_TAG" \
    | grep -v "$CRON_LOG_TAG" \
    || true

  echo "* * * * * $SCRIPT $CRON_DEPLOY_TAG"
  echo "0 0 1 * * truncate -s 0 $LOG $CRON_LOG_TAG"
) | crontab -

############################
# Done
############################

echo
echo "✅ Installation complete!"
echo "Run manually: $SCRIPT"
echo "Logs: tail -f $LOG"
