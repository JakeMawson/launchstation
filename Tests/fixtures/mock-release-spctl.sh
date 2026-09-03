#!/bin/zsh
set -euo pipefail

# Deliberately strict test double: assert the exact Gatekeeper assessment shape
# and target rather than silently accepting any call made by the verifier.
expected_app="${MOCK_RELEASE_EXPECTED_APP:-}"
[[ -n "$expected_app" && "$expected_app" == /* ]] || {
  print -u2 -- 'mock-release-spctl requires an absolute MOCK_RELEASE_EXPECTED_APP'
  exit 64
}

if ! (( $# == 5 )) \
  || [[ "$1" != "--assess" ]] \
  || [[ "$2" != "--type" ]] \
  || [[ "$3" != "execute" ]] \
  || [[ "$4" != "--verbose=4" ]] \
  || [[ "$5" != "$expected_app" ]]; then
  print -u2 -- "unexpected mock spctl invocation: $*"
  exit 64
fi

case "${MOCK_RELEASE_NOTARIZATION:-notarized}" in
  notarized)
    print -- 'source=Notarized Developer ID'
    ;;
  developer-id)
    print -- 'source=Developer ID'
    ;;
  *)
    print -u2 -- "unknown mock release notarization: ${MOCK_RELEASE_NOTARIZATION}"
    exit 64
    ;;
esac
