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
# macOS では `.app` を組み立てます（要件 FR-A.3、未解決 #22）。**10.14 以降、
# マイク（ライン入力）を開くには `Info.plist` の `NSMicrophoneUsageDescription`
# が要ります。**無ければ許可を訊かれることもなく、開こうとした瞬間に OS が
# アプリを終了させます。端末から起動すれば端末の許可で動きますが、それは配る形
# ではありません。
#
# On macOS a `.app` is assembled (requirement FR-A.3, open question #22). **From
# 10.14 on, opening the microphone (line in) needs
# `NSMicrophoneUsageDescription` in `Info.plist`**; without it there is no
# prompt at all -- the system terminates the application the moment it tries.
# Started from a terminal it runs under the terminal's own permission, but that
# is not the shape it is distributed in.
#
# 使い方 / usage:
#   DEEPCW_ONNXRUNTIME=/path/to/libonnxruntime.so.1.x.y \
#   DEEPCW_PORTAUDIO=/path/to/libportaudio.so.2 \
#   tools/make_bundle.sh [出力先 / output directory]
#
# 効く環境変数 / environment:
#   DEEPCW_BUNDLE_ID       入れ物の識別子（既定 io.github.ji1uui.deepcw-station）
#   DEEPCW_BUNDLE_VERSION  版（既定 1.0.0）
#   DEEPCW_MACOS_MINIMUM   動かす最低の macOS（既定 10.14）
#   DEEPCW_BUNDLE_LAYOUT   組み方を指定（macos / flat）。**試験用です。**
#                          macOS 以外でも `.app` の並びを作れます。

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

# 組み方。macOS は `.app`、それ以外は平らに並べます。
#
# **`DEEPCW_BUNDLE_LAYOUT` は試験のためにあります。**macOS の並びは macOS で
# しか作れない——という状態にすると、**並びの誤りは macOS を持ち出すまで
# 見つかりません。**並べること自体はどの OS でもできるので、Linux で並べて
# 確かめられるようにしてあります（中の実行ファイルは当然その OS のものです）。
#
# The layout: a `.app` on macOS, a flat directory elsewhere.
#
# **`DEEPCW_BUNDLE_LAYOUT` exists for the tests.** Were the macOS arrangement
# only producible on macOS, **a mistake in it would wait for a Mac to be
# found.** Arranging is something any system can do, so it can be arranged and
# checked on Linux (with, of course, that system's own executables inside).
layout=${DEEPCW_BUNDLE_LAYOUT:-}
if [ -z "$layout" ]; then
  case $platform in
    macos) layout=macos ;;
    *)     layout=flat ;;
  esac
fi
case $layout in
  macos|flat) ;;
  *) fail "DEEPCW_BUNDLE_LAYOUT は macos か flat です / must be macos or flat: $layout" ;;
esac

bundle_id=${DEEPCW_BUNDLE_ID:-io.github.ji1uui.deepcw-station}
bundle_version=${DEEPCW_BUNDLE_VERSION:-1.0.0}
macos_minimum=${DEEPCW_MACOS_MINIMUM:-10.14}
app_name="DeepCW Station"

# 実行ファイルと同じ場所に置いたものが最優先で読み込まれます。この配置が
# 「追加作業なしで受信できる」の実体です。
# What sits beside the executable is loaded first; that placement is what
# "receives with no further work" actually means.
# 置き場所は 3 つに分かれます。
#
# | | 平らな並び | `.app` の並び |
# | --- | --- | --- |
# | `bin_dir` 実行ファイルと共有ライブラリ | `$stage` | `Contents/MacOS` |
# | `res_dir` 持ち物（model・訳・条項） | `$stage` | `Contents/Resources` |
# | `top_dir` 読み物（LICENSE・はじめに） | `$stage` | `$stage`（`.app` の外） |
#
# **持ち物を `Contents/MacOS/` に置いてはいけません。**署名は
# `Contents/MacOS/` に実行ファイル以外があることを想定しておらず、入れ物の形が
# 違うと言って止まります。読み物を `.app` の中に入れないのは、逆の理由です——
# **`.app` は Finder では 1 個のアイコンに見えるので、中に入れた説明書は
# 開かれません。**
#
# Three places, which coincide in the flat layout:
# `bin_dir` for executables and shared libraries, `res_dir` for what they carry,
# `top_dir` for what the operator reads. **Belongings must not go in
# `Contents/MacOS/`**: signing does not expect anything but executables there
# and rejects the bundle's shape. The readable files stay outside the `.app`
# for the opposite reason -- **a `.app` shows as a single icon in the Finder,
# so a note placed inside it is never opened.**
top_dir=$stage
if [ "$layout" = macos ]; then
  app_dir="$stage/$app_name.app"
  bin_dir="$app_dir/Contents/MacOS"
  res_dir="$app_dir/Contents/Resources"
