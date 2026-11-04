#!/bin/sh
# browser-name — the browser this machine actually runs, for fastfetch.
# (The dotfiles used to hardcode "echo firefox", which kept claiming Firefox
# long after it was removed.)

for cand in /opt/google/chrome/chrome /usr/bin/google-chrome-stable /usr/bin/google-chrome; do
    if [ -x "$cand" ]; then
        ver=$("$cand" --version 2>/dev/null | awk '{print $NF}')
        case "$cand" in
            *google*) name="Google Chrome" ;;
            *)        name="Chrome" ;;
        esac
        printf '%s %s\n' "$name" "$ver"
        exit 0
    fi
done

for cand in /usr/bin/chromium /usr/bin/ungoogled-chromium /usr/bin/chromium-browser; do
    if [ -x "$cand" ]; then
        printf 'Chromium %s\n' "$("$cand" --version 2>/dev/null | awk '{print $NF}')"
        exit 0
    fi
done

if command -v firefox >/dev/null 2>&1; then
    printf 'Firefox\n'
else
    printf 'none\n'
fi
