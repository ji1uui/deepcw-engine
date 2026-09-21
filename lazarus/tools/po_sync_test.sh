#!/bin/sh
# `.pot` が、いまソースに書かれている文言と合っているかを確かめます（要件 NFR-7.6）。
#
# **`resourcestring` を足しても `.pot` に現れなければ、その文言だけが訳されずに
# 残ります。**しかも、それが分かるのは画面を開いたときです。訳す人が気づけるのは
# 「一覧に無い」ことではなく「画面に日本語が出ている」ことだけになります。
#
# ここでは `.rsj` から `.pot` を作り直して、置いてあるものと比べます。違えば、
# `tools/update_po.sh` を走らせるべき状態です。**置いてあるものには触れません。**
#
# Checks that the `.pot` matches the words currently in the source
# (requirement NFR-7.6).
#
# **A `resourcestring` that never reaches the `.pot` is simply left
# untranslated**, and that only shows when the screen is opened: what the
# translator sees is Japanese on screen, not a gap in a list.
#
# It rebuilds the `.pot` from the `.rsj` files into a scratch copy and compares.
# A difference means `tools/update_po.sh` is owed. **Nothing in the tree is
# changed.**
set -e
cd "$(dirname "$0")/.."

POT=app/languages/deepcw_station.pot

if ! command -v updatepofiles >/dev/null 2>&1; then
  echo "updatepofiles がありません（Lazarus の同梱物です）"
  exit 1
fi
if [ ! -f "$POT" ]; then
  echo "$POT がありません。tools/update_po.sh を走らせてください"
  exit 1
fi

RSJ=$(find app/lib -name '*.rsj' | sort)
if [ -z "$RSJ" ]; then
  echo ".rsj がありません。先にビルドしてください"
  exit 1
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cp "$POT" "$WORK/check.pot"
# shellcheck disable=SC2086
updatepofiles $RSJ "$WORK/check.pot" >/dev/null

if diff -q "$POT" "$WORK/check.pot" >/dev/null 2>&1; then
  echo "文言 $(grep -c '^#: ' "$POT") 件、一覧はソースと合っています"
  for PO in app/languages/deepcw_station.*.po; do
    [ -e "$PO" ] || continue
    TOTAL=$(grep -c '^#: ' "$POT")
    # 先頭の `Content-Type:` の行は文言ではないので数えません。
    # The leading `Content-Type:` line is not one of the words.
    DONE=$(awk '/^#, / { if ($0 ~ /fuzzy/) f=1; next }
      /^#: / { f=0; next }
      /^msgstr "..*"/ { if (!f && $0 !~ /Content-Type/) n++ }
      END { print n+0 }' "$PO")
    FUZZY=$(grep -c '^#, .*fuzzy' "$PO" || true)
    echo "  $(basename "$PO"): 訳済み $DONE / $TOTAL（要確認 $FUZZY 件は画面に出ないので未訳に数える）"
  done
  exit 0
fi

echo "一覧がソースと合っていません。tools/update_po.sh を走らせてください"
diff "$POT" "$WORK/check.pot" | head -40
exit 1
