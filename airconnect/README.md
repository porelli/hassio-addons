# AirConnect Home Assistant Add-on

AirConnect allows you to stream audio from Apple devices using AirPlay to Chromecast and UPnP/Sonos devices.

## About

This add-on wraps the excellent [docker-airconnect](https://github.com/1activegeek/docker-airconnect) project, which enables AirPlay streaming to devices that don't natively support it:

- **Chromecast devices** - Stream to any Chromecast Audio, Chromecast, or Google Home device
- **UPnP/Sonos devices** - Stream to Sonos speakers and other UPnP-compatible devices

## Installation

1. Add this repository to your Home Assistant instance:
   - Go to **Supervisor** → **Add-on Store** → **⋮** (menu) → **Repositories**
   - Add the URL of this repository
2. Find "AirConnect" in the add-on store and click Install
3. Start the add-on

## Configuration

The add-on requires host network access to discover devices on your network.

### Options

- `aircast_var` (optional): Command-line arguments for AirCast (Chromecast support)
  - Example: `-b 192.168.1.10` to bind to a specific IP address
  - Set to `kill` to disable Chromecast support

- `airupnp_var` (optional): Command-line arguments for AirUPnP (UPnP/Sonos support)
  - Example: `-l 1000:2000` to set latency
  - Set to `kill` to disable UPnP support

### Example Configuration

```yaml
aircast_var: "-b 192.168.1.10"
airupnp_var: ""
```

## Usage

Once started, the add-on will automatically discover compatible devices on your network. Open the AirPlay menu on your iOS device, Mac, or iTunes, and you should see your Chromecast and Sonos devices listed as AirPlay targets.

## Support

For issues related to the underlying AirConnect software, please visit:
https://github.com/philippe44/AirConnect

For issues with this Home Assistant add-on, please open an issue in this repository.
