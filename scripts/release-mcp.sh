#!/usr/bin/env bash
#
# Release @poorboyai/mcp with one atomic branch+tag push.
#
# Usage:
#   ./scripts/release-mcp.sh 1.2.3
#
# The working tree must be clean. If the atomic push is rejected, the matching
# local release commit and tag are kept so the same command can be rerun safely.

set -Eeuo pipefail

if [ "$#" -ne 1 ]; then
  echo "Usage: $0 <version>" >&2
  exit 2
fi

VERSION="$1"
if [[ ! "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
  echo "Usage: $0 <version>" >&2
  echo "Version must be stable SemVer in X.Y.Z format (for example, 1.2.3)." >&2
  exit 2
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE_PATH="package.json"
PACKAGE_JSON="$ROOT_DIR/$PACKAGE_PATH"
TAG="mcp-v${VERSION}"
COMMIT_MESSAGE="chore: release @poorboyai/mcp v${VERSION}"
REMOTE="${MCP_RELEASE_REMOTE:-origin}"

cd "$ROOT_DIR"

if ! git rev-parse --show-toplevel >/dev/null 2>&1; then
  echo "❌ release-mcp: $ROOT_DIR is not a Git repository." >&2
  exit 1
fi

if [ "$(git rev-parse --show-toplevel)" != "$ROOT_DIR" ]; then
  echo "❌ release-mcp: script must live at the repository root under scripts/." >&2
  exit 1
fi

if [ ! -f "$PACKAGE_JSON" ]; then
  echo "❌ release-mcp: package file not found: $PACKAGE_PATH" >&2
  exit 1
fi

BRANCH="$(git symbolic-ref --quiet --short HEAD || true)"
if [ -z "$BRANCH" ]; then
  echo "❌ release-mcp: releases require a checked-out branch, not detached HEAD." >&2
  exit 1
fi

if [ -n "$(git status --porcelain)" ]; then
  echo "❌ release-mcp: working tree is not clean. Commit or stash changes first." >&2
  exit 1
fi

if ! git remote get-url "$REMOTE" >/dev/null 2>&1; then
  echo "❌ release-mcp: Git remote '$REMOTE' is not configured." >&2
  exit 1
fi

if ! git ls-remote "$REMOTE" >/dev/null 2>&1; then
  echo "❌ release-mcp: cannot reach Git remote '$REMOTE'." >&2
  exit 1
fi

CURRENT_VERSION="$(
  node -e '
    const pkg = require(process.argv[1]);
    if (pkg.name !== "@poorboyai/mcp" || typeof pkg.version !== "string") process.exit(1);
    process.stdout.write(pkg.version);
  ' "$PACKAGE_JSON"
)" || {
  echo "❌ release-mcp: $PACKAGE_PATH is not the @poorboyai/mcp package." >&2
  exit 1
}

START_HEAD="$(git rev-parse HEAD)"
RELEASE_COMMIT=""
RELEASE_TAG_READY=0
RESUMING=0
LOCAL_RELEASE_STARTED=0
RELEASE_PACKAGE_BLOB=""

