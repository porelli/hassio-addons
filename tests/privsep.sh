# shellcheck shell=bash
# Privilege separation inside an add-on's container, sourced by run-accounts.sh and
# run-firefox-sync.sh (their check()): each service runs as its own user, and a service's user
# (an internet-facing one taken over, say) reads no other service's secret files, no other
# user's process environment (/proc/<pid>/environ), and writes nowhere it should not.

# privsep_user <container> <pattern>: the users of the processes whose command line has <pattern>
privsep_user() {
  docker exec "$1" sh -c 'for d in /proc/[0-9]*; do
      [ "${d#/proc/}" != "$$" ] || continue
      c=$(tr "\0" " " < "$d/cmdline" 2> /dev/null) || continue
      case "$c" in *"$0"*) stat -c %U "$d" ;; esac
    done' "$2" 2> /dev/null | sort -u | tr '\n' ' ' | sed 's/ $//'
}

# privsep_runs_as <container> <user> <pattern>...: every process of each pattern runs as <user>
privsep_runs_as() {
  local c=$1 user=$2 pattern
  shift 2
  for pattern in "$@"; do
    check "$(privsep_user "${c}" "${pattern}")" "${user}" "privilege separation: ${pattern} runs as ${user}"
  done
}

# privsep_files <container> <file or glob>...: the ones that exist (as root), globs expanded
privsep_files() {
  local c=$1
  shift
  # shellcheck disable=SC2016 # (expanded in the container)
  docker exec "${c}" sh -c 'for f in $*; do [ -e "$f" ] && echo "$f"; done' privsep "$@" | tr '\n' ' '
}

# privsep_denied <container> <user> <own files> <file>...: as <user>, nothing of the files but
# its own (a space-separated list) can be read, no other user's process environment, and no
# file can be created in the code of the image or in another service's directories (DIRS)
privsep_denied() {
  local c=$1 user=$2 own=" $3 " f files=() got
  shift 3
  for f in "$@"; do
    case "${own}" in *" ${f} "*) ;; *) files+=("${f}") ;; esac
  done
  got=$(docker exec -u "${user}" "${c}" sh -c '
    for f in "$@"; do
      case "$f" in
        dir:*) d=${f#dir:}; p=$d/.privsep-probe-$$; if ( : > "$p" ) 2> /dev/null; then rm -f "$p"; echo "write:$d"; fi ;;
        *) if cat -- "$f" > /dev/null 2>&1; then echo "read:$f"; fi ;;
      esac
    done
    me=$(id -u)
    for d in /proc/[0-9]*; do
      [ "$(stat -c %u "$d" 2> /dev/null)" != "$me" ] || continue
      if cat "$d/environ" > /dev/null 2>&1; then echo "environ:$(tr "\0" " " < "$d/cmdline" | cut -c1-50)"; fi
    done' privsep "${files[@]}" 2>&1 | tr '\n' ';')
  check "${got:-nothing}" nothing "privilege separation: as ${user}, ${#files[@]} secret files and directories and the other services' environments denied"
}
