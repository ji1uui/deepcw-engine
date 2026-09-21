#!/bin/sh
# 稼働中に言語を切り替えて、元の言語へ戻れることを確かめます（要件 NFR-7.6）。
#
# **日本語へ戻す道は、英語へ行く道と違います。**英語へは `.po` を読みますが、
# 日本語はソースに書いてあるものなので、読むファイルがありません。取り違えると
# 「一度英語にしたら戻れない」が起こり、**画面を開いて押してみるまで分かりません。**
#
# **配布物と同じ並びで走らせます。**実行ファイルと `.po` だけを置いた一時の場所へ
# 写して、そこで押します。ソース木には `.pot`（訳文が空の雛形）が `.po` と同じ所に
# あり、**LCL は言語別の `.po` が見つからないとき最後にこれを拾います。**訳文が
# 空なので日本語に戻ってしまい、戻す道が壊れていても通ってしまいます。
# **配布物に `.pot` は入りません。**ソース木でだけ通る試験は、試験になりません。
#
# Checks that the language can be changed while running and come back
# (requirement NFR-7.6).
#
# **The way back to Japanese is not the way out to English**: English is read
# from a `.po`, while the Japanese is what the source holds and has no file.
# Mistake it and the application cannot return once it has gone, and **that
# shows only when someone opens the screen and tries.**
#
# **It runs in the layout the operator gets**: the executable and the `.po`
# files are copied to a scratch directory and tried there. In the source tree
# the `.pot` -- the template, whose translations are empty -- sits beside the
# `.po`, and **the LCL falls back to it when it finds no `.po` for a language.**
# Empty translations restore the Japanese, so a broken way back would pass.
# **No `.pot` goes into a distribution.** A test that passes only in the source
# tree is not a test.
set -e
cd "$(dirname "$0")/.."

if [ ! -x ./app/deepcw_station ]; then
  echo "app/deepcw_station がありません"
  exit 1
fi
if ! command -v xvfb-run >/dev/null 2>&1; then
  echo "xvfb-run がありません"
  exit 1
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

cp ./app/deepcw_station "$WORK/"
mkdir -p "$WORK/languages"
FOUND=0
for po in app/languages/*.po; do
  [ -e "$po" ] || continue
  cp "$po" "$WORK/languages/"
  FOUND=$((FOUND + 1))
done
if [ "$FOUND" -eq 0 ]; then
  echo "訳された .po がありません"
  exit 1
fi
if [ -e "$WORK/languages/deepcw_station.pot" ]; then
  echo "雛形が紛れ込みました。この試験の意味がなくなります"
  exit 1
fi

# 音声装置の無い容器では ALSA と JACK が大量に鳴きます。**通ったときは黙り、
# 落ちたときだけ見せます。**雑音に紛れると、落ちても気づきません。
# On a container with no sound device, ALSA and JACK complain at length.
# **Silent when it passes, shown when it fails**: buried in noise, a failure
# goes unnoticed.
# 音声装置の無い容器では ALSA と JACK が大量に鳴き、**その一部は stdout へ出ます。**
# 報告だけを拾います。落ちたときは報告ごと見せます。
# On a container with no sound device ALSA and JACK complain at length, **some
# of it on stdout.** Only the report is kept; on failure the report is shown.
# **`|` を挟むと終了コードは grep のものになります。**アプリが落ちても通って
# しまうので、いったんファイルに落としてから濾します。
# **A pipe would hand back grep's exit code**, and the test would pass though
# the application failed, so the output is put in a file and filtered after.
if DEEPCW_LANG_CHECK=1 xvfb-run -a "$WORK/deepcw_station" --lang ja \
   >"$WORK/out.txt" 2>/dev/null; then
  OK=0
else
  OK=1
fi
grep -v -e '^ALSA lib' -e '^Cannot connect' -e '^jack server' -e '^JackShm' \
  "$WORK/out.txt" || true
if [ "$OK" -ne 0 ]; then
  echo "言語を戻せませんでした"
  exit 1
fi
