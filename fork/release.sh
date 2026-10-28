#!/usr/bin/env bash
#
# Publishes a release of this fork: an upstream v3 tag plus the 32-bit
# Windows patch, with the module path rewritten so the fork is consumable on
# its own.
#
# The release is tagged <upstream tag>-patched, which sorts after the upstream
# tag it is based on, so `go get github.com/luskaner/wails/v3@latest` picks
# the patched build and not the unpatched upstream one.
#
# Usage:
#   fork/release.sh [--tag <upstream tag>] [--dry-run] [--no-push]
#
#   --tag      upstream tag to patch. Defaults to the latest upstream v3 tag.
#   --dry-run  build and verify everything, but do not push or publish.
#   --no-push  build and verify, push the branch, but do not publish a release.
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

UPSTREAM_TAG=""
FORK_TAG_NAME=""
DRY_RUN=0
PUBLISH=1
REQUIRE_SIGNATURE=0

while [[ $# -gt 0 ]]; do
	case "$1" in
	--tag)
		UPSTREAM_TAG="$2"
		shift 2
		;;
	--tag-name)
		FORK_TAG_NAME="$2"
		shift 2
		;;
	--dry-run)
		DRY_RUN=1
		shift
		;;
	--no-push)
		PUBLISH=0
		shift
		;;
	--require-signature)
		REQUIRE_SIGNATURE=1
		shift
		;;
	*)
		echo "unknown argument: $1" >&2
		exit 2
		;;
	esac
done

PATCH="fork/patches/0001-v3-windows-32bit-runtime-fixes.patch"
BRANCH="patched"
UPSTREAM_REMOTE="https://github.com/wailsapp/wails.git"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
fail() {
	printf '\033[1;31m==> %s\033[0m\n' "$*" >&2
	exit 1
}

[[ -f "$PATCH" ]] || fail "$PATCH is missing"

# ---------------------------------------------------------------------------
# Which upstream release are we patching?
# ---------------------------------------------------------------------------
if [[ -z "$UPSTREAM_TAG" ]]; then
	log "fetching upstream tags"
	git remote get-url upstream >/dev/null 2>&1 ||
		git remote add upstream "$UPSTREAM_REMOTE"
	git fetch --tags --force upstream >/dev/null 2>&1 || true
	# Filter out all patched tags (both -patched and -patched.*)
	UPSTREAM_TAG="$(git tag --list 'v3.*' --sort=-v:refname | grep -v -- '-patched' | head -n 1)"
fi
[[ -n "$UPSTREAM_TAG" ]] || fail "no upstream v3 tag found"

FORK_TAG="${FORK_TAG_NAME:-${UPSTREAM_TAG}-patched}"

# A release is never republished: the go module proxy and the checksum
# database keep the first content they saw for a version forever, so a tag
# that already exists is left alone. An explicit tag name means the caller
# knows what it is doing.
if [[ -z "$FORK_TAG_NAME" ]] && git rev-parse -q --verify "refs/tags/${UPSTREAM_TAG}-patched" >/dev/null; then
	log "${UPSTREAM_TAG} is already released, nothing to do"
	exit 0
fi
if git rev-parse -q --verify "refs/tags/$FORK_TAG" >/dev/null; then
	log "$FORK_TAG already exists, nothing to do"
	exit 0
fi

log "patching upstream ${UPSTREAM_TAG} as ${FORK_TAG}"

# ---------------------------------------------------------------------------
# The upstream tree, the patch and the fork's own files, in a worktree so the
# checkout this script runs from is never touched.
# ---------------------------------------------------------------------------
WORKTREE="${WORKTREE:-$(cd "$ROOT/.." && pwd)/wails-fork-patch}"
cleanup() {
	git worktree remove --force "$WORKTREE" >/dev/null 2>&1 || true
	rm -rf "$WORKTREE"
}
trap cleanup EXIT

# A worktree left behind by an earlier run would be reused with its changes
# still in it, so it is removed before a fresh one is created.
git worktree remove --force "$WORKTREE" >/dev/null 2>&1 || true
rm -rf "$WORKTREE"
git worktree add --detach "$WORKTREE" "$UPSTREAM_TAG" >/dev/null

cd "$WORKTREE"

# The runner has no identity, and the tag needs one. The email is the one of
# the signing key, so GitHub can tie the signature to the account.
git config user.name "${GIT_USER_NAME:-David Fernández Aldana (GitHub)}"
git config user.email "${GIT_USER_EMAIL:-luskaner@gmail.com}"

# The commit and the tag are signed, the same way the ageLANServer releases
# are, so the release can be verified by whoever downloads it. Git does the
# signing, with the gpg program and the keyring it is configured with.
SIGNING_KEY="${GIT_SIGNING_KEY:-$(git config --get user.signingkey || true)}"
signing_works() {
	[[ -n "$1" ]] || return 1
	git -c user.signingkey="$1" -c commit.gpgsign=true \
		commit --allow-empty -q -S -m "probe" >/dev/null 2>&1 || return 1
	git reset -q --hard HEAD >/dev/null 2>&1
	return 0
}
if signing_works "$SIGNING_KEY"; then
	git config user.signingkey "$SIGNING_KEY"
	git config commit.gpgsign true
	git config tag.gpgsign true
	COMMIT_GIT_OPTS=()
	COMMIT_SIGN=(-S)
	TAG_GIT_OPTS=()
	TAG_SIGN=(-s)
	log "signing with $SIGNING_KEY"
