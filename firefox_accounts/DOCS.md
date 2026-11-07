# Mozilla accounts (self-hosted)

Your own Mozilla accounts, for the **Firefox Sync** add-on: Firefox signs up, signs in and
pairs phones with your server instead of `accounts.firefox.com`. This add-on is the self-hosted
accounts of [firefox-sync](https://github.com/porelli/firefox-sync) (`compose/fxa.yml`) in one
container: Mozilla's auth, content and profile servers (the profile worker, its static server
and the avatars' proxy), the pairing server, Redis, and the database migrations and the
sign-up policy, which run before the auth server starts and stop the add-on when they fail.

**It is large.** The image is about **5 GB** to download and unpack, and the add-on needs
**3 to 4 GB of RAM** while it runs (about 2 GB right after the start, more under use). It also
needs an **SMTP server**: every sign-up and every new sign-in is confirmed with a code sent by
email. With a small machine, keep Mozilla's accounts (`accounts: mozilla` in the Firefox Sync
add-on): your Sync data stays on your server either way, encrypted by Firefox.

## Before you start

- **Four host names with HTTPS**, all pointing to your Home Assistant, for example:

  | Option | Example | What it is |
  |---|---|---|
  | `fxa_content_url` | `https://accounts.example.com` | the accounts' web pages |
  | `fxa_auth_url` | `https://api.example.com` | the accounts' API (and OAuth) |
  | `fxa_profile_url` | `https://profile.example.com` | the profile server (names, avatars) |
  | `fxa_pairing_url` | `wss://pairing.example.com` | your own pairing server (optional) |

  and the Sync server's, `sync_public_url` of the Firefox Sync add-on.
- **An SMTP server** for the codes: `fxa_smtp_*`.
- The **Firefox Sync** add-on, set up after this one with `accounts: self_hosted`.

## The reverse proxy

