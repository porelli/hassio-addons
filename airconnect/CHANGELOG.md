# Changelog

## 2.0.0

- Rebuilt from scratch. 1.0.0 could not be installed: it pointed to a `1.0.0` tag of a
  third-party image that does not exist, and its options never reached the bridges.
- The image is built here (`ghcr.io/porelli/hassio-addon-airconnect`) from the binaries of the
  newest [AirConnect](https://github.com/philippe44/AirConnect) release, checked against the
  release's SHA-256 digest: 1.12.4 for this version.
- **New options, the old ones are gone**: `aircast_var` and `airupnp_var` (raw command lines,
  `kill` to turn a bridge off) are replaced by `airupnp` and `aircast` (on or off), `interface`,
  `upnp_port`, `upnp_latency` (default `1000:2000`, for Sonos and Heos), `cast_latency`, `codec`,
  `name_format`, `upnp_exclude_models`, `upnp_exclude_model_numbers`, `cast_media_volume`,
  `noflush` and `log_level`. Each value is checked by the Supervisor. Set them again after
  updating.
- With no `interface`, the bridges bind to the interface of the default route, not to the
  first one they find, which can be a Docker network.
- Config files: `airupnp.xml` and `aircast.xml` in the add-on's `addon_configs` folder.
- The bridges run as their own unprivileged user, under an AppArmor profile of their own.
- aarch64 and amd64 only: armv7 is no longer supported by Home Assistant.
