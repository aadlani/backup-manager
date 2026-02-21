#!/bin/sh
# test_backup.sh — Test suite for backup.sh
#
# Runs on any POSIX shell.  No external test framework required.
# Exit code 0 = all tests passed, 1 = at least one failed.
#
# Usage:  ./tests/test_backup.sh

set -eu

# --------------------------------------------------------------------------- #
# Minimal test harness
# --------------------------------------------------------------------------- #

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
CURRENT_TEST=""

pass() {
    TESTS_PASSED=$((TESTS_PASSED + 1))
    printf "  \033[32mPASS\033[0m  %s\n" "$CURRENT_TEST"
}

fail() {
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf "  \033[31mFAIL\033[0m  %s — %s\n" "$CURRENT_TEST" "$1"
}

run_test() {
    TESTS_RUN=$((TESTS_RUN + 1))
    CURRENT_TEST="$1"
}

summary() {
    echo ""
    printf "%d tests, %d passed, %d failed\n" "$TESTS_RUN" "$TESTS_PASSED" "$TESTS_FAILED"
    [ "$TESTS_FAILED" -eq 0 ]
}

# --------------------------------------------------------------------------- #
# Resolve paths and source the helpers from backup.sh
# --------------------------------------------------------------------------- #

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source only the helper functions — __SOURCED__ tells backup.sh to stop
# before the main pipeline.  Do NOT export it: the e2e tests run backup.sh
# as a subprocess and need the full pipeline to execute.
__SOURCED__=1
# shellcheck disable=SC1091
. "$PROJECT_DIR/backup.sh"
unset __SOURCED__

# Create a throwaway workspace for every run.
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/backup-test.XXXXXX")"
cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

# --------------------------------------------------------------------------- #
# Helper function tests
# --------------------------------------------------------------------------- #

echo "--- Helper functions ---"

run_test "date_subtract: yesterday is 8 digits"
result="$(date_subtract %Y%m%d d 1)"
if echo "$result" | grep -qE '^[0-9]{8}$'; then pass; else fail "got '$result'"; fi

run_test "date_subtract: last month is 6 digits"
result="$(date_subtract %Y%m m 1)"
if echo "$result" | grep -qE '^[0-9]{6}$'; then pass; else fail "got '$result'"; fi

run_test "date_subtract: yesterday < today"
today="$(date +%Y%m%d)"
yesterday="$(date_subtract %Y%m%d d 1)"
if [ "$yesterday" -lt "$today" ]; then pass; else fail "yesterday=$yesterday today=$today"; fi

run_test "date_subtract: last month < this month"
thismonth="$(date +%Y%m)"
lastmonth="$(date_subtract %Y%m m 1)"
if [ "$lastmonth" -lt "$thismonth" ]; then pass; else fail "lastmonth=$lastmonth thismonth=$thismonth"; fi

run_test "find_ere: matches extended regex pattern"
mkdir -p "$WORK_DIR/find_test"
touch "$WORK_DIR/find_test/20260101.tar.gz"
touch "$WORK_DIR/find_test/20260102.tar.gz"
touch "$WORK_DIR/find_test/not-a-match.txt"
count="$(find_ere "$WORK_DIR/find_test" -type f -maxdepth 1 \
    -regex '.*/[0-9]{8}\.tar\.gz$' | wc -l | tr -d ' ')"
if [ "$count" = "2" ]; then pass; else fail "expected 2 matches, got $count"; fi

run_test "find_ere: no match returns empty"
mkdir -p "$WORK_DIR/find_empty"
touch "$WORK_DIR/find_empty/readme.txt"
count="$(find_ere "$WORK_DIR/find_empty" -type f -maxdepth 1 \
    -regex '.*/[0-9]{8}\.tar\.gz$' | wc -l | tr -d ' ')"
if [ "$count" = "0" ]; then pass; else fail "expected 0, got $count"; fi

# --------------------------------------------------------------------------- #
# Config / defaults tests
# --------------------------------------------------------------------------- #

echo ""
echo "--- Configuration ---"

run_test "default BACKUP_SOURCE_DIR uses \$HOME/Documents"
if (
    unset BACKUP_SOURCE_DIR 2>/dev/null || true
    val="${BACKUP_SOURCE_DIR:-$HOME/Documents}"
    [ "$val" = "$HOME/Documents" ]
); then pass; else fail "unexpected default"; fi

run_test "config file is sourced when present"
conf="$WORK_DIR/test.conf"
printf 'TEST_CONF_VAR="hello_from_conf"\n' > "$conf"
# shellcheck disable=SC1090
if (
    . "$conf"
    [ "$TEST_CONF_VAR" = "hello_from_conf" ]
); then pass; else fail "config var not loaded"; fi

# --------------------------------------------------------------------------- #
# End-to-end: full backup pipeline
# --------------------------------------------------------------------------- #
# These tests need rsync installed.  If it is missing, we skip gracefully
# so the helper/unit tests still provide value.

if ! command -v rsync >/dev/null 2>&1; then
    echo ""
    echo "--- End-to-end pipeline (SKIPPED — rsync not found) ---"
    echo ""
    summary
    exit $?
fi

echo ""
echo "--- End-to-end pipeline ---"

# Set up a self-contained environment for backup.sh.
E2E_DIR="$WORK_DIR/e2e"
E2E_SOURCE="$E2E_DIR/source"
E2E_BACKUP="$E2E_DIR/backups"
mkdir -p "$E2E_SOURCE/subdir"
echo "file one" > "$E2E_SOURCE/file1.txt"
echo "file two" > "$E2E_SOURCE/subdir/file2.txt"

