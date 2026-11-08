#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELEASE_SCRIPT="$ROOT_DIR/scripts/release-mcp.sh"
TMPROOT="$(mktemp -d)"
PASSED=0
FAILED=0

cleanup() {
  rm -rf "$TMPROOT"
}
trap cleanup EXIT

pass() {
  echo "✅ $1"
  PASSED=$((PASSED + 1))
}

fail() {
  echo "❌ $1"
  FAILED=$((FAILED + 1))
}

make_fixture() {
  local fixture="$1"
  local remote="$2"

  mkdir -p "$fixture/scripts"
  cp "$RELEASE_SCRIPT" "$fixture/scripts/release-mcp.sh"
  chmod +x "$fixture/scripts/release-mcp.sh"
  cat > "$fixture/package.json" <<'JSON'
{
  "name": "@poorboyai/mcp",
  "version": "1.2.0"
}
JSON
  echo "initial notes" > "$fixture/operator-notes.txt"

  git init --initial-branch=main "$fixture" >/dev/null
  git -C "$fixture" config user.name "MCP Release Test"
  git -C "$fixture" config user.email "mcp-release-test@example.invalid"
  git -C "$fixture" add .
  git -C "$fixture" commit -m "initial" >/dev/null

  git init --bare "$remote" >/dev/null
  git -C "$fixture" remote add origin "$remote"
  git -C "$fixture" push -u origin main >/dev/null
}

package_version() {
  node -p "require('$1/package.json').version"
}

echo "🧪 release-mcp: successful atomic release"
SUCCESS_FIXTURE="$TMPROOT/success"
SUCCESS_REMOTE="$TMPROOT/success.git"
make_fixture "$SUCCESS_FIXTURE" "$SUCCESS_REMOTE"

if (cd "$SUCCESS_FIXTURE" && ./scripts/release-mcp.sh 1.2.1) >/dev/null 2>&1; then
  pass "release command succeeds"
else
  fail "release command should succeed"
fi

if [ "$(package_version "$SUCCESS_FIXTURE")" = "1.2.1" ]; then
  pass "package.json version is updated"
else
  fail "package.json version was not updated"
fi

if [ "$(git -C "$SUCCESS_FIXTURE" log -1 --pretty=%s)" = "chore: release @poorboyai/mcp v1.2.1" ]; then
  pass "release commit uses the exact required message"
else
  fail "release commit message is incorrect"
fi

LOCAL_RELEASE_COMMIT="$(git -C "$SUCCESS_FIXTURE" rev-parse HEAD)"
REMOTE_BRANCH_COMMIT="$(git --git-dir="$SUCCESS_REMOTE" rev-parse refs/heads/main)"
REMOTE_TAG_COMMIT="$(git --git-dir="$SUCCESS_REMOTE" rev-parse 'refs/tags/mcp-v1.2.1^{commit}')"
if [ "$LOCAL_RELEASE_COMMIT" = "$REMOTE_BRANCH_COMMIT" ] &&
   [ "$LOCAL_RELEASE_COMMIT" = "$REMOTE_TAG_COMMIT" ]; then
  pass "branch and matching annotated tag are pushed together"
else
  fail "remote branch and tag do not point to the same release commit"
fi

if [ -z "$(git -C "$SUCCESS_FIXTURE" status --porcelain)" ]; then
  pass "successful release leaves a clean working tree"
else
  fail "successful release left uncommitted changes"
fi

HEAD_BEFORE_INVALID="$(git -C "$SUCCESS_FIXTURE" rev-parse HEAD)"
if (cd "$SUCCESS_FIXTURE" && ./scripts/release-mcp.sh v1.2.2) >/dev/null 2>&1; then
  fail "invalid v-prefixed version should be rejected"
else
  pass "invalid semver is rejected"
fi
if [ "$(git -C "$SUCCESS_FIXTURE" rev-parse HEAD)" = "$HEAD_BEFORE_INVALID" ]; then
  pass "invalid input creates no commit"
else
  fail "invalid input changed repository history"
fi

echo "dirty" > "$SUCCESS_FIXTURE/unrelated.txt"
if (cd "$SUCCESS_FIXTURE" && ./scripts/release-mcp.sh 1.2.2) >/dev/null 2>&1; then
  fail "dirty working tree should be rejected"
else
  pass "dirty working tree is rejected before release"
fi
rm "$SUCCESS_FIXTURE/unrelated.txt"

echo ""
echo "🧪 release-mcp: pre-tag rollback preserves unrelated edits"
ROLLBACK_FIXTURE="$TMPROOT/rollback"
ROLLBACK_REMOTE="$TMPROOT/rollback.git"
make_fixture "$ROLLBACK_FIXTURE" "$ROLLBACK_REMOTE"
ROLLBACK_START="$(git -C "$ROLLBACK_FIXTURE" rev-parse HEAD)"

if git -C "$ROLLBACK_FIXTURE" ls-tree -r --name-only "$ROLLBACK_START" |
   grep -qx "operator-notes.txt"; then
  pass "rollback fixture starts with the unrelated file tracked"
else
  fail "rollback fixture did not commit the unrelated file"
fi

cat > "$ROLLBACK_FIXTURE/.git/hooks/pre-commit" <<'HOOK'
#!/usr/bin/env bash
echo "edited while release was running" > operator-notes.txt
exit 1
HOOK
chmod +x "$ROLLBACK_FIXTURE/.git/hooks/pre-commit"

if (cd "$ROLLBACK_FIXTURE" && ./scripts/release-mcp.sh 1.2.1) >/dev/null 2>&1; then
  fail "pre-commit rejection should fail the release"
