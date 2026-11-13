#!/bin/bash
# tests/wifi-manager-retry-test.sh
#
# Proves the wrong-password handling in scripts/wifi-manager.sh without
# touching the real NetworkManager or the radio (the stub `nmcli` keeps its
# whole world in a temp directory, and `sleep` is a no-op):
#
#   * a rejected password does not stay saved - the profile that only exists
#     because of a failed attempt is removed again
#   * the retry loop asks for the password again, up to three attempts
#   * an already-saved profile is re-keyed in place, never duplicated
#   * an already-saved profile is never deleted behind the user's back
#   * delete_saved_network() asks first, can be cancelled, and needs a second
#     confirmation when the profile carries the current connection
#
# The functions under test are extracted from the shipped script, so this test
# fails loudly if they ever move or disappear.

set -u

REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$REPO_DIR/scripts/wifi-manager.sh"
[ -f "$SCRIPT" ] || { echo "FATAL: $SCRIPT not found"; exit 1; }

FAKE_DIR=$(mktemp -d /tmp/wifi-retry-test-XXXXXX) || exit 1
trap 'rm -rf "$FAKE_DIR"' EXIT
mkdir -p "$FAKE_DIR/bin"
export FAKE_DIR
: > "$FAKE_DIR/db"        # uuid|name|psk
: > "$FAKE_DIR/active"    # uuid of the activated profile (empty = none)
: > "$FAKE_DIR/calls"     # every stub nmcli call, for assertions
printf 'goodpass' > "$FAKE_DIR/correct"

# ------------------------------------------------------------------
# Stub NetworkManager CLI
# ------------------------------------------------------------------
cat > "$FAKE_DIR/bin/nmcli" <<'STUB'
#!/bin/bash
DB="$FAKE_DIR/db"
ACTIVEFILE="$FAKE_DIR/active"
CORRECT=$(cat "$FAKE_DIR/correct")
echo "nmcli $*" >> "$FAKE_DIR/calls"

FIELD=""
ACTIVE_ONLY=0
while [ $# -gt 0 ]; do
    case "$1" in
        -t)        shift ;;
        -f)        FIELD="$2"; shift 2 ;;
        --active)  ACTIVE_ONLY=1; shift ;;
        *)         break ;;
    esac
done
# --active can follow the subcommand, e.g. `connection show --active`
for a in "$@"; do
    [ "$a" = "--active" ] && ACTIVE_ONLY=1
done

uuid_of()  { awk -F'|' -v u="$1" '$1==u{print $2; exit}' "$DB"; }
psk_of()   { awk -F'|' -v u="$1" '$1==u{print $3; exit}' "$DB"; }
set_psk()  { awk -F'|' -v u="$1" -v p="$2" 'BEGIN{OFS="|"} $1==u{$3=p} {print}' "$DB" > "$DB.tmp"
             mv "$DB.tmp" "$DB"; }
active_uuid() { cat "$ACTIVEFILE" 2>/dev/null; }
deactivate()  { : > "$ACTIVEFILE"; }

case "$1" in
device)
    case "$2" in
        status)
            case "$FIELD" in
                DEVICE,TYPE)  echo "wlan0:wifi" ;;
                DEVICE,STATE)
                    if [ -n "$(active_uuid)" ]; then
                        echo "wlan0:connected"
                    else
                        echo "wlan0:disconnected"
                    fi ;;
            esac ;;
        show)
            if [ -n "$(active_uuid)" ]; then
                echo "GENERAL.CONNECTION:$(uuid_of "$(active_uuid)")"
            else
                echo "GENERAL.CONNECTION:"
            fi ;;
        wifi)
            case "$3" in
                connect)
                    ssid="$4"; pass=""
                    if [ "${5:-}" = "password" ]; then pass="$6"; fi
                    u=$(awk -F'|' -v n="$ssid" '$2==n{print $1; exit}' "$DB")
                    if [ -z "$u" ]; then
                        u="uuid-$RANDOM$RANDOM"
                        printf '%s|%s|%s\n' "$u" "$ssid" "$pass" >> "$DB"
                    fi
                    [ -n "$pass" ] && set_psk "$u" "$pass"
                    if [ "$(psk_of "$u")" = "$CORRECT" ]; then
                        printf '%s' "$u" > "$ACTIVEFILE"
                        echo "Device 'wlan0' successfully activated."
                        exit 0
                    fi
                    echo "Error: Connection activation failed: (7) Secrets were required, but not provided." >&2
                    exit 4 ;;
                rescan) exit 0 ;;
                list)
                    # One visible, secured network: SSID:SIGNAL:BSSID\:..:SECURITY
                    printf 'TestNet:90:AA\\:BB\\:CC\\:DD\\:EE\\:FF:WPA2\n' ;;
            esac ;;
    esac ;;
