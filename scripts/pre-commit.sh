#!/usr/bin/env bash
# Safeguard pre-commit secret scan.
# Tracked copy: scripts/pre-commit.sh — install with:
#   cp scripts/pre-commit.sh .git/hooks/pre-commit && chmod +x .git/hooks/pre-commit
# The repo is PUBLIC: this hook blocks staged secrets, tokens, .env files,
# phone numbers, and owner PII. It scans staged content only.
#
# Owner-specific values go ONLY in your local untracked .git/hooks copy.
# NEVER commit real values here — this file is world-readable.
BLOCKED_TEAM_ID="${BLOCKED_TEAM_ID:-}"
BLOCKED_EMAIL="${BLOCKED_EMAIL:-}"

fail=0
block() { echo "pre-commit BLOCKED: $1" >&2; fail=1; }

staged_names=$(git diff --cached --name-only --diff-filter=ACM)
[ -z "$staged_names" ] && exit 0
# Exclude this script's own path: it necessarily names the patterns it scans for.
staged_diff=$(git diff --cached -- . ':!scripts/pre-commit.sh')

# 1. Filenames: real env files (the empty .env.example template is allowed).
bad_files=$(printf '%s\n' "$staged_names" | grep -E '(^|/)\.env($|\.)' | grep -v '\.env\.example$' || true)
[ -n "$bad_files" ] && block "real env file staged (never commit .env files): $bad_files"

# 2. Token/key patterns. Bracket tricks (sk[-], Bear(er)) keep the pattern text
# itself from matching while still matching real tokens in staged content.
token_pat='(sk[-][A-Za-z0-9-]{8,}|gh[op]_[A-Za-z0-9]{8,}|AKIA[0-9A-Z]{12,}|xox[bpas]-[A-Za-z0-9-]{8,}|Bear(er) [A-Za-z0-9._~+/-]{8,}|AC[0-9a-f]{30,}|BEGIN (RSA )?PRIVATE KEY)'
if printf '%s\n' "$staged_diff" | grep -E -q "$token_pat"; then
  block "token/key pattern found (sk-/ghp_/Bearer/AWS/Twilio-SID/private-key). Remove it; keys live in .env (untracked)."
fi

# 3. Assigned secrets with non-empty values (empty `KEY=` template lines pass).
# Quoted literals are always blocked. Unquoted values pass only when they are
# bare code references (identifier, dotted path, os.environ/call) — e.g.
# `api_key=SETTINGS.x` or `self.api_key = api_key`. Real leaked values are
# string literals or token-shaped (dashes etc., also caught by rule 2).
# Known gap: a pure-alphanumeric UNQUOTED value (e.g. `password = hunter2`)
# reads as a code reference and passes; quoted and token-shaped values block.
secret_lhs='(api[_-]?key|auth[_-]?token|client[_-]?secret|TWILIO_[A-Z_]+|password)[ ]*=[ ]*'
candidates=$(printf '%s\n' "$staged_diff" | grep -E -i "$secret_lhs"'[^[:space:]#]' || true)
if [ -n "$candidates" ]; then
  bad_assign=$(printf '%s\n' "$candidates" | grep -v -E -i "$secret_lhs"'`?[A-Za-z_][A-Za-z0-9_]*([.][A-Za-z_][A-Za-z0-9_]*|\([^)]*\))?(\[[^]]*\])?`?[ ,)`]*(#.*)?$' || true)
  [ -n "$bad_assign" ] && block "assigned secret with a value found (e.g. *_KEY=<value>). Keep values in .env (untracked); commit only empty templates."
fi

# 4. Phone numbers (E.164-looking). Fictional +1-555-01xx numbers are allowed
# for fake contacts/tests/docs; everything else is blocked.
phones=$(printf '%s\n' "$staged_diff" | grep -E -o '\+[1-9][0-9]{9,14}' | grep -v '55501' || true)
[ -n "$phones" ] && block "phone number(s) staged: $phones (use fictional +1-555-01xx numbers only)"

# 5. Owner PII — set these ONLY in the local .git/hooks copy, never here.
if [ -n "$BLOCKED_TEAM_ID" ] && printf '%s\n' "$staged_diff" | grep -F -q "$BLOCKED_TEAM_ID"; then
  block "Apple Team ID found in staged content."
fi
if [ -n "$BLOCKED_EMAIL" ] && printf '%s\n' "$staged_diff" | grep -F -q "$BLOCKED_EMAIL"; then
  block "personal email found in staged content."
fi

if [ "$fail" -ne 0 ]; then
  echo "pre-commit: commit refused. Unstage/fix the above, then retry." >&2
  exit 1
fi
exit 0
