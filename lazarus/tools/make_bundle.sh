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

cp "$root/LICENSE" "$stage/LICENSE"
cp "$here/dist-notes/THIRD-PARTY-NOTICES.md" "$stage/THIRD-PARTY-NOTICES.md"
cp "$here/dist-notes/はじめに.txt" "$stage/はじめに.txt"

say ""
say "できあがり / done: $stage"
ls -1 "$stage" | sed 's/^/  /'