else
  pass "pre-tag commit failure is surfaced"
fi

if [ "$(git -C "$ROLLBACK_FIXTURE" rev-parse HEAD)" = "$ROLLBACK_START" ] &&
   [ "$(package_version "$ROLLBACK_FIXTURE")" = "1.2.0" ] &&
   ! git -C "$ROLLBACK_FIXTURE" show-ref --verify --quiet refs/tags/mcp-v1.2.1; then
  pass "incomplete package release is rolled back without a tag"
else
  fail "pre-tag failure left package version, commit, or tag behind"
fi

if [ "$(cat "$ROLLBACK_FIXTURE/operator-notes.txt")" = "edited while release was running" ]; then
  pass "rollback preserves unrelated tracked edits made after preflight"
else
  fail "rollback discarded an unrelated post-start edit"
fi

echo ""
echo "🧪 release-mcp: resume rejects malformed local tags"
LIGHTWEIGHT_FIXTURE="$TMPROOT/lightweight"
LIGHTWEIGHT_REMOTE="$TMPROOT/lightweight.git"
make_fixture "$LIGHTWEIGHT_FIXTURE" "$LIGHTWEIGHT_REMOTE"

node -e '
  const fs = require("node:fs");
  const file = process.argv[1];
  const pkg = JSON.parse(fs.readFileSync(file, "utf8"));
  pkg.version = "1.2.1";
  fs.writeFileSync(file, `${JSON.stringify(pkg, null, 2)}\n`);
' "$LIGHTWEIGHT_FIXTURE/package.json"
git -C "$LIGHTWEIGHT_FIXTURE" add package.json
git -C "$LIGHTWEIGHT_FIXTURE" commit -m "chore: release @poorboyai/mcp v1.2.1" >/dev/null
git -C "$LIGHTWEIGHT_FIXTURE" tag mcp-v1.2.1

if (cd "$LIGHTWEIGHT_FIXTURE" && ./scripts/release-mcp.sh 1.2.1) >/dev/null 2>&1; then
  fail "lightweight release tag should not be accepted for resume"
else
  pass "resume rejects a lightweight release tag"
fi

if [ "$(git -C "$LIGHTWEIGHT_FIXTURE" cat-file -t refs/tags/mcp-v1.2.1)" = "commit" ]; then
  pass "rejected pre-existing lightweight tag is preserved"
else
  fail "resume rejection deleted or rewrote the pre-existing tag"
fi

echo ""
echo "🧪 release-mcp: rejected atomic push remains consistent and retryable"
RETRY_FIXTURE="$TMPROOT/retry"
RETRY_REMOTE="$TMPROOT/retry.git"
make_fixture "$RETRY_FIXTURE" "$RETRY_REMOTE"
START_COMMIT="$(git -C "$RETRY_FIXTURE" rev-parse HEAD)"

cat > "$RETRY_REMOTE/hooks/pre-receive" <<'HOOK'
#!/usr/bin/env bash
while read -r _old _new ref; do
  if [[ "$ref" == refs/tags/mcp-v* ]]; then
    echo "reject release tag for retry test" >&2
    exit 1
  fi
done
HOOK
chmod +x "$RETRY_REMOTE/hooks/pre-receive"

if (cd "$RETRY_FIXTURE" && ./scripts/release-mcp.sh 1.2.1) >/dev/null 2>&1; then
  fail "hook-rejected atomic push should fail"
else
  pass "atomic push rejection is surfaced"
fi

LOCAL_RETRY_COMMIT="$(git -C "$RETRY_FIXTURE" rev-parse HEAD)"
LOCAL_RETRY_TAG="$(git -C "$RETRY_FIXTURE" rev-parse 'refs/tags/mcp-v1.2.1^{commit}')"
REMOTE_RETRY_BRANCH="$(git --git-dir="$RETRY_REMOTE" rev-parse refs/heads/main)"
if [ "$LOCAL_RETRY_COMMIT" = "$LOCAL_RETRY_TAG" ] &&
   [ "$(package_version "$RETRY_FIXTURE")" = "1.2.1" ]; then
  pass "failed push keeps local package commit and tag matched"
else
  fail "failed push left local package and tag divergent"
fi
if [ "$REMOTE_RETRY_BRANCH" = "$START_COMMIT" ] &&
   ! git --git-dir="$RETRY_REMOTE" show-ref --verify --quiet refs/tags/mcp-v1.2.1; then
  pass "atomic rejection leaves both remote refs unchanged"
else
  fail "remote received only part of the rejected release"
fi

rm "$RETRY_REMOTE/hooks/pre-receive"
if (cd "$RETRY_FIXTURE" && ./scripts/release-mcp.sh 1.2.1) >/dev/null 2>&1; then
  pass "same command safely resumes the failed push"
else
  fail "failed release could not be resumed with the same command"
fi

REMOTE_RETRY_BRANCH="$(git --git-dir="$RETRY_REMOTE" rev-parse refs/heads/main)"
REMOTE_RETRY_TAG="$(git --git-dir="$RETRY_REMOTE" rev-parse 'refs/tags/mcp-v1.2.1^{commit}')"
if [ "$REMOTE_RETRY_BRANCH" = "$LOCAL_RETRY_COMMIT" ] &&
   [ "$REMOTE_RETRY_TAG" = "$LOCAL_RETRY_COMMIT" ]; then
  pass "retry atomically publishes the matching branch and tag"
else
  fail "retry did not publish matching remote refs"
fi

echo ""
echo "Results: $PASSED passed, $FAILED failed"
if [ "$FAILED" -ne 0 ]; then
  exit 1
fi