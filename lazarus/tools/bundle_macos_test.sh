#!/bin/sh
# macOS の `.app` が、配れる形に組み上がることを確かめます（要件 FR-A.3、未解決 #22）。
#
# **macOS 10.14 以降、`NSMicrophoneUsageDescription` の無いアプリは、マイク
# （ライン入力）を開こうとした瞬間に OS に終了させられます。**許可を訊かれる
# ことさえありません。利用者からは「起動したのに消えた」としか見えず、
# **受信アプリとしては何もできない状態**になります。
#
# **この容器は Linux です。**macOS で動かすことはできません。できるのは
# 「並べること」と「並びが正しいか見ること」で、それはどの OS でもできます。
# だから `DEEPCW_BUNDLE_LAYOUT=macos` で組ませて、ここで見ます。
#
# **確かめていないこと**（付録 BJ に書いてあります）:
#   - macOS で起動すること
#   - マイクの許可が実際に訊かれること
#   - `codesign` / `notarytool` / Gatekeeper を通ること
#
# Checks that the macOS `.app` is assembled in a shape that can be distributed
# (requirement FR-A.3, open question #22).
#
# **From macOS 10.14 on, an application without
# `NSMicrophoneUsageDescription` is terminated by the system the moment it
# tries to open the microphone (line in)** -- with no prompt at all. To the
# operator the application simply vanished on starting, and **as a receiver it
# can do nothing.**
#
# **This container is Linux** and cannot run macOS. What it can do is arrange
# the bundle and look at the arrangement, which any system can do; hence
# `DEEPCW_BUNDLE_LAYOUT=macos`.
#
# **Not checked here** (appendix BJ says so): that it starts on macOS, that the
# permission is actually asked for, that `codesign`, `notarytool` and Gatekeeper
# accept it.

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

command -v python3 >/dev/null 2>&1 || { echo "python3 がありません"; exit 2; }

mkdir -p "$work/lib"
printf 'MIT LICENCE TEXT\n' > "$work/lib/LICENSE"
printf 'x' > "$work/lib/libfake.so"

DEEPCW_BUNDLE_LAYOUT=macos \
DEEPCW_ONNXRUNTIME="$work/lib/libfake.so" \
DEEPCW_PORTAUDIO="$work/lib/libfake.so" \
  "$here/tools/make_bundle.sh" "$work/out" >"$work/log" 2>&1 \
  || { echo "組み立てに失敗しました"; tail -20 "$work/log"; exit 1; }

stage=$(find "$work/out" -maxdepth 1 -type d -name 'deepcw-station-*' | head -1)
app=$(find "$stage" -maxdepth 1 -type d -name '*.app' | head -1)
[ -n "$app" ] || { echo ".app が出来ていません"; exit 1; }

# [1] 入れ物の骨格。
for f in Contents/Info.plist Contents/PkgInfo; do
  if [ -f "$app/$f" ]; then check "$f がある" ok
  else check "$f がある" ng; fi
done

# [2] `Info.plist` が読めること、そして**マイクの説明が入っていること。**
#     ここがこの試験の主眼です。
python3 - "$app/Contents/Info.plist" > "$work/plist.txt" 2>&1 <<'PY' || true
import plistlib, io, sys
d = plistlib.load(io.open(sys.argv[1], 'rb'))
for k, v in sorted(d.items()):
    print('%s\t%s' % (k, v))
PY
if grep -q '^CFBundleIdentifier' "$work/plist.txt"; then
  check "Info.plist が読める" ok
else
  check "Info.plist が読める" ng "$(head -3 "$work/plist.txt")"
fi

value() { grep "^$1	" "$work/plist.txt" | head -1 | cut -f2-; }

