# Backup Manager

A portable, incremental backup system built entirely from standard Unix
tools.  Originally written for macOS in 2011, now runs on any POSIX system
(Linux, macOS, FreeBSD, ...).

The goal of this project is twofold:

1. **Provide a practical backup solution** — scheduled, incremental,
   snapshot-based, encrypted, and requiring zero manual intervention.
2. **Teach Unix fundamentals by example** — every command, flag, and
   technique used in the script is explained below so newcomers can learn
   real-world shell scripting from a real-world tool.

---

## Features

| Requirement     | How it's met |
|-----------------|-------------|
| **Regular**     | Runs on a cron schedule (e.g. every 30 min) |
| **Unobtrusive** | Runs as a background job, no interaction needed |
| **Incremental** | rsync sends only deltas; hard links deduplicate unchanged files |
| **Snapshots**   | Each run creates a timestamped point-in-time copy |
| **Fast**        | Hard links + delta transfer keep I/O and space minimal |
| **Secure**      | Archives are encrypted with GPG (optional) |
| **Consistent**  | Preserves permissions, timestamps, symlinks, and ownership |

---

## Quick start

```bash
# 1. Clone the repo
git clone https://github.com/aadlani/backup-manager.git
cd backup-manager

# 2. Create your configuration
cp backup.conf.example backup.conf
$EDITOR backup.conf          # set BACKUP_SOURCE_DIR, BACKUP_HOME, etc.

# 3. Run it
./backup.sh

# 4. (Optional) Schedule it with cron — see the cron section below
crontab -e
```

### Dependencies

Only standard Unix utilities — nothing to install on most systems:

- `rsync`
- `tar`
- `find`
- `date`
- `gpg` (only if you enable encryption)

---

## How it works

The script executes five steps in order:

```
 ┌─────────┐     ┌──────────┐     ┌─────────┐     ┌──────────┐
 │ Step 1   │────▶│ Step 2   │────▶│ Step 3   │────▶│ Step 4   │
 │ Snapshot │     │ Compress │     │ Encrypt  │     │ Rotate   │
 └─────────┘     └──────────┘     └─────────┘     └──────────┘
```

1. **Snapshot** — rsync copies the source into a timestamped directory,
   hard-linking unchanged files to the previous snapshot.
2. **Compress** — snapshots older than today are gathered into daily
   `.tar.gz` archives.
3. **Encrypt** — unencrypted archives are encrypted with GPG (skipped if
   `GPG_RECIPIENT` is empty).
4. **Rotate** — daily archives roll into weekly, then monthly buckets.

### Directory layout

```
$BACKUP_HOME/
├── backups.log
├── current -> snapshots/202602211430    # symlink to the latest snapshot
├── snapshots/
│   ├── 202602211400/
│   ├── 202602211430/
│   └── 202602211500/
└── archives/
    ├── daily/
    │   └── 20260220.tar.gz.gpg
    ├── weekly/
    │   └── 202601.WK_2.tar.gz.gpg
    └── monthly/
        └── 202512.tar.gz.gpg
```

---

## Configuration

Copy `backup.conf.example` to one of these locations:

| Priority | Path |
|----------|------|
| 1 | `./backup.conf` (next to the script) |
| 2 | `~/.backup.conf` |

Variables you can set:

| Variable | Default | Purpose |
|----------|---------|---------|
| `BACKUP_SOURCE_DIR` | `$HOME/Documents` | Directory to back up |
| `BACKUP_HOME` | `$HOME/backups` | Where snapshots and archives live |
| `GPG_RECIPIENT` | *(empty — no encryption)* | GPG key email/ID for encrypting archives |
| `RSYNC_EXTRA_OPTS` | *(empty)* | Extra flags for rsync (e.g. `--exclude`) |

---

## Unix tricks explained

The rest of this README walks through the Unix concepts and commands used
in `backup.sh`.  If you are learning the shell, read on.

### Shell strict mode

```sh
set -eu
```

- **`-e`** — exit immediately if any command fails (returns non-zero).
- **`-u`** — treat unset variables as errors instead of silently expanding
  to empty strings.

These two flags catch entire classes of bugs.  Always use them.

> **Note:** `set -o pipefail` is a Bash extension.  The script uses
> `/bin/sh` for maximum portability, so it relies on `set -eu` instead and
> checks pipeline results explicitly.

