#!/bin/zsh
set -euo pipefail

# Public distributable-release verifier. This wrapper has intentionally fixed
# trust inputs: callers cannot select a policy, signing tool, Gatekeeper tool,
# or test mode. Test doubles live only behind Tests/verify-release-app-fixture.zsh.

ROOT="${0:A:h:h}"
RELEASE_TRUST_POLICY="$ROOT/Resources/ReleaseTrustPolicy.plist"
RELEASE_POLICY_LIBRARY="$ROOT/scripts/release-trust-policy.zsh"
RELEASE_VERIFIER_CORE="$ROOT/scripts/release-verifier-core.zsh"
APP=""
MODE="release"

usage() {
  cat <<'EOF'
Usage:
  scripts/verify-release-app.sh --app /absolute/path/Launch\ Station.app [--mode release]

The verifier accepts only notarized Developer ID release bundles. Its publisher
and 10-character Apple Team ID are pinned in the source-controlled
Resources/ReleaseTrustPolicy.plist. The public verifier always uses
/usr/bin/codesign and /usr/sbin/spctl; it has no policy, tool, or test-mode
override. It checks signed release provenance, the exact Developer ID identity,
hardened runtime, a non-empty secure timestamp (never Timestamp=none), strict
nested signature validation, and Gatekeeper's `Notarized Developer ID` result.
EOF
}

fail() {
  print -u2 -- "Release verification refused: $*"
  exit 1
}

require_value() {
  local option="$1"
  (($# >= 2)) || fail "$option requires a value"
}

while (($# > 0)); do
  case "$1" in
    --app)
      require_value "$@"
      APP="$2"
      shift 2
      ;;
    --mode)
      require_value "$@"
      MODE="$2"
      shift 2
      ;;
    --test-tools|--test-policy|--codesign|--spctl|--team-id|--publisher|--policy)
      fail "$1 is unsupported by the public verifier; release trust and Apple tools are fixed by the repository"
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      fail "unknown option: $1"
      ;;
  esac
done

[[ "$MODE" == "release" ]] || fail "only --mode release is supported; developer/ad-hoc bundles are intentionally not release-verifiable"
[[ -n "$APP" ]] || fail "--app is required"
[[ "$APP" == /* ]] || fail "--app must be an absolute path"
[[ -x /usr/bin/codesign && ! -d /usr/bin/codesign ]] || fail "required production codesign tool is unavailable: /usr/bin/codesign"
[[ -x /usr/sbin/spctl && ! -d /usr/sbin/spctl ]] || fail "required production spctl tool is unavailable: /usr/sbin/spctl"
[[ -f "$RELEASE_VERIFIER_CORE" && ! -L "$RELEASE_VERIFIER_CORE" ]] || fail "release verifier core is missing or unsafe: $RELEASE_VERIFIER_CORE"

source "$RELEASE_VERIFIER_CORE"
release_verifier_verify \
  "$APP" \
  "$RELEASE_TRUST_POLICY" \
  /usr/bin/codesign \
  /usr/sbin/spctl \
  "$RELEASE_POLICY_LIBRARY" \
  production || exit 1
