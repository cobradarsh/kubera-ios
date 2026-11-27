#!/bin/bash
# One check of Kubera on the phone while it is unlocked: waits until the app has a window, then runs the steps
# file (lines: a hook like `diag open?type=movie&id=tt1375666`, `snap <name> [wait]`, `sleep <s>`, `log <n>`,
# `# comment`). Pictures go to ./shots.
set -u
cd "$(dirname "$0")/.."
P=tools/phone.sh
STEPS="${1:?steps file}"
echo "waiting for the app to be in front (unlock the phone)…"
end=$((SECONDS + 300))
while [ $SECONDS -lt $end ]; do
    bash $P launch </dev/null >/dev/null 2>&1
    sleep 3
    bash $P diag "snapshot?name=probe" </dev/null >/dev/null 2>&1
    sleep 2
    if bash $P log 1 </dev/null | grep -q "snapshot kb-snap-probe"; then echo "app in front"; break; fi
done
[ $SECONDS -lt $end ] || { echo "gave up: the app never came to the front"; exit 1; }
while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
        ''|'#'*) [ -n "$line" ] && echo "$line"; continue ;;
        sleep\ *) sleep "${line#sleep }" ;;
        snap\ *) bash $P $line </dev/null ;;
        log\ *) bash $P $line </dev/null ;;
        diag\ *) echo "> $line"; bash $P diag "${line#diag }" </dev/null >/dev/null ;;
        *) echo "unknown step: $line" ;;
    esac
done < "$STEPS"
