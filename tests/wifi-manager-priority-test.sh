#!/bin/bash
# tests/wifi-manager-priority-test.sh
#
# Proves the "prioritize saved networks" feature of scripts/wifi-manager.sh
# without touching the real NetworkManager or the radio (the stub `nmcli` keeps
# its whole world in a temp directory):
#
#   * the listing is in NetworkManager's own try-order: highest
#     connection.autoconnect-priority first, most-recently-used as tie-break
#   * "move rank N to position M" re-numbers the profiles so that rank 1 really
#     has the highest autoconnect-priority (that is what "1 = first" means to
#     NetworkManager - the highest number wins)
#   * priorities stay distinct and positive, and the order survives a re-read
#   * invalid input changes nothing at all
#   * A re-ranks by last used
#   * a profile with autoconnect=no is offered to be switched on (asked, never
#     done silently), because otherwise its rank would do nothing at boot
#   * the main menu actually offers the feature (option 6)
#
# The functions under test are extracted from the shipped script, so this test
# fails loudly if they ever move or disappear.

set -u

REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$REPO_DIR/scripts/wifi-manager.sh"
[ -f "$SCRIPT" ] || { echo "FATAL: $SCRIPT not found"; exit 1; }

FAKE_DIR=$(mktemp -d /tmp/wifi-prio-test-XXXXXX) || exit 1
trap 'rm -rf "$FAKE_DIR"' EXIT
mkdir -p "$FAKE_DIR/bin"
export FAKE_DIR
: > "$FAKE_DIR/db"        # uuid|name|autoconnect|priority|timestamp
: > "$FAKE_DIR/active"    # uuid of the active profile (empty = none)
: > "$FAKE_DIR/calls"     # every stub nmcli call, for assertions

# ------------------------------------------------------------------
# Stub NetworkManager CLI
# ------------------------------------------------------------------
cat > "$FAKE_DIR/bin/nmcli" <<'STUB'
#!/bin/bash
DB="$FAKE_DIR/db"
echo "nmcli $*" >> "$FAKE_DIR/calls"

FIELD=""
ACTIVE_ONLY=0
while [ $# -gt 0 ]; do
    case "$1" in
        -t)       shift ;;
        -f)       FIELD="$2"; shift 2 ;;
        --active) ACTIVE_ONLY=1; shift ;;
        *)        break ;;
    esac
done
for a in "$@"; do
    [ "$a" = "--active" ] && ACTIVE_ONLY=1
done

# uuid|name|autoconnect|priority|timestamp
name_of() { awk -F'|' -v u="$1" '$1==u{print $2; exit}' "$DB"; }
auto_of() { awk -F'|' -v u="$1" '$1==u{print $3; exit}' "$DB"; }
prio_of() { awk -F'|' -v u="$1" '$1==u{print $4; exit}' "$DB"; }
ts_of()   { awk -F'|' -v u="$1" '$1==u{print $5; exit}' "$DB"; }

set_field() {   # $1 uuid, $2 field number, $3 value
    awk -F'|' -v u="$1" -v f="$2" -v v="$3" 'BEGIN{OFS="|"} $1==u{$f=v} {print}' "$DB" > "$DB.tmp"
    mv "$DB.tmp" "$DB"
}

