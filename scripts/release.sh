#!/bin/sh
# fen release helper — drive the two-phase release flow that the protected
# `main` branch and `.github/workflows/release.yml` require.
#
# Because `main` is protected, the VERSION bump must land through a PR before a
# tag can point at it; the tag push is what triggers the release workflow. This
# script splits those into two subcommands and guards the invariants the CI
# release job checks (VERSION == tag), so a bad tag never reaches the runner.
#
# Usage:
#   scripts/release.sh prepare <X.Y.Z> [--push] [--pr]
#       Create a release branch off origin/main, bump VERSION, commit, and
#       (optionally) push the branch and open a PR. Merge that PR first.
#
#   scripts/release.sh tag [--push] [--preflight]
#       From an up-to-date main whose VERSION matches, create the vX.Y.Z tag
#       (and push it with --push, which starts the release workflow).
#
# Environment:
#   REMOTE   git remote to sync against and push to (default: origin)
#
# All git/gh side effects that mutate remotes are opt-in via flags, so a bare
# invocation is a dry run you can inspect before pushing anything.

set -eu

REMOTE="${REMOTE:-origin}"
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

err() {
  echo "release: $*" >&2
  exit 1
}

note() {
  echo "release: $*" >&2
}

require_clean_tree() {
  [ -z "$(git status --porcelain)" ] || err "working tree is dirty; commit or stash first"
}

valid_version() {
  # X.Y.Z with optional -prerelease / +build suffixes (no leading v).
  case "$1" in
    v*) return 1 ;;
  esac
  printf '%s\n' "$1" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$'
}

cmd_prepare() {
  version=""
  do_push=0
  do_pr=0
  for arg in "$@"; do
    case "$arg" in
      --push) do_push=1 ;;
      --pr) do_pr=1 ;;
      -*) err "unknown flag for prepare: $arg" ;;
      *)
        [ -z "$version" ] || err "prepare takes a single version argument"
        version=$arg
        ;;
    esac
  done

  [ -n "$version" ] || err "usage: release.sh prepare <X.Y.Z> [--push] [--pr]"
  valid_version "$version" || err "invalid version '$version' (want X.Y.Z, no leading v)"

  require_clean_tree
  note "fetching $REMOTE"
  git fetch "$REMOTE" --tags --quiet

  tag="v$version"
  if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
    err "tag $tag already exists"
  fi

  branch="release/$tag"
  if git show-ref --quiet "refs/heads/$branch"; then
    err "branch $branch already exists locally"
  fi

  note "creating $branch off $REMOTE/main"
  git checkout -q -b "$branch" "$REMOTE/main"
  printf '%s\n' "$version" > VERSION
  git add VERSION
  git commit -q -m "chore(release): $tag"
  note "committed VERSION=$version on $branch"

  if [ "$do_push" -eq 1 ]; then
    note "pushing $branch to $REMOTE"
    git push -u "$REMOTE" "$branch"
    if [ "$do_pr" -eq 1 ]; then
      command -v gh >/dev/null 2>&1 || err "gh CLI not found; open the PR manually"
      gh pr create \
        --title "chore(release): $tag" \
        --body "Release $tag. Bumps VERSION to $version. Merge, then run: scripts/release.sh tag --push"
    fi
  else
    note "dry run: not pushed. Push with:"
    note "  git push -u $REMOTE $branch"
    [ "$do_pr" -eq 0 ] || note "(add --push to open the PR)"
  fi

  note "next: merge the PR, then run: scripts/release.sh tag --push"
}

cmd_tag() {
  do_push=0
  do_preflight=0
  for arg in "$@"; do
    case "$arg" in
      --push) do_push=1 ;;
      --preflight) do_preflight=1 ;;
      *) err "unknown flag for tag: $arg" ;;
    esac
  done

  branch=$(git rev-parse --abbrev-ref HEAD)
  [ "$branch" = "main" ] || err "tag must run on main (currently on '$branch')"

  require_clean_tree
  note "fetching $REMOTE"
  git fetch "$REMOTE" --tags --quiet

  local_main=$(git rev-parse HEAD)
  remote_main=$(git rev-parse "$REMOTE/main")
  [ "$local_main" = "$remote_main" ] || \
    err "main is not in sync with $REMOTE/main (pull the merged VERSION bump first)"

  [ -f VERSION ] || err "VERSION file is missing"
  version=$(tr -d '[:space:]' < VERSION)
  valid_version "$version" || err "VERSION contents '$version' are not a valid version"
  tag="v$version"

  if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
    err "tag $tag already exists locally"
  fi
  if git ls-remote --exit-code --tags "$REMOTE" "$tag" >/dev/null 2>&1; then
    err "tag $tag already exists on $REMOTE"
  fi

  if [ "$do_preflight" -eq 1 ]; then
    note "running release preflight (nix build checks + artifacts)"
    nix build --no-link --print-out-paths \
      .#checks.x86_64-linux.fennelCheck \
      .#checks.x86_64-linux.tests \
      .#checks.x86_64-linux.fenSmoke
    nix build --no-link --print-out-paths .#fen
  fi

  note "creating annotated tag $tag at $local_main"
  git tag -a "$tag" -m "fen $tag"

  if [ "$do_push" -eq 1 ]; then
    note "pushing $tag to $REMOTE (starts the release workflow)"
    git push "$REMOTE" "$tag"
    note "watch: gh run watch \$(gh run list --workflow=release.yml -L1 --json databaseId -q '.[0].databaseId')"
  else
    note "dry run: tag created locally but not pushed. Push with:"
    note "  git push $REMOTE $tag"
  fi
}

subcmd="${1:-}"
[ -n "$subcmd" ] || err "usage: release.sh <prepare|tag> [...]"
shift

case "$subcmd" in
  prepare) cmd_prepare "$@" ;;
  tag) cmd_tag "$@" ;;
  *) err "unknown subcommand '$subcmd' (want prepare or tag)" ;;
esac
