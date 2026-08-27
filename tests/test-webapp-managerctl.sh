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
mock_bin="$tmp_dir/bin"
mkdir -p "$applications" "$data_home/icons/hicolor/256x256/apps" "$mock_bin"

cat > "$mock_bin/omarchy" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ "$1" == "webapp" && "$2" == "install" && $# == 5 ]]
printf '%s\0' "$3" "$4" "$5" > "$WEBAPP_TEST_INSTALL_LOG"
printf 'installed\n'
EOF

cat > "$mock_bin/gio" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ "$1" == "trash" && "$2" == "--" && $# == 3 ]]
source_file="$3"
base_name="$(basename "$source_file")"
mkdir -p "$XDG_DATA_HOME/Trash/files" "$XDG_DATA_HOME/Trash/info"
mv -- "$source_file" "$XDG_DATA_HOME/Trash/files/$base_name"
printf '[Trash Info]\nPath=%s\nDeletionDate=2026-08-27T00:00:00\n' \
  "$source_file" > "$XDG_DATA_HOME/Trash/info/$base_name.trashinfo"
EOF

cat > "$mock_bin/update-desktop-database" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

chmod +x "$mock_bin/omarchy" "$mock_bin/gio" "$mock_bin/update-desktop-database"

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

launch_output="$("$scanner" --read-launch "$applications/example.desktop")"
printf '%s\n' "$launch_output" | jq -e '
  .ok == true
  and .launch.kind == "webapp"
  and .launch.url == "https://example.com"
' >/dev/null || fail "safe descriptor-based launch read"

cat > "$applications/handler.desktop" <<'EOF'
[Desktop Entry]
Name=HEY
Exec=omarchy-webapp-handler-hey %u
Icon=hey
EOF

handler_output="$("$scanner" --read-launch "$applications/handler.desktop")"
printf '%s\n' "$handler_output" | jq -e '
  .ok == true
  and .launch.kind == "handler"
  and .launch.handler == "hey"
' >/dev/null || fail "strict protocol-handler parsing"

cat > "$applications/unicode.desktop" <<'EOF'
[Desktop Entry]
Name=Café
Exec=omarchy-launch-webapp https://unicode.example
Icon=unicode
EOF

unicode_output="$(scan)"
printf '%s\n' "$unicode_output" | jq -e '
  .ok == true
  and ([.apps[] | select(.desktopId == "unicode")][0].name == "Café")
' >/dev/null || fail "UTF-8 desktop field decoding"

cat > "$applications/crafted.desktop" <<'EOF'
[Desktop Entry]
Name=Crafted
Exec=sh -c "touch /tmp/webapp-manager-must-not-run" omarchy-launch-webapp https://example.com
Icon=crafted
EOF

cat > "$applications/fake-handler.desktop" <<'EOF'
[Desktop Entry]
Name=Fake handler
Exec=omarchy-webapp-handler-not-installed %u
Icon=fake
EOF

scan_output="$(scan)"
printf '%s\n' "$scan_output" | jq -e '
  .ok == true
  and (.apps | length == 3)
  and ([.apps[].desktopId] | index("crafted") == null)
  and ([.apps[].desktopId] | index("fake-handler") == null)
' >/dev/null || fail "arbitrary Exec command was not excluded"

set +e
crafted_output="$(XDG_DATA_HOME="$data_home" "$helper" launch --desktop-file "$applications/crafted.desktop")"
crafted_exit=$?
set -e
[[ "$crafted_exit" -eq 2 ]] || fail "arbitrary Exec launch was not rejected"
printf '%s\n' "$crafted_output" | jq -e '.ok == false' >/dev/null \
  || fail "arbitrary Exec launch rejection response"
[[ ! -e /tmp/webapp-manager-must-not-run ]] || fail "arbitrary Exec command ran"

set +e
crafted_remove_output="$(PATH="$mock_bin:$PATH" XDG_DATA_HOME="$data_home" \
  "$helper" remove --desktop-file "$applications/crafted.desktop")"
crafted_remove_exit=$?
set -e
[[ "$crafted_remove_exit" -eq 2 && -f "$applications/crafted.desktop" ]] \
  || fail "arbitrary Exec removal was not rejected"
printf '%s\n' "$crafted_remove_output" | jq -e '.ok == false' >/dev/null \
  || fail "arbitrary Exec removal rejection response"

ln -s example.desktop "$applications/symlink.desktop"
mkfifo "$applications/fifo.desktop"

scan_output="$(timeout 2s env XDG_DATA_HOME="$data_home" "$helper" scan)" || fail "FIFO scan returned a failure or blocked"
printf '%s\n' "$scan_output" | jq -e '.ok == true and (.apps | length == 3)' >/dev/null \
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
printf '%s\n' "$scan_output" | jq -e '.ok == true and (.apps | length == 3)' >/dev/null \
  || fail "oversized file or field was not rejected"

set +e
fifo_output="$(timeout 2s "$scanner" --read-launch "$applications/fifo.desktop" 2>/dev/null)"
fifo_exit=$?
set -e
[[ "$fifo_exit" -eq 2 ]] || fail "FIFO --read-launch was not rejected safely"
printf '%s\n' "$fifo_output" | jq -e '.ok == false and .error.code == "unsafe-path"' >/dev/null \
  || fail "FIFO rejection response"

scan_bytes="$(LC_ALL=C printf '%s' "$scan_output" | LC_ALL=C wc -c)"
[[ "$scan_bytes" -lt $((2 * 1024 * 1024)) ]] || fail "scan output exceeded the configured cap"

