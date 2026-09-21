#!/bin/sh
# 画面の文言を集めて `.pot` を作り直し、各言語の `.po` に反映します（要件 NFR-7.6）。
#
# **手で書き写す工程を作らないためのものです。**`resourcestring` を足しても
# `.po` に現れなければ、その文言だけが訳されずに残ります。しかもそれは
# **画面を開くまで分かりません。**
#
# 流れ:
#   1. アプリケーションをビルドする（fpc が `.rsj` を出す）
#   2. `updatepofiles` が `.rsj` を `.pot` に集める
#   3. 同じ命令で、各言語の `.po` に新しい行を足し、消えた行を落とす
#      **すでに入っている訳は残ります。**
#
# 訳したあとは `tools/regression.sh` を走らせてください。幅が溢れていれば
# そこで落ちます（`DEEPCW_TEXT_CHECK` と `tools/layout_lang_test.sh`）。
#
# Regenerates the `.pot` from the words on screen and folds it into each
# language's `.po` (requirement NFR-7.6).
#
# **This exists so that no step is copied by hand.** A `resourcestring` that
# never reaches the `.po` is simply left untranslated, and **that does not show
# until the screen is opened.**
#
# Existing translations are kept; only new entries are added and gone ones
# dropped. Run `tools/regression.sh` afterwards: an overflowing translation
# fails there.
set -e
cd "$(dirname "$0")/.."

POT=app/languages/deepcw_station.pot

if ! command -v updatepofiles >/dev/null 2>&1; then
  echo "updatepofiles がありません（Lazarus の同梱物です）"
  exit 1
fi

echo "1/3 ビルドして .rsj を出します"
lazbuild app/deepcw_station.lpi >/dev/null

RSJ=$(find app/lib -name '*.rsj' | sort)
if [ -z "$RSJ" ]; then
  echo ".rsj が 1 つも出ていません。resourcestring がありません"
  exit 1
fi
echo "    $(echo "$RSJ" | wc -l) 個の .rsj"

echo "2/3 $POT を作り直します"
mkdir -p app/languages
# `updatepofiles` は無い .pot を作らないので、空で置いてから渡します。
# updatepofiles will not create a missing .pot, so an empty one is put there.
[ -f "$POT" ] || : > "$POT"
# shellcheck disable=SC2086
updatepofiles $RSJ "$POT"

echo "3/3 各言語の .po に反映します"
for PO in app/languages/deepcw_station.*.po; do
  [ -e "$PO" ] || continue
  echo "    $PO"
done
# `.pot` を渡すと、同じ場所の `deepcw_station.<lang>.po` すべてに反映されます。
# Handing it the `.pot` folds the result into every `deepcw_station.<lang>.po`
# beside it.

TOTAL=$(grep -c '^#: ' "$POT" || true)
echo "文言 $TOTAL 件"
for PO in app/languages/deepcw_station.*.po; do
  [ -e "$PO" ] || continue
  # 訳が入っている件数を数えます。**長い訳は次の行へ折り返されます**
  # （`msgstr ""` のあとに `"..."` が続く形）。折り返しを数え落とすと、訳が
  # 壊れていても件数が減らず、**この数えが壊れを見つけられなくなります**
  # （付録 BH.8）。要確認（fuzzy）は画面に出ないので未訳に数えます。
  # 先頭の `Content-Type:` の塊（`#:` より前の `msgid ""`）は文言ではありません。
  #
  # Counts the entries that carry a translation. **A long one is wrapped onto
  # the following lines** (`msgstr ""` then `"..."`), and missing those would
  # keep the count steady while a translation is broken, so **the count would
  # no longer catch the breakage** (appendix BH.8). Fuzzy entries never reach
  # the screen, so they count as untranslated. The leading `Content-Type:`
  # block (the `msgid ""` before any `#:`) is not one of the words.
  DONE=$(awk '/^#: / { f=0; seen=1; next }
      /^#, / { if ($0 ~ /fuzzy/) f=1; next }
      /^msgid ""$/ { hdr=(seen?0:1); pend=0; next }
      /^msgid "/ { hdr=0; pend=0; next }
      /^msgstr "..*"/ { if (!f && !hdr) n++; pend=0; next }
      /^msgstr ""$/ { pend=((f||hdr)?0:1); next }
      /^"..*"/ { if (pend) { n++; pend=0 } next }
      { pend=0 }
      END { print n+0 }' "$PO")
  FUZZY=$(grep -c '^#, .*fuzzy' "$PO" || true)
  echo "  $(basename "$PO"): 訳済み $DONE / $TOTAL（要確認 $FUZZY 件は画面に出ないので未訳に数える）"
done
