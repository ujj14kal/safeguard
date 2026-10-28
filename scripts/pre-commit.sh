#!/usr/bin/env bash
BLOCKED_TEAM_ID="${BLOCKED_TEAM_ID:-}"
BLOCKED_EMAIL="${BLOCKED_EMAIL:-}"

fail=0
block() { echo "pre-commit BLOCKED: $1" >&2; fail=1; }

staged_names=$(git diff --cached --name-only --diff-filter=ACM)
[ -z "$staged_names" ] && exit 0
staged_diff=$(git diff --cached -- . ':!scripts/pre-commit.sh')

bad_files=$(printf '%s\n' "$staged_names" | grep -E '(^|/)\.env($|\.)' | grep -v '\.env\.example$' || true)
[ -n "$bad_files" ] && block "real env file staged (never commit .env files): $bad_files"

token_pat='(sk[-][A-Za-z0-9-]{8,}|gh[op]_[A-Za-z0-9]{8,}|AKIA[0-9A-Z]{12,}|xox[bpas]-[A-Za-z0-9-]{8,}|Bear(er) [A-Za-z0-9._~+/-]{8,}|AC[0-9a-f]{30,}|BEGIN (RSA )?PRIVATE KEY)'
if printf '%s\n' "$staged_diff" | grep -E -q "$token_pat"; then
  block "token/key pattern found (sk-/ghp_/Bearer/AWS/Twilio-SID/private-key). Remove it; keys live in .env (untracked)."
fi

secret_lhs_re='(api[_-]?key|apikey|auth[_-]?token|authtoken|client[_-]?secret|clientsecret|twilio_[a-z_]+|password)[[:space:]]*=[[:space:]]*'
dotted_re='^`?[A-Za-z_][A-Za-z0-9_]*([.][A-Za-z_][A-Za-z0-9_]*|\([^)]*\)|\[[^]]*\])+`?[ ,)`]*(#.*)?$'
shellvar_re='^"?\$\{?[A-Za-z_][A-Za-z0-9_]*\}?"?[ ,)]*(#.*)?$'
lowerident_re='^`?[a-z_]+`?[ ,)`]*(#.*)?$'

looks_like_secret_assignment() {
  local line="$1" rhs
  shopt -s nocasematch
  if ! [[ $line =~ $secret_lhs_re ]]; then
    shopt -u nocasematch
    return 1
  fi
  shopt -u nocasematch
  rhs="${line#*"${BASH_REMATCH[0]}"}"
  [ -z "${rhs//[[:space:]]/}" ] && return 1          # empty template value
  if printf '%s\n' "$rhs" | grep -o -E '[A-Za-z0-9]{20,}' | grep -q '[0-9]'; then
    return 0
  fi
  if [[ $rhs =~ $dotted_re ]] || [[ $rhs =~ $shellvar_re ]] || [[ $rhs =~ $lowerident_re ]]; then
    return 1
  fi
  return 0
}

bad_assign=""
while IFS= read -r added; do
  if looks_like_secret_assignment "${added#+}"; then
    bad_assign="$added"
    break
  fi
done < <(printf '%s\n' "$staged_diff" | grep -E '^\+' | grep -v -E '^\+\+\+' || true)
[ -n "$bad_assign" ] && block "assigned secret with a value found (e.g. *_KEY=<value>). Keep values in .env (untracked); commit only empty templates, or read the value from the environment."

phones=$(printf '%s\n' "$staged_diff" | grep -E -o '\+[1-9][0-9]{9,14}' | grep -v '55501' || true)
[ -n "$phones" ] && block "phone number(s) staged: $phones (use fictional +1-555-01xx numbers only)"

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
