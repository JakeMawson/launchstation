#!/bin/zsh
set -euo pipefail

# Test-only harness for release-verifier-core.zsh. It is deliberately under
# Tests/, not a supported distribution command: it permits fixture policy/tools
# so setup-contracts can exercise the real verifier logic without weakening the
# public scripts/verify-release-app.sh boundary.

ROOT="${0:A:h:h}"
CORE="$ROOT/scripts/release-verifier-core.zsh"
POLICY_LIBRARY="$ROOT/scripts/release-trust-policy.zsh"
APP=""
POLICY=""
CODESIGN=""
SPCTL=""

fail() {
  print -u2 -- "Release verifier fixture refused: $*"
  exit 1
}

require_value() {
  local option="$1"
  (($# >= 2)) || fail "$option requires a value"
}

while (($# > 0)); do
  case "$1" in
    --app)
      require_value "$@"; APP="$2"; shift 2 ;;
    --policy)
      require_value "$@"; POLICY="$2"; shift 2 ;;
    --codesign)
      require_value "$@"; CODESIGN="$2"; shift 2 ;;
    --spctl)
      require_value "$@"; SPCTL="$2"; shift 2 ;;
    *)
      fail "unknown test fixture option: $1" ;;
  esac
done

for value in "$APP" "$POLICY" "$CODESIGN" "$SPCTL"; do
  [[ -n "$value" && "$value" == /* ]] || fail "all fixture arguments must be absolute paths"
done
[[ -f "$CORE" && ! -L "$CORE" ]] || fail "fixture verifier core is missing or unsafe: $CORE"

source "$CORE"
release_verifier_verify "$APP" "$POLICY" "$CODESIGN" "$SPCTL" "$POLICY_LIBRARY" test || exit 1
