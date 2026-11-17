#!/usr/bin/env bash
#
# Moves the manifest to GpgFrontend's latest stable release. The workflow
# (.github/workflows/update-release.yml) then proposes the change as a pull
# request, so Flathub builds and offers the update.
#
# "Latest stable" is the latest GitHub release of the upstream repository:
# upstream's github-release.yml publishes one only after checking it against
# the signed update index, and never marks a pre-release as latest.
#
# Per new release this edits the work tree, and nothing else:
#   - pins the release tag and its commit in com.bktus.gpgfrontend.yaml
#   - regenerates cargo-sources.json from the tag's rust/Cargo.lock
# It changes nothing when the manifest already has that commit, or when the
# branch for it (dev/<X.Y.Z>.1) exists already, so a release is proposed once.
#
# When it changed the files, it writes branch, title and body for the pull
# request to GITHUB_OUTPUT (or to stdout, run by hand).
#
# Environment:
#   VERSION   X.Y.Z (or vX.Y.Z) instead of the latest release
#   REPO      this repository on GitHub (default: GITHUB_REPOSITORY, or
#             flathub/com.bktus.gpgfrontend)
#   PYTHON    interpreter with aiohttp and tomlkit (default: python3)
#   GH_TOKEN  for gh, to read the upstream release (read access suffices)

set -euo pipefail

UPSTREAM=saturneric/GpgFrontend
MANIFEST=com.bktus.gpgfrontend.yaml
CARGO_SOURCES=cargo-sources.json
METAINFO=resource/appstream/com.bktus.gpgfrontend.metainfo.xml

# flatpak-builder-tools' cargo generator, pinned; bump both together
GENERATOR_REV=9d86d336a39b9af38b86f114b6ce5820fe260f91
GENERATOR_SHA256=0a2db6be87d75910facef28ab46d4d6460802e8419ab850d0caa6a364d26b380

REPO=${REPO:-${GITHUB_REPOSITORY:-flathub/com.bktus.gpgfrontend}}
PYTHON=${PYTHON:-python3}

log() { printf '%s\n' "$*" >&2; }
die() {
  log "error: $*"
  exit 1
}

cd "$(dirname "$0")/.."

# 1. The release
if [ -n "${VERSION:-}" ]; then
  tag="v${VERSION#v}"
else
  tag=$(gh api "repos/${UPSTREAM}/releases/latest" --jq .tag_name)
fi
[[ ${tag} =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
  die "\"${tag}\" is not a stable release tag (vX.Y.Z)"
version=${tag#v}

# 2. Its commit: the peeled tag, since release tags are annotated
commit=$(git ls-remote "https://github.com/${UPSTREAM}.git" \
  "refs/tags/${tag}^{}" "refs/tags/${tag}" |
  awk 'NR == 1 || /\^\{\}$/ { c = $1 } END { print c }')
[[ ${commit} =~ ^[0-9a-f]{40}$ ]] || die "tag ${tag} not found upstream"

# 3. Already there?
[ "$(grep -cE '^ +commit: [0-9a-f]{40}$' "${MANIFEST}")" = 1 ] ||
  die "expected exactly one pinned commit in ${MANIFEST}"
current=$(sed -nE 's/^ +commit: ([0-9a-f]{40})$/\1/p' "${MANIFEST}")
if [ "${current}" = "${commit}" ]; then
  log "already at ${tag} (${commit})"
  exit 0
fi

# 4. Already proposed?
branch="dev/${version}.1"
if git ls-remote --exit-code --heads "https://github.com/${REPO}.git" \
  "${branch}" >/dev/null; then
  log "branch ${branch} exists on ${REPO}; nothing to do"
  exit 0
fi

log "updating to ${tag} (${commit})"

work=$(mktemp -d)
trap 'rm -rf "${work}"' EXIT

raw() {
  curl -fsSL --retry 3 -o "$2" \
    "https://raw.githubusercontent.com/$1"
}

# 5. The release's own files
raw "${UPSTREAM}/${commit}/rust/Cargo.lock" "${work}/Cargo.lock"
raw "${UPSTREAM}/${commit}/${METAINFO}" "${work}/metainfo.xml"
grep -q "<release version=\"${version}\"" "${work}/metainfo.xml" ||
  die "${tag}'s metainfo has no <release version=\"${version}\">"

# 6. cargo-sources.json
raw "flatpak/flatpak-builder-tools/${GENERATOR_REV}/cargo/flatpak-cargo-generator.py" \
  "${work}/flatpak-cargo-generator.py"
echo "${GENERATOR_SHA256}  ${work}/flatpak-cargo-generator.py" |
  sha256sum -c --quiet - || die "cargo generator does not match its pin"
"${PYTHON}" -I "${work}/flatpak-cargo-generator.py" \
  "${work}/Cargo.lock" -o "${CARGO_SOURCES}"

# 7. The manifest: the tag right before the commit, both in place
sed -i -E "/^ +tag: v[0-9.]+$/d" "${MANIFEST}"
sed -i -E "s/^( +)commit: [0-9a-f]{40}$/\\1tag: ${tag}\\n\\1commit: ${commit}/" \
  "${MANIFEST}"

git --no-pager diff --stat -- "${MANIFEST}" "${CARGO_SOURCES}"

# 8. What the pull request is
{
  echo "branch=${branch}"
  echo "title=Version ${version}.1"
  echo "commit-message<<EOF"
  echo "chore(gpgfrontend): update to ${tag}"
  echo
  echo "- pin GpgFrontend ${tag} (${commit})"
  echo "- regenerate cargo sources from its Cargo.lock"
  echo "EOF"
  echo "body<<EOF"
  echo "Update GpgFrontend to [${tag}](https://github.com/${UPSTREAM}/releases/tag/${tag})."
  echo
  echo "- source: \`${commit}\`"
  echo "- cargo sources regenerated from the tag's \`rust/Cargo.lock\`"
  echo "EOF"
} >>"${GITHUB_OUTPUT:-/dev/stdout}"
