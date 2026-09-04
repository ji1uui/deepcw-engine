#!/bin/sh
# 書いたものが、強制終了しても残ることを確かめます。
#
#   受信テキストの記録（要件 FR-B.6）
#   交信記録（要件 FR-E.3。失うと交信そのものが失われます）
#
# 通常の試験は「閉じる前にファイルへ残っている」ところまでしか押さえられません。
# ここでは、書いたプロセスを実際に kill -9 して、書いたものがファイルに
# 残っているかを見ます。
#
# Checks that what was written survives being killed: the transcript journal
# (requirement FR-B.6) and the contact log (requirement FR-E.3, where losing it
# loses the contacts themselves).
#
# The ordinary tests can only show that the bytes reach the file before it is
# closed. Here the process that wrote them is actually killed with SIGKILL and
# the file is inspected for what it wrote.
set -e
HERE=$(cd "$(dirname "$0")/.." && pwd)
run_case() {
  LABEL="$1"; FLAG="$2"; NEEDLE="$3"
  DIR=${TMPDIR:-/tmp}/deepcw-kill-$FLAG
# 前回の走行が残したものを必ず消します。残っていると、まだ書いていない今回の
# 走行を「書けている」と読み違えます。
# Anything left by a previous run is removed: leaving it would let this run be
# read as having written when it has not.
  rm -rf "$DIR" "$DIR.out"

  "$HERE/cli/dsp_check" "--$FLAG-until-killed" "$DIR" > "$DIR.out" 2>&1 &
  PID=$!
# 記録そのものができるまで待ちます。ファイル名が出ただけでは、まだ 1 行も
# 書けていないことがあります。
# Wait for the record itself: the file name appearing does not yet mean a line
# has been written.
  FILE=''
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    [ -s "$DIR.out" ] && FILE=$(head -1 "$DIR.out")
    [ -n "$FILE" ] && [ -s "$FILE" ] && break
    sleep 0.3
  done

  kill -9 "$PID" 2>/dev/null || true
  wait "$PID" 2>/dev/null || true

  if [ -f "$FILE" ] && grep -q "$NEEDLE" "$FILE"; then
    echo "  ok   強制終了しても残る: $LABEL"
    RESULT=0
  else
    echo "  NG   強制終了で失われた: $LABEL"
    RESULT=1
  fi
  rm -rf "$DIR" "$DIR.out"
  return $RESULT
}

FAILED=0
run_case "受信テキストの記録 / the transcript journal" journal JH2XYZ || FAILED=1
run_case "交信記録 / the contact log" log JH2XYZ || FAILED=1
exit $FAILED
