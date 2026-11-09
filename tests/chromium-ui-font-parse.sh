#!/bin/bash
# tests/chromium-ui-font-parse.sh — regression test for the UI font config
# parser that lives inside patches/chromium/0001-per-element-ui-font-deltas.patch
#
# The parser is Chromium code (chrome/browser/ui/views/chrome_typography.cc),
# but its behaviour — which keys it honours, what it does with junk, how it
# clamps — is ours. Testing it normally would mean a multi-hour Chromium build
# on every change, so instead the block between the patch's
#   // BEGIN chrome-ui-font-parser
#   // END   chrome-ui-font-parser
# markers is extracted, compiled against small stubs for the four base::
# helpers it uses, and driven through the cases below.
#
# Consequences for maintainers:
#   * keep those two marker lines when rebasing the patch (this test fails if
#     they disappear, which is the intended alarm);
#   * keep the block self-contained in <algorithm>/<cstdlib>/<string>/
#     <string_view> plus base/files/file_util.h, base/strings/
#     string_number_conversions.h, base/strings/string_split.h and
#     base/strings/string_util.h.
#
# Usage: bash tests/chromium-ui-font-parse.sh      (exit 0 = all passed)

set -u

REPO_DIR="${REPO_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
PATCH="$REPO_DIR/patches/chromium/0001-per-element-ui-font-deltas.patch"
WORK=$(mktemp -d /tmp/chromium-ui-font-parse.XXXXXX) || exit 1
trap 'rm -rf "$WORK"' EXIT

CXX="${CXX:-$(command -v g++ || command -v clang++)}"
[ -n "$CXX" ] || { echo "FAIL: no C++ compiler (g++/clang++)"; exit 1; }
[ -f "$PATCH" ] || { echo "FAIL: patch not found: $PATCH"; exit 1; }

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  PASS  %s\n' "$*"; }
bad() { fail=$((fail + 1)); printf '  FAIL  %s\n' "$*"; }

# ── Extract the parser block out of the patch ────────────────────────────────
# Every line of the block is an added line, i.e. prefixed with '+' in the hunk.
awk '
    /^\+.*BEGIN chrome-ui-font-parser/ { inblock = 1; next }
    /^\+.*END chrome-ui-font-parser/   { inblock = 0; next }
    inblock && /^\+/ { sub(/^\+/, ""); print }
' "$PATCH" > "$WORK/parser.inc"

if ! grep -q "namespace chrome_ui_font" "$WORK/parser.inc"; then
    echo "FAIL: could not extract the parser block from $PATCH"
    echo "      (did a rebase drop the BEGIN/END chrome-ui-font-parser markers?)"
    exit 1
fi
echo "Extracted $(wc -l < "$WORK/parser.inc") lines of parser code"

# ── Stubs for the base:: helpers the parser calls ────────────────────────────
cat > "$WORK/shim.h" <<'SHIM'
// Minimal stand-ins for base/ helpers used by the extracted parser.
// Behaviour mirrors upstream closely enough to be meaningful:
//   TrimWhitespaceASCII  trims " \t\n\v\f\r"
//   SplitStringPiece     single-char separators, optional trim/drop-empty
//   StringToInt          full-string parse, refuses junk and overflow
//   ReadFileToStringWithMaxSize  false when the file is bigger than max_size
#ifndef CHROMIUM_UI_FONT_PARSE_SHIM_H_
#define CHROMIUM_UI_FONT_PARSE_SHIM_H_

#include <cctype>
#include <cstdint>
#include <fstream>
#include <sstream>
#include <string>
#include <string_view>
#include <vector>

namespace base {

class FilePath {
 public:
  FilePath() = default;
  explicit FilePath(const char* path) : path_(path) {}
  explicit FilePath(const std::string& path) : path_(path) {}
  const std::string& value() const { return path_; }

