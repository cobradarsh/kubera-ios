#!/bin/bash
# Drives Kubera on the jailbroken iPhone over SSH (host alias "iphone-root", TrollStore installed).
#
#   phone.sh install <Kubera.ipa>   copy the IPA over and install it with TrollStore's helper
#   phone.sh container             print the app's data folder (fixed: /var/mobile/Library/Kubera)
#   phone.sh enable | disable      create / remove the marker file that turns the test hooks on
#   phone.sh diag <command?query>  run a test hook, e.g. `diag state` (the phone must be unlocked)
#   phone.sh log [n]               last n lines of the hook log (default 40)
#   phone.sh snap <name> [wait]    picture of the app window, copied to ./shots/<name>.png
#   phone.sh launch                open the app
#   phone.sh cmd <command?query>   queue a hook in the command file (app must be running)
#   phone.sh deb <file.deb>        install the Kubera Listener tweak and respring
#   phone.sh tweaklog [n]          the tweak's log
set -u
SSHIN="${KUBERA_SSH:-ssh -o BatchMode=yes -o ConnectTimeout=12 -o ServerAliveInterval=15 ${KUBERA_PHONE:-iphone-root}}"
SSH="$SSHIN -n"   # no stdin: a waiting ssh must not hang on an open pipe
BID=com.cobradarsh.kubera
ROOT="${KUBERA_ROOT-/rootfs}"    # the real file system, as a RootHide shell sees it; "" on other jailbreaks
OUT="${KUBERA_SHOTS:-./shots}"
META=.com.apple.mobile_container_manager.metadata.plist

# Kubera keeps its data and test files at fixed paths (no app container; see App/Platform.swift).
DIAG="$ROOT/var/mobile/Library/Kubera/Diag"
container() { echo "$ROOT/var/mobile/Library/Kubera"; }

case "${1:-}" in
    install)
        [ -f "${2:-}" ] || { echo "usage: phone.sh install <Kubera.ipa>"; exit 2; }
        $SSHIN "cat > $ROOT/var/tmp/Kubera.ipa" < "$2" || exit 1
        # TrollStore's helper is not a jailbreak binary, so it gets the path as the real file system has it.
        $SSH "HELPER=\$(ls -d $ROOT/var/containers/Bundle/Application/*/TrollStore.app/trollstorehelper | head -1); \
              \"\$HELPER\" install /var/tmp/Kubera.ipa 2>&1 | tail -3; echo helper-exit=\$?; \
              rm -f $ROOT/var/tmp/Kubera.ipa; ls -d $ROOT/var/containers/Bundle/Application/*/Kubera.app"
        ;;
    container) container ;;
    enable)
        $SSH "mkdir -p '$DIAG' && touch '$DIAG/kb-diag' && chown -R mobile:mobile '$ROOT/var/mobile/Library/Kubera' && ls '$DIAG'"
        ;;
    disable)
        $SSH "cd '$DIAG' && rm -f kb-diag kb-diag.log kb-diag-cmd && find . -name 'kb-snap-*.png' -delete; ls"
        ;;
    launch) $SSH "uiopen 'kubera://'; echo uiopen-exit=\$?" ;;
    diag) $SSH "uiopen 'kubera://_diag/$2'; echo uiopen-exit=\$?" ;;
    log) $SSH "tail -n ${2:-40} '$DIAG/kb-diag.log' 2>/dev/null" ;;
    # A hook through the command file (no uiopen; works while the app is open, even in the background).
    cmd)
        $SSH "echo '$2' >> '$DIAG/kb-diag-cmd'; echo queued"
        ;;
    # The Kubera Listener tweak: copy, dpkg -i, respring.
    deb)
        [ -f "${2:-}" ] || { echo "usage: phone.sh deb <file.deb>"; exit 2; }
        $SSHIN "cat > /tmp/kuberalistener.deb" < "$2" || exit 1
        $SSH "dpkg -i /tmp/kuberalistener.deb 2>&1 | tail -3; rm -f /tmp/kuberalistener.deb; sbreload >/dev/null 2>&1 & sleep 1; echo installed"
        ;;
    tweaklog) $SSH "tail -n ${2:-30} $ROOT/var/mobile/Library/Logs/KuberaListener.log 2>/dev/null" ;;
    snap)
        mkdir -p "$OUT"
        $SSH "rm -f '$DIAG/kb-snap-$2.png'; uiopen 'kubera://_diag/snapshot?name=$2'" >/dev/null
        sleep "${3:-3}"
        $SSH "cat '$DIAG/kb-snap-$2.png'" > "$OUT/$2.png" && $SSH "rm -f '$DIAG/kb-snap-$2.png'"
        ls -la "$OUT/$2.png"
        ;;
    *) sed -n '2,13p' "$0"; exit 2 ;;
esac
