#!/bin/sh
# 組み立ての失敗が「分かっている 1 つ」（未解決 #25）かどうかを判じます。
#
# macOS で画面のアプリはリンクできません。FPC 3.2.2 が出す Objective-C の
# 目録を、新しい Apple のリンカが拒むためです（`malformed method list atom
# 'ltmp…'`）。直したのは FPC のコミット 55b9954619 で、3.2.4 に入りますが、
# 3.2.4 はまだ出ていません。**3.2.2 のまま進めると決めています**（付録 BK.4）。
#
# **ずっと赤い CI は、新しい失敗を知らせられません。**版 2.62 から macOS の
# 段は毎回この理由で落ちていて、ほかの理由で落ちても見分けが付きませんでした。
# そこで**この 1 つだけ**を見分けて通し、ほかはすべて落とします。
#
#   通す（終了コード 0）のは、次の 3 つがすべて揃うときだけです。
#     1. FPC が 3.2.2 である（3.2.4 に上げても落ちるなら、それは別の問題）
#     2. 記録にリンカの `malformed method list atom 'ltmp` がある
#     3. 記録にコンパイルの誤り（`file.pas(行,桁) Error:` / `Fatal:`）が無い
#   **コンパイルはリンクより前に終わる**ので、ソースの誤りはこれまでどおり
#   macOS でも捕まります。
#
# Decides whether a failed build is "the one we know" (open question #25).
#
# On macOS the GUI application cannot be linked: Apple's newer linker rejects
# the Objective-C metadata FPC 3.2.2 emits (`malformed method list atom
# 'ltmp…'`). FPC commit 55b9954619 fixes it for 3.2.4, which is not released;
# **the decision is to stay on 3.2.2** (appendix BK.4).
#
# **A CI that is always red cannot announce a new failure.** Since version 2.62
# the macOS job failed on every push for this reason, and a failure for any
# other reason looked the same. So **this one alone** is recognised and let
# through; everything else fails.
#
#   It passes (exit 0) only when all three hold:
#     1. FPC is 3.2.2 (still failing after 3.2.4 is a different problem)
#     2. the log has the linker's `malformed method list atom 'ltmp`
#     3. the log has no compile error (`file.pas(line,col) Error:` / `Fatal:`)
#   **Compilation finishes before linking**, so an error in the source is
#   still caught on macOS.
#
#   使い方 / usage:  tools/known_link_failure.sh <build.log> <fpc-version>
set -u

LOG="${1:-}"
VERSION="${2:-}"
if [ -z "$LOG" ] || [ ! -f "$LOG" ]; then
  echo "記録がありません: $LOG"
  exit 2
fi

if [ "$VERSION" != "3.2.2" ]; then
  echo "FPC $VERSION では、#25 を理由に通しません"
  exit 1
fi
if ! grep -q "malformed method list atom 'ltmp" "$LOG"; then
  echo "#25 の印がありません。別の失敗です"
  exit 1
fi
if grep -Eq '\.(pas|pp|lpr|inc)\([0-9]+(,[0-9]+)?\) (Error|Fatal):' "$LOG"; then
  echo "コンパイルの誤りがあります。#25 ではありません"
  exit 1
fi
echo "#25（FPC 3.2.2 と新しいリンカ）による失敗です"
exit 0
