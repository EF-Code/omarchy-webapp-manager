#!/usr/bin/env bash

set -Eeuo pipefail

root_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly root_dir
readonly helper="$root_dir/scripts/webapp-managerctl"
readonly scanner="$root_dir/scripts/webapp-manager-scan.pl"

tmp_dir="$(mktemp -d)"
cleanup() {
  rm -rf -- "$tmp_dir"
}
trap cleanup EXIT

data_home="$tmp_dir/data"
applications="$data_home/applications"
mkdir -p "$applications" "$data_home/icons/hicolor/256x256/apps"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

scan() {
  XDG_DATA_HOME="$data_home" "$helper" scan
}

cat > "$applications/example.desktop" <<'EOF'
[Desktop Entry]
Name=Example
Exec=omarchy-launch-webapp https://example.com
Icon=example
MimeType=text/html;
EOF

scan_output="$(scan)"
printf '%s\n' "$scan_output" | jq -e '
  .ok == true
  and (.apps | length == 1)
  and .apps[0].name == "Example"
  and .apps[0].url == "https://example.com"
  and .apps[0].kind == "webapp"
' >/dev/null || fail "normal web-app scan"

exec_output="$("$scanner" --read-exec "$applications/example.desktop")"
printf '%s\n' "$exec_output" | jq -e '
  .ok == true
  and .exec == "omarchy-launch-webapp https://example.com"
' >/dev/null || fail "safe descriptor-based Exec read"

ln -s example.desktop "$applications/symlink.desktop"
mkfifo "$applications/fifo.desktop"

scan_output="$(timeout 2s env XDG_DATA_HOME="$data_home" "$helper" scan)" || fail "FIFO scan returned a failure or blocked"
printf '%s\n' "$scan_output" | jq -e '.ok == true and (.apps | length == 1)' >/dev/null \
  || fail "symlink/FIFO entries were not excluded"

{
  printf '[Desktop Entry]\nName='
  printf '%*s' 121 '' | tr ' ' N
  printf '\nExec=omarchy-launch-webapp https://oversized.example\n'
} > "$applications/oversized-name.desktop"

{
  printf '[Desktop Entry]\nComment='
  dd if=/dev/zero bs=1 count=65537 2>/dev/null | tr '\0' C
  printf '\n'
} > "$applications/oversized-file.desktop"

{
  printf '[Desktop Entry]\nExec='
  printf '%*s' 513 '' | tr ' ' E
  printf '\n'
} > "$applications/oversized-exec.desktop"

{
  printf '[Desktop Entry]\nExec=omarchy-launch-webapp https://icon.example\nIcon='
  printf '%*s' 257 '' | tr ' ' I
  printf '\n'
} > "$applications/oversized-icon.desktop"

{
  printf '[Desktop Entry]\nExec=omarchy-launch-webapp https://mime.example\nMimeType='
  printf '%*s' 513 '' | tr ' ' M
  printf '\n'
} > "$applications/oversized-mime.desktop"

scan_output="$(scan)" || fail "bounded scan after oversized fixtures"
printf '%s\n' "$scan_output" | jq -e '.ok == true and (.apps | length == 1)' >/dev/null \
  || fail "oversized file or field was not rejected"

set +e
fifo_output="$(timeout 2s "$scanner" --read-exec "$applications/fifo.desktop" 2>/dev/null)"
fifo_exit=$?
set -e
[[ "$fifo_exit" -eq 2 ]] || fail "FIFO --read-exec was not rejected safely"
printf '%s\n' "$fifo_output" | jq -e '.ok == false and .error.code == "unsafe-path"' >/dev/null \
  || fail "FIFO rejection response"

scan_bytes="$(LC_ALL=C printf '%s' "$scan_output" | LC_ALL=C wc -c)"
[[ "$scan_bytes" -lt $((2 * 1024 * 1024)) ]] || fail "scan output exceeded the configured cap"

printf '%s\n' 'webapp-managerctl regression tests: pass'
