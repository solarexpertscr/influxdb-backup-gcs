#!/usr/bin/env bash
# scan-secrets.sh — Pre-commit hook to prevent leaking secrets to git
#
# Scans staged changes for known credential patterns and blocks the commit
# if any are found. Returns exit code 0 if clean, 1 if secrets detected.
#
# Install: ln -sf ../../scripts/scan-secrets.sh .git/hooks/pre-commit
#
# This is a defense-in-depth check. Vaultwarden is the canonical secret store.
# Any token/credential in a tracked file is a leak — rotate the underlying
# credential AND refactor the code to read from Vaultwarden.

set -uo pipefail

RED='\033[0;31m'
YELLOW='\033[0;33m'
GREEN='\033[0;32m'
NC='\033[0m'

# Files to ignore (binary, generated, etc.)
IGNORE_PATTERN='\.(db|sqlite|sqlite3|jpg|jpeg|png|gif|webp|svg|ico|pdf|zip|tar|gz|bz2|xz|7z|rar|mp[34]|mov|avi|webm|woff2?|ttf|otf|eot|pyc|class|o|so|dll|exe)$'

# Self-exception: this file is the scanner itself, so it contains patterns
# as documentation/tripwires. Skip it to allow the hook to install itself.
SELF_FILE="scripts/scan-secrets.sh"

# Secret patterns to detect (regex → friendly description)
declare -A PATTERNS=(
  ["github_pat_[A-Za-z0-9_]{20,}"]="GitHub fine-grained PAT"
  ["ghp_[A-Za-z0-9]{30,}"]="GitHub classic PAT"
  ["gho_[A-Za-z0-9]{30,}"]="GitHub OAuth token"
  ["ghs_[A-Za-z0-9]{30,}"]="GitHub server token"
  ["ghr_[A-Za-z0-9]{30,}"]="GitHub refresh token"
  ["cfut_[A-Za-z0-9_-]{20,}"]="Cloudflare API token"
  ["sk-[A-Za-z0-9]{20,}"]="OpenAI/Anthropic API key"
  ["AIza[0-9A-Za-z_-]{30,}"]="Google API key"
  ["xox[baprs]-[0-9a-zA-Z-]{10,}"]="Slack token"
  ["[0-9]{8,}:[A-Za-z0-9_-]{30,}"]="Telegram bot token"
  ["DI_API_TOKEN_REDACTED_LEGACY"]="OLD DI API token (revoked - just a marker)"
  ["EZsite_MCP_TOKEN_REDACTED_LEGACY=="]="OLD EZsite MCP token (revoked - just a marker)"
  ["[a-f0-9]{64}"]="Generic 64-char hex (likely API token, verify)"
)

# Get list of staged files (added/modified content, not deletions)
STAGED_FILES=$(git diff --cached --name-only --diff-filter=ACMR 2>/dev/null)
if [ -z "$STAGED_FILES" ]; then
  exit 0
fi

FOUND_SECRETS=0
FOUND_FILES=()

for FILE in $STAGED_FILES; do
  # Skip binary files
  if echo "$FILE" | grep -qE "$IGNORE_PATTERN"; then
    continue
  fi

  # Skip .gitignore (it has patterns, not secrets)
  if [ "$(basename "$FILE")" = ".gitignore" ]; then
    continue
  fi

  # Skip the scanner itself (it contains patterns as tripwires)
  if [ "$FILE" = "$SELF_FILE" ]; then
    continue
  fi

  # Skip memory/ files (they're markdown logs and may document redacted secrets)
  # but still flag obvious issues
  for PATTERN in "${!PATTERNS[@]}"; do
    DESCRIPTION="${PATTERNS[$PATTERN]}"
    # Look for the pattern in the staged content (not the working tree)
    if git show ":$FILE" 2>/dev/null | grep -qE "$PATTERN"; then
      MATCH=$(git show ":$FILE" 2>/dev/null | grep -E "$PATTERN" | head -1)
      if [ -n "$MATCH" ]; then
        # Only report this file/pattern once
        KEY="${FILE}::${PATTERN}"
        if [[ " ${FOUND_FILES[@]:-} " =~ " $KEY " ]]; then
          continue
        fi
        FOUND_FILES+=("$KEY")
        echo -e "${RED}✗ SECRET DETECTED${NC} in ${YELLOW}$FILE${NC}" >&2
        echo -e "  Pattern: ${DESCRIPTION}" >&2
        echo -e "  Match:   ${MATCH:0:80}..." >&2
        FOUND_SECRETS=1
      fi
    fi
  done
done

if [ "$FOUND_SECRETS" -eq 1 ]; then
  echo "" >&2
  echo -e "${RED}=== COMMIT BLOCKED ===${NC}" >&2
  echo -e "Secrets detected in staged changes." >&2
  echo "" >&2
  echo -e "If these are real secrets:" >&2
  echo -e "  1. ${YELLOW}DO NOT${NC} commit them. Remove the hardcoded value." >&2
  echo -e "  2. Refactor the code to read from Vaultwarden at runtime." >&2
  echo -e "  3. Rotate the underlying credential (the one that was in the file is now compromised)." >&2
  echo -e "  4. Try the commit again after fixing." >&2
  echo "" >&2
  echo -e "If these are false positives (e.g. you're documenting a redacted token):" >&2
  echo -e "  - Use a placeholder like ${YELLOW}<redacted — see Vaultwarden item X>${NC}" >&2
  echo -e "  - Or temporarily bypass with: ${YELLOW}git commit --no-verify${NC}" >&2
  echo "" >&2
  echo -e "Bypass (NOT recommended): ${YELLOW}git commit --no-verify -m '...'"${NC} >&2
  exit 1
fi

echo -e "${GREEN}✓ scan-secrets: clean (no secrets detected in staged changes)${NC}" >&2
exit 0
