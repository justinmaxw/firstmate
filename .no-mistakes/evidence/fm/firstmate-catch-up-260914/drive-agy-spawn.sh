#!/usr/bin/env bash
# Drives bin/fm-spawn.sh on harness=agy in an isolated firstmate home.
# tmux is faked (records the literal launch payload); `agy models` is served by
# the REAL installed agy 1.2.2 against the captain's real signed-in account, so
# the live catalog check is genuine.
set -u
ROOT=$1; shift
REAL_AGY=$(command -v agy); REAL_HOME=$HOME
. "$ROOT/tests/agy-helpers.sh"
TMP=$(mktemp -d /tmp/agy-live.XXXX)
name=$1; shift
rec=$(make_agy_case "$TMP" "$name")
IFS='|' read -r case_dir home proj wt fakebin id agyhome <<<"$rec"
cat > "$fakebin/agy" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = models ]; then HOME="$REAL_HOME" exec "$REAL_AGY" models; fi
printf '%s\n' "\$*" >> "$home/agy-argv.log"
SH
chmod +x "$fakebin/agy"
out=$(run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$id" "$agyhome" "$@"); status=$?
echo "=== fm-spawn $id agy $* -> exit $status"
printf '%s\n' "$out" | grep -iE 'error|notice|refus' | head -5
[ -f "$home/launch.log" ] && { echo "--- launch payload:"; grep -o '\-\-prompt-interactive.*' "$home/launch.log" | sed 's/"\$(.*)"/"<brief>"/' | head -1; }
[ -f "$home/state/$id.meta" ] && { echo "--- meta:"; grep -E '^(harness|model|effort)=' "$home/state/$id.meta"; } || echo "--- no task meta published"
rm -rf "$TMP"
