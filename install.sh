#!/bin/bash
set -e

echo "======================================"
echo "  Dploy Auto-Deploy Installer"
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
# Discord embed sender (NO PYTHON)
####################################

notify_discord() {
  [ -z "$DISCORD_WEBHOOK" ] && return 0

  local TITLE="$1"
  local DESCRIPTION="$2"
  local COLOR="$3"

  TITLE_ESCAPED=$(printf '%s' "$TITLE" | sed 's/\\/\\\\/g; s/"/\\"/g')
  DESC_ESCAPED=$(printf '%s' "$DESCRIPTION" \
    | sed 's/\\/\\\\/g; s/"/\\"/g; s/$/\\n/' | tr -d '\n')

  curl -s -X POST "$DISCORD_WEBHOOK" \
    -H "Content-Type: application/json" \
    -d "{
      \"username\": \"Deploy master\",
      \"avatar_url\": \"https://cdn.pfps.gg/pfps/4408-cartoon-meme.png\",
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
  MSG="git_repository not found in config.yml"
  echo "$(date '+%Y-%m-%d %H:%M:%S') ERROR: $MSG" >> "$LOG"

  notify_discord \
    "[$BASE] Deploy failed" \
    "**ERROR:** $MSG" \
    13835549

  exit 1
fi

####################################
# Lock
####################################

exec 9>"$LOCK"
flock -n 9 || exit 0

####################################
# Git remote check
####################################

export GIT_SSH_COMMAND="ssh -i $KEY -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"

REMOTE=$(git ls-remote "$REPO" "refs/heads/$BRANCH" | awk '{print $1}')

if [ -z "$REMOTE" ]; then
  MSG="git ls-remote failed"
  echo "$(date '+%Y-%m-%d %H:%M:%S') ERROR: $MSG" >> "$LOG"

  notify_discord \
    "[$BASE] Deploy failed" \
    "\`$BRANCH\`\n**ERROR:** $MSG" \
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
  echo "$(date '+%Y-%m-%d %H:%M:%S') $BRANCH: deployed $SHORT_COMMIT (${DURATION}s)" >> "$LOG"

  notify_discord \
    "[$BASE] Deploy successful" \
    "\`$BRANCH/$SHORT_COMMIT\` (${DURATION} s)" \
    5832563
else
  FIRST_LINE=$(echo "$OUTPUT" | head -n 1 | tr -d '\r')
  echo "$(date '+%Y-%m-%d %H:%M:%S') ERROR (${DURATION}s): $FIRST_LINE" >> "$LOG"

  notify_discord \
    "[$BASE] Deploy failed" \
    "\`$BRANCH/$SHORT_COMMIT\` (${DURATION} s)\n**ERROR:** $FIRST_LINE" \
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
echo
echo "Run manually:"
echo "  $SCRIPT"
echo
echo "Logs:"
echo "  tail -f $LOG"
