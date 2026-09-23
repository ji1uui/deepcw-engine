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

# **利用者の設定に触れません。**アプリは終わるときに設定を書き戻すので、
# 本物の `~/.config` で走らせると、試験のたびに利用者の設定を書き換えます。
# 途中で落ちれば、英語に切り替えたまま残ることもあります。しかも結果が、その
# 設定（名簿や前置きの置き場所）に左右されます。一時の場所を家として渡します。
# **The operator's settings are left alone.** The application writes its
# settings back as it exits, so run against the real `~/.config` every test
# would rewrite them -- and a failure midway could leave them in English.
# The outcome would also depend on those settings (where the roster and the
# prefixes live). A scratch directory is handed over as home.
mkdir -p "$WORK/home" "$WORK/config"
HOME="$WORK/home"
XDG_CONFIG_HOME="$WORK/config"
export HOME XDG_CONFIG_HOME

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
  echo "言語の切替に問題があります（戻らない・訳が反映されない）"
  exit 1
fi

# **命令行の `--lang` は 1 度きりです**（`UiLangFromCommandLine`）。覚えてある
# 言語を上書きしないこと、覚えてあるものが無ければ何も書かないことを見ます。
# 設定ファイルが書かれたことも確かめます。**書かれていなければ、この確認は
# 何も見ていません。**
# **A command-line `--lang` is for one run** (`UiLangFromCommandLine`): it must
# not overwrite the remembered language, and with nothing remembered it must
# write none. That the settings file was written at all is checked too:
# **unwritten, this check would be looking at nothing.**
run_en() {
  DEEPCW_TEXT_CHECK=1 xvfb-run -a "$WORK/deepcw_station" --lang en \
    >/dev/null 2>&1 || true
}
config_file() {
  find "$WORK/config" -name '*.cfg' | head -n 1
}

rm -rf "$WORK/config"; mkdir -p "$WORK/config"
run_en
CFG=$(config_file)
if [ -z "$CFG" ]; then
  echo "設定ファイルが書かれませんでした。書き戻しを確かめられません"
  exit 1
fi
if grep -q '^language=en' "$CFG"; then
  echo "1 度きりの --lang en が、覚える言語として書かれました"
  exit 1
fi

printf '[ui]\nlanguage=ja\n' >"$CFG"
run_en
if ! grep -q '^language=ja' "$CFG"; then
  echo "覚えてあった日本語が、1 度きりの --lang en で上書きされました"
  grep '^language=' "$CFG" || true
  exit 1
fi
echo "  1 度きりの --lang は覚える言語を変えません"
