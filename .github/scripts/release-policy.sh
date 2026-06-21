#!/usr/bin/env bash

# Shared helpers for the release pipeline (release-intake / release-guard /
# post-merge-release). This project derives its release version purely from the
# git tag at build time: release.yml extracts it from the vX.Y.Z tag and passes
# it to the OpenWrt build. The Makefile NORDVPN_EASY_DEFAULT_VERSION is only a
# fallback for local builds, so there is NO in-repo version file to bump and NO
# manifest assertions here.

# Keep this regex identical to the SemVer check in release.yml so the two never
# disagree. release.yml accepts ONLY strict vX.Y.Z (no prerelease suffix), so we
# must too: creating an immutable vX.Y.Z-rc1 tag here would be refused by the
# release build, leaving a stuck immutable tag.
RELEASE_TAG_REGEX='^v[0-9]+\.[0-9]+\.[0-9]+$'
# Unprotected trigger tag that starts a release. It deliberately does NOT match
# the v* glob (release.yml / a tag-immutability ruleset), so it can be created and
# deleted freely; the real vX.Y.Z tag is CREATED ONCE on the squash commit by
# post-merge-release (a tag creation, which a tag-immutability ruleset allows).
PR_TAG_REGEX='^pr-v[0-9]+\.[0-9]+\.[0-9]+$'

die() {
  echo "::error::$*" >&2
  exit 1
}

notice() {
  echo "::notice::$*"
}

is_release_tag() {
  [[ "${1:-}" =~ ${RELEASE_TAG_REGEX} ]]
}

validate_release_tag() {
  local tag="${1:-}"

  if ! is_release_tag "${tag}"; then
    die "Invalid release tag '${tag}'. Allowed format is vX.Y.Z."
  fi
}

is_pr_tag() {
  [[ "${1:-}" =~ ${PR_TAG_REGEX} ]]
}

# pr-vX.Y.Z -> vX.Y.Z (the release tag that will be CREATED at merge).
release_tag_from_pr_tag() {
  local pr_tag="${1:-}"

  if ! is_pr_tag "${pr_tag}"; then
    die "Invalid trigger tag '${pr_tag}'. Expected pr-vX.Y.Z."
  fi
  printf '%s\n' "${pr_tag#pr-}"
}

# vX.Y.Z -> X.Y.Z (the value written into the package Makefiles).
version_from_tag() {
  local tag="${1:-}"

  validate_release_tag "${tag}"
  printf '%s\n' "${tag#v}"
}

# This project keeps its version in the two OpenWrt package Makefiles, not in a
# single manifest: NORDVPN_EASY_DEFAULT_VERSION must be identical in both (the
# lockstep test tests/nordvpn-easy/test-package-lockstep.sh enforces it). The
# release tag is the source of truth and the pipeline keeps both Makefiles in
# sync with it (mirrors addhОn's manifest.json handling). The built artifact
# takes its version from the tag via release.yml regardless; the Makefile default
# is the version for local/manual SDK builds and for repo correctness.
BACKEND_MAKEFILE="openwrt-packages/nordvpn-easy/Makefile"
LUCI_MAKEFILE="openwrt-packages/luci-app-nordvpn-easy/Makefile"

# Read NORDVPN_EASY_DEFAULT_VERSION from the backend Makefile at a git ref
# (same extraction idiom as the lockstep test's extract_make_var).
package_version_at_ref() {
  local ref="${1:-}"

  git show "${ref}:${BACKEND_MAKEFILE}" \
    | sed -n 's/^NORDVPN_EASY_DEFAULT_VERSION:=//p' | head -n 1
}

# Set NORDVPN_EASY_DEFAULT_VERSION to ${version} in BOTH Makefiles (working tree).
set_package_version() {
  local version="${1:-}"
  local makefile

  for makefile in "${BACKEND_MAKEFILE}" "${LUCI_MAKEFILE}"; do
    sed -i "s/^NORDVPN_EASY_DEFAULT_VERSION:=.*/NORDVPN_EASY_DEFAULT_VERSION:=${version}/" "${makefile}"
  done
}