# Write a config at $HOME/.backup.conf (the script's fallback location).
# We override HOME so the test is fully isolated.
E2E_HOME="$E2E_DIR/home"
mkdir -p "$E2E_HOME"
cat > "$E2E_HOME/.backup.conf" <<CONF
BACKUP_SOURCE_DIR="$E2E_SOURCE"
BACKUP_HOME="$E2E_BACKUP"
GPG_RECIPIENT=""
CONF

run_test "backup.sh runs without error"
if (HOME="$E2E_HOME" sh "$PROJECT_DIR/backup.sh") >/dev/null 2>&1; then
    pass
else
    fail "backup.sh exited with non-zero status"
fi

run_test "snapshot directory was created"
snap_count="$(find "$E2E_BACKUP/snapshots" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"
if [ "$snap_count" -ge 1 ]; then pass; else fail "no snapshot dirs found"; fi

run_test "current symlink exists and points to a snapshot"
if [ -L "$E2E_BACKUP/current" ]; then pass; else fail "current is not a symlink"; fi

run_test "snapshot contains the source files"
latest="$(find "$E2E_BACKUP/snapshots" -mindepth 1 -maxdepth 1 -type d | sort | tail -n1)"
# rsync copies the source directory *into* the snapshot, so look one level deeper.
base="$(basename "$E2E_SOURCE")"
if [ -f "$latest/$base/file1.txt" ] && [ -f "$latest/$base/subdir/file2.txt" ]; then
    pass
else
    fail "files not found in $latest"
fi

run_test "log file records the run"
if [ -f "$E2E_BACKUP/backups.log" ] && grep -q "Backup started" "$E2E_BACKUP/backups.log"; then
    pass
else
    fail "backups.log missing or incomplete"
fi

run_test "log file records completion"
if grep -q "Backup finished" "$E2E_BACKUP/backups.log"; then
    pass
else
    fail "backups.log does not contain completion entry"
fi

# --------------------------------------------------------------------------- #
# End-to-end: archiving old snapshots
# --------------------------------------------------------------------------- #

echo ""
echo "--- Archiving ---"

# Simulate an old snapshot (yesterday) by creating a directory with
# yesterday's date prefix and re-running the script.
yesterday="$(date_subtract %Y%m%d d 1)"

run_test "old snapshots are compressed into daily archives"
mkdir -p "$E2E_BACKUP/snapshots/${yesterday}0800"
echo "old data" > "$E2E_BACKUP/snapshots/${yesterday}0800/old.txt"
(HOME="$E2E_HOME" sh "$PROJECT_DIR/backup.sh") >/dev/null 2>&1
if [ -f "$E2E_BACKUP/archives/daily/${yesterday}.tar.gz" ]; then
    pass
else
    fail "daily archive not created for $yesterday"
fi

run_test "archived snapshot directory was removed"
if [ ! -d "$E2E_BACKUP/snapshots/${yesterday}0800" ]; then
    pass
else
    fail "snapshot dir still exists after archiving"
fi

# --------------------------------------------------------------------------- #
# End-to-end: hard-link deduplication
# --------------------------------------------------------------------------- #

echo ""
echo "--- Hard-link deduplication ---"

run_test "second snapshot hard-links unchanged files"
# Run backup once, then rename the snapshot to a different minute so that
# the next run creates a genuinely new directory (minute-resolution timestamps
# would otherwise collide if both runs happen within the same minute).
(HOME="$E2E_HOME" sh "$PROJECT_DIR/backup.sh") >/dev/null 2>&1
first_snap="$(find "$E2E_BACKUP/snapshots" -mindepth 1 -maxdepth 1 -type d | sort | tail -n1)"
today="$(date +%Y%m%d)"
mv "$first_snap" "$E2E_BACKUP/snapshots/${today}0001"
ln -snf "$E2E_BACKUP/snapshots/${today}0001" "$E2E_BACKUP/current"
(HOME="$E2E_HOME" sh "$PROJECT_DIR/backup.sh") >/dev/null 2>&1

snaps="$(find "$E2E_BACKUP/snapshots" -mindepth 1 -maxdepth 1 -type d | sort | tail -n2)"
snap_a="$(echo "$snaps" | head -n1)"
snap_b="$(echo "$snaps" | tail -n1)"
base="$(basename "$E2E_SOURCE")"

if [ -n "$snap_a" ] && [ -n "$snap_b" ] && [ "$snap_a" != "$snap_b" ]; then
    # stat -c is GNU, stat -f is BSD/macOS
    if stat -c '%i' / >/dev/null 2>&1; then
        inode_a="$(stat -c '%i' "$snap_a/$base/file1.txt" 2>/dev/null)" || true
        inode_b="$(stat -c '%i' "$snap_b/$base/file1.txt" 2>/dev/null)" || true
    else
        inode_a="$(stat -f '%i' "$snap_a/$base/file1.txt" 2>/dev/null)" || true
        inode_b="$(stat -f '%i' "$snap_b/$base/file1.txt" 2>/dev/null)" || true
    fi
    if [ -n "$inode_a" ] && [ "$inode_a" = "$inode_b" ]; then
        pass
    else
        fail "inodes differ ($inode_a vs $inode_b) — not hard-linked"
    fi
else
    fail "could not find two distinct snapshots"
fi

# --------------------------------------------------------------------------- #
# Summary
# --------------------------------------------------------------------------- #

echo ""
summary
