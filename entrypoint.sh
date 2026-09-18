#!/bin/sh
# Start script for PocketBase on Dockhold.
#
# Dockhold hands this app a port (PORT) and, when App storage is turned on, a
# folder that survives restarts (DATA_DIR). The admin email and password come
# from the Secrets tab as PB_ADMIN_EMAIL and PB_ADMIN_PASSWORD. This script
# checks those, creates or updates the admin account, and then hands over to
# PocketBase. It reads only PORT, DATA_DIR, PB_ADMIN_EMAIL, PB_ADMIN_PASSWORD
# and PB_ORIGINS, and it never prints a secret value.
#
# Every check below fails with one line and exit code 1. Dockhold shows that
# line on the app page, so the line is the whole error message.
set -eu

# 1. App storage.
#
# PocketBase keeps everything (database, uploads, settings) in one folder.
# Without App storage that folder would be gone after the next restart, so
# the app refuses to start instead of starting empty. There is no fallback to
# a folder inside the image, on purpose: it would look like it works and lose
# every record on the first restart.
storage_missing() {
  echo "This app keeps its data on App storage. Turn on App storage in the Size tab and redeploy." >&2
  exit 1
}
[ -n "${DATA_DIR:-}" ] || storage_missing
case "$DATA_DIR" in /*) ;; *) storage_missing ;; esac
[ -d "$DATA_DIR" ] || storage_missing
[ -w "$DATA_DIR" ] || storage_missing
# Permission bits can say "writable" on a folder that is mounted read-only.
# Creating and removing a file is the only check that cannot be fooled.
probe="$DATA_DIR/.dockhold-write-check.$$"
( : > "$probe" ) 2>/dev/null || storage_missing
rm -f "$probe"

PB_DATA="$DATA_DIR/pb_data"

# 2. Secrets.
#
# Both values must be present and non-empty. The check runs before anything
# listens: PocketBase without a superuser would print a setup link that
# anyone who reaches the URL first could use, and this script never lets it
# get that far. The values themselves are never printed.
missing=""
[ -n "${PB_ADMIN_EMAIL:-}" ] || missing="PB_ADMIN_EMAIL"
[ -n "${PB_ADMIN_PASSWORD:-}" ] || missing="${missing:+$missing and }PB_ADMIN_PASSWORD"
if [ -n "$missing" ]; then
  echo "$missing is missing or empty. Add PB_ADMIN_EMAIL and PB_ADMIN_PASSWORD as secrets on this app's Secrets tab and restart." >&2
  exit 1
fi

# 3. The admin account, before the listener.
#
# "upsert" creates the superuser when the email is new and sets its password
# when it already exists. It runs on every start, so the values on the
# Secrets tab are always the ones that work: change the password there and
# restart, and the new one works; change it inside PocketBase, and the next
# restart puts the Secrets tab value back. A superuser with a different email
# is never deleted here; remove old ones in Settings > Admins.
#
# The success line echoes the email, so stdout goes to /dev/null. On a bad
# value (not an email, password shorter than 8 or longer than 71 characters)
# PocketBase says why on stderr and the script stops here with exit code 1.
# The same folders are passed as for the server below, so PocketBase looks
# in exactly one place for hooks and migrations in both steps.
/app/pocketbase superuser upsert "$PB_ADMIN_EMAIL" "$PB_ADMIN_PASSWORD" \
  --dir "$PB_DATA" \
  --hooksDir /app/pb_hooks \
  --migrationsDir /app/pb_migrations \
  --automigrate=false \
  >/dev/null

# 4. Established-install marker.
#
# Written only after every check above passed, so it exists on a storage
# folder that has actually run this template. It lives under .dockhold so
# PocketBase's own layout stays untouched. Its presence means "an existing
# installation": nothing in this script ever wipes or re-seeds a folder,
# with or without the marker; the marker is there for support and for
# telling which version last ran on this storage.
version=$(/app/pocketbase --version)
version=${version##* }
mkdir -p "$DATA_DIR/.dockhold"
chmod 0700 "$DATA_DIR/.dockhold"
printf 'pocketbase-starter %s\n' "$version" > "$DATA_DIR/.dockhold/template"

# 5. Hand over to PocketBase.
#
# exec makes PocketBase the main process, so the stop signal from the
# platform reaches it directly and it closes the database cleanly.
# --automigrate=false: a schema change made in the admin panel is saved to
# the database on App storage and is not written out as a file (the image
# is read-only, and such a file would never reach your repo anyway).
# Migrations come from pb_migrations/ in the repo and run on every start;
# PocketBase remembers which ones already ran.
# --origins is left at PocketBase's default (any origin) unless PB_ORIGINS
# is set, because an API is usually called from a site on another origin.
exec /app/pocketbase serve \
  --http "0.0.0.0:${PORT:-8090}" \
  --dir "$PB_DATA" \
  --hooksDir /app/pb_hooks \
  --migrationsDir /app/pb_migrations \
  --publicDir /app/pb_public \
  --automigrate=false \
  ${PB_ORIGINS:+--origins "$PB_ORIGINS"}