mic=$(value NSMicrophoneUsageDescription)
# **空でないだけでは足りません。**`TODO` や `.` のような当たり障りのない文面は
# Apple の審査で落ちますし、何より**訊かれた人が判断できません。**20 バイトは、
# 「なぜ要るのか」を書けば必ず超える長さです（`sh` の `${#...}` は字ではなく
# バイトを数えます。日本語は 1 字 3 バイトなので、なお余裕があります）。
# **Not empty is not enough**: a placeholder like `TODO` or `.` fails Apple's
# review and, more to the point, **tells the person being asked nothing.**
# Twenty bytes is a length that saying why cannot fall short of (`sh`'s
# `${#...}` counts bytes, not characters).
if [ ${#mic} -ge 20 ]; then
  check "マイクの説明がある（${#mic} バイト）" ok
else
  check "マイクの説明がある" ng "「$mic」"
fi

exe=$(value CFBundleExecutable)
if [ -n "$exe" ] && [ -x "$app/Contents/MacOS/$exe" ]; then
  check "CFBundleExecutable が実在する（$exe）" ok
else
  check "CFBundleExecutable が実在する" ng "「$exe」"
fi

if [ "$(value CFBundlePackageType)" = "APPL" ]; then
  check "CFBundlePackageType が APPL" ok
else
  check "CFBundlePackageType が APPL" ng "$(value CFBundlePackageType)"
fi

# 識別子は**許可の鍵**です。逆 DNS でなければ、他のアプリと衝突しえます。
# The identifier is the key the permission is filed under; not reverse-DNS, it
# can collide with another application's.
id=$(value CFBundleIdentifier)
if printf '%s' "$id" | grep -Eq '^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+){2,}$'; then
  check "CFBundleIdentifier が逆 DNS（$id）" ok
else
  check "CFBundleIdentifier が逆 DNS" ng "「$id」"
fi

# マイクの許可は 10.14 から。それより低く宣言すると、**許可を持たない古い
# macOS で動くと約束したことになります。**
# The microphone permission arrived in 10.14; declaring less promises to run on
# a macOS that has no such permission at all.
minimum=$(value LSMinimumSystemVersion)
if printf '%s' "$minimum" | awk -F. '{ exit !(($1 > 10) || ($1 == 10 && $2 >= 14)) }'; then
  check "LSMinimumSystemVersion が 10.14 以上（$minimum）" ok
else
  check "LSMinimumSystemVersion が 10.14 以上" ng "「$minimum」"
fi

# [3] 訳した許可の文面。
for lang in ja en; do
  f="$app/Contents/Resources/$lang.lproj/InfoPlist.strings"
  if [ -f "$f" ] && grep -q 'NSMicrophoneUsageDescription' "$f"; then
    check "$lang.lproj/InfoPlist.strings に説明がある" ok
  else
    check "$lang.lproj/InfoPlist.strings に説明がある" ng
  fi
done

# [4] 持ち物の置き場所。
for f in model.onnx model.onnx.json languages licences; do
  if [ -e "$app/Contents/Resources/$f" ]; then
    check "Contents/Resources/$f がある" ok
  else
    check "Contents/Resources/$f がある" ng
  fi
done

# [5] **`Contents/MacOS/` に実行ファイルと共有ライブラリ以外を置かないこと。**
#     署名はそれを想定しておらず、入れ物の形が違うと言って止まります。
#
#     **実行権限では見分けられません。**`model.onnx` はこの木で 755 で置かれて
#     いて、権限だけを見る書き方は**この試験を書いた当日にすり抜けました**
#     （付録 BJ.4）。中身の先頭を見ます——実行できる形式か、名前が共有
#     ライブラリか、そのどちらかだけを通します。
#
#     A `Contents/MacOS/` holding anything but executables and shared libraries
#     is a shape the signing step rejects.
#
#     **The execute bit does not tell them apart**: `model.onnx` is kept 755 in
#     this tree, and a check that looked only at permissions **let it through on
#     the day this test was written** (appendix BJ.4). The first bytes are what
#     is looked at: either it is an executable format, or its name says shared
#     library, or it does not belong.
stray=$(python3 - "$app/Contents/MacOS" <<'STRAY'
import os, sys, io
# 実行できる形式の先頭（ELF・Mach-O 32/64・universal）。
# The first bytes of an executable format: ELF, Mach-O 32/64, universal.
MAGIC = (b'\x7fELF', b'\xcf\xfa\xed\xfe', b'\xce\xfa\xed\xfe',
         b'\xfe\xed\xfa\xcf', b'\xfe\xed\xfa\xce',
         b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca')
out = []
for name in sorted(os.listdir(sys.argv[1])):
    path = os.path.join(sys.argv[1], name)
    if name.endswith('.dylib') or name.endswith('.dll') or \
       name.endswith('.so') or '.so.' in name:
        continue
    if os.path.isdir(path):
        out.append(name + '(ディレクトリ)')
        continue
    head = io.open(path, 'rb').read(4)
    if not head.startswith(MAGIC):
        out.append(name)
print(' '.join(out))
STRAY
)
if [ -z "$stray" ]; then
  check "Contents/MacOS に実行ファイルと共有ライブラリだけ" ok
else
  check "Contents/MacOS に実行ファイルと共有ライブラリだけ" ng "余分: $stray"
fi

# [6] 読み物は `.app` の外。**Finder では `.app` は 1 個のアイコンに見えるので、
#     中に入れた説明書は開かれません。**
for f in LICENSE THIRD-PARTY-NOTICES.md はじめに.txt; do
  if [ -f "$stage/$f" ]; then
    check "$f が .app の外にある" ok
  else
    check "$f が .app の外にある" ng
  fi
done

# [7] **実際に中から読めること。**並べただけでは、アプリが見つけられるとは
#     限りません。`Contents/MacOS/` から起動して、訳が引けるかを見ます。
#     そして**訳を実行ファイルの隣へ移すと引けなくなること**も見ます——
#     引けたままなら、この置き換えは何もしていないことになります。
#     **Actually readable from inside.** Arranging does not by itself mean the
#     application finds them: started from `Contents/MacOS/`, it must find the
#     translations -- and **must stop finding them when they are moved beside
#     the executable**, for otherwise the change did nothing.
if command -v xvfb-run >/dev/null 2>&1; then
  if (cd "$app/Contents/MacOS" && DEEPCW_TEXT_CHECK=1 xvfb-run -a ./deepcw_station) \
       >"$work/text1" 2>&1 && grep -q '訳 [0-9]* 件' "$work/text1"; then
    check "中から訳を引ける" ok
  else
    check "中から訳を引ける" ng "$(grep -v 'ALSA\|Jack\|Gtk' "$work/text1" | tail -3)"
  fi
  # 並べ替えが効いていない（訳がそもそも `Resources` に無い）ときは、この
  # 変異は置けません。**置けなかったことを ok にしてはいけません。**
  # When the arrangement did not happen (no translations in `Resources` at
  # all), this mutation cannot be placed. **Not placing it is not a pass.**
  if [ -d "$app/Contents/Resources/languages" ]; then
    mv "$app/Contents/Resources/languages" "$app/Contents/MacOS/languages"
    (cd "$app/Contents/MacOS" && DEEPCW_TEXT_CHECK=1 xvfb-run -a ./deepcw_station) \
      >"$work/text2" 2>&1 || true
    if grep -q '訳された文言はありません' "$work/text2"; then
      check "実行ファイルの隣へ移すと引けなくなる" ok
    else
      check "実行ファイルの隣へ移すと引けなくなる" ng "隣でも引けています（置き換えが効いていません）"
    fi
    mv "$app/Contents/MacOS/languages" "$app/Contents/Resources/languages"
  else
    check "実行ファイルの隣へ移すと引けなくなる" ng "Contents/Resources/languages がありません"
  fi
else
  check "中から訳を引ける" ng "xvfb-run がありません"
fi

if [ "$failures" -gt 0 ]; then
  printf '%d 件が通りませんでした。\n' "$failures"
  exit 1
fi
exit 0
