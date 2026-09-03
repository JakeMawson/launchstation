#!/bin/zsh

# Internal implementation shared by the production release verifier and the
# test-only fixture harness. This is deliberately not a public CLI: only the
# production wrapper selects the fixed Apple tools and fixed repository policy.

release_verifier_core_fail() {
  print -u2 -- "Release verification refused: $*"
  return 1
}

release_verifier_has_exact_line() {
  local haystack="$1"
  local expected="$2"
  print -r -- "$haystack" | /usr/bin/grep -Fqx -- "$expected"
}

# Arguments:
#   APP POLICY_PATH CODESIGN_TOOL SPCTL_TOOL POLICY_LIBRARY TEST_MODE
# TEST_MODE may only be selected by the test-only harness under Tests/; the
# public verifier always passes production and exposes no override switches.
release_verifier_verify() {
  if (( $# != 6 )); then
    release_verifier_core_fail "internal verifier requires app, policy, codesign, spctl, policy library, and mode"
    return 1
  fi

  local app="$1"
  local policy_path="$2"
  local codesign_tool="$3"
  local spctl_tool="$4"
  local policy_library="$5"
  local mode="$6"
  local expected_bundle_id="com.jakemawson.launchstation"
  local symlink info_plist provenance_plist bundled_policy
  local bundle_id bundle_version provenance_mode provenance_version provenance_team
  local provenance_publisher provenance_identity expected_authority signature_info
  local gatekeeper_assessment timestamp_line timestamp_value

  [[ "$mode" == "production" || "$mode" == "test" ]] || {
    release_verifier_core_fail "internal verifier mode must be production or test"
    return 1
  }
  [[ "$app" == /* ]] || {
    release_verifier_core_fail "--app must be an absolute path"
    return 1
  }
  [[ "$policy_path" == /* && "$policy_library" == /* ]] || {
    release_verifier_core_fail "release trust policy inputs must be absolute paths"
    return 1
  }
  [[ -x "$codesign_tool" && ! -d "$codesign_tool" ]] || {
    release_verifier_core_fail "codesign tool is unavailable: $codesign_tool"
    return 1
  }
  [[ -x "$spctl_tool" && ! -d "$spctl_tool" ]] || {
    release_verifier_core_fail "spctl tool is unavailable: $spctl_tool"
    return 1
  }
  [[ -f "$policy_library" && ! -L "$policy_library" ]] || {
    release_verifier_core_fail "release trust policy loader is missing or unsafe: $policy_library"
    return 1
  }

  source "$policy_library"
  release_trust_policy_load "$policy_path" || {
    release_verifier_core_fail "could not load the fixed release trust policy: $policy_path"
    return 1
  }
  expected_authority="$RELEASE_TRUST_POLICY_IDENTITY"

  [[ -d "$app" && ! -L "$app" ]] || {
    release_verifier_core_fail "application bundle must be a real non-symlink directory: $app"
    return 1
  }
  app="${app:a}"
  [[ "${app:e}" == "app" ]] || {
    release_verifier_core_fail "application bundle must have a .app suffix: $app"
    return 1
  }

  symlink=$(/usr/bin/find "$app" -type l -print -quit 2>/dev/null) || {
    release_verifier_core_fail "could not traverse application bundle safely: $app"
    return 1
  }
  [[ -z "$symlink" ]] || {
    release_verifier_core_fail "application bundle contains a symlink entry: $symlink"
    return 1
  }

  info_plist="$app/Contents/Info.plist"
  provenance_plist="$app/Contents/Resources/BuildProvenance.plist"
  bundled_policy="$app/Contents/Resources/ReleaseTrustPolicy.plist"
  [[ -f "$info_plist" && ! -L "$info_plist" ]] || {
    release_verifier_core_fail "application Info.plist is missing or unsafe: $info_plist"
    return 1
  }
  [[ -f "$provenance_plist" && ! -L "$provenance_plist" ]] || {
    release_verifier_core_fail "release provenance is missing; this is not a release package: $provenance_plist"
    return 1
  }
  [[ -f "$bundled_policy" && ! -L "$bundled_policy" ]] || {
    release_verifier_core_fail "signed release trust policy is missing from the candidate bundle: $bundled_policy"
    return 1
  }
  /usr/bin/cmp -s "$policy_path" "$bundled_policy" || {
    release_verifier_core_fail "candidate release trust policy does not exactly match the fixed local trust anchor"
    return 1
  }

  bundle_id=$(/usr/bin/plutil -extract CFBundleIdentifier raw -expect string -o - "$info_plist" 2>/dev/null) || {
    release_verifier_core_fail "application bundle identifier could not be read"
    return 1
  }
  [[ "$bundle_id" == "$expected_bundle_id" ]] || {
    release_verifier_core_fail "application bundle identifier must be $expected_bundle_id, found $bundle_id"
    return 1
  }
  bundle_version=$(/usr/bin/plutil -extract CFBundleShortVersionString raw -expect string -o - "$info_plist" 2>/dev/null) || {
    release_verifier_core_fail "application bundle version could not be read"
    return 1
  }
  [[ -n "$bundle_version" ]] || {
    release_verifier_core_fail "application bundle version is empty"
    return 1
  }

  provenance_mode=$(/usr/bin/plutil -extract BuildMode raw -expect string -o - "$provenance_plist" 2>/dev/null) || {
    release_verifier_core_fail "release provenance BuildMode is missing or invalid"
    return 1
  }
  provenance_version=$(/usr/bin/plutil -extract PackageVersion raw -expect string -o - "$provenance_plist" 2>/dev/null) || {
    release_verifier_core_fail "release provenance PackageVersion is missing or invalid"
    return 1
  }
  provenance_team=$(/usr/bin/plutil -extract TeamIdentifier raw -expect string -o - "$provenance_plist" 2>/dev/null) || {
    release_verifier_core_fail "release provenance TeamIdentifier is missing or invalid"
    return 1
  }
  provenance_publisher=$(/usr/bin/plutil -extract Publisher raw -expect string -o - "$provenance_plist" 2>/dev/null) || {
    release_verifier_core_fail "release provenance Publisher is missing or invalid"
    return 1
  }
  provenance_identity=$(/usr/bin/plutil -extract SigningIdentity raw -expect string -o - "$provenance_plist" 2>/dev/null) || {
    release_verifier_core_fail "release provenance SigningIdentity is missing or invalid"
    return 1
  }

  [[ "$provenance_mode" == "release" ]] || {
    release_verifier_core_fail "BuildProvenance.plist identifies this as $provenance_mode, not a notarized release"
    return 1
  }
  [[ "$provenance_version" == "$bundle_version" ]] || {
    release_verifier_core_fail "release provenance PackageVersion does not match the application bundle version"
    return 1
  }
  [[ "$provenance_team" == "$RELEASE_TRUST_POLICY_TEAM_ID" ]] || {
    release_verifier_core_fail "release provenance TeamIdentifier does not match the fixed trusted team"
    return 1
  }
  [[ "$provenance_publisher" == "$RELEASE_TRUST_POLICY_PUBLISHER" ]] || {
    release_verifier_core_fail "release provenance Publisher does not match the fixed trusted publisher"
    return 1
  }
  [[ "$provenance_identity" == "$expected_authority" ]] || {
    release_verifier_core_fail "release provenance SigningIdentity does not match the fixed trusted Developer ID identity"
    return 1
  }

  if [[ "$mode" == "test" ]]; then
    MOCK_RELEASE_EXPECTED_APP="$app" "$codesign_tool" --verify --deep --strict --verbose=2 "$app" >/dev/null 2>&1 || {
      release_verifier_core_fail "strict nested code-signature verification failed"
      return 1
    }
    signature_info=$(MOCK_RELEASE_EXPECTED_APP="$app" "$codesign_tool" -d --verbose=4 "$app" 2>&1) || {
      release_verifier_core_fail "could not inspect the application signing identity"
      return 1
    }
    gatekeeper_assessment=$(MOCK_RELEASE_EXPECTED_APP="$app" "$spctl_tool" --assess --type execute --verbose=4 "$app" 2>&1) || {
      release_verifier_core_fail "Gatekeeper rejected the application bundle: $gatekeeper_assessment"
      return 1
    }
  else
    "$codesign_tool" --verify --deep --strict --verbose=2 "$app" >/dev/null 2>&1 || {
      release_verifier_core_fail "strict nested code-signature verification failed"
      return 1
    }
    signature_info=$("$codesign_tool" -d --verbose=4 "$app" 2>&1) || {
      release_verifier_core_fail "could not inspect the application signing identity"
      return 1
    }
    gatekeeper_assessment=$("$spctl_tool" --assess --type execute --verbose=4 "$app" 2>&1) || {
      release_verifier_core_fail "Gatekeeper rejected the application bundle: $gatekeeper_assessment"
      return 1
    }
  fi

  release_verifier_has_exact_line "$signature_info" "Identifier=$expected_bundle_id" || {
    release_verifier_core_fail "signed bundle identifier is not $expected_bundle_id"
    return 1
  }
  release_verifier_has_exact_line "$signature_info" "TeamIdentifier=$RELEASE_TRUST_POLICY_TEAM_ID" || {
    release_verifier_core_fail "signed TeamIdentifier is not the fixed trusted team"
    return 1
  }
  release_verifier_has_exact_line "$signature_info" "Authority=$expected_authority" || {
    release_verifier_core_fail "signed leaf authority is not the fixed trusted Developer ID publisher/team"
    return 1
  }
  if ! print -r -- "$signature_info" | /usr/bin/grep -F 'flags=' | /usr/bin/grep -Fq '(runtime)'; then
    release_verifier_core_fail "signed application is missing the hardened runtime flag"
    return 1
  fi
  timestamp_line=$(print -r -- "$signature_info" | /usr/bin/grep -E '^Timestamp=' | /usr/bin/head -n 1 || true)
  timestamp_value="${timestamp_line#Timestamp=}"
  if [[ -z "$timestamp_line" || -z "$timestamp_value" || "${timestamp_value:l}" == "none" ]]; then
    release_verifier_core_fail "signed application is missing a secure timestamp"
    return 1
  fi

  if ! print -r -- "$gatekeeper_assessment" | /usr/bin/grep -Fqx 'source=Notarized Developer ID'; then
    release_verifier_core_fail "Gatekeeper did not report a Notarized Developer ID source"
    return 1
  fi

  print "Release verified: $app"
}
