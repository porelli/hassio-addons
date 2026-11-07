# Firefox Sync

Your own Firefox Sync server: bookmarks, passwords, history, tabs and add-ons sync through
your Home Assistant instead of Mozilla's servers. This add-on is the
[firefox-sync](https://github.com/porelli/firefox-sync) stack in one container: Mozilla's
syncstorage-rs (the Sync server and its tokenserver), its database migrations, the init step
that enforces the maximum number of users, and the firefox-sync admin UI, in the Home Assistant
sidebar.

Firefox still signs in with a Mozilla account: Mozilla's (the default), or your own with the
**Mozilla accounts (self-hosted)** add-on of this repository.

## Before you start

- **A host name with HTTPS** that reaches this add-on's Sync port, for example
  `https://sync.example.com`. Firefox refuses a Sync server without HTTPS. The
  [NGINX Proxy Manager](https://github.com/hassio-addons/addon-nginx-proxy-manager) add-on
  does it: a proxy host for `sync.example.com` to this add-on (its host name on the add-on
  network is shown on the add-on's Info page, or use your Home Assistant host's address and the
  Sync port below). In its **Advanced** tab add `client_max_body_size 10m;`: Firefox sends
  batches of up to 2.5 MB, and nginx refuses more than 1 MB by default.
- **A database.** By default the add-on runs its own MariaDB inside the container. To keep the
  data in the official **MariaDB** add-on instead, install and start it first, then turn
  `sync_db_containers` off (see below).

## Installation

1. Add this repository to the add-on store, install **Firefox Sync**.
1. Set `sync_public_url` to your public HTTPS URL, then start the add-on.
1. Check the log: the last lines of the start say `Current users: N`, then the Sync server
   starts. Nothing reaches the Sync server before the user limit is in place.
1. Open the admin UI from the sidebar (**Firefox Sync**).
1. In Firefox, open `about:config`, set `identity.sync.tokenserver.uri` to
   `https://sync.example.com/1.0/sync/1.5` (your URL), then sign in to Sync. The details for
   desktop, Android and iOS are in
   [firefox-sync's docs](https://github.com/porelli/firefox-sync/blob/main/docs/firefox.md).

## Configuration

The options are the stack's own settings (`.env` of firefox-sync), in lower case.

| Option | Setting of the stack | What it does |
|---|---|---|
| `sync_public_url` | `SYNC_PUBLIC_URL` | The public HTTPS URL of the Sync server, what Firefox is given. Required |
| `sync_max_users` | `SYNC_MAX_USERS` | Who can use the server: a number (applied at every start, read-only in the admin UI), `initial:N` (applied once, then managed in the admin UI, the default `initial:5`), or `unlimited`. `0`: nobody new |
| `admin` | the `admin` profile | The admin UI, in the sidebar through Home Assistant's ingress. On by default |
| `sync_db_containers` | `SYNC_DB_CONTAINERS` | On: the bundled MariaDB. Off: the MariaDB add-on (it must run) |
| `accounts` | `FXA_OAUTH_SERVER_URL`, `FXA_EMAIL_DOMAIN` | `mozilla`: Mozilla's accounts. `self_hosted`: the **Mozilla accounts (self-hosted)** add-on, which must run first |
| `fxa_link_code` | | With `self_hosted`: the link code the accounts add-on prints in its log (see its documentation). The add-on fetches the accounts' addresses and passwords with it at every start |
| `sync_mariadb_upgrade` | (keep-major) | Optional, off. See [MariaDB updates](#mariadb-updates) |

**Network:** the Sync port, `8000/tcp` in the container, is published on port `5000` of the
host by default. Change it, or clear it to keep the Sync server on the add-on network only
(the NGINX Proxy Manager add-on reaches it there). Ports `8080` (the admin UI) and `8081` (the
sign-up gate of the self-hosted accounts) are not published by default: the integration, the
ingress and the reverse proxy reach them on the add-on network.

### The admin UI and signing in

The admin UI opens in the sidebar. Home Assistant signs you in: its ingress lets only
Home Assistant administrators in, and the Supervisor tells the admin UI who you are
(`X-Remote-User-Name`, and the group `system-admin`). There is no admin password. Inside the
container a small nginx accepts the ingress connections only from the Supervisor
(`172.30.32.2`) and passes those headers to the admin UI from `127.0.0.1`, the one address it
trusts (`ADMIN_AUTH_HEADER`, `ADMIN_AUTH_GROUPS_HEADER`, `ADMIN_TRUSTED_PROXIES`,
`ADMIN_ALLOWED_GROUPS=system-admin`).

Some pages of the admin UI show `docker compose` commands: they are those of a compose install.
Here the add-on's options and its log are the equivalents.

### The MariaDB add-on

With `sync_db_containers` off the add-on asks the Supervisor for the MariaDB add-on's service
account, and with it creates the stack's databases and users at every start
(`tokenserver`, `syncstorage`, `ffs_admin` and their users, as `database-setup.sql` of
firefox-sync has them), then checks them. You don't add anything to the MariaDB add-on's
options. The MariaDB add-on is MariaDB 11.4 today, which firefox-sync supports.

Switching between the bundled MariaDB and the MariaDB add-on starts with empty databases:
the data stays where it was.

### The integration

After the start the add-on announces itself to Home Assistant: **Settings > Devices &
services** offers the **Firefox Sync** integration (install it from HACS first,
`porelli/ha-firefox-sync`). It reads the admin UI's metrics: accounts, max users, storage,
database sizes, backups, errors, certificates, and the health of each part.

## The images

The add-on is a prebuilt image, `ghcr.io/porelli/hassio-addon-firefox-sync` (aarch64 and
amd64), tagged with the add-on's version: installing and updating download it, nothing is
built on your device. The image is built from firefox-sync's public images,
`ghcr.io/porelli/firefox-sync` (`syncstorage-rs-mysql-latest`, `admin-latest`...), when the
version is released.

**Testing with firefox-sync's dev images** (for development, not for your Home Assistant): the
Dockerfile's `IMAGE_REPOSITORY` build argument picks where they come from, and the dev ones have
the same tag names:

- `docker build --build-arg IMAGE_REPOSITORY=ghcr.io/porelli/firefox-sync-dev firefox_sync`
  (after `docker login ghcr.io`: the dev images are private).
- In this repository's CI: set the repository variable `FIREFOX_SYNC_IMAGES` to
  `ghcr.io/porelli/firefox-sync-dev`. The builder then builds both add-ons from the dev images
  and publishes nothing; delete the variable to go back.
- As a local add-on built by the Supervisor (`tests/haos/`): copy the add-on folder to
  `/addons`, delete its `image:` line (so the Supervisor builds it) and change the default of
  `ARG IMAGE_REPOSITORY` in the copied Dockerfile to the dev repository; the Supervisor needs
  `ha docker registries add --server ghcr.io --username <user> --password <token with
  read:packages>`.

## Backups

Home Assistant's backups of this add-on hold `/data`:

| In `/data` | What it is |
|---|---|
| `options.json` | the options |
| `secrets.env` | the secrets the add-on generated on its first start: `SYNC_MASTER_SECRET`, the metrics hash secret, the database passwords, `ADMIN_DB_PASSWORD`, `ADMIN_METRICS_TOKEN`. 0600, never generated again |
| `firefox-sync.env` | the pin of the bundled MariaDB's major (`SYNC_MARIADB_IMAGE=mariadb:12`) |
| `backup/` | the dump of the databases, taken right before the backup |
| `mariadb/` | the bundled MariaDB's files: **left out of the backups** |

Before each backup the add-on dumps its databases (`mariadb-dump --single-transaction`, a
consistent copy while Sync keeps running) into `/data/backup`, and records the run for the
admin UI (its backup age and status, and the integration's sensors). The raw MariaDB files of
a running server are not a consistent copy, so the backup leaves them out
(`backup_exclude`): restoring the backup gives an add-on without them, which creates a new
data directory and loads the dump at its start.

With the MariaDB add-on, back up that add-on too: its own backups hold the Sync databases.
The dump in `/data/backup` is a second copy.

Keep the backups private: they hold the secrets, and the accounts' emails.

## MariaDB updates

The bundled MariaDB is MariaDB's newest long-term release when the add-on image was built
(MariaDB 12.3 today). An update of the add-on can bring the next long-term major, which would
upgrade your data with no way back. So the add-on records the major of your data in
`/data/firefox-sync.env` and refuses to start on data of another major, saying so in the log.
To move to the new major: take a backup of the add-on, turn on `sync_mariadb_upgrade` (in the
configuration, "Show unused optional configuration options"), and start the add-on. Data of a
newer major than the add-on's is always refused.

## Limits

- No PostgreSQL or MySQL server: the bundled MariaDB or the MariaDB add-on.
- The nightly backup service of firefox-sync is replaced by Home Assistant's backups.
- The admin UI's sign-in by password or OpenID Connect is not set up: Home Assistant signs you in.

## Support

- This add-on: [issues of porelli/hassio-addons](https://github.com/porelli/hassio-addons/issues).
- The stack itself: [firefox-sync's documentation](https://github.com/porelli/firefox-sync/tree/main/docs)
  and its [issues](https://github.com/porelli/firefox-sync/issues).
- The integration: [porelli/ha-firefox-sync](https://github.com/porelli/ha-firefox-sync).

## License

The add-on's files are MIT ([LICENSE](https://github.com/porelli/hassio-addons/blob/main/LICENSE)).
The image holds firefox-sync (GPL-3.0), Mozilla's syncstorage-rs (MPL-2.0) and MariaDB
(GPL-2.0), under their own licenses.
