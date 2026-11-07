# AirConnect

This add-on runs philippe44's [AirConnect](https://github.com/philippe44/AirConnect). It is a
pair of bridges that make players without AirPlay show up as AirPlay speakers:

- **airupnp** finds the UPnP/DLNA renderers on your network (Sonos, Heos, Bose SoundTouch,
  many TVs and network receivers) and creates one AirPlay speaker for each.
- **aircast** does the same for Chromecasts (Chromecast Audio, Google and Nest speakers, Cast
  groups, TVs with Chromecast built in).

The AirPlay speaker takes the player's name followed by `+`, so "Kitchen" becomes "Kitchen+".
Pick it in the AirPlay menu of an iPhone, iPad or Mac, and the bridge receives the audio and
streams it to the player over HTTP (as FLAC by default). Volume, pause, next and previous on
the player are passed back to the AirPlay sender.

## Installation

1. Add this repository to Home Assistant (see the repository's README), then install
   **AirConnect** from the app store.
2. Start it. The defaults run both bridges.
3. Open the **Log** tab. Each player it finds is logged ("adding renderer" for UPnP), and its
   AirPlay speaker appears on your Apple devices within about 30 seconds.

The add-on uses the host's network (`host_network`), as AirConnect needs: it finds the players
by multicast (SSDP and mDNS) and announces the AirPlay speakers by mDNS. Home Assistant and its
players must be on the same network, with nothing that does NAT between them.

## Configuration

| Option | Default | What it does |
|---|---|---|
| `airupnp` | on | The UPnP/Sonos bridge |
| `aircast` | on | The Chromecast bridge |
| `interface` | (the default route's) | The network interface (`end0`, `eth0`, `wlan0`...) or IPv4 address to use (`-b`). When it is empty, the add-on takes the interface of the default route, which on Home Assistant OS is your LAN, not one of the Docker networks. An interface that doesn't exist stops the add-on, and the log lists the ones that do |
| `upnp_port` | | airupnp's UPnP port, 49153 to 65535, for a firewall (`-b <interface>:<port>`). When it is empty, airupnp uses 49152 or the next free port |
| `upnp_latency` | `1000:2000` | airupnp's buffering in ms, `<rtp>[:<http>][:f]` (`-l`). Sonos and Heos need `1000:2000` (upstream's advice). Empty: AirConnect's default, `0:0` |
| `cast_latency` | | aircast's buffering, in the same format |
| `codec` | | The format sent to the players (`-c`): `flac[:0-9][/blocksize]`, `mp3[:kbps]`, `aac[:kbps]`, `wav`, or `pcm` (UPnP only; aircast keeps its default). Players show the title and artwork only with `mp3` or `aac`. Empty: FLAC |
| `name_format` | | The AirPlay names (`-N`). `%s` stands for the player's name, for example `%s (AirPlay)`. Only one `%s` is allowed, and no other `%` |
| `upnp_exclude_models` | | UPnP players to leave out (`-m`), by comma-separated parts of their model name, for example `Sonos One,Era` for Sonos players that do AirPlay themselves |
| `upnp_exclude_model_numbers` | | The same, by parts of their model number (`-n`) |
| `cast_media_volume` | | The volume factor of Chromecast groups, 0 to 1 (`-v`, default 0.5) |
| `noflush` | off | Ignore AirPlay's FLUSH (`--noflush`), for players that stop when you skip a track. A pause then sends silence |
| `log_level` | `info` | `error`, `warn`, `info`, `debug` or `sdebug` for every log of the bridges (`-d all=<level>`) |

The options in the table without a default are under "Show unused optional configuration
options". The Supervisor checks every value against the pattern AirConnect expects, so a
mistyped latency or codec is refused when you save, not when the add-on starts. The log shows
the command line each bridge was started with.

### Config files

For the settings that have no option, such as per-player names, turning single players off,
per-player latency or codec, `http_length`, Sonos' `stream_type` or `metadata`, AirConnect
reads an XML config file. Put it in the add-on's folder of the `addon_configs` share (with the
Samba or the File editor add-on), `/addon_configs/<repository>_airconnect/`:

- `airupnp.xml` for the UPnP bridge, `aircast.xml` for the Chromecast bridge.
- To get a template with your players in it, run `airupnp -i airupnp.xml` (or
  `aircast -i aircast.xml`) once on any computer of the same network, using the binaries of the
  [release](https://github.com/philippe44/AirConnect/releases). The parameters are in
  [AirConnect's README](https://github.com/philippe44/AirConnect#config-file-parameters).
- Restart the add-on after a change. The log says "Config file /config/airupnp.xml".

The add-on's options are still passed on the command line, and the command line wins over the
file's `<common>` section. The `<device>` sections of the file are applied per player.

## How it is built

The image (`ghcr.io/porelli/hassio-addon-airconnect`, aarch64 and amd64) contains the
`airupnp-linux-*` and `aircast-linux-*` binaries of the newest AirConnect release at the time
it was built. They are taken from the release's zip, and the zip is checked against the SHA-256
digest GitHub records for that release asset. The log shows the AirConnect version.

The add-on's version changes when a new image is published, and a published version is never
rebuilt. So a new AirConnect release reaches you with the add-on's next version. To build it
yourself, comment out `image:` in `config.yaml` of a local copy, and Home Assistant builds the
Dockerfile. `--build-arg AIRCONNECT_VERSION=<tag>` picks a release.

The bridges run as their own unprivileged user, under the add-on's AppArmor profile. That
profile gives them the network, their binaries, `/etc` and their config files, and nothing
else.

## Limits

- **Audio only.** The bridges convert AirPlay's real-time stream into an HTTP stream, and that
  adds a delay of a second or more. Sound is not in sync with video, and no latency setting
  changes that (see AirConnect's README).
- When you skip tracks or switch sources, the new audio can take a few seconds to start.
  Senders that don't flush the stream make it worse. Try `noflush`, or lower latencies on
  players that cope with them.
- Players on another network or VLAN are found only if your network forwards SSDP and mDNS
  between them. Routers that filter multicast make players disappear now and then (see
  AirConnect's "Misc tips").
- Sonos: only the coordinator of a group shows up. Recent Sonos players have AirPlay 2
  themselves; leave them out with `upnp_exclude_models`.
- These are AirPlay 1 (RAOP) speakers. iPhones and iPads group only AirPlay 2 speakers, so
  they play to one of them at a time. Music on a Mac can play to several at once.
- armv7 and i386 are not built. Home Assistant dropped them in 2025.12.

## Support

- This add-on: [issues of porelli/hassio-addons](https://github.com/porelli/hassio-addons/issues).
  Include the log, with `log_level: debug` if you can.
- AirConnect itself, and players that don't play:
  [philippe44/AirConnect](https://github.com/philippe44/AirConnect) (its README and issues).

## License

The add-on's files are MIT ([LICENSE](https://github.com/porelli/hassio-addons/blob/main/LICENSE)).
The image contains AirConnect's binaries, which are GPL-3.0-or-later (`airupnp -t`), unchanged.
Their source is in [philippe44/AirConnect](https://github.com/philippe44/AirConnect), at the tag
of the version in the log.