rollback_incomplete_release() {
  local status=$?
  trap - EXIT

  if [ "$status" -ne 0 ] &&
     [ "$RELEASE_TAG_READY" -eq 0 ] &&
     [ "$LOCAL_RELEASE_STARTED" -eq 1 ]; then
    local current_head
    current_head="$(git rev-parse HEAD)"

    # If interruption landed immediately after tag creation, preserve the
    # complete annotated release pair rather than rewinding one side of it.
    if git show-ref --verify --quiet "refs/tags/$TAG" &&
       [ "$(git cat-file -t "refs/tags/$TAG" 2>/dev/null || true)" = "tag" ] &&
       [ "$(git rev-parse "${TAG}^{commit}" 2>/dev/null || true)" = "$current_head" ] &&
       [ "$(git for-each-ref --format='%(subject)' "refs/tags/$TAG")" = "$COMMIT_MESSAGE" ]; then
      echo "release-mcp: complete local release commit/tag pair preserved for retry." >&2
      exit "$status"
    fi

    local worktree_package_blob=""
    if [ -f "$PACKAGE_JSON" ]; then
      worktree_package_blob="$(git hash-object "$PACKAGE_JSON" 2>/dev/null || true)"
    fi

    # Move HEAD only when it is provably the exact one-file commit this helper
    # just created. --soft preserves unrelated staged and working-tree edits.
    local changed_paths=""
    changed_paths="$(git diff-tree --no-commit-id --name-only -r "$current_head" 2>/dev/null || true)"
    if [ "$current_head" != "$START_HEAD" ] &&
       [ "$(git rev-parse "${current_head}^" 2>/dev/null || true)" = "$START_HEAD" ] &&
       [ "$(git log -1 --pretty=%s "$current_head")" = "$COMMIT_MESSAGE" ] &&
       [ "$changed_paths" = "$PACKAGE_PATH" ]; then
      git reset --soft "$START_HEAD" >/dev/null
    fi

    if [ -n "$RELEASE_PACKAGE_BLOB" ] &&
       [ "$worktree_package_blob" = "$RELEASE_PACKAGE_BLOB" ]; then
      # The package still contains exactly our generated update, so restoring
      # this one path cannot discard another process's later edit.
      git restore --source="$START_HEAD" --staged --worktree -- "$PACKAGE_PATH"
    else
      # Preserve any later package edit in the worktree; only remove our staged
      # release version from the index.
      git restore --source="$START_HEAD" --staged -- "$PACKAGE_PATH" 2>/dev/null || true
      echo "release-mcp: preserved a concurrent package.json edit for manual review." >&2
    fi

    echo "release-mcp: rolled back only the helper-owned incomplete release changes." >&2
  fi

  exit "$status"
}
trap rollback_incomplete_release EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [ "$CURRENT_VERSION" = "$VERSION" ]; then
  # A failed atomic push intentionally leaves a complete local commit+tag pair.
  # Recognize only that exact pair so rerunning this command is safe.
  if ! git show-ref --verify --quiet "refs/tags/$TAG"; then
    echo "❌ release-mcp: package.json is already $VERSION but local tag $TAG is missing." >&2
    exit 1
  fi

  if [ "$(git cat-file -t "refs/tags/$TAG" 2>/dev/null || true)" != "tag" ]; then
    echo "❌ release-mcp: local tag $TAG must be annotated, not lightweight." >&2
    exit 1
  fi

  RELEASE_COMMIT="$(git rev-parse "${TAG}^{commit}")"
  if [ "$RELEASE_COMMIT" != "$START_HEAD" ] ||
     [ "$(git log -1 --pretty=%s "$START_HEAD")" != "$COMMIT_MESSAGE" ] ||
     [ "$(git for-each-ref --format='%(subject)' "refs/tags/$TAG")" != "$COMMIT_MESSAGE" ]; then
    echo "❌ release-mcp: existing version/tag is not the expected release commit." >&2
    exit 1
  fi

  RELEASE_TAG_READY=1
  RESUMING=1
  echo "ℹ️  release-mcp: resuming atomic push for $TAG."
else
  if git show-ref --verify --quiet "refs/tags/$TAG"; then
    echo "❌ release-mcp: local tag $TAG already exists." >&2
    exit 1
  fi

  if [ -n "$(git ls-remote --tags "$REMOTE" "refs/tags/$TAG")" ]; then
    echo "❌ release-mcp: remote tag $TAG already exists on $REMOTE." >&2
    exit 1
  fi

  if [ -z "$(git config user.name)" ] || [ -z "$(git config user.email)" ]; then
    echo "❌ release-mcp: Git user.name and user.email must be configured." >&2
    exit 1
  fi

  LOCAL_RELEASE_STARTED=1
  TARGET_VERSION="$VERSION" PACKAGE_JSON="$PACKAGE_JSON" node <<'NODE'
const fs = require("node:fs");
const file = process.env.PACKAGE_JSON;
const version = process.env.TARGET_VERSION;
const pkg = JSON.parse(fs.readFileSync(file, "utf8"));
pkg.version = version;
fs.writeFileSync(file, `${JSON.stringify(pkg, null, 2)}\n`);
NODE

  RELEASE_PACKAGE_BLOB="$(git hash-object "$PACKAGE_JSON")"
  git add -- "$PACKAGE_PATH"
  git commit -m "$COMMIT_MESSAGE" -- "$PACKAGE_PATH"
  RELEASE_COMMIT="$(git rev-parse HEAD)"
  git tag -a "$TAG" -m "$COMMIT_MESSAGE" "$RELEASE_COMMIT"
  RELEASE_TAG_READY=1
fi

# One atomic ref transaction means the remote receives both the release commit
# and matching tag, or neither. GitHub supports atomic pushes.
if ! git push --atomic "$REMOTE" \
  "HEAD:refs/heads/$BRANCH" \
  "refs/tags/$TAG:refs/tags/$TAG"; then
  echo "❌ release-mcp: atomic push failed; remote refs were not partially updated." >&2
  echo "   Resolve the push issue, then rerun: ./scripts/release-mcp.sh $VERSION" >&2
  exit 1
fi

trap - EXIT INT TERM
if [ "$RESUMING" -eq 1 ]; then
  echo "✅ Resumed and published $TAG from existing release commit $RELEASE_COMMIT."
else
  echo "✅ Released @poorboyai/mcp v$VERSION as $TAG ($RELEASE_COMMIT)."
fi