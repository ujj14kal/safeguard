#!/usr/bin/env bash
# Tests scripts/pre-commit.sh in a throwaway repo: every FAKE secret must be
# blocked and every code reference must pass.
# Run: ./scripts/test-pre-commit.sh [path/to/another/hook.sh]
#
# The fake secrets are assembled at runtime (name and value joined by `mk`) so
# this file never contains a contiguous `<name> = <value>` that the hook itself
# would block when this file is committed.
set -uo pipefail
cd "$(dirname "$0")/.."
HOOK="$(cd "$(dirname "${1:-scripts/pre-commit.sh}")" && pwd)/$(basename "${1:-scripts/pre-commit.sh}")"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cd "$work"
git init -q
git config user.email "test@example.invalid"
git config user.name "hook test"
mkdir -p .git/hooks
cp "$HOOK" .git/hooks/pre-commit
chmod +x .git/hooks/pre-commit
git commit -q --allow-empty -m base

failures=0
mk() { printf '%s%s\n' "$1" "$2"; }

check() { # expected(BLOCK|PASS) description content [filename]
  local expected="$1" description="$2" content="$3" file="${4:-sample.txt}"
  printf '%s\n' "$content" > "$file"
  git add -f "$file"
  if git commit -q -m t >/dev/null 2>&1; then
    actual=PASS
    git reset -q --soft HEAD~1
  else
    actual=BLOCK
  fi
  git reset -q
  rm -f "$file"
  if [ "$actual" = "$expected" ]; then
    printf '  ok    %-5s %s\n' "$expected" "$description"
  else
    printf '  FAIL  expected %s, got %s: %s\n' "$expected" "$actual" "$description"
    failures=$((failures + 1))
  fi
}

echo "must BLOCK (fake secrets):"
check BLOCK "quoted literal"                       "$(mk 'api_' 'key = "abcd1234efgh5678"')"
check BLOCK "hex auth token starting with a letter" "$(mk 'TWILIO_AUTH_' 'TOKEN=a1b2c3d4e5f60718293a4b5c6d7e8f90')"
check BLOCK "hex auth token starting with a digit"  "$(mk 'TWILIO_AUTH_' 'TOKEN=9f2b4c6d8e0a1b3c5d7e9f0a2b4c6d8e')"
check BLOCK "alphanumeric unquoted API key"         "$(mk 'META_MODEL_API_' 'KEY=mk9AbCdEfGhIjKlMnOpQrStUvWxYz012345')"
check BLOCK "short alphanumeric password"           "$(mk 'pass' 'word = hunter2')"
check BLOCK "mixed-case letters-only value"         "$(mk 'AUTH_' 'TOKEN=Tokenvalue')"
check BLOCK "JWT-shaped dotted value"               "$(mk 'api_' 'key = eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.abc123def456')"
check BLOCK "exported unquoted value with digits"   "$(mk 'export META_MODEL_API_' 'KEY=abcDEF123456')"
check BLOCK "client secret literal"                 "$(mk 'client_' 'secret = "Zk9Qx2LmN8Rt4Vb7Yc3Wd6Fg1Hj5"')"
check BLOCK "dotted path hiding a long token"       "$(mk 'api_' 'key = config.Zk9Qx2LmN8Rt4Vb7Yc3Wd6Fg1Hj5')"
check BLOCK "env file by name"                      "SOMETHING=harmless" ".env"
check BLOCK "phone number (not the fictional range)" "$(mk 'call +91987' '6543210 now')"
check BLOCK "key-prefixed token"                    "$(mk 'sk' '-abcdefgh12345678')"

echo "must PASS (code, not secrets):"
check PASS "empty template value"                   "$(mk 'META_MODEL_API_' 'KEY=')"
check PASS "settings reference"                     "$(mk 'api_' 'key = SETTINGS.meta_model_api_key')"
check PASS "self reference"                         "$(mk 'self.api_' 'key = api_key')"
check PASS "os.environ subscript"                   "$(mk 'api_' 'key = os.environ["META_MODEL_API_KEY"]')"
check PASS "os.environ.get call"                    "$(mk 'api_' 'key = os.environ.get("K")')"
check PASS "shell variable"                         "$(mk 'export META_MODEL_API_' 'KEY="$KEY"')"
check PASS "bare lowercase identifier"              "$(mk 'pass' 'word = password')"
check PASS "ordinary text"                          "nothing secret in this line"
check PASS "fictional phone number (555-01xx range)"  "call +14155550123 now"

echo
if [ "$failures" -eq 0 ]; then
  echo "pre-commit hook tests: all passed"
else
  echo "pre-commit hook tests: $failures FAILED"
  exit 1
fi
