#!/bin/sh
# 命令行の道具が、日本語を UTF-8 のまま出せることを確かめます（未解決 #24、付録 BQ）。
#
# `dsp_check --text-probe` が、同じ「日本語」を literal と `Format` の 2 通りで
# 出します。ここで**標準出力に届いたバイト列**を、UTF-8 の「日本語」
# （E6 97 A5 E6 9C AC E8 AA 9E）と突き合わせます。**画面で見て判じません**——
# コンソールの表示は、出したバイト列とは別にもう一度化けうるからです。
#
# プローブの報告（符号系とメモリ上のバイト列）もそのまま見せます。
# **メモリ上で既に違えばプログラムの中、メモリ上は正しく出力で違えば出力の段**
# で化けています。
#
# Checks that the command-line tools write Japanese out as UTF-8 (open question
# #24, appendix BQ).
#
# `dsp_check --text-probe` writes the same Japanese word twice, as a literal and
# through `Format`. The **bytes that reached standard output** are compared
# with the UTF-8 encoding of that word. **The screen is not the judge**: a
# console can garble correct bytes all over again on display.
#
# The probe's report (code pages, bytes in memory) is shown as is:
# **wrong in memory means the program, right in memory but wrong at output
# means the output stage.**
set -u
cd "$(dirname "$0")/.."

EXE=./cli/dsp_check
[ -x "$EXE" ] || EXE=./cli/dsp_check.exe
if [ ! -x "$EXE" ]; then
  echo "dsp_check がありません"
  exit 2
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
"$EXE" --text-probe >"$WORK/out" 2>&1
UTF8_HEX=e697a5e69cace8aa9e

# 各行の、見出しより後ろのバイト列を 16 進で取り出します（CR は除きます）。
# The bytes after each line's tag, as hex (a CR is dropped).
bytes_of() {
  grep -a "^$1 " "$WORK/out" | head -n 1 | tr -d '\r' | cut -d' ' -f2- \
    | od -An -tx1 | tr -d ' \n'
}

FAILED=0
for TAG in PROBE-OUT-LIT PROBE-OUT-FMT; do
  GOT=$(bytes_of "$TAG")
  case "$GOT" in
    "$UTF8_HEX"*) echo "  ok   $TAG は UTF-8 のまま届いた" ;;
    *) echo "  NG   $TAG が UTF-8 ではない: $GOT"; FAILED=1 ;;
  esac
done

# **置き場所と引数も、日本語の名前で確かめます**（付録 BQ）。Windows の
# `ParamStr` は ANSI なので、日本語の名前の場所に置いた実行ファイルは自分の
# 場所（モデルや訳を探す起点）を取り違え、日本語のファイル名は開けません。
# 名前を表示させるだけでなく、**実際にファイルを書いて読み戻します。**
# **The location and the arguments are tried with Japanese names too**
# (appendix BQ). Windows' `ParamStr` is ANSI, so an executable in a folder with
# a Japanese name mistakes its own location (where the model and translations
# are looked for), and a Japanese file name cannot be opened. Beyond printing
# the names, **a file is really written and read back.**
FOLDER="$WORK/日本語フォルダ"
mkdir -p "$FOLDER"
cp "$EXE" "$FOLDER/"
COPY="$FOLDER/$(basename "$EXE")"
"$COPY" --text-probe 引数 >"$WORK/out2" 2>&1
hex_of() { printf '%s' "$1" | od -An -tx1 | tr -d ' \n'; }
line_hex() {
  grep -a "^$1 " "$WORK/out2" | head -n 1 | cut -d' ' -f2- | tr -d '\r\n' \
    | od -An -tx1 | tr -d ' \n'
}
FOLDER_HEX=$(hex_of 日本語フォルダ)
case "$(line_hex PROBE-EXE)" in
  *"$FOLDER_HEX"*) echo "  ok   日本語の名前の場所で、自分の置き場所が分かる" ;;
  *) echo "  NG   自分の置き場所を取り違えた: $(grep -a '^PROBE-EXE' "$WORK/out2" | tr -d '\r')"; FAILED=1 ;;
esac
if [ "$(line_hex PROBE-ARG)" = "$(hex_of 引数)" ]; then
  echo "  ok   日本語の引数がそのまま届く"
else
  echo "  NG   日本語の引数が化けた: $(line_hex PROBE-ARG)"; FAILED=1
fi
WAV="$WORK/日本語.wav"
if "$COPY" --fist-wav "$WAV" '' 'TEST' >/dev/null 2>&1 && [ -f "$WAV" ] \
   && "$COPY" --wav-check "$WAV" >/dev/null 2>&1; then
  echo "  ok   日本語のファイル名で書いて読み戻せる"
else
  echo "  NG   日本語のファイル名で書けないか、読み戻せない"
  ls "$WORK" | sed 's/^/      /'
  FAILED=1
fi

# 報告は通ったときも出します。**どの OS がどの符号系で動いているかは、
# 通ったときにも記録に値します。**3 行だけです。
# The report is shown on success too: **which code pages each system runs
# with is worth recording either way.** It is three lines.
echo "  プローブの報告 / probe report:"
grep -a -e '^PROBE-CP' -e '^PROBE-HEX' "$WORK/out" | tr -d '\r' | sed 's/^/    /'
exit $FAILED