 private:
  std::string path_;
};

enum TrimPositions { TRIM_NONE = 0, TRIM_LEADING = 1, TRIM_TRAILING = 2, TRIM_ALL = 3 };
enum WhitespaceHandling { KEEP_WHITESPACE, TRIM_WHITESPACE };
enum SplitResult { SPLIT_WANT_ALL, SPLIT_WANT_NONEMPTY };

inline bool IsAsciiWhitespace(char c) {
  return std::isspace(static_cast<unsigned char>(c)) != 0;
}

inline std::string_view TrimWhitespaceASCII(std::string_view input,
                                            TrimPositions positions) {
  size_t begin = 0;
  size_t end = input.size();
  if (positions & TRIM_LEADING) {
    while (begin < end && IsAsciiWhitespace(input[begin])) {
      ++begin;
    }
  }
  if (positions & TRIM_TRAILING) {
    while (end > begin && IsAsciiWhitespace(input[end - 1])) {
      --end;
    }
  }
  return input.substr(begin, end - begin);
}

inline std::vector<std::string_view> SplitStringPiece(
    std::string_view input,
    std::string_view separators,
    WhitespaceHandling whitespace,
    SplitResult result_type) {
  std::vector<std::string_view> pieces;
  size_t pos = 0;
  while (true) {
    size_t next = input.find_first_of(separators, pos);
    const bool last = next == std::string_view::npos;
    if (last) {
      next = input.size();
    }
    std::string_view piece = input.substr(pos, next - pos);
    if (whitespace == TRIM_WHITESPACE) {
      piece = TrimWhitespaceASCII(piece, TRIM_ALL);
    }
    if (!piece.empty() || result_type == SPLIT_WANT_ALL) {
      pieces.push_back(piece);
    }
    if (last) {
      break;
    }
    pos = next + 1;
  }
  return pieces;
}

inline bool ReadFileToStringWithMaxSize(const FilePath& path,
                                        std::string* contents,
                                        int64_t max_size) {
  std::ifstream in(path.value(), std::ios::binary);
  if (!in) {
    return false;
  }
  std::ostringstream buffer;
  buffer << in.rdbuf();
  const std::string data = buffer.str();
  if (max_size >= 0 && static_cast<int64_t>(data.size()) > max_size) {
    return false;
  }
  *contents = data;
  return true;
}

inline bool StringToInt(std::string_view input, int* output) {
  if (input.empty()) {
    return false;
  }
  size_t i = 0;
  bool negative = false;
  if (input[0] == '+' || input[0] == '-') {
    negative = input[0] == '-';
    i = 1;
  }
  if (i >= input.size()) {
    return false;
  }
  long long value = 0;
  for (; i < input.size(); ++i) {
    if (input[i] < '0' || input[i] > '9') {
      return false;
    }
    value = value * 10 + (input[i] - '0');
    if (value > 0x7fffffffLL) {
      return false;  // overflow: base::StringToInt refuses
    }
  }
  *output = static_cast<int>(negative ? -value : value);
  return true;
}

}  // namespace base

#endif  // CHROMIUM_UI_FONT_PARSE_SHIM_H_
SHIM

cat > "$WORK/main.cc" <<'MAIN'
// Standard headers the real translation unit provides (the patch adds them to
// chrome/browser/ui/views/chrome_typography.cc); the extracted block
// deliberately includes nothing itself.
#include <algorithm>
#include <cstdlib>
#include <string>
#include <string_view>

#include <cstdio>

#include "shim.h"
#include "parser.inc"   // the extracted chrome_ui_font block

int main() {
  std::printf("omnibox=%d tab=%d\n", chrome_ui_font::OmniboxDelta(),
              chrome_ui_font::TabDelta());
  return 0;
}
MAIN

# ── Build the harness ────────────────────────────────────────────────────────
if ! ( cd "$WORK" && "$CXX" -std=c++20 -Wall -Wextra -Wno-unused-function \
        -I. -o harness main.cc ) 2> "$WORK/build.log"; then
    echo "FAIL: parser block does not compile"
    cat "$WORK/build.log"
    exit 1
