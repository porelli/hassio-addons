#!/bin/bash
# supervisor.sh <method> <path> [json on stdin]: the Supervisor API as the CLI container (admin role)
m=$1 p=$2
if [ "$m" = GET ]; then
  "$(dirname "$0")/haos-vm.sh" ssh "docker exec hassio_cli sh -c 'curl -s -H \"Authorization: Bearer \$SUPERVISOR_TOKEN\" http://supervisor$p'"
else
  "$(dirname "$0")/haos-vm.sh" ssh "docker exec -i hassio_cli sh -c 'curl -s -X $m -H \"Authorization: Bearer \$SUPERVISOR_TOKEN\" -H \"Content-Type: application/json\" --data-binary @- http://supervisor$p'"
fi
