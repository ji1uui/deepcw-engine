#!/bin/sh
# 配布物を組み立てます。
#
# 展開して起動するだけで受信が始められる状態にするのが目的です（要件 FR-A.1）。
# ONNX Runtime も PortAudio も、事前に導入してもらうことはしません。どちらも
# MIT 系の許諾であり、AGPL のアプリケーションに同梱して配布できます。
#
# Assembles the distributable.
#
# The aim is that unpacking and starting is all it takes to receive
# (requirement FR-A.1); neither ONNX Runtime nor PortAudio is something the
# operator has to install first. Both are MIT-style licensed and may be
# shipped alongside an AGPL application.
#
# 使い方 / usage:
#   DEEPCW_ONNXRUNTIME=/path/to/libonnxruntime.so.1.x.y \
#   DEEPCW_PORTAUDIO=/path/to/libportaudio.so.2 \
#   tools/make_bundle.sh [出力先 / output directory]

set -eu

here=$(cd "$(dirname "$0")/.." && pwd)
root=$(cd "$here/.." && pwd)
out=${1:-$here/dist}

case $(uname -s) in
  Linux)  platform=linux ;;
  Darwin) platform=macos ;;
  MINGW*|MSYS*|CYGWIN*) platform=windows ;;
  *)      platform=$(uname -s | tr 'A-Z' 'a-z') ;;
esac
arch=$(uname -m)
stage="$out/deepcw-station-$platform-$arch"

say() { printf '%s\n' "$*"; }
fail() { printf '%s\n' "$*" >&2; exit 1; }

# 実行ファイルと同じ場所に置いたものが最優先で読み込まれます。この配置が
# 「追加作業なしで受信できる」の実体です。
# What sits beside the executable is loaded first; that placement is what
# "receives with no further work" actually means.
say "組み立て先 / staging into: $stage"
rm -rf "$stage"
mkdir -p "$stage"

say "ビルド / building"
lazbuild "$here/app/deepcw_station.lpi" >/dev/null
lazbuild "$here/cli/decode_morse.lpi" >/dev/null
lazbuild "$here/cli/cw_devices.lpi" >/dev/null

copy_binary() {
  src=$1
  [ -f "$src" ] || fail "見つかりません / not found: $src"
  cp "$src" "$stage/"
  say "  同梱 / bundled: $(basename "$src")"
}

copy_binary "$here/app/deepcw_station"
copy_binary "$here/cli/decode_morse"
copy_binary "$here/cli/cw_devices"
copy_binary "$root/model.onnx"
copy_binary "$root/model.onnx.json"

# 共有ライブラリは、探索される名前そのもので置きます。版番号つきの名前のまま
# では見つけられません。
# The shared libraries go in under the exact names that are searched for; the
# versioned names they usually carry would not be found.
bundle_library() {
  src=$1
  wanted=$2
  what=$3
  if [ -z "$src" ]; then
    say "  未同梱 / not bundled: $what（環境変数で場所を指定してください）"
    return
  fi
  [ -f "$src" ] || fail "見つかりません / not found: $src"
  cp "$src" "$stage/$wanted"
  say "  同梱 / bundled: $wanted  ($src)"
}

case $platform in
  windows) ort_name=onnxruntime.dll;      pa_name=portaudio.dll ;;
  macos)   ort_name=libonnxruntime.dylib; pa_name=libportaudio.dylib ;;
  *)       ort_name=libonnxruntime.so;    pa_name=libportaudio.so.2 ;;
esac

bundle_library "${DEEPCW_ONNXRUNTIME:-}" "$ort_name" "ONNX Runtime"
bundle_library "${DEEPCW_PORTAUDIO:-}" "$pa_name" "PortAudio"

# 同梱するなら、その許諾条項も一緒に置きます（要件 NFR-8.2）。
#
# MIT 系の許諾は、著作権表示と条項を配布物に含めることを求めます。版 2.44 まで
# は「置くのは配布する人の責任です」と注記に書いてあるだけで、**置き忘れても
# 何も起きませんでした。**忘れられる手順は、いつか忘れられます。
#
# 条項は取りに行きません（この機械から外へは出ません）。**同梱する binary の
# そばに在るものを写します。**配っている当人が付けた条項が、その binary に
# 対して正しい条項だからです。ONNX Runtime の wheel は `LICENSE` と
# `ThirdPartyNotices.txt` を持ち、Debian の PortAudio は
# `/usr/share/doc/<パッケージ>/copyright` を持ちます。
#
# 見つからなければ**止まります。**条項の無い配布物を黙って作るくらいなら、
# 作らないほうがよい。意図して省くときだけ DEEPCW_ALLOW_MISSING_LICENCE=1 を
# 置いてください。
#
# A bundled library travels with its licence text (requirement NFR-8.2).
#
# MIT-style licences require the copyright notice and the terms to be included.
# Up to version 2.44 a note said that placing them was the distributor's
# responsibility -- and **forgetting had no consequence.** A step that can be
# forgotten will be.
#
# The texts are not fetched (nothing leaves this machine): **what sits beside
# the bundled binary is copied**, that being the text its own distributor
# attached to it. The ONNX Runtime wheel carries `LICENSE` and
# `ThirdPartyNotices.txt`; Debian's PortAudio carries
# `/usr/share/doc/<package>/copyright`.
#
# Not found, it **stops**. Better no distribution than one quietly missing the
# terms. Set DEEPCW_ALLOW_MISSING_LICENCE=1 to leave them out on purpose.
mkdir -p "$stage/licences"
missing_licences=0

