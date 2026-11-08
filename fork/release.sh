#!/usr/bin/env bash
#
# Publishes patched releases of this fork: an upstream v3 tag plus the 32-bit
# Windows patch, with the module path left as upstream's so the fork can be
# consumed with a `replace` directive.
#
# The release REPLACES the upstream tag of the same name with the patched
# version, so `go get`/`replace` for `github.com/luskaner/wails/v3@<tag>` gets
# the fixed build. This "repairs" the upstream release by overwriting the tag
# in this fork.
#
# The default mode (no --tag) publishes two things: the latest stable upstream
# v3 release and the latest upstream v3 tag overall (the newest nightly/beta).
# Tags that already point at a patched tree are skipped, because the Go module
# proxy freezes the first content it sees for a version: republishing a tag
# that has already been fetched does not change what `go get` returns.
#
# Usage:
#   fork/release.sh [--tag <upstream tag>] [--tag-name <fork tag>]
#                   [--dry-run] [--no-push] [--force] [--list]
#                   [--require-signature]
#
#   --tag      upstream tag to patch. May be repeated. When omitted, the
#              latest stable and the latest pre-release are released.
#   --tag-name fork tag to create instead of the upstream tag name. Only valid
#              with a single --tag. Use it to publish the same upstream release
#              again under a new name when the patch has to change.
#   --dry-run  build and verify everything, but do not tag, push or publish.
#   --no-push  build and tag locally, but do not push the tag nor publish.
#   --force    rebuild and re-push a tag that is already patched. The module
#              proxy keeps serving the old content, so this is only useful to
#              repair the repository itself.
#   --list     print what would be released and exit.
#
# The commit and the tag are signed with GPG when a usable signing key is
# available (the fork-release workflow imports it from the GPG_PRIVATE_KEY and
# PASSPHRASE secrets). Without a usable key the release is published unsigned
# unless --require-signature is given.
#
# This script never pushes the default branch. The release tree is built on a
# detached worktree and published only as a tag: force-pushing it over master
# would delete the fork's workflow files (the release tree drops
# .github/workflows) and stop CI from running at all.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

PATCH="fork/patches/0001-v3-windows-32bit-runtime-fixes.patch"
UPSTREAM_REMOTE="${UPSTREAM_REMOTE:-https://github.com/wailsapp/wails.git}"
FORK_REPO="${FORK_REPO:-luskaner/wails}"
WORKTREE="${WORKTREE:-$(cd "$ROOT/.." && pwd)/wails-fork-patch}"

UPSTREAM_TAGS=()
FORK_TAG_NAME=""
DRY_RUN=0
NO_PUSH=0
FORCE=0
LIST_ONLY=0
REQUIRE_SIGNATURE=0

usage() {
	cat <<'EOF'
Usage:
  fork/release.sh [--tag <upstream tag>] [--tag-name <fork tag>]
                  [--dry-run] [--no-push] [--force] [--list]
                  [--require-signature]

  --tag      upstream tag to patch. May be repeated. When omitted, the
             latest stable and the latest pre-release are released.
  --tag-name fork tag to create instead of the upstream tag name. Only valid
             with a single --tag. Use it to publish the same upstream release
             again under a new name when the patch has to change.
  --dry-run  build and verify everything, but do not tag, push or publish.
  --no-push  build and tag locally, but do not push the tag nor publish.
  --force    rebuild and re-push a tag that is already patched. The module
             proxy keeps serving the old content, so this is only useful to
             repair the repository itself.
  --list     print what would be released and exit.
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	--tag)
		UPSTREAM_TAGS+=("$2")
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
		NO_PUSH=1
		shift
		;;
	--force)
		FORCE=1
		shift
		;;
	--list)
		LIST_ONLY=1
		shift
		;;
	--require-signature)
		REQUIRE_SIGNATURE=1
		shift
		;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		echo "unknown argument: $1" >&2
		usage >&2
		exit 2
		;;
	esac
