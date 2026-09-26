#!/bin/sh
# ファイルの復号で画面が止まらないことを、アプリの画面そのもので確かめます
# （要件 NFR-4.2、計画 6.1 の P1、付録 CE）。
#
# 版 2.82 まで、読み込み・同調・帯域・標本化・自動の幅が画面のスレッドで走り、
# 5 分の録音で約 1.7 秒、30 分で約 12 秒、画面が何も受け付けませんでした。
# **関数を単独で測っても、画面が止まるかどうかは分かりません。**アプリの
# 「デコード」と同じ道で読み、画面のスレッドが続けて塞がった長さを測ります。
#
# 5 分・8 kHz の録音（700 Hz の局と、300 Hz 横の強い局）を同調・自動の幅で
# 読みます。**確かめること**: 止まりが 200 ms 以下、700 Hz の局の文が読める、
# 幅が隣の局に合わせて ±150 Hz に狭まる（作業スレッドで決めた幅が画面へ届く）。
#
# 受け入れの基準は 100 ms で、実測は 30 分の録音で 34 ms（付録 CE）。ここで
# 200 ms（画面の更新間隔。`gui_probe` が「止まったと感じる」とする値）とするのは、
# 仮想機では推論がコアを埋めた間に画面のスレッドが 60 ms ほど待たされることが
# あるためです。**変更前はこの録音で約 1.7 秒なので、戻れば必ず落ちます。**
#
# Checks, in the application's own window, that decoding a file does not
# freeze the screen (requirement NFR-4.2, plan 6.1 P1, appendix CE).
#
# Up to version 2.82, loading, tuning, band limiting, rate conversion and the
# automatic width ran on the UI thread: about 1.7 s of unresponsive screen for
# five minutes of audio, about 12 s for thirty. **Timing the functions alone
# does not say whether the screen freezes**, so the file is read the way
# "decode" reads it and the longest stretch the UI thread stays blocked is
# measured.
#
# Five minutes at 8 kHz (a station at 700 Hz, a strong one 300 Hz away) is read
# tuned, with the automatic width. **Checked**: a stall of at most 200 ms, the
# 700 Hz station's text is read, and the width narrows to +/-150 Hz for the
# neighbour (the width decided on the worker reaches the screen).
#
# The acceptance is 100 ms, measured at 34 ms on thirty minutes (appendix CE).
# 200 ms here -- the display's refresh interval, what `gui_probe` treats as
# feeling frozen -- because on a virtual machine the UI thread is sometimes kept
# waiting about 60 ms while inference fills the cores. **Before the change this
# recording stalled about 1.7 s, so a regression cannot pass.**
set -e
cd "$(dirname "$0")/.."

if [ ! -x ./app/deepcw_station ]; then
  echo "app/deepcw_station がありません"
  exit 1
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
# 利用者の設定に触れません（`lang_roundtrip_test.sh` と同じ理由）。
# The operator's settings are left alone (as in `lang_roundtrip_test.sh`).
mkdir -p "$WORK/home" "$WORK/config"
HOME="$WORK/home"
XDG_CONFIG_HOME="$WORK/config"
export HOME XDG_CONFIG_HOME

python3 - "$WORK/five.wav" <<'PY'
import math, struct, sys, wave, random
M = {'A': '.-', 'B': '-...', 'C': '-.-.', 'D': '-..', 'E': '.', 'H': '....',
     'J': '.---', 'K': '-.-', 'Q': '--.-', 'S': '...', 'T': '-', 'X': '-..-',
     'Y': '-.--', 'Z': '--..', '1': '.----', '2': '..---'}
RATE, SECONDS = 8000, 300

def keying(text, wpm):
    unit = int(round(1.2 / wpm * RATE))
    env = [0] * (3 * unit)
    for word in text.split():
        for ch in word:
            for s in M[ch]:
                env += [1] * ((3 if s == '-' else 1) * unit) + [0] * unit
            env += [0] * (2 * unit)
        env += [0] * (4 * unit)
    return env

def smooth(env):
    # 5 ms の立ち上がり。クリックを避けます / 5 ms edges, avoiding clicks
    ramp = int(0.005 * RATE)
    out, level = [], 0.0
    for v in env:
        level += (v - level) / ramp
        out.append(level)
    return out

near = smooth(keying("CQ CQ DE JA1ABC JA1ABC K", 20))
far = smooth(keying("TEST DE JH2XYZ JH2XYZ TEST", 24))
rnd = random.Random(1)
frames = bytearray()
for n in range(RATE * SECONDS):
    t = n / RATE
    x = (0.3 * near[n % len(near)] * math.sin(2 * math.pi * 700 * t)
         + 0.6 * far[n % len(far)] * math.sin(2 * math.pi * 1000 * t)
         + 0.03 * rnd.gauss(0, 1))
    frames += struct.pack('<h', int(max(-1.0, min(1.0, x)) * 32000))
with wave.open(sys.argv[1], 'wb') as f:
    f.setnchannels(1)
    f.setsampwidth(2)
    f.setframerate(RATE)
    f.writeframes(bytes(frames))
PY

set +e
OUT=$(env DEEPCW_FILE_CHECK="$WORK/five.wav" DEEPCW_FILE_CHECK_TUNE=700 \
  DEEPCW_FILE_CHECK_LIMIT_MS=200 xvfb-run -a ./app/deepcw_station 2>/dev/null)
RC=$?
set -e
echo "$OUT" | grep -E "decode button|width:|text:" | cut -c1-200
if [ $RC -ne 0 ]; then
  echo "止まりが 200 ms を超えたか、何も読めませんでした（終了コード $RC）"
  exit 1
fi
if ! echo "$OUT" | grep -q "text: .*JA1ABC"; then
  echo "700 Hz の局の文（JA1ABC）が読めていません"
  exit 1
fi
if ! echo "$OUT" | grep -q "±150 Hz"; then
  echo "自動の幅が隣の局に合わせて ±150 Hz になっていません"
  exit 1
fi
echo "ok"