connection)
    case "$2" in
        show)
            if [ "$ACTIVE_ONLY" = "1" ]; then
                [ -n "$(active_uuid)" ] && echo "$(active_uuid):802-11-wireless"
                exit 0
            fi
            if [ -n "${3:-}" ]; then
                u="$3"
                case "$FIELD" in
                    connection.id)                        v=$(uuid_of "$u") ;;
                    connection.autoconnect)               v="yes" ;;
                    connection.timestamp)                 v="0" ;;
                    802-11-wireless.ssid)                 v=$(uuid_of "$u") ;;
                    802-11-wireless-security.key-mgmt)    v="wpa-psk" ;;
                    802-11-wireless-security.wep-key-type) v="unknown" ;;
                    *)                                    v="" ;;
                esac
                echo "$FIELD:$v"
            else
                while IFS='|' read -r u n p; do
                    [ -z "$u" ] && continue
                    case "$FIELD" in
                        UUID)           echo "$u" ;;
                        UUID,TYPE)      echo "$u:802-11-wireless" ;;
                        NAME,UUID,TYPE) echo "$n:$u:802-11-wireless" ;;
                        *)              echo "$n:$u:802-11-wireless" ;;
                    esac
                done < "$DB"
            fi ;;
        modify)
            u="$3"; shift 3
            while [ $# -gt 0 ]; do
                case "$1" in
                    wifi-sec.psk|wifi-sec.wep-key0) set_psk "$u" "$2"; shift 2 ;;
                    *) shift ;;
                esac
            done ;;
        delete)
            u="$3"; n=$(uuid_of "$u")
            awk -F'|' -v u="$u" '$1!=u' "$DB" > "$DB.tmp"; mv "$DB.tmp" "$DB"
            if [ "$(active_uuid)" = "$u" ]; then deactivate; fi
            echo "Connection '$n' ($u) successfully deleted." ;;
        up)
            u="$3"
            if [ -z "$(uuid_of "$u")" ]; then
                echo "Error: unknown connection '$u'." >&2
                exit 10
            fi
            if [ "$(psk_of "$u")" = "$CORRECT" ]; then
                printf '%s' "$u" > "$ACTIVEFILE"
                echo "Connection successfully activated."
                exit 0
            fi
            echo "Error: Connection activation failed: (7) Secrets were required, but not provided." >&2
            exit 4 ;;
    esac ;;
esac
exit 0
STUB
chmod +x "$FAKE_DIR/bin/nmcli"
export PATH="$FAKE_DIR/bin:$PATH"

# ------------------------------------------------------------------
# Take the functions under test out of the shipped script
# ------------------------------------------------------------------
FUNCS="$FAKE_DIR/functions.sh"
awk '/^get_wifi_ifaces\(\) \{/ { f=1 }
     f && /^list_saved_networks\(\) \{/ { exit }
     f { print }' "$SCRIPT" > "$FUNCS"
awk '/^delete_saved_network\(\) \{/ { f=1 }
     f && /^# -{10,}/ { exit }
     f { print }' "$SCRIPT" >> "$FUNCS"

for fn in get_wifi_ifaces wifi_connect_try wifi_connect_with_retry find_connection_uuid \
          set_connection_password confirm_yes prompt_password \
          join_network delete_saved_network; do
    if ! grep -q "^${fn}() {" "$FUNCS"; then
        echo "FATAL: could not extract ${fn}() from $SCRIPT"
        exit 1
    fi
done
bash -n "$FUNCS" || { echo "FATAL: extracted functions do not parse"; exit 1; }

BOLD=''; NC=''; RED=''; GREEN=''; YELLOW=''
# shellcheck disable=SC1090
. "$FUNCS"
sleep() { :; }                # keep the retry waits from making the test slow
internet_ok() { return 0; }   # no real ping in the simulation
VERBOSE=false

# ------------------------------------------------------------------
# Helpers and assertions
# ------------------------------------------------------------------
reset_fake() {
    : > "$FAKE_DIR/db"
    : > "$FAKE_DIR/active"
    : > "$FAKE_DIR/calls"
}

add_fake_profile() {   # $1 name, $2 psk -> uuid
    local uuid="uuid-$RANDOM$RANDOM"
    printf '%s|%s|%s\n' "$uuid" "$1" "$2" >> "$FAKE_DIR/db"
    echo "$uuid"
}

count_profiles() { awk 'END{print NR+0}' "$FAKE_DIR/db"; }
psk_of()  { awk -F'|' -v n="$1" '$2==n{print $3; exit}' "$FAKE_DIR/db"; }
uuid_of() { awk -F'|' -v n="$1" '$2==n{print $1; exit}' "$FAKE_DIR/db"; }

PASS=0
FAIL=0
check() {   # $1 description, $2 expected, $3 actual
    if [ "$2" = "$3" ]; then
        printf '  ok   %s\n' "$1"
        PASS=$((PASS + 1))
    else
        printf '  FAIL %s\n       expected: %s\n       actual:   %s\n' "$1" "$2" "$3"
        FAIL=$((FAIL + 1))
    fi
}
check_contains() {   # $1 description, $2 needle, $3 haystack
    case "$3" in
        *"$2"*) check "$1" "yes" "yes" ;;
        *)      check "$1" "yes" "no" ;;
    esac
}

