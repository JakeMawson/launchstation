#!/bin/zsh

# Shared loader for the source-controlled release trust anchor. Callers must
# pass the fixed repository policy path; this file deliberately has no
# environment-variable or command-line trust-root fallback.

RELEASE_TRUST_POLICY_SCHEMA_VERSION=1

release_trust_policy_fail() {
  print -u2 -- "Release trust policy refused: $*"
  return 1
}

release_trust_policy_require_safe_path() {
  local path="$1"
  local description="$2"
  local cursor

  [[ "$path" == /* ]] || {
    release_trust_policy_fail "$description must be an absolute path: $path"
    return 1
  }
  cursor="$path"
  while [[ "$cursor" != "/" ]]; do
    [[ ! -L "$cursor" ]] || {
      release_trust_policy_fail "$description contains a symlink path component: $cursor"
      return 1
    }
    cursor="${cursor:h}"
  done
  [[ -f "$path" && ! -L "$path" ]] || {
    release_trust_policy_fail "$description must be a regular non-symlink file: $path"
    return 1
  }
}

# On success this sets the globals below. The policy is deliberately fail-closed
# while Configured is false, so development builds remain possible but release
# packaging, verification, installation, and upgrade cannot silently invent a
# trust root.
release_trust_policy_load() {
  if (( $# != 1 )); then
    release_trust_policy_fail "expected exactly one policy path"
    return 1
  fi

  local policy_path="$1"
  local policy_version
  local configured
  local team_id
  local publisher

  release_trust_policy_require_safe_path "$policy_path" "Release trust policy" || return 1
  /usr/bin/plutil -lint "$policy_path" >/dev/null || {
    release_trust_policy_fail "Release trust policy is not a valid plist: $policy_path"
    return 1
  }

  policy_version=$(/usr/bin/plutil -extract PolicyVersion raw -expect integer -o - "$policy_path" 2>/dev/null) || {
    release_trust_policy_fail "Release trust policy PolicyVersion is missing or invalid: $policy_path"
    return 1
  }
  [[ "$policy_version" == "$RELEASE_TRUST_POLICY_SCHEMA_VERSION" ]] || {
    release_trust_policy_fail "Release trust policy PolicyVersion must be $RELEASE_TRUST_POLICY_SCHEMA_VERSION, found $policy_version"
    return 1
  }

  configured=$(/usr/bin/plutil -extract Configured raw -expect bool -o - "$policy_path" 2>/dev/null) || {
    release_trust_policy_fail "Release trust policy Configured flag is missing or invalid: $policy_path"
    return 1
  }
  [[ "$configured" == "true" ]] || {
    release_trust_policy_fail "Release trust policy is intentionally unconfigured. Set Configured=true plus the owned Developer ID publisher and TeamIdentifier in $policy_path before release packaging, verification, installation, or upgrade."
    return 1
  }

  team_id=$(/usr/bin/plutil -extract TeamIdentifier raw -expect string -o - "$policy_path" 2>/dev/null) || {
    release_trust_policy_fail "Release trust policy TeamIdentifier is missing or invalid: $policy_path"
    return 1
  }
  [[ ${#team_id} -eq 10 ]] || {
    release_trust_policy_fail "Release trust policy TeamIdentifier must be the exact 10-character Apple Team ID"
    return 1
  }
  print -rn -- "$team_id" | /usr/bin/grep -Eq '^[A-Z0-9]{10}$' || {
    release_trust_policy_fail "Release trust policy TeamIdentifier must contain only uppercase letters and digits"
    return 1
  }

  publisher=$(/usr/bin/plutil -extract Publisher raw -expect string -o - "$policy_path" 2>/dev/null) || {
    release_trust_policy_fail "Release trust policy Publisher is missing or invalid: $policy_path"
    return 1
  }
  [[ -n "$publisher" && "$publisher" != *$'\n'* && "$publisher" != *$'\r'* ]] || {
    release_trust_policy_fail "Release trust policy Publisher must be a non-empty one-line value"
    return 1
  }
  [[ "$publisher" != "Developer ID Application:"* ]] || {
    release_trust_policy_fail "Release trust policy Publisher must not include the Developer ID Application: prefix"
    return 1
  }

  typeset -g RELEASE_TRUST_POLICY_PATH="${policy_path:a}"
  typeset -g RELEASE_TRUST_POLICY_TEAM_ID="$team_id"
  typeset -g RELEASE_TRUST_POLICY_PUBLISHER="$publisher"
  typeset -g RELEASE_TRUST_POLICY_IDENTITY="Developer ID Application: $publisher ($team_id)"
}
