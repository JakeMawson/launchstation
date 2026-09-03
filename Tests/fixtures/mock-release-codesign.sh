#!/bin/zsh
set -euo pipefail

# Deliberately strict test double: accepting an underspecified verifier command
# would let setup-contracts pass while the real verifier accidentally weakened
# its codesign invocation.
expected_app="${MOCK_RELEASE_EXPECTED_APP:-}"
[[ -n "$expected_app" && "$expected_app" == /* ]] || {
  print -u2 -- 'mock-release-codesign requires an absolute MOCK_RELEASE_EXPECTED_APP'
  exit 64
}

if (( $# == 5 )) \
  && [[ "$1" == "--verify" ]] \
  && [[ "$2" == "--deep" ]] \
  && [[ "$3" == "--strict" ]] \
  && [[ "$4" == "--verbose=2" ]] \
  && [[ "$5" == "$expected_app" ]]; then
  exit 0
fi

if (( $# == 3 )) \
  && [[ "$1" == "-d" ]] \
  && [[ "$2" == "--verbose=4" ]] \
  && [[ "$3" == "$expected_app" ]]; then
  case "${MOCK_RELEASE_SIGNATURE:-trusted}" in
    trusted)
      print -u2 -- 'Authority=Developer ID Application: Example Publisher (ABCDE12345)'
      print -u2 -- 'Identifier=com.jakemawson.codex-launcher'
      print -u2 -- 'TeamIdentifier=ABCDE12345'
      print -u2 -- 'flags=0x10000(runtime)'
      print -u2 -- 'Timestamp=Jul 18, 2026 at 10:00:00 AM'
      print -u2 -- 'Signature=authority'
      ;;
    trusted-no-timestamp)
      print -u2 -- 'Authority=Developer ID Application: Example Publisher (ABCDE12345)'
      print -u2 -- 'Identifier=com.jakemawson.codex-launcher'
      print -u2 -- 'TeamIdentifier=ABCDE12345'
      print -u2 -- 'flags=0x10000(runtime)'
      print -u2 -- 'Timestamp=none'
      print -u2 -- 'Signature=authority'
      ;;
    adhoc)
      print -u2 -- 'Signature=adhoc'
      print -u2 -- 'TeamIdentifier=not set'
      ;;
    development)
      print -u2 -- 'Authority=Apple Development: Example Publisher (ABCDE12345)'
      print -u2 -- 'Identifier=com.jakemawson.codex-launcher'
      print -u2 -- 'TeamIdentifier=ABCDE12345'
      print -u2 -- 'flags=0x10000(runtime)'
      print -u2 -- 'Timestamp=Jul 18, 2026 at 10:00:00 AM'
      ;;
    *)
      print -u2 -- "unknown mock release signature: ${MOCK_RELEASE_SIGNATURE}"
      exit 64
      ;;
  esac
  exit 0
fi

print -u2 -- "unexpected mock codesign invocation: $*"
exit 64
