# Home Assistant Add-ons Repository

[![Builder](https://github.com/porelli/hassio-addons/actions/workflows/builder.yml/badge.svg)](https://github.com/porelli/hassio-addons/actions/workflows/builder.yml)
[![Lint](https://github.com/porelli/hassio-addons/actions/workflows/lint.yml/badge.svg)](https://github.com/porelli/hassio-addons/actions/workflows/lint.yml)

A Home Assistant app (add-on) repository: Firefox Sync on your own Home Assistant, with
Mozilla's accounts or self-hosted ones, and AirConnect.

## Installation

[![Add the repository to your Home Assistant][my-badge]][my-link]

Or by hand:

1. In Home Assistant go to **Settings** > **Apps** > **Install app** (the app store; "Add-ons"
   in older versions).
2. Open the **⋮** menu in the top right and select **Repositories**.
3. Add `https://github.com/porelli/hassio-addons` and select **Add**.
4. The apps of this repository appear in the store, under "porelli's Home Assistant apps".

The Firefox Sync apps are prebuilt images on ghcr.io (aarch64 and amd64): nothing is built on
your device. Apps need the Supervisor, that is Home Assistant OS.

[my-badge]: https://my.home-assistant.io/badges/supervisor_add_addon_repository.svg
[my-link]: https://my.home-assistant.io/redirect/supervisor_add_addon_repository/?repository_url=https%3A%2F%2Fgithub.com%2Fporelli%2Fhassio-addons

## Add-ons

This repository contains the following add-ons:

### AirConnect

![Supports aarch64 Architecture][aarch64-shield]
![Supports amd64 Architecture][amd64-shield]
![Supports armv7 Architecture][armv7-shield]

AirConnect enables AirPlay streaming to Chromecast and UPnP/Sonos devices.

[aarch64-shield]: https://img.shields.io/badge/aarch64-yes-green.svg
[amd64-shield]: https://img.shields.io/badge/amd64-yes-green.svg
[armv7-shield]: https://img.shields.io/badge/armv7-yes-green.svg

### Firefox Sync

![Supports aarch64 Architecture][aarch64-shield]
![Supports amd64 Architecture][amd64-shield]

Your own Firefox Sync server and the firefox-sync admin UI, with Mozilla's accounts or the
self-hosted ones. See [firefox_sync](firefox_sync/README.md). The
[Firefox Sync integration](https://github.com/porelli/ha-firefox-sync) (HACS) shows its health.

### Mozilla accounts (self-hosted)

![Supports aarch64 Architecture][aarch64-shield]
![Supports amd64 Architecture][amd64-shield]

Self-hosted Mozilla accounts for the Firefox Sync add-on. Large: a 5 GB image, 3 to 4 GB of
RAM. See [firefox_accounts](firefox_accounts/README.md).

## Testing the add-ons without Home Assistant

`tests/` runs the Firefox Sync add-ons' images standalone, with a mock Supervisor
(`tests/mock_supervisor.py`): `tests/run-firefox-sync.sh` and `tests/run-accounts.sh`, see
their headers. They need firefox-sync's checkout for its tests, and Docker.
They build the add-ons from firefox-sync's public images; for its dev images see
"The images" in [firefox_sync/DOCS.md](firefox_sync/DOCS.md).
`tests/haos/` runs Home Assistant OS in qemu with the real Supervisor (`haos-vm.sh`, and
`supervisor.sh`, `ha.py` to drive it): the add-ons as local add-ons, see the headers.

## Contributing

Contributions are welcome! Please see [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