fi
echo "Compiled parser harness with $CXX"

# --conf FILE: report what the browser would do with a real config file, then
# stop. Used to cross-check what scripts/chromium-ui-font.sh writes.
if [ "${1:-}" = "--conf" ]; then
    [ -n "${2:-}" ] || { echo "usage: $0 --conf FILE"; exit 2; }
    [ -f "$2" ] || { echo "no such file: $2"; exit 2; }
    echo "parsed $(CHROMIUM_UI_FONT_CONF="$2" "$WORK/harness"):"
    sed -n 's/^\(omnibox_delta\|tab_delta\)=/  \1=/p' "$2"
    exit 0
fi

# ── Cases ────────────────────────────────────────────────────────────────────
# Each case: write a config file, run the harness with CHROMIUM_UI_FONT_CONF
# pointing at it, compare against expected "omnibox=N tab=M".
# The parser reads once per process, exactly like a browser launch, so a
# separate process per case is the honest test.
case_no=0
check() {   # $1 = description, $2 = expected, ($3 = file contents OR "") ($4 = "nofile")
    case_no=$((case_no + 1))
    local desc="$1" expected="$2" contents="${3:-}" mode="${4:-file}"
    local cfg="$WORK/case$case_no.conf"
    rm -f "$cfg"
    if [ "$mode" != "nofile" ]; then
        printf '%b' "$contents" > "$cfg"
    fi
    local got
    got=$(CHROMIUM_UI_FONT_CONF="$cfg" "$WORK/harness" 2>&1)
    if [ "$got" = "$expected" ]; then
        ok "$desc -> $got"
    else
        bad "$desc: expected '$expected', got '$got'"
    fi
}

check "missing config file falls back to stock"           "omnibox=0 tab=0" "" nofile
check "empty config file"                                 "omnibox=0 tab=0" ""
check "omnibox_delta only"                                "omnibox=2 tab=0" "omnibox_delta=2\n"
check "tab_delta only"                                    "omnibox=0 tab=1" "tab_delta=1\n"
check "independent deltas"                                "omnibox=3 tab=-2" "omnibox_delta=3\ntab_delta=-2\n"
check "whitespace around = and value"                     "omnibox=4 tab=1" "omnibox_delta = 4\ntab_delta=  1  \n"
check "comments and unknown keys are ignored"             "omnibox=1 tab=1" "# tab_delta=9\nfoo=7\nbar\nomnibox_delta=1\ntab_delta=1\n"
check "blank lines and trailing newlines"                 "omnibox=2 tab=2" "\n\nomnibox_delta=2\n\ntab_delta=2\n\n"
check "CRLF line endings"                                 "omnibox=2 tab=3" "omnibox_delta=2\r\ntab_delta=3\r\n"
check "non-numeric value ignored"                         "omnibox=0 tab=1" "omnibox_delta=abc\ntab_delta=1\n"
check "float value ignored (no partial parse)"            "omnibox=0 tab=0" "omnibox_delta=2.5\n"
check "suffix junk ignored"                               "omnibox=0 tab=0" "omnibox_delta=2pt\n"
check "clamped high (10)"                                 "omnibox=10 tab=10" "omnibox_delta=99\ntab_delta=42\n"
check "clamped low (-6)"                                  "omnibox=-6 tab=-6" "omnibox_delta=-99\ntab_delta=-7\n"
check "explicit + sign"                                   "omnibox=2 tab=0" "omnibox_delta=+2\n"
check "last assignment wins"                              "omnibox=5 tab=0" "omnibox_delta=1\nomnibox_delta=5\n"
check "no trailing newline on last line"                  "omnibox=1 tab=2" "omnibox_delta=1\ntab_delta=2"

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "chromium-ui-font parser: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
exit 0