### Checking for commands

Before doing anything, the script makes sure every required tool is
available:

```sh
for cmd in date rsync find tar; do
    command -v "$cmd" >/dev/null 2>&1 || die "$cmd is not installed"
done
```

- **`command -v`** is the POSIX way to check if a command exists.
  Prefer it over `which`, which behaves differently across systems.
- **`>/dev/null 2>&1`** silences both stdout and stderr — we only care
  about the exit code.

### Date arithmetic across platforms

This is the single biggest portability pitfall in shell scripts.  macOS
ships BSD `date`; Linux ships GNU `date`.  They have completely different
syntax for relative dates.

| What you want | GNU date (Linux) | BSD date (macOS) |
|---------------|-------------------|-------------------|
| Yesterday | `date -d "1 day ago" +%Y%m%d` | `date -v -1d +%Y%m%d` |
| Last month | `date -d "1 month ago" +%Y%m` | `date -v -1m +%Y%m` |

The script detects which variant is available at runtime:

```sh
date_subtract() {
    _fmt="$1" _unit="$2" _n="$3"
    if date -d "now" +%s >/dev/null 2>&1; then
        # GNU date
        case "$_unit" in
            d) date -d "$_n day ago"   +"$_fmt" ;;
            m) date -d "$_n month ago" +"$_fmt" ;;
        esac
    else
        # BSD date
        case "$_unit" in
            d) date -v "-${_n}d" +"$_fmt" ;;
            m) date -v "-${_n}m" +"$_fmt" ;;
        esac
    fi
}
```

**Trick:** the detection itself is just `date -d "now"`.  GNU date accepts
`-d`; BSD date does not.  We test once and branch.

### rsync with hard links

```sh
rsync -aH --link-dest="$CURRENT_LINK" "$BACKUP_SOURCE_DIR" "$SNAPSHOT_DIR/$NOW"
```

| Flag | Meaning |
|------|---------|
| `-a` | Archive mode — recurse, preserve permissions, timestamps, symlinks, owner, group |
| `-H` | Preserve hard links within the source |
| `--link-dest=DIR` | For files unchanged since DIR, create hard links instead of copies |

The `--link-dest` trick is the core of the space efficiency.  A snapshot of
143 MB of data may only use 16 KB of new disk space if almost nothing
changed:

```
$ du -sch backups/snapshots/*
143M  snapshots/202602211400
 16K  snapshots/202602211430
 16K  snapshots/202602211500
178M  total
```

