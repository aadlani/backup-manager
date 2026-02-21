#!/bin/sh
# backup.sh — Incremental backup with rsync, tar, and gpg
#
# A portable backup script that creates timestamped snapshots using rsync
# hard links, compresses old snapshots into daily archives, encrypts them
# with GPG, and rotates daily → weekly → monthly.
#
# Works on both GNU/Linux and macOS (BSD).
#
# Usage:
#   1. Copy backup.conf.example to backup.conf and edit it.
#   2. Run: ./backup.sh
#   3. (Optional) Add to crontab for scheduled runs.

set -eu

# --------------------------------------------------------------------------- #
# Helpers  (also used by the test suite — see __SOURCED__)
# --------------------------------------------------------------------------- #

die() { printf "error: %s\n" "$1" >&2; exit 1; }

log() { printf "[%s] %s\n" "$(date +%Y%m%d%H%M%S)" "$@" >> "$LOGFILE"; }

# Portable "date minus N" — works with both GNU date (-d) and BSD date (-v).
# Usage: date_subtract <format> <unit> <amount>
#   unit: d (days), m (months)
#   amount: positive integer to subtract
#
# Examples:
#   date_subtract "%Y%m%d" d 1    → yesterday in YYYYMMDD
#   date_subtract "%Y%m"  m 1    → last month in YYYYMM
date_subtract() {
    _fmt="$1" _unit="$2" _n="$3"
    # Detect GNU vs BSD date: GNU accepts -d, BSD does not.
    if date -d "now" +%s >/dev/null 2>&1; then
        # GNU date — uses "N day ago" / "N month ago" syntax.
        case "$_unit" in
            d) date -d "$_n day ago"   +"$_fmt" ;;
            m) date -d "$_n month ago" +"$_fmt" ;;
            *) die "date_subtract: unknown unit '$_unit'" ;;
        esac
    else
        # BSD date (macOS) — uses -v flag with relative offsets.
        case "$_unit" in
            d) date -v "-${_n}d" +"$_fmt" ;;
            m) date -v "-${_n}m" +"$_fmt" ;;
            *) die "date_subtract: unknown unit '$_unit'" ;;
        esac
    fi
}

# Portable find with extended regex.
# GNU find: -regextype posix-extended -regex ...
# BSD find: -E ... -regex ...
# Usage: find_ere <dir> [find-args...] -regex <pattern>
find_ere() {
    _dir="$1"; shift
    if find "$_dir" -maxdepth 0 -regextype posix-extended >/dev/null 2>&1; then
        # GNU find
        find "$_dir" -regextype posix-extended "$@"
    else
        # BSD find
        find -E "$_dir" "$@"
    fi
}

# --------------------------------------------------------------------------- #
# Stop here when sourced for testing: `__SOURCED__=1 . ./backup.sh`
# --------------------------------------------------------------------------- #

# shellcheck disable=SC2317  # Reachable when this file is sourced (. ./backup.sh).
if [ "${__SOURCED__:-0}" = "1" ]; then return 0 2>/dev/null || exit 0; fi

# --------------------------------------------------------------------------- #
# Configuration
# --------------------------------------------------------------------------- #

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Load config: look next to the script, then in $HOME.
# shellcheck disable=SC1091  # Config files are user-provided; not available at lint time.
if [ -f "$SCRIPT_DIR/backup.conf" ]; then
    . "$SCRIPT_DIR/backup.conf"
elif [ -f "$HOME/.backup.conf" ]; then
    . "$HOME/.backup.conf"
fi

# Apply defaults for anything not set in the config file.
BACKUP_SOURCE_DIR="${BACKUP_SOURCE_DIR:-$HOME/Documents}"
BACKUP_HOME="${BACKUP_HOME:-$HOME/backups}"
GPG_RECIPIENT="${GPG_RECIPIENT:-}"
RSYNC_EXTRA_OPTS="${RSYNC_EXTRA_OPTS:-}"

# --------------------------------------------------------------------------- #
# Dependency check
# --------------------------------------------------------------------------- #

for cmd in date rsync find tar; do
    command -v "$cmd" >/dev/null 2>&1 || die "$cmd is not installed"
done

if [ -n "$GPG_RECIPIENT" ]; then
    command -v gpg >/dev/null 2>&1 || die "gpg is not installed (needed for encryption)"
fi

# --------------------------------------------------------------------------- #
# Dates — computed once so every step sees the same values
# --------------------------------------------------------------------------- #

NOW="$(date +%Y%m%d%H%M)"           # YYYYMMDDHHMM
YESTERDAY="$(date_subtract %Y%m%d d 1)"
PREVIOUSMONTH="$(date_subtract %Y%m m 1)"

# --------------------------------------------------------------------------- #
# Step 0 — Initialise the directory tree
# --------------------------------------------------------------------------- #

LOGFILE="$BACKUP_HOME/backups.log"
CURRENT_LINK="$BACKUP_HOME/current"
SNAPSHOT_DIR="$BACKUP_HOME/snapshots"
ARCHIVES_DIR="$BACKUP_HOME/archives"
DAILY_ARCHIVES_DIR="$ARCHIVES_DIR/daily"
WEEKLY_ARCHIVES_DIR="$ARCHIVES_DIR/weekly"
MONTHLY_ARCHIVES_DIR="$ARCHIVES_DIR/monthly"

mkdir -p "$SNAPSHOT_DIR" "$DAILY_ARCHIVES_DIR" "$WEEKLY_ARCHIVES_DIR" "$MONTHLY_ARCHIVES_DIR"
: >> "$LOGFILE"   # create if missing, don't truncate