install_log="$tmp_dir/install.log"
valid_name="$(printf 'é%.0s' {1..60})"
install_output="$(WEBAPP_TEST_INSTALL_LOG="$install_log" PATH="$mock_bin:$PATH" XDG_DATA_HOME="$data_home" \
  "$helper" install --name "$valid_name" --url "HTTPS://example.com" --icon "example")"
printf '%s\n' "$install_output" | jq -e '.ok == true' >/dev/null || fail "120-byte UTF-8 name install"
[[ "$(tr '\0' '\n' < "$install_log" | sed -n '1p')" == "$valid_name" ]] || fail "install argument integrity"
[[ "$(tr '\0' '\n' < "$install_log" | sed -n '2p')" == "HTTPS://example.com" ]] || fail "case-insensitive HTTP scheme"

oversized_name="$(printf 'é%.0s' {1..61})"
set +e
invalid_name_output="$(WEBAPP_TEST_INSTALL_LOG="$install_log" PATH="$mock_bin:$PATH" XDG_DATA_HOME="$data_home" \
  "$helper" install --name "$oversized_name" --url "https://example.com" --icon "example")"
invalid_name_exit=$?
set -e
[[ "$invalid_name_exit" -eq 2 ]] || fail "oversized UTF-8 name was accepted"
printf '%s\n' "$invalid_name_output" | jq -e '.ok == false and .error.code == "invalid-name"' >/dev/null \
  || fail "oversized UTF-8 name response"

oversized_icon="$(printf 'i%.0s' {1..257})"
set +e
invalid_icon_output="$(WEBAPP_TEST_INSTALL_LOG="$install_log" PATH="$mock_bin:$PATH" XDG_DATA_HOME="$data_home" \
  "$helper" install --name "Icon test" --url "https://example.com" --icon "$oversized_icon")"
invalid_icon_exit=$?
set -e
[[ "$invalid_icon_exit" -eq 2 ]] || fail "oversized icon was accepted"
printf '%s\n' "$invalid_icon_output" | jq -e '.ok == false and .error.code == "invalid-icon"' >/dev/null \
  || fail "oversized icon response"

set +e
invalid_url_output="$(WEBAPP_TEST_INSTALL_LOG="$install_log" PATH="$mock_bin:$PATH" XDG_DATA_HOME="$data_home" \
  "$helper" install --name "URL test" --url 'https://example.com/"bad' --icon "example")"
invalid_url_exit=$?
set -e
[[ "$invalid_url_exit" -eq 2 ]] || fail "quoted URL was accepted"
printf '%s\n' "$invalid_url_output" | jq -e '.ok == false and .error.code == "invalid-url"' >/dev/null \
  || fail "quoted URL response"

remove_output="$(PATH="$mock_bin:$PATH" XDG_DATA_HOME="$data_home" \
  "$helper" remove --desktop-file "$applications/example.desktop")"
printf '%s\n' "$remove_output" | jq -e '.ok == true' >/dev/null || fail "reversible removal"
[[ ! -e "$applications/example.desktop" ]] || fail "removed launcher remained in applications"
[[ -f "$data_home/Trash/files/example.desktop" ]] || fail "removed launcher was not moved to trash"
[[ -f "$data_home/Trash/info/example.desktop.trashinfo" ]] || fail "trash metadata was not created"
grep -Fq "Path=$applications/example.desktop" "$data_home/Trash/info/example.desktop.trashinfo" \
  || fail "trash metadata original path"

cap_home="$tmp_dir/cap-data"
cap_apps="$cap_home/applications"
mkdir -p "$cap_apps"
CAP_APPS="$cap_apps" perl -e '
  use strict;
  use warnings;
  my $directory = $ENV{CAP_APPS};
  for my $index (1 .. 256) {
    my $path = sprintf("%s/app-%03d.desktop", $directory, $index);
    open(my $file, ">", $path) or die $!;
    binmode($file);
    print {$file} "[Desktop Entry]\nName=", "\x01" x 120,
      "\nExec=omarchy-launch-webapp https://x.example/", "\x01" x 460,
      "\nIcon=", "\x01" x 256,
      "\nMimeType=", "\x01" x 512, "\n";
    close($file);
  }
'
set +e
cap_output="$(timeout 5s "$scanner" "$cap_apps" "$cap_home")"
cap_exit=$?
set -e
[[ "$cap_exit" -eq 1 ]] || fail "output-cap scan did not fail quickly and safely"
printf '%s\n' "$cap_output" | jq -e '.ok == false and .error.code == "output-limit"' >/dev/null \
  || fail "output-cap response"
cap_bytes="$(LC_ALL=C printf '%s\n' "$cap_output" | LC_ALL=C wc -c)"
[[ "$cap_bytes" -lt 256 ]] || fail "output-cap error was unexpectedly large"

limit_home="$tmp_dir/limit-data"
limit_apps="$limit_home/applications"
mkdir -p "$limit_apps"
LIMIT_APPS="$limit_apps" perl -e '
  use strict;
  use warnings;
  my $directory = $ENV{LIMIT_APPS};
  for my $index (1 .. 257) {
    my $path = sprintf("%s/app-%03d.desktop", $directory, $index);
    open(my $file, ">", $path) or die $!;
    print {$file} "[Desktop Entry]\nName=App $index\nExec=omarchy-launch-webapp https://example.com/$index\n";
    close($file);
  }
'
limit_output="$(timeout 5s "$scanner" "$limit_apps" "$limit_home")" || fail "entry-count cap scan"
printf '%s\n' "$limit_output" | jq -e '.ok == true and (.apps | length == 256)' >/dev/null \
  || fail "entry-count cap"

printf '%s\n' 'webapp-managerctl regression tests: pass'
