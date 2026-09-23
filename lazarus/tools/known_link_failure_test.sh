#!/bin/sh
# `known_link_failure.sh` が「分かっている 1 つ」だけを通すことを確かめます。
# 記録は CI（macOS ARM64、版 2.66）の実際の行から作りました。
# **通すべきものを通すだけでなく、落とすべきものを落とすことを見ます。**
# 見分けが甘ければ、ずっと赤かった CI が今度はずっと緑になるだけです。
#
# Checks that `known_link_failure.sh` lets through only "the one we know".
# The logs are made from the actual lines of the CI (macOS ARM64, version 2.66).
# **It checks that what must fail fails, not only that what may pass passes**:
# a loose test would merely turn a CI that was always red into one that is
# always green.
set -u
cd "$(dirname "$0")/.."

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
FAILED=0

LINK_FAIL='(9015) Linking /Users/runner/work/deepcw-engine/deepcw-engine/lazarus/app/deepcw_station
ld: malformed method list atom '"'"'ltmp5'"'"' (/Users/runner/lazarus/lcl/units/aarch64-darwin/cocoa/cocoawsextctrls.o), fixups found beyond the number of method entries
An error occurred while linking
Error: (9013) Error while linking
Fatal: (10026) There were 1 errors compiling module, stopping'
HINTS='/Users/runner/work/deepcw-engine/deepcw-engine/lazarus/app/frmmain.pas(691,29) Hint: (5024) Parameter "Sender" not used
/Users/runner/work/deepcw-engine/deepcw-engine/lazarus/app/frmmain.pas(6371,19) Warning: (5093) function result variable of a managed type does not seem to be initialized'
COMPILE_ERR='/Users/runner/work/deepcw-engine/deepcw-engine/lazarus/app/frmmain.pas(1225,28) Error: (5002) Duplicate identifier "RsTxSending"'
OTHER_LINK='ld: library not found for -lportaudio
Error: (9013) Error while linking'

expect() {
  NAME="$1"; WANT="$2"; VERSION="$3"; BODY="$4"
  printf '%s\n' "$BODY" >"$WORK/log"
  if ./tools/known_link_failure.sh "$WORK/log" "$VERSION" >/dev/null; then GOT=pass; else GOT=fail; fi
  if [ "$GOT" = "$WANT" ]; then
    echo "  ok   $NAME（$GOT）"
  else
    echo "  NG   $NAME（期待 $WANT、実際 $GOT）"
    FAILED=1
  fi
}

expect "#25 そのもの"                          pass 3.2.2 "$HINTS
$LINK_FAIL"
expect "#25 の印があってもコンパイルの誤りがある" fail 3.2.2 "$COMPILE_ERR
$LINK_FAIL"
expect "別のリンクの失敗"                      fail 3.2.2 "$HINTS
$OTHER_LINK"
expect "3.2.4 でも #25 の印が出る"             fail 3.2.4 "$HINTS
$LINK_FAIL"
expect "記録が空"                              fail 3.2.2 ""

exit $FAILED