case "$1" in
connection)
    case "$2" in
        show)
            if [ "$ACTIVE_ONLY" = "1" ]; then
                [ -s "$FAKE_DIR/active" ] && echo "$(cat "$FAKE_DIR/active"):802-11-wireless"
                exit 0
            fi
            if [ -n "${3:-}" ]; then
                u="$3"
                case "$FIELD" in
                    connection.id)                    v=$(name_of "$u") ;;
                    connection.autoconnect)           v=$(auto_of "$u") ;;
                    connection.autoconnect-priority)  v=$(prio_of "$u") ;;
                    connection.timestamp)             v=$(ts_of "$u") ;;
                    *)                                v="" ;;
                esac
                echo "$FIELD:$v"
            else
                while IFS='|' read -r u n a p t; do
                    [ -z "$u" ] && continue
                    case "$FIELD" in
                        NAME,UUID,TYPE) echo "$n:$u:802-11-wireless" ;;
                        UUID,TYPE)      echo "$u:802-11-wireless" ;;
                        UUID)           echo "$u" ;;
                        *)              echo "$n:$u:802-11-wireless" ;;
                    esac
                done < "$DB"
            fi ;;
        modify)
            u="$3"; shift 3
            while [ $# -gt 0 ]; do
                case "$1" in
                    connection.autoconnect-priority) set_field "$u" 4 "$2"; shift 2 ;;
                    connection.autoconnect)          set_field "$u" 3 "$2"; shift 2 ;;
                    *) shift ;;
                esac
            done ;;
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
awk '/^prioritize_saved_networks\(\) \{/ { f=1 }
     f && /^delete_saved_network\(\) \{/ { exit }
     f { print }' "$SCRIPT" >> "$FUNCS"

for fn in active_wifi_uuid connection_priority saved_wifi_order \
          apply_autoconnect_order show_priority_list reorder_uuid_file \
          apply_last_used_order prioritize_saved_networks confirm_yes; do
    if ! grep -q "^${fn}() {" "$FUNCS"; then
        echo "FATAL: could not extract ${fn}() from $SCRIPT"
        exit 1
    fi
done
bash -n "$FUNCS" || { echo "FATAL: extracted functions do not parse"; exit 1; }

BOLD=''; NC=''; RED=''; GREEN=''; YELLOW=''
# shellcheck disable=SC1090
. "$FUNCS"

# ------------------------------------------------------------------
# Helpers and assertions
# ------------------------------------------------------------------
reset_fake() {
    : > "$FAKE_DIR/db"
    : > "$FAKE_DIR/active"
    : > "$FAKE_DIR/calls"
}

add_profile() {   # $1 name, $2 autoconnect, $3 priority, $4 timestamp -> uuid
    local uuid="uuid-$RANDOM$RANDOM"
    printf '%s|%s|%s|%s|%s\n' "$uuid" "$1" "$2" "$3" "$4" >> "$FAKE_DIR/db"
    echo "$uuid"
}

prio_of()    { awk -F'|' -v n="$1" '$2==n{print $4; exit}' "$FAKE_DIR/db"; }
auto_of()    { awk -F'|' -v n="$1" '$2==n{print $3; exit}' "$FAKE_DIR/db"; }
uuid_of()    { awk -F'|' -v n="$1" '$2==n{print $1; exit}' "$FAKE_DIR/db"; }
name_of_file() {   # $1 = rank in the ordered UUID file -> profile name
    awk -F'|' -v u="$(sed -n "$1p" "$FAKE_DIR/order")" '$1==u{print $2; exit}' "$FAKE_DIR/db"
}

refresh_order() {   # snapshot the live NetworkManager order into $FAKE_DIR/order
    show_priority_list "$FAKE_DIR/order" > /dev/null
}

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
echo "WIFI MANAGER - PRIORITIZE SAVED NETWORKS SIMULATION"
echo "*****************************************************"
echo "script:    $SCRIPT"
echo "fake NM:   $FAKE_DIR"
echo ""

# ------------------------------------------------------------------
echo "1. The listing is in NetworkManager's own try-order"
reset_fake
home=$(add_profile Home yes 0 100)
office=$(add_profile Office yes 0 300)
cafe=$(add_profile Cafe yes 5 50)
out=$(show_priority_list "$FAKE_DIR/order")
check "highest priority first"            "Cafe"   "$(name_of_file 1)"
check "ties broken by most recent"        "Office" "$(name_of_file 2)"
check "oldest of the ties last"           "Home"   "$(name_of_file 3)"
check "every saved network is listed"     3 "$(grep -c . "$FAKE_DIR/order")"
check_contains "ranks are shown"          "1. Cafe" "$out"
check_contains "priority is shown"        "priority=5" "$out"

# ------------------------------------------------------------------
echo ""
echo "2. Move rank 2 to position 1 -> that network becomes first"
reset_fake
a=$(add_profile Alpha yes 0 300)          # tried first to start with
b=$(add_profile Bravo yes 0 200)
c=$(add_profile Charlie yes 0 100)
printf '2\n1\nX\n' | prioritize_saved_networks > "$FAKE_DIR/out2"
refresh_order
rc=$?
check "returns success"                       0 "$rc"
check "Bravo is now rank 1"                   "$b" "$(head -1 "$FAKE_DIR/order")"
check "rank 1 has the highest priority"       30 "$(prio_of Bravo)"
check "rank 2 is next"                        20 "$(prio_of Alpha)"
check "rank 3 is last"                        10 "$(prio_of Charlie)"
check "priorities are distinct"               3 \
    "$(awk -F'|' '{print $4}' "$FAKE_DIR/db" | sort -u | grep -c .)"
check "every priority is positive"            0 "$(awk -F'|' '$4<=0' "$FAKE_DIR/db" | wc -l | tr -d ' ')"
check_contains "the move is reported"         "Moved to position 1" "$(cat "$FAKE_DIR/out2")"
check_contains "success is reported"          "SUCCESS:" "$(cat "$FAKE_DIR/out2")"

# ------------------------------------------------------------------
echo ""
echo "3. The new order survives a re-read (it is in the profiles, not in RAM)"
out=$(show_priority_list "$FAKE_DIR/order")
check "Bravo is still rank 1"      "$b" "$(head -1 "$FAKE_DIR/order")"
check "Alpha is still rank 2"      "$a" "$(sed -n 2p "$FAKE_DIR/order")"
check_contains "the priority is read back" "priority=30" "$out"

# ------------------------------------------------------------------
echo ""
echo "4. Moving to the last position"
reset_fake
a=$(add_profile Alpha yes 0 300)
b=$(add_profile Bravo yes 0 200)
printf '1\n2\nX\n' | prioritize_saved_networks > /dev/null
refresh_order
check "Bravo is rank 1" "$b" "$(head -1 "$FAKE_DIR/order")"
check "Alpha is rank 2" "$a" "$(sed -n 2p "$FAKE_DIR/order")"
check "rank 1 priority" 20 "$(prio_of Bravo)"
check "rank 2 priority" 10 "$(prio_of Alpha)"

# ------------------------------------------------------------------
echo ""
echo "5. Invalid input changes nothing"
reset_fake
a=$(add_profile Alpha yes 10 300)
b=$(add_profile Bravo yes 20 200)
printf '9\n1\n5\n2\nX\n' | prioritize_saved_networks > "$FAKE_DIR/out5"
refresh_order
check "out-of-range rank is refused"      10 "$(prio_of Alpha)"
check "unchanged priority for Bravo"      20 "$(prio_of Bravo)"
check "still only two profiles"           2 "$(grep -c . "$FAKE_DIR/db")"
check_contains "invalid rank is reported" "Invalid choice." "$(cat "$FAKE_DIR/out5")"
check_contains "invalid position is reported" "Invalid position. Nothing changed." "$(cat "$FAKE_DIR/out5")"

# A non-numeric answer at the first prompt must not be read as a rank.
reset_fake
add_profile Alpha yes 10 300 > /dev/null
printf 'zz\nX\n' | prioritize_saved_networks > "$FAKE_DIR/out5b"
refresh_order
check "a word is not a rank"          10 "$(prio_of Alpha)"
check_contains "the word is rejected" "Invalid choice." "$(cat "$FAKE_DIR/out5b")"

# Moving a rank onto itself is a no-op, not an error.
reset_fake
add_profile Alpha yes 10 300 > /dev/null
printf '1\n1\nX\n' | prioritize_saved_networks > "$FAKE_DIR/out5c"
refresh_order
check "same position keeps the priority" 10 "$(prio_of Alpha)"
check_contains "same position is reported" "already at position 1" "$(cat "$FAKE_DIR/out5c")"

# ------------------------------------------------------------------
echo ""
echo "6. A re-ranks by last used (most recently joined = 1)"
reset_fake
old=$(add_profile Old yes 30 100)
new=$(add_profile New yes 10 400)
printf 'A\nX\n' | prioritize_saved_networks > "$FAKE_DIR/out6"
refresh_order
check "the most recently used is rank 1" "$new" "$(head -1 "$FAKE_DIR/order")"
check "the older one is rank 2"          "$old" "$(sed -n 2p "$FAKE_DIR/order")"
check "rank 1 has the higher priority"   20 "$(prio_of New)"
check "rank 2 has the lower priority"    10 "$(prio_of Old)"
check_contains "the re-rank is reported" "Re-ranked by last used" "$(cat "$FAKE_DIR/out6")"

# ------------------------------------------------------------------
echo ""
echo "7. autoconnect=no is asked about, never changed silently"
reset_fake
a=$(add_profile Alpha yes 30 400)     # rank 1
b=$(add_profile Bravo no 10 300)      # rank 2, would be skipped at boot
printf '2\n1\ny\nX\n' | prioritize_saved_networks > "$FAKE_DIR/out7"
refresh_order
check "Bravo is rank 1"                    "$b" "$(head -1 "$FAKE_DIR/order")"
check "autoconnect was enabled after y"    "yes" "$(auto_of Bravo)"
check_contains "the problem was explained" "autoconnect=no" "$(cat "$FAKE_DIR/out7")"
check_contains "the change is reported"    "autoconnect enabled" "$(cat "$FAKE_DIR/out7")"

reset_fake
a=$(add_profile Alpha yes 30 400)
b=$(add_profile Bravo no 10 300)
printf '2\n1\nn\nX\n' | prioritize_saved_networks > "$FAKE_DIR/out7b"
refresh_order
check "declining leaves autoconnect=no"    "no" "$(auto_of Bravo)"
check "the rank is still applied"          "$b" "$(head -1 "$FAKE_DIR/order")"

# ------------------------------------------------------------------
echo ""
echo "8. With no saved networks it says so and changes nothing"
reset_fake
out=$(printf 'X\n' | prioritize_saved_networks)
check "returns success" 0 "$?"
check_contains "there is nothing to rank" "No saved WiFi networks yet" "$out"
check "no nmcli modify was attempted" 0 "$(grep -c 'connection modify' "$FAKE_DIR/calls")"

# ------------------------------------------------------------------
echo ""
echo "9. reorder_uuid_file moves exactly one entry"
printf 'one\ntwo\nthree\nfour\n' > "$FAKE_DIR/move"
reorder_uuid_file "$FAKE_DIR/move" 1 3
check "1 -> 3 (front to middle)" "two three one four" "$(tr '\n' ' ' < "$FAKE_DIR/move" | sed 's/ $//')"
printf 'one\ntwo\nthree\nfour\n' > "$FAKE_DIR/move"
reorder_uuid_file "$FAKE_DIR/move" 4 1
check "4 -> 1 (back to front)"   "four one two three" "$(tr '\n' ' ' < "$FAKE_DIR/move" | sed 's/ $//')"
printf 'one\ntwo\nthree\nfour\n' > "$FAKE_DIR/move"
reorder_uuid_file "$FAKE_DIR/move" 1 4
check "1 -> 4 (front to back)"   "two three four one" "$(tr '\n' ' ' < "$FAKE_DIR/move" | sed 's/ $//')"
check "no entry is lost"         4 "$(grep -c . "$FAKE_DIR/move")"

# ------------------------------------------------------------------
echo ""
echo "10. apply_autoconnect_order numbers the ranks from the top"
reset_fake
x=$(add_profile X yes 0 0)
y=$(add_profile Y yes 0 0)
z=$(add_profile Z yes 0 0)
apply_autoconnect_order "$x" "$y" "$z"
check "rank 1 = 30" 30 "$(prio_of X)"
check "rank 2 = 20" 20 "$(prio_of Y)"
check "rank 3 = 10" 10 "$(prio_of Z)"
apply_autoconnect_order "$z" "$x" "$y"
check "re-applying moves the numbers" 30 "$(prio_of Z)"
check "nothing keeps a stale top rank" 20 "$(prio_of X)"

# ------------------------------------------------------------------
echo ""
echo "11. The main menu offers the feature"
check_contains "option 6 is in the menu" \
    "6. Prioritize saved networks" "$(cat "$SCRIPT")"
check_contains "priority submenu is wired" \
    "prioritize_saved_networks" \
    "$(awk '/^        6\)/,/;;/' "$SCRIPT")"

# ------------------------------------------------------------------
echo ""
echo "*****************************************************"
echo "RESULT: $PASS passed, $FAIL failed"
echo "*****************************************************"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