done

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m==>\033[0m %s\n' "$*" >&2; }
fail() {
	printf '\033[1;31m==> %s\033[0m\n' "$*" >&2
	exit 1
}

[[ -f "$PATCH" ]] || fail "$PATCH is missing"

if [[ -n "$FORK_TAG_NAME" && ${#UPSTREAM_TAGS[@]} -gt 1 ]]; then
	fail "--tag-name can only be used with a single --tag"
fi

# ---------------------------------------------------------------------------
# Git helpers
# ---------------------------------------------------------------------------

cleanup_worktree() {
	git worktree remove --force "$WORKTREE" >/dev/null 2>&1 || true
	rm -rf "$WORKTREE"
}
trap cleanup_worktree EXIT

tag_exists() { git rev-parse -q --verify "$1" >/dev/null 2>&1; }

# A tag belongs to this fork's release scheme when its tree carries the patch.
# Mirrored upstream tags, which are copied into the fork without the patch,
# do not.
tag_is_patched() {
	local ref="$1" commit
	commit="$(git rev-parse -q --verify "${ref}^{commit}" 2>/dev/null)" || return 1
	[[ -n "$(git ls-tree -r --name-only "$commit" -- "$PATCH" 2>/dev/null)" ]]
}

# Upstream tags live in refs/upstream-tags/* and fork tags in refs/fork-tags/*,
# so a patched tag in the fork is never clobbered by the upstream tag with the
# same name.
fetch_tags() {
	log "fetching upstream tags"
	git remote get-url upstream >/dev/null 2>&1 ||
		git remote add upstream "$UPSTREAM_REMOTE"
	git fetch --quiet --force --no-tags upstream '+refs/tags/v3.*:refs/upstream-tags/v3.*' ||
		fail "could not fetch the upstream tags from $UPSTREAM_REMOTE"

	log "fetching fork tags"
	git fetch --quiet --force --no-tags origin '+refs/tags/v3.*:refs/fork-tags/v3.*' ||
		fail "could not fetch the fork tags from origin"
}

latest_tag_by_date() {
	git for-each-ref --sort=-creatordate --count=1 \
		--format='%(refname:lstrip=2)' refs/upstream-tags
}

# Highest v3 release without a prerelease suffix (v3.1.0, not v3.2.0-nightly.*).
latest_stable_tag() {
	local tag
	while IFS= read -r tag; do
		if [[ "$tag" =~ ^v3\.[0-9]+(\.[0-9]+)*$ ]]; then
			printf '%s\n' "$tag"
			return 0
		fi
	done < <(git for-each-ref --sort=-v:refname \
		--format='%(refname:lstrip=2)' refs/upstream-tags)
	return 0
}

select_targets() {
	if [[ ${#UPSTREAM_TAGS[@]} -gt 0 ]]; then
		printf '%s\n' "${UPSTREAM_TAGS[@]}"
		return 0
	fi

	local stable overall
	stable="$(latest_stable_tag)"
	overall="$(latest_tag_by_date)"
	if [[ -n "$stable" ]]; then
		printf '%s\n' "$stable"
	fi
	if [[ -n "$overall" && "$overall" != "$stable" ]]; then
		printf '%s\n' "$overall"
	fi
}

release_exists() {
	command -v gh >/dev/null 2>&1 || return 1
	gh release view "$1" --repo "$FORK_REPO" >/dev/null 2>&1
}

write_notes() {
	local upstream_tag="$1" fork_tag="$2" notes="$3"
	local how_used

	if [[ "$fork_tag" == "$upstream_tag" ]]; then
		how_used="This release REPLACES the upstream tag \`${upstream_tag}\` in this fork with the
patched version. Use it with a \`replace\` directive:"
	else
		how_used="This release is published as \`${fork_tag}\`, a patched copy of the upstream tag
\`${upstream_tag}\`. Use it with a \`replace\` directive:"
	fi

	cat >"$notes" <<EOF
${upstream_tag} of [wailsapp/wails](https://github.com/wailsapp/wails) with the
32-bit Windows runtime fixes applied.

Wails v3 does not run on 32-bit Windows: the \`IDropTarget\` COM callbacks take
a \`POINT\` by value, which is wider than a \`uintptr\` on GOARCH=386, and
\`GetWindowLongPtrW\`/\`SetWindowLongPtrW\` are macros that the 32-bit
\`user32.dll\` does not export. Both crash every application at startup. This
release carries the fixes for both.

The patch is the one from [wailsapp/wails#5836](https://github.com/wailsapp/wails/pull/5836)
and is kept in \`fork/patches/\` in this repository, where the release workflow
reapplies it to every new upstream v3 release.

${how_used}

\`\`\`go
require github.com/wailsapp/wails/v3 ${upstream_tag}

replace github.com/wailsapp/wails/v3 => github.com/luskaner/wails/v3 ${fork_tag}
\`\`\`

Go accepts it because the module declares the path it is replacing, and the
application keeps importing \`github.com/wailsapp/wails/v3/...\` unchanged.
EOF
}

create_release() {
	local upstream_tag="$1" fork_tag="$2" notes

	if [[ $DRY_RUN -eq 1 || $NO_PUSH -eq 1 ]]; then
		log "not publishing the release $fork_tag"
		return 0
	fi
	if ! command -v gh >/dev/null 2>&1; then
		log "gh is not available, skipping the release"
		return 0
	fi
	if [[ $FORCE -eq 1 ]] && release_exists "$fork_tag"; then
		log "deleting the existing release $fork_tag (--force)"
		gh release delete "$fork_tag" --repo "$FORK_REPO" --yes >/dev/null
	fi

	notes="$(mktemp)"
	write_notes "$upstream_tag" "$fork_tag" "$notes"
	log "creating the release $fork_tag"
	gh release create "$fork_tag" \
		--repo "$FORK_REPO" \
		--verify-tag \
		--title "$fork_tag" \
		--notes-file "$notes" \
		"$ROOT/$PATCH"
	rm -f "$notes"

	log "released $fork_tag"
}

# Builds and publishes one upstream tag as a patched fork tag. Returns 0 when
# there is nothing to do (already released) or the work is done.
release_one() {
	local upstream_tag="$1" fork_tag="$2"
	local upstream_ref="refs/upstream-tags/${upstream_tag}"
	local fork_ref="refs/fork-tags/${fork_tag}"
	local upstream_commit push_force=0

	if [[ $LIST_ONLY -eq 1 ]]; then
		upstream_commit="$(git rev-parse -q --verify "${upstream_ref}^{commit}" 2>/dev/null)" ||
			fail "upstream tag ${upstream_tag} is not available; fetch the upstream tags first"
		local state="new"
		if tag_exists "$fork_ref"; then
			if tag_is_patched "$fork_ref"; then state="patched"; else state="unpatched"; fi
		fi
		printf '%s\t%s\t%s\n' "$upstream_tag" "$fork_tag" "$state"
		return 0
	fi

	if tag_exists "$fork_ref"; then
		if tag_is_patched "$fork_ref" && [[ $FORCE -eq 0 ]]; then
			if release_exists "$fork_tag"; then
				log "$fork_tag is already released, nothing to do"
				return 0
			fi
			log "$fork_tag already points at a patched tree, but the GitHub release is missing"
			create_release "$upstream_tag" "$fork_tag"
			return 0
		fi
		if tag_is_patched "$fork_ref"; then
			warn "$fork_tag is already patched; re-publishing it because of --force"
			warn "the Go module proxy may keep serving the old content for this version"
		else
			log "$fork_tag exists in the fork without the patch; repairing it"
		fi
		push_force=1
	fi

	upstream_commit="$(git rev-parse -q --verify "${upstream_ref}^{commit}" 2>/dev/null)" ||
		fail "upstream tag ${upstream_tag} is not available; fetch the upstream tags first"

	log "patching upstream ${upstream_tag} as ${fork_tag}"

	# A worktree left behind by an earlier run would be reused with its changes
	# still in it, so it is removed before a fresh one is created.
	cleanup_worktree
	git worktree add --detach "$WORKTREE" "$upstream_commit" >/dev/null

	(
		cd "$WORKTREE"

		# The runner has no identity, and the tag needs one. The email is the
		# one of the signing key, so GitHub can tie the signature to the account.
		git config user.name "${GIT_USER_NAME:-David Fernández Aldana (GitHub)}"
		git config user.email "${GIT_USER_EMAIL:-luskaner@gmail.com}"

		# The commit and the tag are signed, the same way the ageLANServer
		# releases are, so whoever downloads the module can verify where it
		# comes from. Git does the signing, with the gpg program and the keyring
		# it is configured with.
		SIGNING_KEY="${GIT_SIGNING_KEY:-$(git config --get user.signingkey || true)}"
		signing_works() {
			[[ -n "$1" ]] || return 1
			git -c user.signingkey="$1" -c commit.gpgsign=true \
				commit --allow-empty -q -S -m "probe" >/dev/null 2>&1 || return 1
			# Remove the probe commit again. `git reset --hard HEAD` would keep
			# it, and a leftover probe ends up in the release history.
			git reset -q --hard "$upstream_commit" >/dev/null 2>&1
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
		git apply --3way "$ROOT/$PATCH" ||
			fail "the patch does not apply to ${upstream_tag}: update $PATCH"

		# The fork's own files travel with the release, so the tag is self
		# contained. Only the fork/ directory with the patch, release.sh and
		# README.md are needed at that path.
		mkdir -p fork
		cp -R "$ROOT/fork/." fork/

		# Upstream tags carry their own .github/workflows. The GitHub token has
		# no `workflows` permission, so pushing a tag that creates or updates
		# them is rejected. They are not needed in a release tag anyway: the
		# release workflow lives on the default branch.
		rm -rf .github/workflows

		# The patched tree has to build for every Windows architecture.
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

		git add -A
		# The scripts have to stay executable in the tag, whatever the
		# filesystem the release is built on can express.
		git update-index --chmod=+x fork/release.sh
		git "${COMMIT_GIT_OPTS[@]}" commit "${COMMIT_SIGN[@]}" -m "fix(v3/windows): support 32-bit Windows on ${upstream_tag}

Applies the fork patch to ${upstream_tag}." >/dev/null

		if [[ ${#COMMIT_SIGN[@]} -gt 0 ]]; then
			git verify-commit HEAD >/dev/null || fail "the commit signature does not verify"
		fi

		if [[ $DRY_RUN -eq 1 ]]; then
			log "dry run, not tagging nor pushing"
			git --no-pager show --stat --oneline HEAD
			exit 0
		fi

		# The local tag may exist from a previous fetch of the upstream or the
		# fork tags. It is safe to replace: a patched tag was skipped above.
		git "${TAG_GIT_OPTS[@]}" tag -f "${TAG_SIGN[@]}" -a "$fork_tag" \
			-m "${fork_tag}: ${upstream_tag} with 32-bit Windows support (repaired)" >/dev/null
		if [[ ${#TAG_SIGN[@]} -gt 0 ]]; then
			git verify-tag "$fork_tag" >/dev/null || fail "the tag signature does not verify"
		fi

		if [[ $NO_PUSH -eq 1 ]]; then
			log "not pushing $fork_tag (--no-push)"
			exit 0
		fi

		log "pushing $fork_tag"
		if [[ $push_force -eq 1 ]]; then
			git push --force origin "refs/tags/$fork_tag"
		else
			git push origin "refs/tags/$fork_tag"
		fi
	)

	cleanup_worktree

	if [[ $DRY_RUN -eq 1 || $NO_PUSH -eq 1 ]]; then
		return 0
	fi
	create_release "$upstream_tag" "$fork_tag"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
fetch_tags

if [[ -z "$(git for-each-ref refs/upstream-tags)" ]]; then
	fail "no upstream v3 tags were found"
fi

TARGETS=()
while IFS= read -r tag; do
	if [[ -n "$tag" ]]; then
		TARGETS+=("$tag")
	fi
done < <(select_targets)
[[ ${#TARGETS[@]} -gt 0 ]] || fail "no upstream v3 tag selected"

for tag in "${TARGETS[@]}"; do
	release_one "$tag" "${FORK_TAG_NAME:-$tag}"
done

if [[ $LIST_ONLY -eq 0 ]]; then
	log "done"
fi