else
  app_dir=''
  bin_dir=$stage
  res_dir=$stage
fi

say "組み立て先 / staging into: $stage"
say "組み方 / layout: $layout"
rm -rf "$stage"
mkdir -p "$bin_dir" "$res_dir" "$top_dir"

say "ビルド / building"
lazbuild "$here/app/deepcw_station.lpi" >/dev/null
lazbuild "$here/cli/decode_morse.lpi" >/dev/null
lazbuild "$here/cli/cw_devices.lpi" >/dev/null

copy_into() {
  src=$1
  dest=$2
  [ -f "$src" ] || fail "見つかりません / not found: $src"
  cp "$src" "$dest/"
  say "  同梱 / bundled: $(basename "$src")"
}

# 命令行の道具も `.app` の中に置きます。**model.onnx を 2 つ持ちたくない**
# ためです。`Contents/MacOS/` に居れば、同じ `Contents/Resources/` を見ます。
# The command-line tools go inside the `.app` as well, to **avoid carrying
# `model.onnx` twice**: from `Contents/MacOS/` they see the same
# `Contents/Resources/`.
copy_into "$here/app/deepcw_station" "$bin_dir"
copy_into "$here/cli/decode_morse" "$bin_dir"
copy_into "$here/cli/cw_devices" "$bin_dir"
copy_into "$root/model.onnx" "$res_dir"
copy_into "$root/model.onnx.json" "$res_dir"

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
  cp "$src" "$bin_dir/$wanted"
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
mkdir -p "$res_dir/licences"
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
  cp "$found" "$res_dir/licences/$wanted"
  say "  許諾条項 / licence: licences/$wanted  ($found)"
  # 依存の依存まで書いた表記があれば、それも一緒に置きます。**同梱物の中に
  # また同梱物があることは珍しくありません。**
  # A notices file covering dependencies of the dependency travels too:
  # **something bundled often bundles something itself.**
  notices=$(dirname "$found")/ThirdPartyNotices.txt
  if [ -f "$notices" ]; then
    cp "$notices" "$res_dir/licences/${wanted%.txt}-ThirdPartyNotices.txt"
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