- **`du -s`** — summary (don't recurse into subdirectories)
- **`du -c`** — show a grand total at the end
- **`du -h`** — human-readable sizes (K, M, G)

> **Caveat:** Hard links do not work on NTFS or FAT filesystems (e.g.
> Samba mounts).  rsync will silently fall back to full copies.

### Symbolic links and `ln`

After each snapshot, the script points `current` to the latest one:

```sh
ln -snf "$LATEST" "$CURRENT_LINK"
```

| Flag | Purpose |
|------|---------|
| `-s` | Create a symbolic (soft) link, not a hard link |
| `-n` | If the target is already a symlink to a directory, don't follow it |
| `-f` | Overwrite the existing link |

Without `-n`, `ln` would follow the existing symlink and create a link
*inside* the old snapshot directory instead of replacing the symlink itself.

### Chained commands (`&&`)

```sh
command1 && command2
```

`command2` runs only if `command1` succeeds (exit code 0).  This is used
throughout the script so that destructive operations (like `rm`) only run
after the preceding step completes without error.

### Command substitution

```sh
LATEST="$(ls -1d "$SNAPSHOT_DIR"/* | tail -n1)"
```

`$(...)` runs the enclosed command in a subshell and substitutes its
stdout into the outer command.  Prefer `$(...)` over backticks (`` `...` ``)
because it nests cleanly and is easier to read.

### `find` with extended regex

The rotation step needs to match filenames like `20260220.tar.gz.gpg`.  The
script uses a helper to stay portable:

```sh
find_ere() {
    _dir="$1"; shift
    if find "$_dir" -maxdepth 0 -regextype posix-extended >/dev/null 2>&1; then
        find "$_dir" -regextype posix-extended "$@"    # GNU find
    else
        find -E "$_dir" "$@"                           # BSD find
    fi
}
```

| System | How to enable extended regex |
|--------|-----------------------------|
| GNU find (Linux) | `-regextype posix-extended` |
| BSD find (macOS) | `-E` flag before the path |

### `tar` — create compressed archives

```sh
tar -czf archive.tar.gz -C /parent dir1 dir2
```

| Flag | Meaning |
|------|---------|
| `-c` | Create a new archive |
| `-z` | Compress with gzip |
| `-f` | Write to the given filename |
| `-C` | Change to this directory before adding files (avoids storing absolute paths) |

### GPG encryption

```sh
gpg --batch --yes -r "$GPG_RECIPIENT" --encrypt-files archive.tar.gz
```

| Flag | Meaning |
|------|---------|
| `-r` | Recipient — encrypt so only this key can decrypt |
| `--encrypt-files` | Encrypt every file argument (produces `.gpg` files) |
| `--batch --yes` | Non-interactive mode, skip confirmation prompts |

To decrypt later:

```sh
gpg --decrypt-files archive.tar.gz.gpg
```

You will be prompted for your passphrase.

### Sourcing config files

```sh
. "$SCRIPT_DIR/backup.conf"
```

The dot (`.`) command reads and executes a file in the *current* shell —
meaning any variables set in that file become available to the rest of the
script.  It is the POSIX equivalent of Bash's `source`.

### Variable defaults with `${VAR:-default}`

```sh
BACKUP_HOME="${BACKUP_HOME:-$HOME/backups}"
```

If `BACKUP_HOME` is unset or empty, use `$HOME/backups`.  This is a POSIX
parameter expansion — no external commands needed.

### Redirecting stderr

```sh
command >/dev/null 2>&1
```

- `>/dev/null` — send stdout to the void.
- `2>&1` — redirect file descriptor 2 (stderr) to wherever 1 (stdout)
  currently points (also the void).

The combined effect: silence the command completely.  Useful when you only
care about the exit code.

### String slicing with parameter expansion

```sh
TODAY="${NOW%????}"      # remove last 4 characters
THISMONTH="${TODAY%??}"  # remove last 2 characters
```

`${var%pattern}` removes the shortest match of `pattern` from the *end* of
`$var`.  Each `?` matches one character.  This is POSIX shell — no need for
`cut` or `sed` for simple trimming.

There is also `${var#pattern}` which removes from the *beginning*:

| Syntax | Removes from |
|--------|-------------|
| `${var%pattern}` | End (shortest match) |
| `${var%%pattern}` | End (longest match) |
| `${var#pattern}` | Beginning (shortest match) |
| `${var##pattern}` | Beginning (longest match) |

---

## Scheduling with cron

Edit your crontab:

```sh
crontab -e
```

A cron entry has five time fields followed by the command:

```
*  *  *  *  *    command
┬  ┬  ┬  ┬  ┬
│  │  │  │  └─  day of week   (0-6, Sunday=0)
│  │  │  └────  month         (1-12)
│  │  └───────  day of month  (1-31)
│  └──────────  hour          (0-23)
└─────────────  minute        (0-59)
```

Example — run every 30 minutes during work hours on weekdays:

```
*/30 8-18 * * 1-5  /path/to/backup.sh
```

| Field | Value | Meaning |
|-------|-------|---------|
| `*/30` | every 30 min | the `/` means "every" |
| `8-18` | hours 8–18 | the `-` means a range |
| `1-5` | Mon–Fri | day-of-week range |

**Tip:** use `crontab -l` to list your current entries without opening an
editor.

---

## Restoring files

### From a snapshot (most recent data)

Snapshots are plain directories — just copy what you need:

```sh
cp ~/backups/current/Documents/report.txt ~/Documents/
```

### From an archive

```sh
# Decrypt first (if encrypted)
gpg --decrypt-files ~/backups/archives/daily/20260220.tar.gz.gpg

# Extract
tar -xzf ~/backups/archives/daily/20260220.tar.gz -C /tmp/restore/

# Browse and copy what you need
ls /tmp/restore/
```

---

## License

MIT — see [LICENSE](LICENSE).

---

*Originally published at
[anouar.im](http://anouar.im/2011/12/how-to-backup-with-rsync-tar-gpg-on-osx.html)
in December 2011.*