START_TIME="$(date +%s)"
log "Backup started"

# --------------------------------------------------------------------------- #
# Step 1 — Create a snapshot with rsync
# --------------------------------------------------------------------------- #
# rsync copies only what changed.  --link-dest makes unchanged files hard
# links to the previous snapshot, so they consume almost no extra space.

# shellcheck disable=SC2086
rsync -aH --link-dest="$CURRENT_LINK" $RSYNC_EXTRA_OPTS \
    "$BACKUP_SOURCE_DIR" "$SNAPSHOT_DIR/$NOW"
LATEST="$(find "$SNAPSHOT_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | tail -n1)"
if [ -n "$LATEST" ]; then
    ln -snf "$LATEST" "$CURRENT_LINK"
    log "Snapshot $SNAPSHOT_DIR/$NOW created (linked to $CURRENT_LINK)"
fi

# --------------------------------------------------------------------------- #
# Step 2 — Compress yesterday's (and older) snapshots into daily archives
# --------------------------------------------------------------------------- #
# We iterate over snapshot directories, group them by date (first 8 chars of
# the directory name), and archive any group that is older than today.

find "$SNAPSHOT_DIR" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | sort | \
while read -r snap; do
    group="${snap%????}"   # YYYYMMDD (strip HHMM)

    # Only archive snapshots that are at least a day old.
    if [ "$group" -le "$YESTERDAY" ] 2>/dev/null; then
        # Collect all snapshots for that day.
        archive="$DAILY_ARCHIVES_DIR/$group.tar.gz"
        # shellcheck disable=SC2046
        tar -czf "$archive" -C "$SNAPSHOT_DIR" \
            $(cd "$SNAPSHOT_DIR" && ls -d1 "${group}"* 2>/dev/null) \
        && rm -rf "${SNAPSHOT_DIR:?}/${group:?}"* \
        && log "Archived snapshots for $group → $archive"
    fi
done

# --------------------------------------------------------------------------- #
# Step 3 — Encrypt daily archives with GPG
# --------------------------------------------------------------------------- #
# Encrypt any unencrypted .tar.gz files.  Skip this step entirely when no
# GPG_RECIPIENT is configured — the archives stay unencrypted on disk.

if [ -n "$GPG_RECIPIENT" ]; then
    for archive in "$DAILY_ARCHIVES_DIR"/*.tar.gz; do
        [ -e "$archive" ] || continue   # glob matched nothing
        gpg --batch --yes -r "$GPG_RECIPIENT" --encrypt-files "$archive" \
            && rm -f "$archive" \
            && log "Encrypted $(basename "$archive")"
    done
fi

# --------------------------------------------------------------------------- #
# Step 4 — Rotate archives: daily → weekly → monthly
# --------------------------------------------------------------------------- #

# What file extension do we look for?
if [ -n "$GPG_RECIPIENT" ]; then
    ARCHIVE_EXT="tar.gz.gpg"
else
    ARCHIVE_EXT="tar.gz"
fi

# 4.1  Daily → Weekly (for the previous month's archives)
# 4.2  Daily → Monthly (for anything older than the previous month)
find_ere "$DAILY_ARCHIVES_DIR" -type f -mindepth 1 -maxdepth 1 \
    -regex ".*/[0-9]{8}\\.${ARCHIVE_EXT}\$" -exec basename {} \; | sort | \
while read -r f; do
    month="$(echo "$f" | cut -c1-6)"

    if echo "$f" | grep -q "^${PREVIOUSMONTH}"; then
        # Previous month → weekly bucket.
        day="$(echo "$f" | cut -c7-8)"
        # Strip leading zero to avoid octal interpretation in POSIX sh.
        day="${day#0}"
        week=$(( (day - 1) / 7 ))
        dest="$WEEKLY_ARCHIVES_DIR/${PREVIOUSMONTH}.WK_${week}.${ARCHIVE_EXT}"
        mv "$DAILY_ARCHIVES_DIR/$f" "$dest" \
            && log "Rotated $f → weekly ($dest)"
    elif [ "$month" -lt "$PREVIOUSMONTH" ] 2>/dev/null; then
        # Older than previous month → monthly bucket.
        dest="$MONTHLY_ARCHIVES_DIR/${month}.${ARCHIVE_EXT}"
        mv -n "$DAILY_ARCHIVES_DIR/$f" "$dest" \
            && log "Rotated $f → monthly ($dest)"
    fi
done

# 4.3  Weekly → Monthly (weekly archives older than the previous month)
find_ere "$WEEKLY_ARCHIVES_DIR" -type f -mindepth 1 -maxdepth 1 \
    -regex ".*/[0-9]{6}\\.WK_[0-4]\\.${ARCHIVE_EXT}\$" -exec basename {} \; | sort | \
while read -r f; do
    month="$(echo "$f" | cut -c1-6)"
    if [ "$month" -lt "$PREVIOUSMONTH" ] 2>/dev/null; then
        dest="$MONTHLY_ARCHIVES_DIR/${month}.${ARCHIVE_EXT}"
        mv "$WEEKLY_ARCHIVES_DIR/$f" "$dest" \
            && log "Rotated $f → monthly ($dest)"
    fi
done

# --------------------------------------------------------------------------- #
# Done
# --------------------------------------------------------------------------- #

END_TIME="$(date +%s)"
ELAPSED=$((END_TIME - START_TIME))
log "Backup finished in ${ELAPSED}s"
