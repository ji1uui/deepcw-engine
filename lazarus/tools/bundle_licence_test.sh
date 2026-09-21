#!/bin/sh
# 配布物に許諾条項が入ることと、**入らないときは止まること**を確かめます
# （要件 NFR-8.2）。
#
# 版 2.44 まで、条項を置くのは「配布する人の責任です」と注記に書いてあるだけ
# でした。**忘れても何も起きない手順は、いつか忘れられます。**止まることを
# 確かめるのがこの試験の主眼で、入ることのほうは、その裏返しです。
#
# Checks that a distribution carries the licence texts, and **that it stops when
# it cannot** (requirement NFR-8.2).
#
# Up to version 2.44 a note said placing them was the distributor's
# responsibility. **A step that can be forgotten without consequence will be.**
# The point of this test is the stopping; the carrying is its other side.

set -eu

here=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

check() {
  if [ "$2" = "ok" ]; then
    printf '  ok   %s\n' "$1"
  else
    printf '  NG   %s  %s\n' "$1" "${3:-}"
    failures=$((failures + 1))
  fi
}

# 条項を持つ偽のライブラリと、持たない偽のライブラリを作ります。**本物の
# ライブラリは要りません。**確かめたいのは「そばの条項を見つけるか」だけです。
# A fake library with terms beside it, and one without. **No real library is
# needed**: what is checked is only whether the text beside it is found.
mkdir -p "$work/withlicence" "$work/without"
printf 'MIT LICENCE TEXT\n' > "$work/withlicence/LICENSE"
printf 'x' > "$work/withlicence/libfake.so"
printf 'x' > "$work/without/libbare.so"

# [1] 両方に条項があれば、配布物に入ること。
DEEPCW_ONNXRUNTIME="$work/withlicence/libfake.so" \
DEEPCW_PORTAUDIO="$work/withlicence/libfake.so" \
  "$here/tools/make_bundle.sh" "$work/out1" >"$work/log1" 2>&1 || true
# 置き場所は組み方で変わります（macOS は `.app` の中の `Contents/Resources/`）。
# **ここで確かめたいのは「入ったか」であって「どこに入ったか」ではありません。**
# 場所は `tools/bundle_macos_test.sh` が見ます。
# Where they land depends on the layout (inside `Contents/Resources/` on
# macOS). **What is checked here is that they are carried, not where**; the
# place is `tools/bundle_macos_test.sh`'s business.
stage1=$(find "$work/out1" -maxdepth 1 -type d -name 'deepcw-station-*' | head -1)
if [ -n "$stage1" ] \
   && [ -n "$(find "$stage1" -name 'ONNX-Runtime-LICENSE.txt' | head -1)" ] \
   && [ -n "$(find "$stage1" -name 'PortAudio-LICENSE.txt' | head -1)" ]; then
  check "そばに条項があれば、配布物に入る" ok
else
  check "そばに条項があれば、配布物に入る" ng "$(tail -3 "$work/log1")"
fi

# [2] 条項が見つからなければ、**止まること。**ここがこの試験の主眼です。
if DEEPCW_ONNXRUNTIME="$work/without/libbare.so" \
   DEEPCW_PORTAUDIO="$work/without/libbare.so" \
     "$here/tools/make_bundle.sh" "$work/out2" >"$work/log2" 2>&1; then
  check "条項が無ければ止まる" ng "止まらずに作ってしまいました"
else
  check "条項が無ければ止まる" ok
fi
# 「許諾条項」という語を探すだけでは足りません。**止まるときの文言にも同じ語が
# 入っているので、どのライブラリで欠けたのかを言わなくなっても気づけません。**
# 壊して確かめて分かりました。名前で探します。
# Looking for the words "licence text" is not enough: **the stopping message
# carries them too, so dropping the per-library line would go unnoticed.** Trying
# to break it is what showed this; the library's name is what is looked for.
if grep -q "ONNX Runtime" "$work/log2" && grep -q "PortAudio" "$work/log2"; then
  check "どのライブラリで欠けたのかを言う" ok
else
  check "どのライブラリで欠けたのかを言う" ng "$(tail -5 "$work/log2")"
fi

# [3] 意図して省くときだけ、続けられること。**逃げ道が無ければ、条項を持たない
#     環境で配布物を作れません。**
if DEEPCW_ALLOW_MISSING_LICENCE=1 \
   DEEPCW_ONNXRUNTIME="$work/without/libbare.so" \
   DEEPCW_PORTAUDIO="$work/without/libbare.so" \
     "$here/tools/make_bundle.sh" "$work/out3" >"$work/log3" 2>&1; then
  check "意図して省くときは続く" ok
else
  check "意図して省くときは続く" ng "$(tail -3 "$work/log3")"
fi

# [4] ファイルを直接指せること。**そばに無くても、指せば入る。**
if DEEPCW_ONNXRUNTIME="$work/without/libbare.so" \
   DEEPCW_ONNXRUNTIME_LICENCE="$work/withlicence/LICENSE" \
   DEEPCW_PORTAUDIO="$work/withlicence/libfake.so" \
     "$here/tools/make_bundle.sh" "$work/out4" >"$work/log4" 2>&1; then
  stage4=$(find "$work/out4" -maxdepth 1 -type d -name 'deepcw-station-*' | head -1)
  if [ -n "$(find "$stage4" -name 'ONNX-Runtime-LICENSE.txt' | head -1)" ]; then
    check "指したファイルが入る" ok
  else
    check "指したファイルが入る" ng "入っていません"
  fi
else
  check "指したファイルが入る" ng "$(tail -3 "$work/log4")"
fi

if [ "$failures" -gt 0 ]; then
  printf '%d 件が通りませんでした。\n' "$failures"
  exit 1
fi
exit 0
