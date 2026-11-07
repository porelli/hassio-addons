#!/command/with-contenv bashio
# shellcheck shell=bash
# One AirConnect bridge, as its s6 service runs it: bridge.sh airupnp | aircast. The add-on's
# options (the Supervisor's, through bashio) become the bridge's command line; it runs in
# the foreground (-Z, no prompt), as the airconnect user, logging to the add-on's log.
# Turned off in the options: nothing runs.
bridge=${1:?airupnp or aircast}
case "${bridge}" in
  airupnp) what="UPnP/Sonos" ;;
  aircast) what="Chromecast" ;;
  *) bashio::exit.nok "bridge.sh: unknown bridge ${bridge}" ;;
esac

# a wrong option stops the add-on (its log says why) instead of a restart every second
fatal() {
  bashio::log.fatal "$*"
  /run/s6/basedir/bin/halt
  exec sleep infinity
}

# (the option is always set: null is a Supervisor that did not answer; s6 starts this again)
enabled=$(bashio::config "${bridge}")
if [ "${enabled}" = null ]; then
  bashio::log.error "No options from the Supervisor: trying again"
  sleep 4
  exit 1
fi
if [ "${enabled}" != true ]; then
  bashio::log.info "The ${what} bridge (${bridge}) is off"
  exec sleep infinity
fi

# value <option>: the option's value, nothing when it is not set
value() {
  if bashio::config.has_value "$1"; then bashio::config "$1"; fi
}

args=(-Z)

# the interface: the option, else the one of the IPv4 default route (on Home Assistant OS
# the bridges would otherwise risk binding to a Docker network, where no player is)
interface=$(value interface)
if [ -z "${interface}" ]; then
  # (/proc/net/route: Iface Destination Gateway Flags RefCnt Use Metric Mask...)
  while read -r iface destination _ _ _ _ _ mask _; do
    if [ "${destination}" = 00000000 ] && [ "${mask}" = 00000000 ]; then interface=${iface}; break; fi
  done < /proc/net/route
  if [ -n "${interface}" ]; then
    bashio::log.info "Interface ${interface} (the default route's)"
  else
    bashio::log.warning "No default route: ${bridge} picks the interface itself (set the interface option)"
  fi
elif [[ ! "${interface}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && [ ! -e "/sys/class/net/${interface}" ]; then
  fatal "No interface ${interface} on this host: $(cd /sys/class/net && echo *)"
fi
port=$(value upnp_port)
if [ -n "${interface}" ]; then
  if [ "${bridge}" = airupnp ] && [ -n "${port}" ]; then
    args+=(-b "${interface}:${port}")
  else
    args+=(-b "${interface}")
  fi
elif [ "${bridge}" = airupnp ] && [ -n "${port}" ]; then
  fatal "upnp_port needs an interface (none found: set the interface option)"
fi

if [ "${bridge}" = airupnp ]; then
  latency=$(value upnp_latency)
else
  latency=$(value cast_latency)
fi
[ -z "${latency}" ] || args+=(-l "${latency}")

codec=$(value codec)
if [ "${codec}" = pcm ] && [ "${bridge}" = aircast ]; then
  bashio::log.warning "Chromecast has no pcm: aircast uses its default codec"
elif [ -n "${codec}" ]; then
  args+=(-c "${codec}")
fi

name_format=$(value name_format)
[ -z "${name_format}" ] || args+=(-N "${name_format}")

if [ "${bridge}" = airupnp ]; then
  models=$(value upnp_exclude_models)
  [ -z "${models}" ] || args+=(-m "${models}")
  # (-n is the model number, whatever airupnp -h says)
  numbers=$(value upnp_exclude_model_numbers)
  [ -z "${numbers}" ] || args+=(-n "${numbers}")
else
  volume=$(value cast_media_volume)
  [ -z "${volume}" ] || args+=(-v "${volume}")
fi

bashio::config.true noflush && args+=(--noflush)

args+=(-d "all=$(bashio::config log_level)")

# an advanced config file (DOCS.md, "Config files"): /addon_configs/<slug>/<bridge>.xml on
# the host, /config here, next to the options above
config=/config/${bridge}.xml
if [ -e "${config}" ]; then
  if /command/s6-setuidgid airconnect test -r "${config}"; then
    args+=(-x "${config}")
    bashio::log.info "Config file ${config}"
  else
    bashio::log.warning "${config} is not readable: left out"
  fi
fi

bashio::log.info "Starting the ${what} bridge (AirConnect $(cat /usr/share/airconnect/version)): ${bridge} ${args[*]}"
# (a working directory without a config.xml: the bridges read ./config.xml when there is no -x)
cd / || exit 1
exec /command/s6-setuidgid airconnect "/usr/bin/${bridge}" "${args[@]}"
