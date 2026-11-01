#!/bin/bash
# A Home Assistant OS VM on this machine, to test the add-ons with the real Supervisor: the
# generic-aarch64 (or generic-x86-64) qcow2 of home-assistant/operating-system, in qemu with
# HVF (KVM on Linux) and UEFI, as firefox-sync's tests/vm/vm.sh runs its Ubuntu VM. Its own
# folder and ports: it does not touch that VM.
#
#   haos-vm.sh create     download the latest release (or HAOS_VERSION), the UEFI variables, and
#                         a CONFIG drive with this machine's SSH key: HAOS's developer SSH, root on
#                         the host's port 22222 (developers.home-assistant.io, debugging HAOS)
#   haos-vm.sh start      boot it headless; Home Assistant on http://127.0.0.1:${HA_PORT} (its port
#                         80, the default since Core 2026.10; 8123 on HA_PORT+1, which redirects)
#   haos-vm.sh ssh [cmd]  root on the HAOS host (docker, the ha CLI through `ha`, /mnt/data)
#   haos-vm.sh stop | destroy   shut down / delete everything but this script
#
# Settings: HAOS_DIR (default ~/vms/haos-test), HA_PORT (18123), SSH_PORT (22223),
# SYNC_PORT (15000, the Firefox Sync add-on's port 5000), CPUS (4), MEM (6144), HAOS_VERSION.
set -u
DIR=${HAOS_DIR:-${HOME}/vms/haos-test}
HA_PORT=${HA_PORT:-18123} SSH_PORT=${SSH_PORT:-22223} SYNC_PORT=${SYNC_PORT:-15000}
KEY=${HAOS_SSH_KEY:-${HOME}/.ssh/id_ed25519}
case "$(uname -m)" in arm64 | aarch64) ARCH=aarch64 BOARD=generic-aarch64 ;; *) ARCH=x86_64 BOARD=generic-x86-64 ;; esac
ACCEL=hvf
[ "$(uname -s)" = Linux ] && ACCEL=kvm
die() { echo "haos-vm.sh: $*" >&2; exit 1; }
firmware() {
  local d
  for d in /opt/homebrew/share/qemu /usr/local/share/qemu /usr/share/qemu /usr/share/AAVMF; do
    if [ "${ARCH}" = aarch64 ] && [ -f "${d}/edk2-aarch64-code.fd" ]; then CODE=${d}/edk2-aarch64-code.fd VARS_T=${d}/edk2-arm-vars.fd; return; fi
    if [ "${ARCH}" = x86_64 ] && [ -f "${d}/edk2-x86_64-code.fd" ]; then CODE=${d}/edk2-x86_64-code.fd VARS_T=${d}/edk2-i386-vars.fd; return; fi
  done
  die "no UEFI firmware (Homebrew's qemu has it)"
}
vssh() { ssh -i "${KEY}" -p "${SSH_PORT}" -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5 root@127.0.0.1 "$@"; }

create() {
  mkdir -p "${DIR}" && chmod 700 "${DIR}"
  # each part only when missing, so a create that stopped halfway resumes
  if [ -f "${DIR}/haos.qcow2" ]; then
    echo "exists: ${DIR}/haos.qcow2"
  else
    local version=${HAOS_VERSION:-$(curl -fsSL https://api.github.com/repos/home-assistant/operating-system/releases/latest | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p')}
    [ -n "${version}" ] || die "no HAOS version"
    echo "HAOS ${version} (${BOARD})"
    curl -fL -o "${DIR}/haos.qcow2.xz" "https://github.com/home-assistant/operating-system/releases/download/${version}/haos_${BOARD}-${version}.qcow2.xz" || die "download failed"
    xz -d "${DIR}/haos.qcow2.xz" || die "xz failed"
    echo "${version}" > "${DIR}/version"
  fi
  firmware
  [ -f "${DIR}/efi-vars.fd" ] || cp "${VARS_T}" "${DIR}/efi-vars.fd"
  [ -f "${DIR}/config.img" ] && { echo "created in ${DIR}"; return; }
  # the CONFIG drive: HAOS imports authorized_keys from a FAT partition labelled CONFIG at boot
  [ -f "${KEY}.pub" ] || die "no ${KEY}.pub"
  # (mtools: macOS cannot mount FAT unprivileged; brew install mtools dosfstools, or make it
  # elsewhere: CONFIG_IMG=<a 16 MB FAT image labelled CONFIG with authorized_keys>)
  if [ -n "${CONFIG_IMG:-}" ]; then
    cp "${CONFIG_IMG}" "${DIR}/config.img"
  else
    command -v mformat > /dev/null || die "no mtools (brew install mtools), or CONFIG_IMG=<image>"
    dd if=/dev/zero of="${DIR}/config.img" bs=1048576 count=16 2> /dev/null
    mformat -i "${DIR}/config.img" -v CONFIG :: && mcopy -i "${DIR}/config.img" "${KEY}.pub" ::authorized_keys || die "CONFIG drive failed"
  fi
  echo "created in ${DIR}"
}

start() {
  [ -f "${DIR}/haos.qcow2" ] || die "no VM: haos-vm.sh create"
  [ -f "${DIR}/qemu.pid" ] && kill -0 "$(cat "${DIR}/qemu.pid")" 2> /dev/null && { echo "already running"; return; }
  firmware
  local machine=virt
  [ "${ARCH}" = x86_64 ] && machine=q35
  "qemu-system-${ARCH}" -machine "${machine},accel=${ACCEL}" -cpu host -smp "${CPUS:-4}" -m "${MEM:-6144}" \
    -rtc base=utc,clock=host \
    -drive if=pflash,format=raw,readonly=on,file="${CODE}" -drive if=pflash,format=raw,file="${DIR}/efi-vars.fd" \
    -drive if=virtio,format=qcow2,file="${DIR}/haos.qcow2",discard=unmap,detect-zeroes=unmap \
    -drive if=none,id=config,format=raw,file="${DIR}/config.img" -device usb-ehci -device usb-storage,drive=config \
    -nic "user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:${HA_PORT}-:80,hostfwd=tcp:127.0.0.1:$((HA_PORT + 1))-:8123,hostfwd=tcp:127.0.0.1:${SSH_PORT}-:22222,hostfwd=tcp:127.0.0.1:${SYNC_PORT}-:5000" \
    -display none -serial file:"${DIR}/console.log" -daemonize -pidfile "${DIR}/qemu.pid" || die "qemu failed"
  printf 'booting'
  for _ in $(seq 1 200); do curl -s -o /dev/null "http://127.0.0.1:${HA_PORT}/" && break; printf '.'; sleep 3; done
  echo " Home Assistant on http://127.0.0.1:${HA_PORT}, root ssh: haos-vm.sh ssh"
}

stop() {
  [ -f "${DIR}/qemu.pid" ] || return 0
  vssh 'ha host shutdown' > /dev/null 2>&1 || true
  for _ in $(seq 1 60); do kill -0 "$(cat "${DIR}/qemu.pid")" 2> /dev/null || break; sleep 2; done
  kill "$(cat "${DIR}/qemu.pid")" 2> /dev/null
  rm -f "${DIR}/qemu.pid"
}

case "${1:-}" in
  create) create ;;
  start) start ;;
  stop) stop ;;
  ssh) shift; vssh "$@" ;;
  destroy) stop; rm -rf "${DIR}"; echo "removed ${DIR}" ;;
  *) sed -n '2,20p' "$0"; exit 2 ;;
esac