# 訳した文言（要件 NFR-7.6）。**入れ忘れると、配った先では日本語のままになります。**
# 実行ファイルの隣の `languages/` を、`LCLTranslator` が探します。
# The translations (requirement NFR-7.6). **Left out, the distribution runs in
# Japanese**: `LCLTranslator` looks for `languages/` beside the executable.
if [ -d "$here/app/languages" ]; then
  mkdir -p "$res_dir/languages"
  for po in "$here/app/languages"/*.po; do
    [ -e "$po" ] || continue
    cp "$po" "$res_dir/languages/"
  done
  say "  訳: $(ls -1 "$res_dir/languages" | wc -l) 言語ぶん"
else
  say "  訳: ありません（日本語のまま動きます）"
fi

cp "$root/LICENSE" "$top_dir/LICENSE"
cp "$here/dist-notes/THIRD-PARTY-NOTICES.md" "$top_dir/THIRD-PARTY-NOTICES.md"
cp "$here/dist-notes/はじめに.txt" "$top_dir/はじめに.txt"

# `.app` の書類（未解決 #22）。
#
# **`NSMicrophoneUsageDescription` がこの仕事の中心です。**macOS 10.14 以降、
# これが無いアプリがマイク（ライン入力）を開こうとすると、**許可を訊かれる
# ことさえなく、OS がその場でアプリを終了させます。**訊かれないので、利用者に
# は「起動したのに消えた」としか見えません。
#
# 文面は**なぜ要るのかを書きます。**Apple の審査の要求である以前に、許可を
# 求められた人が判断できる材料が要ります。
#
# 識別子（`CFBundleIdentifier`）は**許可の鍵**です。macOS は許可をこの文字列で
# 覚えるので、**あとから変えると許可は最初からやり直しになります。**変えるなら
# 配る前に決めてください。
#
# The bundle's papers (open question #22).
#
# **`NSMicrophoneUsageDescription` is the heart of this work.** From macOS 10.14
# on, an application without it that tries to open the microphone (line in) is
# **terminated on the spot, with no prompt at all** -- to the operator the
# application simply vanished on starting.
#
# The wording **says why it is needed**: before it is Apple's requirement, it is
# what the person being asked needs in order to decide.
#
# `CFBundleIdentifier` is **the key the permission is filed under**. macOS
# remembers the grant by that string, so **changing it later starts the
# permission over.** Settle it before distributing.
write_plist() {
  cat > "$app_dir/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>ja</string>
	<key>CFBundleDisplayName</key>
	<string>DeepCW モールス通信</string>
	<key>CFBundleExecutable</key>
	<string>deepcw_station</string>
	<key>CFBundleIdentifier</key>
	<string>$bundle_id</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleLocalizations</key>
	<array>
		<string>ja</string>
		<string>en</string>
	</array>
	<key>CFBundleName</key>
	<string>$app_name</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>$bundle_version</string>
	<key>CFBundleSignature</key>
	<string>????</string>
	<key>CFBundleVersion</key>
	<string>$bundle_version</string>
	<key>LSMinimumSystemVersion</key>
	<string>$macos_minimum</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSMicrophoneUsageDescription</key>
	<string>無線機から届くモールス信号の音を読み取るために、マイク（ライン入力）を使います。音は外へ送られません。</string>
</dict>
</plist>
PLIST
}

# 許可を求める文面は訳せます。**訊かれるときの言葉は OS の言語で決まります。**
# アプリの中の言語設定（NFR-7.6）ではありません——訊くのは OS だからです。
#
# 見つからなければ `Info.plist` の日本語が出ます（fail-soft）。
#
# The usage description is localizable. **The language it is asked in is the
# system's**, not the application's own setting (NFR-7.6): it is the system
# that asks. Missing, the Japanese from `Info.plist` is shown (fail-soft).
write_info_strings() {
	mkdir -p "$res_dir/ja.lproj" "$res_dir/en.lproj"
	cat > "$res_dir/ja.lproj/InfoPlist.strings" <<'JA'
"CFBundleDisplayName" = "DeepCW モールス通信";
"NSMicrophoneUsageDescription" = "無線機から届くモールス信号の音を読み取るために、マイク（ライン入力）を使います。音は外へ送られません。";
JA
	cat > "$res_dir/en.lproj/InfoPlist.strings" <<'EN'
"CFBundleDisplayName" = "DeepCW Morse Station";
"NSMicrophoneUsageDescription" = "Reads the Morse tone coming from your radio through the microphone or line input. The audio is not sent anywhere.";
EN
}

if [ "$layout" = macos ]; then
	write_plist
	write_info_strings
	# `PkgInfo` は古い決まりですが、**無いと一部の道具が入れ物と認めません。**
	# 中身は `CFBundlePackageType` と `CFBundleSignature` をつなげたものです。
	# `PkgInfo` is an old convention, but **some tools do not recognise a bundle
	# without it.** Its contents are the package type and signature joined.
	printf 'APPL????' > "$app_dir/Contents/PkgInfo"
	say "  入れ物 / bundle: $app_name.app（$bundle_id, 版 $bundle_version, macOS $macos_minimum 以降）"
	say "  マイクの許可 / microphone: NSMicrophoneUsageDescription を ja・en で"
	# 署名はここではしません。**この機械では確かめられないものを、確かめた形で
	# 置かないためです。**配る人が `codesign` と `notarytool` を通してください。
	# Nothing is signed here: **what cannot be checked on this machine is not
	# left looking as though it had been.** The distributor runs `codesign` and
	# `notarytool`.
	say "  署名 / signing: していません（配る前に codesign と notarytool を通してください）"
fi

say ""
say "できあがり / done: $stage"
ls -1 "$stage" | sed 's/^/  /'
