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

# 報告は通ったときも出します。**どの OS がどの符号系で動いているかは、
# 通ったときにも記録に値します。**3 行だけです。
# The report is shown on success too: **which code pages each system runs
# with is worth recording either way.** It is three lines.
echo "  プローブの報告 / probe report:"
grep -a -e '^PROBE-CP' -e '^PROBE-HEX' "$WORK/out" | tr -d '\r' | sed 's/^/    /'
exit $FAILED