echo "*****************************************************"
echo "WIFI MANAGER - WRONG PASSWORD / DELETE SIMULATION"
echo "*****************************************************"
echo "script:   $SCRIPT"
echo "fake NM:  $FAKE_DIR"
echo ""

# ------------------------------------------------------------------
echo "1. New network, wrong password, then the corrected one"
reset_fake
out=$(printf 'y\ngoodpass\n' | wifi_connect_with_retry wlan0 TestNet "" badpass true "")
rc=$?
check "returns success after the retry"           0 "$rc"
check "exactly one profile is saved"              1 "$(count_profiles)"
check "the saved password is the corrected one"   goodpass "$(psk_of TestNet)"
check_contains "the failed attempt was cleaned up" \
    "Removed the profile this attempt created" "$out"
check_contains "the attempt counter is shown" "attempt 1/3" "$out"

# ------------------------------------------------------------------
echo ""
echo "2. New network, wrong password, retry declined"
reset_fake
out=$(printf 'n\n' | wifi_connect_with_retry wlan0 TestNet "" badpass true "")
rc=$?
check "returns failure"                    1 "$rc"
check "no profile is left behind"          0 "$(count_profiles)"
check_contains "output says nothing was kept" \
    "Removed the profile this attempt created" "$out"

# ------------------------------------------------------------------
echo ""
echo "3. Three wrong attempts in a row"
reset_fake
printf 'y\nbad2\ny\nbad3\n' \
    | wifi_connect_with_retry wlan0 TestNet "" bad1 true "" > "$FAKE_DIR/out3"
check "returns failure after three attempts" 1 "$?"
check "no profile is left behind"            0 "$(count_profiles)"
check "exactly three attempts were made"     3 \
    "$(grep -c 'device wifi connect TestNet' "$FAKE_DIR/calls")"

# ------------------------------------------------------------------
echo ""
echo "4. Already-saved profile with a bad secret, password re-entered"
reset_fake
uuid=$(add_fake_profile TestNet badpass)
: > "$FAKE_DIR/calls"
wifi_connect_with_retry wlan0 TestNet "$uuid" goodpass true "$uuid" > /dev/null
check "connects with the corrected password"  0 "$?"
check "still exactly one profile"             1 "$(count_profiles)"
check "uuid unchanged (re-keyed in place)"    "$uuid" "$(uuid_of TestNet)"
check "stored password was corrected"         goodpass "$(psk_of TestNet)"

# ------------------------------------------------------------------
echo ""
echo "5. Already-saved profile, wrong password, retry declined"
reset_fake
uuid=$(add_fake_profile TestNet goodpass)
wifi_connect_with_retry wlan0 TestNet "$uuid" wrongpass true "$uuid" > /dev/null
check "returns failure"                                      1 "$?"
check "the existing profile is kept (deletion is the user's call)" 1 "$(count_profiles)"

# ------------------------------------------------------------------
echo ""
echo "6. Deleting a saved network"
reset_fake
add_fake_profile "Keep Me" secret > /dev/null
out=$(printf 'X\n' | delete_saved_network)
check "X cancels the listing"        1 "$(count_profiles)"
check_contains "cancel is reported" "Cancelled. Nothing was deleted." "$out"

