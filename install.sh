#!/bin/bash
set -e

echo "======================================"
echo "  Dploy Auto-Deploy Installer"
echo "======================================"
echo

# ===== Defaults =====
DEFAULT_BASE="$(pwd)"
DEFAULT_BRANCH="production"
DEFAULT_KEY_NAME="dploy-git"

# ===== Interactive if TTY, defaults otherwise =====
if [ -t 0 ]; then
  read -p "Base directory for deployment [${DEFAULT_BASE}]: " BASE
  BASE="${BASE:-$DEFAULT_BASE}"

  read -p "Git branch to deploy [${DEFAULT_BRANCH}]: " BRANCH
  BRANCH="${BRANCH:-$DEFAULT_BRANCH}"

  read -p "SSH key filename inside .ssh [${DEFAULT_KEY_NAME}]: " KEY_NAME
  KEY_NAME="${KEY_NAME:-$DEFAULT_KEY_NAME}"
else
  # Non-interactive mode (curl | bash)
  BASE="$DEFAULT_BASE"
  BRANCH="$DEFAULT_BRANCH"
  KEY_NAME="$DEFAULT_KEY_NAME"
  echo "Non-interactive mode detected — using defaults:"
  echo "  Base: $BASE"
  echo "  Branch: $BRANCH"
  echo "  SSH key: $KEY_NAME"
fi

# ===== Paths =====
CFG="$BASE/.dploy/config.yml"
KEY="$BASE/.ssh/$KEY_NAME"
SCRIPT="$BASE/deploy.sh"
STATE="$BASE/.last_commit"
LOG="$BASE/deploy.log"
LOCK="/tmp/website-deploy.lock"

# ===== Summary =====
echo
echo "Configuration summary:"
echo "  Base dir:  $BASE"
echo "  Branch:    $BRANCH"
echo "  SSH key:   $KEY"
echo "  Config:    $CFG"
echo

# ===== Sanity checks =====
[ ! -d "$BASE" ] && { echo "❌ Base directory does not exist: $BASE"; exit 1; }
[ ! -f "$CFG" ] && { echo "❌ Missing $CFG"; exit 1; }
[ ! -f "$KEY" ] && { echo "❌ Missing SSH key $KEY"; exit 1; }

# ===== Create deploy.sh =====
cat > "$SCRIPT" <<'EOF'
#!/bin/bash
set -e

BASE="$(cd "$(dirname "$0")" && pwd)"
KEY="$BASE/.ssh/KEY_NAME_PLACEHOLDER"
STATE="$BASE/.last_commit"
LOG="$BASE/deploy.log"
LOCK="/tmp/website-deploy.lock"

export PATH=/usr/local/bin:/usr/bin:/bin

# HARDCODED branch
BRANCH="BRANCH_PLACEHOLDER"

# Dynamic repo from YAML
REPO=$(grep 'git_repository:' "$BASE/.dploy/config.yml" | head -n1 | sed -E 's/^[[:space:]]*git_repository:[[:space:]]*//; s/^'\''//; s/'\''$//')

[ -z "$REPO" ] && { echo "$(date '+%Y-%m-%d %H:%M:%S') $BRANCH: ERROR: git_repository not found" >> "$LOG"; exit 1; }

exec 9>"$LOCK"
flock -n 9 || exit 0

export GIT_SSH_COMMAND="ssh -i $KEY -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"

REMOTE=$(git ls-remote "$REPO" "refs/heads/$BRANCH" | awk '{print $1}')
[ -z "$REMOTE" ] && { echo "$(date '+%Y-%m-%d %H:%M:%S') $BRANCH: ERROR: git ls-remote failed" >> "$LOG"; exit 1; }

LAST=$(cat "$STATE" 2>/dev/null || echo "")

[ "$REMOTE" = "$LAST" ] && exit 0  # skip no-changes logs

START=$(date +%s)
OUTPUT=$(dploy deploy "$BRANCH" 2>&1)
STATUS=$?
END=$(date +%s)
DURATION=$((END - START))

SHORT_COMMIT="${REMOTE:0:7}"

if [ $STATUS -eq 0 ]; then
  echo "$REMOTE" > "$STATE"
  echo "$(date '+%Y-%m-%d %H:%M:%S') $BRANCH: deployed $SHORT_COMMIT (${DURATION}s)" >> "$LOG"
else
  FIRST=$(echo "$OUTPUT" | head -n 1 | tr -d '\r')
  echo "$(date '+%Y-%m-%d %H:%M:%S') $BRANCH: ERROR (${DURATION}s): $FIRST" >> "$LOG"
  exit 1
fi
EOF

# Replace placeholders
sed -i "s|KEY_NAME_PLACEHOLDER|$KEY_NAME|" "$SCRIPT"
sed -i "s|BRANCH_PLACEHOLDER|$BRANCH|" "$SCRIPT"

chmod +x "$SCRIPT"
touch "$STATE" "$LOG"

# ===== Cron =====
( crontab -l 2>/dev/null | grep -v "$SCRIPT" || true
  echo "*/2 * * * * $SCRIPT"
  echo "0 0 1 * * truncate -s 0 $LOG"
) | crontab -

echo
echo "✅ Installation complete!"
echo
echo "Run manually:"
echo "  $SCRIPT"
echo
echo "Follow logs:"
echo "  tail -f $LOG"