else
	# Whatever the environment has configured, the release is not signed.
	COMMIT_GIT_OPTS=(-c commit.gpgsign=false)
	COMMIT_SIGN=()
	TAG_GIT_OPTS=(-c tag.gpgsign=false)
	TAG_SIGN=()
	if [[ $REQUIRE_SIGNATURE -eq 1 ]]; then
		fail "the signing key ${SIGNING_KEY:-none} is not usable and a signed release was required"
	fi
	log "no usable signing key, the release will not be signed"
fi

log "applying $PATCH"
git apply --3way "$ROOT/$PATCH" || fail "the patch does not apply to ${UPSTREAM_TAG}: update $PATCH"

# The fork's own files travel with the release, so the tag is self contained.
# (Only the fork/ directory with patches, release.sh, README.md; not workflows
# because the GitHub token lacks workflows permission and they're not needed in
# the release tag - the fork-release workflow lives in the fork's default branch.)
mkdir -p fork
cp -R "$ROOT/fork/." fork/

# Remove any upstream workflow files that came with the tag (e.g., nightly tags
# include .github/workflows/). The GitHub App token lacks 'workflows' permission
# so we must not include them in the release commit.
rm -rf .github/workflows

# ---------------------------------------------------------------------------
# The patched tree has to build for every Windows architecture.
# ---------------------------------------------------------------------------
if command -v go >/dev/null 2>&1; then
	for arch in 386 amd64 arm64; do
		log "building for windows/${arch}"
		(
			cd v3
			GOOS=windows GOARCH="$arch" CGO_ENABLED=0 go build ./pkg/... ./internal/webview2/...
		) || fail "the patched tree does not build for windows/${arch}"
	done
else
	log "go is not available, skipping the build check"
fi

# ---------------------------------------------------------------------------
# Commit, tag and publish.
# ---------------------------------------------------------------------------
git add -A
# The scripts have to stay executable in the tag, whatever the filesystem the
# release is built on can express.
git update-index --chmod=+x fork/release.sh
git "${COMMIT_GIT_OPTS[@]}" commit "${COMMIT_SIGN[@]}" -m "fix(v3/windows): support 32-bit Windows on ${UPSTREAM_TAG}

Applies the fork patch to ${UPSTREAM_TAG}." >/dev/null

if [[ ${#COMMIT_SIGN[@]} -gt 0 ]]; then
	git verify-commit HEAD >/dev/null || fail "the commit signature does not verify"
fi

if [[ $DRY_RUN -eq 1 ]]; then
	log "dry run, not tagging nor pushing"
	git --no-pager show --stat --oneline HEAD
	exit 0
fi

git "${TAG_GIT_OPTS[@]}" tag "${TAG_SIGN[@]}" -a "$FORK_TAG" -m "${FORK_TAG}: ${UPSTREAM_TAG} with 32-bit Windows support"
if [[ ${#TAG_SIGN[@]} -gt 0 ]]; then
	git verify-tag "$FORK_TAG" >/dev/null || fail "the tag signature does not verify"
fi

log "pushing $FORK_TAG"
git push origin "refs/tags/$FORK_TAG"

# The default branch follows the latest upstream release, so a release built
# for an older tag does not move it backwards.
LATEST_UPSTREAM_TAG="$(git tag --list 'v3.*' --sort=-v:refname | grep -v -- '-patched' | head -n 1)"
if [[ "$UPSTREAM_TAG" == "$LATEST_UPSTREAM_TAG" ]]; then
	git push --force origin "HEAD:refs/heads/master"
else
	log "not the latest upstream release, leaving master alone"
fi

if [[ $PUBLISH -eq 0 ]]; then
	log "not publishing a release"
	exit 0
fi

if ! command -v gh >/dev/null 2>&1; then
	log "gh is not available, skipping the release"
	exit 0
fi

NOTES="$(mktemp)"
cat >"$NOTES" <<EOF
${UPSTREAM_TAG} of [wailsapp/wails](https://github.com/wailsapp/wails) with the
32-bit Windows runtime fixes applied.

Wails v3 does not run on 32-bit Windows: the \`IDropTarget\` COM callbacks take
a \`POINT\` by value, which is wider than a \`uintptr\` on GOARCH=386, and
\`GetWindowLongPtrW\`/\`SetWindowLongPtrW\` are macros that the 32-bit
\`user32.dll\` does not export. Both crash every application at startup. This
release carries the fixes for both.

The patch is the one from [wailsapp/wails#5836](https://github.com/wailsapp/wails/pull/5836)
and is kept in \`fork/patches/\` in this repository, where the release workflow
reapplies it to every new upstream v3 release.

The module keeps its upstream path, so the fork is used with a \`replace\`:

\`\`\`go
require github.com/wailsapp/wails/v3 ${UPSTREAM_TAG}

replace github.com/wailsapp/wails/v3 => github.com/luskaner/wails/v3 ${FORK_TAG}
\`\`\`

Go accepts it because the module declares the path it is replacing, and the
application keeps importing \`github.com/wailsapp/wails/v3/...\` unchanged.
EOF

log "creating the release"
gh release create "$FORK_TAG" \
	--repo luskaner/wails \
	--title "$FORK_TAG" \
	--notes-file "$NOTES" \
	"$ROOT/$PATCH"
rm -f "$NOTES"

log "released $FORK_TAG"
