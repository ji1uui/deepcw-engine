#!/bin/sh
# 画素密度の違う画面で、窓の組み方が破綻しないことを確かめます（要件 NFR-5.1）。
#
# **目で見て気づけるのは、たまたま開いたタブの、たまたま見えている場所だけ**
# です。ここでは画面を 2 つ作り、アプリケーション自身に全タブを数えさせます。
# 96 dpi（等倍）と 192 dpi（200%）を、日本語と英語の 2 言語で。150% は付録 AW.5。
#
# Checks that the window's layout does not break on screens of different pixel
# density (requirement NFR-5.1). **The eye only catches this on the tab that
# happens to be open**, so two screens are made and the application counts the
# breakages on every tab itself: 96 dpi and 192 dpi. 144 dpi is measured
# separately in appendix AW.5.
set -e
cd "$(dirname "$0")/.."

if [ ! -x ./app/deepcw_station ]; then
  echo "app/deepcw_station がありません"
  exit 1
fi
if ! command -v Xvfb >/dev/null 2>&1; then
  echo "Xvfb がありません"
  exit 1
fi

FAILED=0

run_at() {
  DPI="$1"
  SIZE="$2"
  NUM="$3"
  LANG_="${4:-}"
  Xvfb ":$NUM" -screen 0 "$SIZE" -dpi "$DPI" >/dev/null 2>&1 &
  XPID=$!
  # 画面が立ち上がるのを待ちます。/ Wait for the screen to come up.
  I=0
  while [ $I -lt 30 ]; do
    if [ -e "/tmp/.X11-unix/X$NUM" ]; then break; fi
    sleep 1
    I=$((I + 1))
  done
  OUT=$(DISPLAY=":$NUM" DEEPCW_LAYOUT_CHECK=1 ./app/deepcw_station --lang "$LANG_" 2>/dev/null) || FAILED=1
  echo "$OUT" | sed 's/^/    /'
  kill $XPID 2>/dev/null || true
  wait $XPID 2>/dev/null || true
}

echo "  96 dpi（日本語）:"
run_at 96 1600x1200x24 121 ja
echo "  192 dpi（日本語）:"
run_at 192 2600x2000x24 122 ja

# **言語を変えると文字の幅が変わります**（要件 NFR-7.6）。部品の大きさは日本語に
# 合わせて決めてあるので、訳が広ければ同じ場所で破綻します。画素密度と同じ扱いで、
# もう 1 つの軸として数えさせます。
#
# **The words change width with the language** (requirement NFR-7.6). The
# controls were sized for the Japanese, so a wider translation breaks in the
# same places. It is counted as a second axis, exactly like pixel density.
if [ -f app/languages/deepcw_station.en.po ]; then
  echo "  96 dpi（English）:"
  run_at 96 1600x1200x24 123 en
  echo "  192 dpi（English）:"
  run_at 192 2600x2000x24 124 en
else
  echo "  英語の .po がありません（訳を入れたら軸が増えます）"
fi

if [ $FAILED -ne 0 ]; then
  echo "組み方の破綻が見つかりました"
  exit 1
fi
exit 0
