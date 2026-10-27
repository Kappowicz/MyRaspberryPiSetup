#!/usr/bin/env bash
# Run on macOS. Private configuration lives next to this script, outside Git.
set -euo pipefail
umask 077
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${MALINKA_BACKUP_CONFIG:-$SCRIPT_DIR/backup.conf}"
[ -f "$CONFIG" ] || { echo "Copy backup.conf.example to $CONFIG and configure it." >&2; exit 1; }
# shellcheck disable=SC1090
. "$CONFIG"
: "${HOST:?}" "${DRIVE:?}"
LOCAL="${LOCAL:-$HOME/malinka-backups}"
PASSPHRASE="${PASSPHRASE:-$LOCAL/.archive-passphrase}"
OSSL="${OSSL:-/opt/homebrew/bin/openssl}"
ITER="${ITER:-600000}"
mkdir -p "$LOCAL"
[ -s "$PASSPHRASE" ] && [ -x "$OSSL" ] || { echo "Existing passphrase and OpenSSL are required." >&2; exit 1; }
LOCK="$LOCAL/.backup-all.lock"
mkdir "$LOCK" 2>/dev/null || { echo "Backup is already running (lock: $LOCK)." >&2; exit 1; }
TMPD=$(mktemp -d "$LOCAL/.verify.XXXXXXXX")
cleanup() { rm -rf "$TMPD"; rmdir "$LOCK"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
ssh -o ConnectTimeout=10 "$HOST" '$HOME/backup.sh' > "$TMPD/remote.log" 2>&1 || {
  tail -20 "$TMPD/remote.log" >&2; exit 1;
}
NAME=$(sed -n 's/^BACKUP_NAME=//p' "$TMPD/remote.log")
[[ "$NAME" =~ ^malinka-[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6}$ ]] || { echo "Missing/unexpected backup name." >&2; exit 1; }
WORK="$LOCAL/.$NAME.partial"
[ ! -e "$WORK" ] && [ ! -e "$LOCAL/$NAME" ] || { echo "Backup destination already exists." >&2; exit 1; }
mkdir "$WORK"
rsync -a "$HOST:backups/$NAME/" "$WORK/"
[ -s "$WORK/SUCCESS" ] && [ -s "$WORK/SHA256SUMS" ]
(cd "$WORK" && shasum -a 256 -c SHA256SUMS)
# Compare the downloaded manifest itself with the host, too.
ssh "$HOST" "cat backups/$NAME/SHA256SUMS" > "$TMPD/remote-sums"
cmp "$TMPD/remote-sums" "$WORK/SHA256SUMS"
mv "$WORK" "$LOCAL/$NAME"
ENC="$LOCAL/$NAME.tar.gz.enc"
[ ! -e "$ENC" ]
tar czf - -C "$LOCAL" "$NAME" | "$OSSL" enc -aes-256-cbc -pbkdf2 -iter "$ITER" -salt \
  -pass "file:$PASSPHRASE" -out "$ENC.partial"
"$OSSL" enc -d -aes-256-cbc -pbkdf2 -iter "$ITER" -pass "file:$PASSPHRASE" \
  -in "$ENC.partial" | tar xzf - -C "$TMPD"
(cd "$TMPD/$NAME" && shasum -a 256 -c SHA256SUMS)
diff -r "$LOCAL/$NAME" "$TMPD/$NAME"
mv "$ENC.partial" "$ENC"
mkdir -p "$DRIVE"
cp "$ENC" "$DRIVE/.$NAME.tar.gz.enc.partial"
cmp "$ENC" "$DRIVE/.$NAME.tar.gz.enc.partial"
mv "$DRIVE/.$NAME.tar.gz.enc.partial" "$DRIVE/$NAME.tar.gz.enc"
cat > "$DRIVE/HOW-TO-DECRYPT.txt" <<HELP
AES-256-CBC, PBKDF2, $ITER iterations. Keep the passphrase in a password manager.
openssl enc -d -aes-256-cbc -pbkdf2 -iter $ITER -in $NAME.tar.gz.enc | tar xzf - -C /private/restore
After extraction: cd $NAME && shasum -a 256 -c SHA256SUMS
The decrypted archive contains secrets. Extract outside cloud storage.
A matching file in the mounted Drive folder does not prove server-side sync finished.
HELP
# Preserve the existing one-generation policy. Delete only older, completed names.
ssh "$HOST" "bash -s -- '$NAME'" <<'REMOTE'
set -euo pipefail
cd "$HOME/backups"
for path in malinka-*; do
  [[ "$path" =~ ^malinka-[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6}$ ]] || continue
  if [[ "$path" < "$1" ]] && [ -f "$path/SUCCESS" ]; then rm -rf -- "$path"; fi
done
REMOTE
for dir in "$LOCAL" "$DRIVE"; do
  for path in "$dir"/malinka-*; do
    base=$(basename "$path")
    [[ "$base" =~ ^(malinka-[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6})(\.tar\.gz\.enc)?$ ]] || continue
    if [[ "${BASH_REMATCH[1]}" < "$NAME" ]]; then rm -rf -- "$path"; fi
  done
done
printf 'Verified backup: %s (Pi, Mac, mounted Drive folder).\n' "$NAME"
