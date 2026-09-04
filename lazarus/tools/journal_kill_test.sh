#!/bin/sh
# 受信テキストの記録が、強制終了しても残ることを確かめます（要件 FR-B.6）。
#
# 通常の試験は「閉じる前にファイルへ残っている」ところまでしか押さえられません。
# ここでは、記録を書いたプロセスを実際に kill -9 して、書いた行がファイルに
# 残っているかを見ます。
#
# Checks that the transcript journal survives being killed (requirement FR-B.6).
#
# The ordinary tests can only show that the bytes reach the file before it is
# closed. Here the process that wrote them is actually killed with SIGKILL and
# the file is inspected for the lines it wrote.
set -e
HERE=$(cd "$(dirname "$0")/.." && pwd)
DIR=${TMPDIR:-/tmp}/deepcw-journal-kill
# 前回の走行が残したものを必ず消します。残っていると、まだ書いていない今回の
# 走行を「書けている」と読み違えます。
# Anything left by a previous run is removed: leaving it would let this run be
# read as having written when it has not.
rm -rf "$DIR" "$DIR.out"

"$HERE/cli/dsp_check" --journal-until-killed "$DIR" > "$DIR.out" 2>&1 &
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

if [ -f "$FILE" ] && grep -q "JH2XYZ" "$FILE"; then
  echo "  ok   強制終了しても記録が残る / the journal survives a kill"
  echo "       $(cat "$FILE")"
  RESULT=0
else
  echo "  NG   強制終了で記録が失われた / the journal was lost on kill"
  RESULT=1
fi
rm -rf "$DIR" "$DIR.out"
exit $RESULT
