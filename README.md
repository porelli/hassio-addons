# Home Assistant Add-ons Repository

[![Builder](https://github.com/porelli/hassio-addons/actions/workflows/builder.yml/badge.svg)](https://github.com/porelli/hassio-addons/actions/workflows/builder.yml)
[![Lint](https://github.com/porelli/hassio-addons/actions/workflows/lint.yml/badge.svg)](https://github.com/porelli/hassio-addons/actions/workflows/lint.yml)

Custom Home Assistant add-ons repository.

## Installation

Add this repository to your Home Assistant instance:

1. Navigate to **Supervisor** → **Add-on Store** in your Home Assistant instance
2. Click the **⋮** menu in the top right and select **Repositories**
3. Add the URL of this repository:
   ```
   https://github.com/porelli/hassio-addons
   ```
4. The add-ons from this repository should now be available in your add-on store

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
self-hosted ones. See [firefox_sync](firefox_sync/README.md).

### Mozilla accounts (self-hosted)

![Supports aarch64 Architecture][aarch64-shield]
![Supports amd64 Architecture][amd64-shield]

Self-hosted Mozilla accounts for the Firefox Sync add-on. Large: a 5 GB image, 3 to 4 GB of
RAM. See [firefox_accounts](firefox_accounts/README.md).

## Testing the add-ons without Home Assistant

`tests/` runs the Firefox Sync add-ons' images standalone, with a mock Supervisor
(`tests/mock_supervisor.py`): `tests/run-firefox-sync.sh` and `tests/run-accounts.sh`, see
their headers. They need firefox-sync's checkout for its tests, and Docker.
`tests/haos/` runs Home Assistant OS in qemu with the real Supervisor (`haos-vm.sh`, and
`supervisor.sh`, `ha.py` to drive it): the add-ons as local add-ons, see the headers.

## Contributing

Contributions are welcome! Please see [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
