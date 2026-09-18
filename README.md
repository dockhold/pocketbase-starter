# PocketBase on Dockhold

[PocketBase](https://pocketbase.io) is a backend in one file: a database, user
accounts, file uploads, a REST API, and an admin panel. This template runs the
maintained upstream binary (version 0.40.4) on [Dockhold](https://dockhold.eu)
and adds a start script that wires it to Dockhold's port, App storage, and
your admin account. Nothing else is changed. Deploy it as it is, or use it as
the starting point for your own backend.

[![Deploy to Dockhold](https://img.shields.io/badge/Deploy%20to-Dockhold-2563eb?style=for-the-badge)](https://app.dockhold.eu/new?repo=https://github.com/dockhold/pocketbase-starter&name=pocketbase)

## Deploy

1. Open the [Deploy link](https://app.dockhold.eu/new?repo=https://github.com/dockhold/pocketbase-starter&name=pocketbase)
   and sign in if asked.
2. On the **Size** tab, turn on **App storage** (10 GB) and start at
   **256 MB** of memory. The free plan is enough.
3. On the **Secrets** tab, add two secrets and map them to the variable names
   PocketBase expects. Give the entries names that belong to this app, for
   example `pocketbase-admin-email` and `pocketbase-admin-password`, because
   secrets are shared across your apps by name and two PocketBase apps that
   share an entry would share a password.

   | Secret entry (your name) | Variable name | Value |
   | --- | --- | --- |
   | `pocketbase-admin-email` | `PB_ADMIN_EMAIL` | The email you will sign in with |
   | `pocketbase-admin-password` | `PB_ADMIN_PASSWORD` | 8 to 71 characters |

4. Click **Deploy** and wait until the app shows as running.
5. Open `https://<your app>/_/` and sign in with that email and password.

If the app refuses to start, its page shows one line saying what is missing
(App storage, or one of the two secrets). Fix it and click **Restart**.

## Two ways to use it

**Run PocketBase.** Deploy this repository as it is. You get a hosted
PocketBase with an admin panel, and you build your schema in that panel.
**Redeploy** rebuilds from this repository's `main`, so you pick up starter
updates when you choose to. `main` only moves for documented upgrades; see
[CHANGELOG.md](CHANGELOG.md) and "Backups, upgrading, restoring" below.

**Develop your backend.** Click **Use this template** on GitHub to make your
own copy, connect that repository in Dockhold, and deploy it. From then on
every push redeploys the app. Put server-side logic in `pb_hooks/`, schema
changes in `pb_migrations/`, and a static frontend in `pb_public/`. The
repository's own checks (`.github/workflows/check.yml`) run on every push to
your copy.

Only the second path gives you push-to-deploy. The first path never reads
your GitHub account.

## Try it

Open `https://<your app>/api/collections/notes/records` in a private browser
window. It returns one record. The `notes` collection is created by the
migration shipped in `pb_migrations/`: anyone can read it, only superusers can
change it. Now add a record in the admin panel and refresh the private window.

## Your admin account

The start script creates or updates one superuser from `PB_ADMIN_EMAIL` and
`PB_ADMIN_PASSWORD` on every start, before PocketBase starts listening. The
values on the Secrets tab are always the ones that work.

| What you do | What happens |
| --- | --- |
| Change the password on the Secrets tab, then **Restart** | The new password works. |
| Change the password inside PocketBase (Settings > Admins) | It works until the next restart, then the Secrets tab value is back. Change it on the Secrets tab instead. |
| Change `PB_ADMIN_EMAIL`, then **Restart** | A second superuser is created. The old one stays until you remove it in Settings > Admins. |
| Delete the managed admin inside PocketBase | It is recreated on the next restart. |
| Create other superusers inside PocketBase | They are never touched. |
| Set a value that PocketBase rejects (not an email, a password under 8 or over 71 characters) | The app refuses to start and its page says why. The previous login keeps working once you fix the value and restart. |

**Sessions.** A password change signs out every existing admin session for
that account, whether the change was made on the Secrets tab or inside
PocketBase. So does a plain **Restart** or **Redeploy** with the password
unchanged, because the start script re-saves the managed account each time.
Sign in again. Sessions of other superusers, and of your app's users, are not
affected.

## Migrations and the admin panel

Schema changes you make in the hosted admin panel are saved on App storage.
They are not written back to GitHub. To version a schema change, add a
migration file to `pb_migrations/` and push (Develop path). Migrations run on
the next deploy; PocketBase remembers which ones already ran. Both ways work
at the same time, and neither loses the other's changes. The shipped
migration is a small example of the file shape.

## Settings

* `PB_ORIGINS` (optional). A comma-separated list of origins allowed to call
  the API from a browser. Unset, any origin is allowed, because an API is
  usually called from a site on another address. Set it when you want to
  restrict that.
* **Email** (password resets, verification) needs an SMTP server. Configure
  it in Settings > Mail settings in the admin panel.
* **File uploads** are stored on App storage next to the database.

Dockhold sets `PORT` and `DATA_DIR` itself. Do not add them.

## Backups, upgrading, restoring

**Your backup set** is the `pb_data` folder on App storage plus the two
secrets. The easiest way to take one is Settings > Backups in the admin panel,
which writes a zip you can download or send to S3. App storage is not a
backup of itself: take one before you upgrade and on a schedule.

**Upgrading.** Take a backup first. On the Run path, click **Redeploy** after
this repository's `main` has moved; the [CHANGELOG](CHANGELOG.md) entry says
whether the upgrade changes your data. On the Develop path, change both
`PB_VERSION` and `PB_SHA256` in the `Dockerfile` (the sha256 is on the
PocketBase release page in `checksums.txt`) and push. PocketBase is pre-1.0:
upstream does not guarantee compatibility between releases, and some
upgrades need manual migration steps. Read the release notes.

If the app comes back on the previous version after an upgrade (Dockhold
rolls a deploy back when the new version does not become healthy), do not
keep using it: an old version on data a newer version already changed is
not safe. Restore the backup, then retry the upgrade.

**Restoring.** Deploy the version the backup was taken with, then upload
and restore the backup in Settings > Backups. On the Develop path you pin
that version in the `Dockerfile`. The Run path always builds the current
`main`, so to go back to an older version, switch to the Develop path and pin
it there.

## Limitations

* One running copy while App storage is attached. PocketBase keeps its
  database in a file, so this is also what PocketBase expects.
* Email does nothing until you configure SMTP in the admin panel.
* Realtime subscriptions (server-sent events) are not yet covered by this
  template's checks.

## License

PocketBase is MIT licensed
([upstream LICENSE](https://github.com/pocketbase/pocketbase/blob/v0.40.4/LICENSE.md)).
This template's glue (Dockerfile, start script, workflows, README, the
example migration and static page) is MIT too, see [LICENSE](LICENSE).

## Full walkthrough

[Deploy PocketBase](https://dockhold.eu/docs/recipes/deploy-pocketbase): the
step-by-step recipe.