Each host name goes to a port of this add-on. With the
[NGINX Proxy Manager](https://github.com/hassio-addons/addon-nginx-proxy-manager) add-on, one
proxy host each, scheme `http`, forward host this add-on's host name on the add-on network
(on its Info page; the Firefox Sync add-on's for the gate), with a certificate:

| Proxy host | Forward to | Also |
|---|---|---|
| `accounts.example.com` | this add-on, port `3030` | |
| `api.example.com` | this add-on, port `9000` | **the sign-up gate:** a custom location `/v1/account/create` to the **Firefox Sync** add-on, port `8081` |
| `profile.example.com` | this add-on, port `1111` | a custom location `/img/` to this add-on, port `1114` |
| `pairing.example.com` | this add-on, port `8000` | **Websockets Support** on; in **Advanced**: `proxy_read_timeout 600;` |
| `sync.example.com` | the **Firefox Sync** add-on, port `8000` | in **Advanced**: `client_max_body_size 10m;` |

- **The sign-up gate.** `POST /v1/account/create`, the sign-up, goes to the admin UI of the
  Firefox Sync add-on, which enforces who can sign up and how many accounts there may be, and
  passes the allowed ones on to this add-on. Without that route the accounts' database still
  refuses what the sign-up policy forbids, but the admin UI cannot tell the users why. See
  [Sign-up gate](https://github.com/porelli/firefox-sync/blob/main/docs/reverse-proxy.md#sign-up-gate).
- **The avatars.** Port `1114` serves `/img/...` of the profile host as it is (the prefix
  stripped inside the add-on), so no rewrite is needed in the proxy.
- **The client's address.** The accounts limit sign-in attempts per IP address, read from
  `X-Forwarded-For`, which NGINX Proxy Manager sets. Behind one proxy this is right as it is
  (`FXA_CLIENT_ADDRESS_DEPTH=2`, see
  [Client IP address](https://github.com/porelli/firefox-sync/blob/main/docs/reverse-proxy.md#client-ip-address)).

A proxy outside Home Assistant reaches the add-on through the host's ports instead: publish
them in the add-on's **Network** section (they are off by default).

Single sign-on (Authelia...) or client certificates in front of the accounts' pages: see
[access control](https://github.com/porelli/firefox-sync/blob/main/docs/access-control.md). Only
the accounts pages can sit behind them; Firefox calls the other hosts without cookies or a
certificate.

## Configuration

The options are the stack's settings (`.env` of firefox-sync), in lower case:

| Option | What it does |
|---|---|
| `fxa_content_url`, `fxa_auth_url`, `fxa_profile_url` | the public HTTPS URLs above. Required |
| `fxa_pairing_url` | your own pairing server, `wss://...`. Empty: Mozilla's (`wss://channelserver.services.mozilla.com`), and no pairing server runs here |
| `sync_public_url` | the Firefox Sync add-on's public URL (`SYNC_PUBLIC_URL`) |
| `fxa_db_containers` | on: the bundled MariaDB. Off: the MariaDB add-on, which must run |
| `fxa_smtp_host`, `fxa_smtp_port`, `fxa_smtp_user`, `fxa_smtp_pass`, `fxa_smtp_secure`, `fxa_smtp_sender` | the SMTP server of the codes; `fxa_smtp_secure` on for TLS from the start (port 465), off for STARTTLS (587) |
| `fxa_signups` | who can create an account: `open`, `allowlist` (`fxa_signup_allowlist`) or `closed`. The admin UI of the Firefox Sync add-on changes it too |
| `fxa_signup_allowlist` | with `allowlist`: emails and `@domains`, comma-separated |
| `fxa_mariadb_upgrade` | optional, off: see [MariaDB updates](#mariadb-updates) |

**The images.** The add-on is a prebuilt image, `ghcr.io/porelli/hassio-addon-firefox-accounts`
(aarch64 and amd64, tagged with the add-on's version), built from firefox-sync's public images
`ghcr.io/porelli/firefox-sync` (`fxa-mono-latest`, `fxa-channelserver-latest`,
`admin-latest`). To test with the dev images instead, as in the Firefox Sync add-on
(its documentation, "The images"): `--build-arg IMAGE_REPOSITORY=ghcr.io/porelli/firefox-sync-dev`,
or the repository variable `FIREFOX_SYNC_IMAGES` in this repository's CI.

The maximum number of accounts is managed in the admin UI (`FXA_MAX_ACCOUNTS=initial:unlimited`).

### Linking the Firefox Sync add-on

At every start this add-on prints a **link code** in its log:

```text
Link code for the Firefox Sync add-on (its option fxa_link_code): a0d7b954-firefox-accounts:Xq3...
```

Paste it into the Firefox Sync add-on's `fxa_link_code` option (with `accounts: self_hosted`).
The code is this add-on's host name on the add-on network and a random token, generated once.
At its start the Firefox Sync add-on fetches what it needs with it, from this add-on's port 8101
(on the add-on network only): the addresses of the accounts' servers, and the passwords of the
admin UI's database user and of Redis. Without the token the port answers nothing. Inside the
container every server runs as its own user, and only the link's (`fxa-link`) can read those
details: the servers that face the internet, the pairing server first, cannot. Nothing is
written to `/share`, which every add-on that maps it could read. Start this add-on first (it
starts before the application add-ons at boot); start the Firefox Sync add-on again after
changing this one's options. The token is in `/data/secrets.env` (`FXA_LINK_TOKEN`); to change
it, delete that line, restart this add-on and paste the new code.

### The database

With the bundled MariaDB (the default) the accounts' five databases (`fxa`, `fxa_oauth`,
`fxa_profile`, `pushbox`, `ffs`) live in `/data/mariadb`. It listens on the add-on network too,
for the Firefox Sync add-on's admin UI, which signs in as its own user (`ffs_admin`).

With the MariaDB add-on (`fxa_db_containers` off) the add-on creates its users there at every
start with the MariaDB add-on's service account (`fxa`, `ffs_policy`, `ffs_admin`, as
`database-setup-fxa.sql` of firefox-sync has them). Mozilla runs the accounts on MySQL;
MariaDB passes the same tests (firefox-sync's images carry
[mozilla/fxa#21494](https://github.com/mozilla/fxa/pull/21494) for MariaDB 12).

## Backups

| In `/data` | What it is |
|---|---|
| `secrets.env` | the accounts' secrets and passwords, generated on the first start, never again |
| `fxa-keys/` | **the signing keys** of the accounts (generated once): without them every Firefox is signed out |
| `fxa-profile-images/` | the avatars |
| `firefox-accounts.env` | the pin of the bundled MariaDB's major |
| `backup/` | the dump of the five databases, taken right before each backup |
| `mariadb/` | the bundled MariaDB's files: **left out of the backups**, the dump is restored instead |

Restoring a backup restores the keys and the secrets; the add-on then loads the dump into a
new data directory at its start. With the MariaDB add-on, back up that add-on too.

## MariaDB updates

As in the Firefox Sync add-on: the major of the data is pinned in `/data/firefox-accounts.env`,
another major is refused at the start. To move to a new major, back up the add-on, turn on
`fxa_mariadb_upgrade`, start it.

## Support

- This add-on: [issues of porelli/hassio-addons](https://github.com/porelli/hassio-addons/issues).
- [Self-hosted accounts in firefox-sync's docs](https://github.com/porelli/firefox-sync/blob/main/docs/accounts.md),
  and firefox-sync's [issues](https://github.com/porelli/firefox-sync/issues).

## License

The add-on's files are MIT ([LICENSE](https://github.com/porelli/hassio-addons/blob/main/LICENSE)).
The image holds Mozilla's accounts and pairing server (MPL-2.0), firefox-sync's admin tool
(GPL-3.0), Redis and MariaDB, under their own licenses.
