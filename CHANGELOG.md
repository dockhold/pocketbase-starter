# Changelog

Each entry names the PocketBase version this starter pins and says whether
moving to it changes your data. Take a backup before any upgrade (see
"Backups, upgrading, restoring" in the README).

## 0.40.4 (2026-09-18)

Initial release. Pins PocketBase 0.40.4. No data migration.

Template change, same day, same PocketBase version, no data migration:

* Rate limits are on by default with PocketBase's default rules, and the
  visitor address is read from the header Dockhold's edge sets
  (`pb_migrations/1789770000_security_settings.js`). Redeploy picks it up;
  the migration runs once.
* The start script passes the admin email and password after `--`, so a
  value starting with `-` is never read as an option.