find_licence() {
  # $1 = 同梱した binary の場所 / where the bundled binary came from
  from=$1
  dir=$(cd "$(dirname "$from")" && pwd)
  level=0
  while [ "$level" -le 3 ]; do
    for name in LICENSE LICENSE.txt LICENCE LICENCE.txt COPYING COPYING.txt; do
      if [ -f "$dir/$name" ]; then
        printf '%s\n' "$dir/$name"
        return 0
      fi
    done
    dir=$(dirname "$dir")
    level=$((level + 1))
  done
  # 配布物として導入された共有ライブラリは、条項がそばではなく文書置き場に
  # あります。Debian 系は `/usr/share/doc/<パッケージ>/copyright` と決まって
  # いるので、ライブラリの名前から当たります。**推測ではなく、その体系の
  # 決まりです。**
  # A library installed as a package keeps its terms in the documentation tree
  # rather than beside itself. On Debian-like systems that is
  # `/usr/share/doc/<package>/copyright` by policy, so it is looked up from the
  # library's name: **a stated convention, not a guess.**
  base=$(basename "$from")
  base=${base%%.so*}
  base=${base%%.dylib*}
  base=${base%%.dll*}
  for guess in "$base" "$base"2 "${base#lib}" "${base#lib}2"; do
    if [ -f "/usr/share/doc/$guess/copyright" ]; then
      printf '%s\n' "/usr/share/doc/$guess/copyright"
      return 0
    fi
  done
  return 1
}

bundle_licence() {
  src=$1
  what=$2
  wanted=$3
  explicit=$4
  if [ -z "$src" ]; then
    return
  fi
  found=''
  if [ -n "$explicit" ]; then
    [ -f "$explicit" ] || fail "見つかりません / not found: $explicit"
    found=$explicit
  else
    found=$(find_licence "$src" || true)
  fi
  if [ -z "$found" ]; then
    say "  許諾条項が見つかりません / licence text not found: $what"
    missing_licences=$((missing_licences + 1))
    return
  fi
  cp "$found" "$stage/licences/$wanted"
  say "  許諾条項 / licence: licences/$wanted  ($found)"
  # 依存の依存まで書いた表記があれば、それも一緒に置きます。**同梱物の中に
  # また同梱物があることは珍しくありません。**
  # A notices file covering dependencies of the dependency travels too:
  # **something bundled often bundles something itself.**
  notices=$(dirname "$found")/ThirdPartyNotices.txt
  if [ -f "$notices" ]; then
    cp "$notices" "$stage/licences/${wanted%.txt}-ThirdPartyNotices.txt"
    say "  第三者表記 / third-party notices: licences/${wanted%.txt}-ThirdPartyNotices.txt"
  fi
}

bundle_licence "${DEEPCW_ONNXRUNTIME:-}" "ONNX Runtime" \
  "ONNX-Runtime-LICENSE.txt" "${DEEPCW_ONNXRUNTIME_LICENCE:-}"
bundle_licence "${DEEPCW_PORTAUDIO:-}" "PortAudio" \
  "PortAudio-LICENSE.txt" "${DEEPCW_PORTAUDIO_LICENCE:-}"

if [ "$missing_licences" -gt 0 ]; then
  if [ "${DEEPCW_ALLOW_MISSING_LICENCE:-0}" = "1" ]; then
    say "  許諾条項を $missing_licences 件欠いたまま続けます（意図した指定）"
  else
    fail "許諾条項が $missing_licences 件そろっていません。\
同梱する binary のそばに条項が無い場合は、DEEPCW_ONNXRUNTIME_LICENCE または \
DEEPCW_PORTAUDIO_LICENCE でファイルを指してください。\
意図して省くときは DEEPCW_ALLOW_MISSING_LICENCE=1 を置いてください。"
  fi
fi

cp "$root/LICENSE" "$stage/LICENSE"
cp "$here/dist-notes/THIRD-PARTY-NOTICES.md" "$stage/THIRD-PARTY-NOTICES.md"
cp "$here/dist-notes/はじめに.txt" "$stage/はじめに.txt"

say ""
say "できあがり / done: $stage"
ls -1 "$stage" | sed 's/^/  /'
