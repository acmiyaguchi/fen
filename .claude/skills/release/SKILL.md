---
name: release
description: Cut a tagged fen release — bump VERSION via PR, then tag main to trigger the release workflow. Use when the user asks to release, tag, or publish a fen version.
user-invocable: true
---

# Release

Use this to publish a tagged `fen` release.
Releases are driven by pushing a `vX.Y.Z` tag, which runs `.github/workflows/release.yml` (checks → per-arch static builds → GitHub Release with `SHA256SUMS`).

Two hard constraints shape the flow:

- The repo-root `VERSION` file is the source of truth for non-CI builds, and the release job **fails** unless `v$(cat VERSION)` equals the pushed tag.
- `main` is protected, so the `VERSION` bump must land through a PR before the tag can point at it.

`scripts/release.sh` encodes both.
Bare invocations are dry runs; remote-mutating steps are opt-in.

## Steps

1. **Pick the version.**
   Choose `X.Y.Z` (semver) from what changed since the last tag:

   ```sh
   git describe --tags --abbrev=0
   git log --oneline "$(git describe --tags --abbrev=0)"..main
   ```

2. **Prepare the bump PR** (branch off `origin/main`, write `VERSION`, commit, push, open PR):

   ```sh
   scripts/release.sh prepare X.Y.Z --push --pr
   # or: make release-prepare VERSION=X.Y.Z PUSH=1
   ```

   Omit `--push`/`--pr` (or `PUSH=1`) first to inspect the dry run.

3. **Merge the PR** once CI is green, then sync main:

   ```sh
   git checkout main && git pull
   ```

4. **Tag and push.**
   This verifies main is in sync and `VERSION` matches, then pushes the tag that starts the release:

   ```sh
   scripts/release.sh tag --push
   # or: make release-tag PUSH=1
   ```

   Add `--preflight` to build the release checks and `.#fen` locally first:

   ```sh
   scripts/release.sh tag --preflight --push
   ```

5. **Watch the workflow** and confirm the release assets and `SHA256SUMS`:

   ```sh
   gh run watch "$(gh run list --workflow=release.yml -L1 --json databaseId -q '.[0].databaseId')"
   gh release view "vX.Y.Z"
   ```

## Guardrails

- Ask the user before step 4; pushing a tag publishes a release.
- `scripts/release.sh` refuses a dirty tree, a mismatched or leading-`v` version, an existing tag, or a `main` that is out of sync with the remote.
  Fix the reported condition rather than forcing past it.
- Never hand-edit `VERSION` and tag separately; the two-phase script keeps them consistent and matches the CI guard.
- For a full local preflight beyond `--preflight`, run `nix flake check` before tagging (the tag workflow uses a narrower gate).

See `docs/distribution.md` ("Releases") for the workflow internals and artifact matrix.