out=$(printf '1\nn\n' | delete_saved_network)
check "answering n keeps the profile" 1 "$(count_profiles)"
check_contains "cancel is reported"   "Cancelled. Nothing was deleted." "$out"

out=$(printf '1\ny\n' | delete_saved_network)
check "answering y deletes the profile" 0 "$(count_profiles)"
check_contains "success is reported" "SUCCESS:" "$out"


reset_fake
uuid=$(add_fake_profile "Active One" secret)
printf '%s' "$uuid" > "$FAKE_DIR/active"
out=$(printf '1\ny\nn\n' | delete_saved_network)
check "active profile is kept when the second prompt is declined" 1 "$(count_profiles)"
check_contains "cancel is reported" "Cancelled. Nothing was deleted." "$out"

# Only one 'y' (then EOF) must not be enough either: the active profile needs
# a second, separate confirmation.
reset_fake
uuid=$(add_fake_profile "Active One" secret)
printf '%s' "$uuid" > "$FAKE_DIR/active"
out=$(printf '1\ny\n' | delete_saved_network)
check "one y is not enough for the active profile" 1 "$(count_profiles)"
check_contains "cancel is reported" "Cancelled. Nothing was deleted." "$out"

reset_fake
uuid=$(add_fake_profile "Active One" secret)
printf '%s' "$uuid" > "$FAKE_DIR/active"
out=$(printf '1\ny\ny\n' | delete_saved_network)
check "active profile is deleted after both confirmations" 0 "$(count_profiles)"


# ------------------------------------------------------------------
echo ""
echo "7. join_network: saved profile, password typed again ('p')"
reset_fake
uuid=$(add_fake_profile TestNet badpass)
out=$(printf '1\np\nwrongpass\ny\ngoodpass\n' | join_network)
check "join succeeds after correcting the password" 0 "$?"
check "still exactly one profile"                    1 "$(count_profiles)"
check "uuid unchanged (re-keyed in place)"           "$uuid" "$(uuid_of TestNet)"
check "stored password was corrected"                goodpass "$(psk_of TestNet)"
check_contains "the saved profile was offered" "already has a saved profile" "$out"
check_contains "the failed attempt was reported" "was not accepted" "$out"

# ------------------------------------------------------------------
echo ""
echo "8. join_network: saved profile deleted ('d'), then joined fresh"
reset_fake
uuid=$(add_fake_profile TestNet goodpass)
out=$(printf '1\nd\ny\ngoodpass\n' | join_network)
check "join succeeds"                        0 "$?"
check "exactly one profile exists afterwards" 1 "$(count_profiles)"
check "the new profile is not the deleted uuid" "yes" \
    "$([ "$(uuid_of TestNet)" != "$uuid" ] && echo yes || echo no)"
check "the network is saved with the good password" goodpass "$(psk_of TestNet)"

# ------------------------------------------------------------------
echo ""
echo "9. join_network: brand-new network, wrong password twice, then right"
reset_fake
out=$(printf '1\nbad1\ny\nbad2\ny\ngoodpass\n' | join_network)
check "join succeeds on the third attempt"   0 "$?"
check "exactly one profile is left"          1 "$(count_profiles)"
check "saved password is the accepted one"   goodpass "$(psk_of TestNet)"
check "three connect attempts were made"     3 \
    "$(grep -c 'device wifi connect TestNet' "$FAKE_DIR/calls")"

# ------------------------------------------------------------------
echo ""
echo "10. join_network: wrong password, retry declined, falls back to the old network"
reset_fake
home=$(add_fake_profile Home goodpass)
printf '%s' "$home" > "$FAKE_DIR/active"
out=$(printf '1\nbad1\nn\n' | join_network)
check "join reports failure"                        1 "$?"
check "only the old profile remains"                1 "$(count_profiles)"
check "the old network is re-activated"             "$home" "$(cat "$FAKE_DIR/active")"
check_contains "nothing was kept from the attempt" \
    "No profile was left behind, so the wrong password is not saved." "$out"
check_contains "the fallback ran" "Falling back" "$out"

# ------------------------------------------------------------------
# ------------------------------------------------------------------
echo ""
echo "*****************************************************"
echo "RESULT: $PASS passed, $FAIL failed"
echo "*****************************************************"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
