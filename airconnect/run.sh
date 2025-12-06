#!/usr/bin/with-contenv bashio

# Get options from config
AIRCAST_VAR=$(bashio::config 'aircast_var')
AIRUPNP_VAR=$(bashio::config 'airupnp_var')

# Export environment variables
export AIRCAST_VAR
export AIRUPNP_VAR

bashio::log.info "Starting AirConnect..."

# Start AirConnect using the original entrypoint
exec /init
