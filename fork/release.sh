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
	UPSTREAM_TAG="$(git tag --list 'v3.*' --sort=-v:refname | grep -v -- '-patched$' | head -n 1)"
fi
[[ -n "$UPSTREAM_TAG" ]] || fail "no upstream v3 tag found"

FORK_TAG="${FORK_TAG_NAME:-${UPSTREAM_TAG}-patched}"

# A release is never republished: the go module proxy and the checksum
# database keep the first content they saw for a version forever, so a tag
# that already exists is left alone.
if git tag --list "${UPSTREAM_TAG}-patched*" | grep -q .; then
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

# The runner has no identity, and the tag needs one.
git config user.name "${GIT_USER_NAME:-luskaner}"
git config user.email "${GIT_USER_EMAIL:-luskaner@users.noreply.github.com}"

# The commit and the tag are signed, the same way the ageLANServer releases
# are, so the release can be verified by whoever downloads it.
SIGNING_KEY="${GIT_SIGNING_KEY:-$(git config --get user.signingkey || true)}"
if [[ -n "$SIGNING_KEY" ]]; then
	git config user.signingkey "$SIGNING_KEY"
	git config commit.gpgsign true
	git config tag.gpgsign true
	SIGN_COMMIT=(-S)
	log "signing with $SIGNING_KEY"
else
	SIGN_COMMIT=()
	if [[ $REQUIRE_SIGNATURE -eq 1 ]]; then
		fail "no signing key configured and a signed release was required"
	fi
	log "no signing key configured, the release will not be signed"
fi

log "applying $PATCH"
git apply --3way "$ROOT/$PATCH" || fail "the patch does not apply to ${UPSTREAM_TAG}: update $PATCH"

# The fork's own files travel with the release, so the tag is self contained.
mkdir -p fork .github/workflows
cp -R "$ROOT/fork/." fork/
cp "$ROOT/.github/workflows/fork-release.yml" .github/workflows/

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
git commit "${SIGN_COMMIT[@]}" -m "fix(v3/windows): support 32-bit Windows on ${UPSTREAM_TAG}

Applies the fork patch to ${UPSTREAM_TAG}." >/dev/null

if [[ ${#SIGN_COMMIT[@]} -gt 0 ]]; then
	git verify-commit HEAD >/dev/null || fail "the commit signature does not verify"
fi

if [[ $DRY_RUN -eq 1 ]]; then
	log "dry run, not tagging nor pushing"
	git --no-pager show --stat --oneline HEAD
	exit 0
fi

if [[ ${#SIGN_COMMIT[@]} -gt 0 ]]; then
	git tag -s -a "$FORK_TAG" -m "${FORK_TAG}: ${UPSTREAM_TAG} with 32-bit Windows support"
	git verify-tag "$FORK_TAG" >/dev/null || fail "the tag signature does not verify"
else
	git tag -a "$FORK_TAG" -m "${FORK_TAG}: ${UPSTREAM_TAG} with 32-bit Windows support"
fi

log "pushing $FORK_TAG"
git push origin "refs/tags/$FORK_TAG"
git push --force origin "HEAD:refs/heads/$BRANCH"

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