# Assert both Makefiles' default version at ${ref} equals the tag's version
# (also covers the lockstep invariant that the two files agree).
assert_package_version_matches_tag() {
  local ref="${1:-}"
  local tag="${2:-}"
  local expected backend luci

  expected="$(version_from_tag "${tag}")"
  backend="$(git show "${ref}:${BACKEND_MAKEFILE}" | sed -n 's/^NORDVPN_EASY_DEFAULT_VERSION:=//p' | head -n 1)"
  luci="$(git show "${ref}:${LUCI_MAKEFILE}" | sed -n 's/^NORDVPN_EASY_DEFAULT_VERSION:=//p' | head -n 1)"

  if [[ "${backend}" != "${expected}" ]]; then
    die "backend Makefile version '${backend}' does not match tag '${tag}' (expected '${expected}')."
  fi
  if [[ "${luci}" != "${expected}" ]]; then
    die "luci-app Makefile version '${luci}' does not match tag '${tag}' (expected '${expected}')."
  fi
}

# Success if the given commit is contained in (ancestor of, or equal to)
# origin/main. The caller MUST `git fetch origin main` first.
tag_commit_on_main() {
  git merge-base --is-ancestor "${1:-}" origin/main
}

extract_pr_marker() {
  local marker="${1:-}"

  python3 - "${marker}" <<'PY'
import os
import re
import sys

marker = sys.argv[1]
body = os.environ.get("PR_BODY", "")
pattern = rf"^<!-- {re.escape(marker)}: ([^<\n]+) -->$"
match = re.search(pattern, body, re.MULTILINE)
if not match:
    sys.exit(1)
print(match.group(1).strip())
PY
}

delete_remote_tag() {
  local tag="${1:-}"

  # Best-effort cleanup of the unprotected trigger tag. Stays non-fatal, but a
  # transient failure is surfaced as a warning: if the pr-vX.Y.Z tag is left
  # behind, re-pushing the same trigger is a no-op (ref unchanged) and won't
  # re-fire intake, so the leftover needs manual deletion before re-releasing.
  git push origin ":refs/tags/${tag}" || \
    echo "::warning::Failed to delete tag ${tag} (non-fatal); it may need manual cleanup before this version can be re-released."
}

# Existence probes that DISTINGUISH absent from error. A transient auth/network
# failure must never be silently read as "does not exist" (which would defeat the
# preflight / immutability gates). Echo: present|absent|error.

remote_tag_state() {
  local tag="${1:-}"
  local rc=0
  # git ls-remote --exit-code: 0 = ref found, 2 = no matching ref, other = failure.
  git ls-remote --exit-code --tags origin "refs/tags/${tag}" >/dev/null 2>&1 || rc=$?
  case "${rc}" in
    0) echo "present" ;;
    2) echo "absent" ;;
    *) echo "error" ;;
  esac
}

remote_release_state() {
  local tag="${1:-}"
  local out
  local rc=0
  out="$(gh api "repos/${GITHUB_REPOSITORY}/releases/tags/${tag}" 2>&1)" || rc=$?
  if [[ "${rc}" -eq 0 ]]; then
    echo "present"
  elif printf '%s' "${out}" | grep -qi 'HTTP 404\|Not Found'; then
    echo "absent"
  else
    echo "error"
  fi
}

# Hard gates: die on "present" AND on "error" (fail closed). Used where the only
# acceptable state to proceed is a confirmed "absent".
assert_release_tag_absent() {
  local tag="${1:-}"
  case "$(remote_tag_state "${tag}")" in
    present) die "Tag ${tag} already exists and is immutable." ;;
    error)   die "Could not determine whether tag ${tag} exists (git ls-remote failed); aborting." ;;
  esac
}

assert_release_absent() {
  local tag="${1:-}"
  case "$(remote_release_state "${tag}")" in
    present) die "Release ${tag} already exists." ;;
    error)   die "Could not determine whether release ${tag} exists (gh api failed); aborting." ;;
  esac
}
