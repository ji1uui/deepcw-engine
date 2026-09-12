#!/usr/bin/env bash
# 回帰試験をひととおり走らせます。
#
# **これまで、確かめる手立ては揃っていたのに、走らせるのは人の手でした。**
# 6 つの命令を順に叩き、出力を目で読んで判じていたため、読み飛ばせば劣化は
# そのまま通ります。ここでまとめて走らせ、1 つでも落ちれば全体を落とします。
#
# Runs the whole regression.
#
# **The means to check were all in place; running them was not.** Six commands
# were typed by hand and their output read by eye, so anything skimmed over
# passed. This runs them together and fails as a whole if any one fails.
#
#   使い方 / usage:  tools/regression.sh [--quick]
#     --quick  時間のかかる測定（sweep・shift・image・bandwidth・scale・
#              soak・track・wide）を飛ばします。
#              飛ばしたことは最後に明示します。
set -u

cd "$(dirname "$0")/.." || exit 2
QUICK=0
[ "${1:-}" = "--quick" ] && QUICK=1

PASS=0; FAIL=0; SKIP=0
FAILED_STEPS=""
SKIPPED_STEPS=""

step() {
  local name="$1"; shift
  printf '%-46s ' "$name"
  local out rc
  out=$("$@" 2>&1); rc=$?
  if [ $rc -eq 0 ]; then
    echo "ok"
    PASS=$((PASS + 1))
  else
    echo "NG (終了コード $rc)"
    echo "$out" | tail -15 | sed 's/^/      /'
    FAIL=$((FAIL + 1))
    FAILED_STEPS="$FAILED_STEPS
  - $name"
  fi
}

skip() {
  printf '%-46s とばしました（%s）\n' "$1" "$2"
  SKIP=$((SKIP + 1))
  SKIPPED_STEPS="$SKIPPED_STEPS
  - $1: $2"
}

# ---- 環境 ----
echo "環境: $(uname -srm) / fpc $(fpc -iV 2>/dev/null || echo '不明')"
if [ -z "${DEEPCW_ONNXRUNTIME:-}" ]; then
  for c in /usr/local/lib/python3*/dist-packages/onnxruntime/capi/libonnxruntime.so* \
           /usr/lib/libonnxruntime.so*; do
    [ -f "$c" ] && export DEEPCW_ONNXRUNTIME="$c" && break
  done
fi
echo "ONNX Runtime: ${DEEPCW_ONNXRUNTIME:-（見つかりません）}"
echo

# ---- 組み立て ----
echo "== 組み立て / build =="
for p in app/deepcw_station app/gui_probe cli/cw_devices cli/cw_loopback \
         cli/cw_stream cli/cw_tune cli/decode_morse cli/dsp_check; do
  step "$p" lazbuild -B "$p.lpi"
done
echo

# ---- 音声装置の要らない検証 ----
echo "== 数値と部品 / numeric and component checks =="
step "dsp_check（数値・記録・読み取り・待ち符号）" ./cli/dsp_check
if command -v xvfb-run >/dev/null 2>&1; then
  step "gui_probe（画面部品）" xvfb-run -a ./app/gui_probe
else
  skip "gui_probe（画面部品）" "xvfb-run がありません"
fi
step "強制終了しても記録が残る" ./tools/kill_safety_test.sh
echo

# ---- エンジンを使う検証 ----
echo "== 復号 / decoding =="
if [ -z "${DEEPCW_ONNXRUNTIME:-}" ] && [ ! -f ./libonnxruntime.so ]; then
  skip "cw_loopback ほか" "ONNX Runtime が見つかりません"
else
  step "cw_loopback（6 種の本文を完全一致で読む）" ./cli/cw_loopback
  step "cw_tune（同調・検出・多局・形・待ち符号・読み直し・送信訓練・間隔）" \
    ./cli/cw_tune --tests stream,correctness,overload,review,detect,multi,shape,callsign,watch,recheck,fist,pace,reference
  if [ $QUICK -eq 1 ]; then
    skip "cw_tune（同調の根拠）" "--quick"
    skip "cw_tune（規模・追跡・広帯域）" "--quick"
    skip "cw_tune（長時間・メモリ）" "--quick"
  else
    # 同調・イメージ・帯域幅の測定は、付録 E.1〜E.3 の設計判断そのものです。
    # **表を出すだけで一度も走らせていませんでした。**判定を付けたので、
    # ここへ入れます（約 84 秒）。
    # The tuning, image and bandwidth measurements are the design decisions of
    # appendix E.1-E.3 themselves, and **they printed tables while never being
    # run here at all.** Now that they reach a verdict, they belong in the
    # regression (about 84 seconds).
    step "cw_tune（同調の根拠: 掃引・偏移・イメージ・帯域幅）" \
      ./cli/cw_tune --tests sweep,shift,image,bandwidth
    step "cw_tune（規模・追跡・広帯域）" \
      ./cli/cw_tune --tests scale,track,wide
    # 長時間の走行は**別のプロセスで**行います。規模の測定は 24 局ぶんの
    # 領域を確保し、Free Pascal のヒープはそれを OS へ返しません。同じ
    # プロセスで続けると、長時間の走行は「すでに広いヒープ」から始まり、
    # **増えないのが当たり前**になります（実測 419516 kB から開始。単体では
    # 138792 kB）。メモリの測定は、測る対象だけが走っている場所で行います。
    # The long run goes in **a process of its own.** The scale measurement
    # claims the memory for 24 stations and Free Pascal's heap does not return
    # it to the system; continuing in the same process would start the long run
    # from an already-wide heap, where **not growing is guaranteed** (measured:
    # it began at 419516 kB against 138792 kB on its own). Memory is measured
    # where only the thing being measured is running.
    step "cw_tune（長時間・メモリ）" ./cli/cw_tune --tests soak
  fi

  # ---- 遅延（要件 NFR-1.1・NFR-1.2）----
  # 上限を本文ごとに変えるのは、確定の遅延が語の長さで決まるためです（付録 C.5）。
  # 短い語の交信は要件どおりの 5.0 秒で判じ、コールサインの多い本文は
  # **分かっている未達を、それ以上悪くさせない天井**として渡します。
  step "遅延: 短い語の交信（暫定 1.5 / 確定 5.0 秒）" \
    ./cli/cw_stream --quiet --check \
      --text "TNX FER QSO 73 ES GL WX IS FB HR RIG IS 100W ANT IS GP"
  step "遅延: 符号の多い本文（暫定 1.5 / 天井 7.0 秒）" \
    ./cli/cw_stream --quiet --check --max-confirmed 7.0 \
      --text "CQ CQ DE JH2XYZ JH2XYZ K JA1ABC DE JH2XYZ UR 599 599 QTH NAGOYA"
fi
echo

# ---- 参照実装との一致（要件 NFR-2.1）----
echo "== 参照実装との一致 / parity with the reference =="
PARITY_WAV="$(mktemp -d)/parity.wav"
if python3 -c "import numpy, onnxruntime" 2>/dev/null && \
   [ -f ../model.onnx ] && [ -n "${DEEPCW_ONNXRUNTIME:-}" ]; then
  if ./cli/cw_loopback --save-wav "$PARITY_WAV" >/dev/null 2>&1; then
    :
  fi
  # cw_loopback に書き出しが無い版では、Python 側で音を作ります。
  if [ ! -f "$PARITY_WAV" ]; then
    python3 - "$PARITY_WAV" <<'PY' 2>/dev/null
import sys, wave, numpy as np
M={'A':'.-','B':'-...','C':'-.-.','D':'-..','E':'.','F':'..-.','G':'--.','H':'....','I':'..','J':'.---','K':'-.-','L':'.-..','M':'--','N':'-.','O':'---','P':'.--.','Q':'--.-','R':'.-.','S':'...','T':'-','U':'..-','V':'...-','W':'.--','X':'-..-','Y':'-.--','Z':'--..','0':'-----','1':'.----','2':'..---','3':'...--','4':'....-','5':'.....','6':'-....','7':'--...','8':'---..','9':'----.'}
sr,wpm,f=8000,20,700; u=1.2/wpm
def seg(n,on):
    t=np.arange(int(n*u*sr))/sr
    if not on: return t*0
    x=np.sin(2*np.pi*f*t)*0.5; e=int(0.005*sr)
    if len(x)>2*e:
        r=np.hanning(2*e); x[:e]*=r[:e]; x[-e:]*=r[e:]
    return x
parts=[np.zeros(int(0.2*sr))]
for ch in "CQ CQ DE JA1ABC JA1ABC K":
    if ch==' ': parts.append(seg(4,False)); continue
    for s in M[ch]:
        parts.append(seg(3 if s=='-' else 1,True)); parts.append(seg(1,False))
    parts.append(seg(2,False))
parts.append(np.zeros(int(0.2*sr)))
x=np.concatenate(parts); w=np.int16(np.clip(x,-1,1)*32000)
with wave.open(sys.argv[1],'wb') as fo:
    fo.setnchannels(1); fo.setsampwidth(2); fo.setframerate(sr); fo.writeframes(w.tobytes())
PY
  fi
  if [ -f "$PARITY_WAV" ]; then
    PY_OUT=$(python3 ../examples/python/decode_morse.py --wav "$PARITY_WAV" \
      --model ../model.onnx --metadata ../model.onnx.json 2>/dev/null | tail -1)
    PAS_OUT=$(./cli/decode_morse --wav "$PARITY_WAV" 2>/dev/null | tail -1)
    printf '%-46s ' "Python 実装と同じ文字列を返す"
    if [ -n "$PY_OUT" ] && [ "$PY_OUT" = "$PAS_OUT" ]; then
      echo "ok"; PASS=$((PASS + 1))
    else
      echo "NG"; echo "      Python: $PY_OUT"; echo "      Pascal: $PAS_OUT"
      FAIL=$((FAIL + 1))
      FAILED_STEPS="$FAILED_STEPS
  - Python 実装との一致"
    fi
  else
    skip "Python 実装との一致" "試験用の音を作れません"
  fi
else
  skip "Python 実装との一致" "numpy / onnxruntime / model.onnx がありません"
fi
rm -rf "$(dirname "$PARITY_WAV")"
echo

# ---- まとめ ----
echo "=========================================="
echo "通った $PASS 件 / 通らなかった $FAIL 件 / とばした $SKIP 件"
[ -n "$SKIPPED_STEPS" ] && echo "とばしたもの:$SKIPPED_STEPS"
if [ $FAIL -gt 0 ]; then
  echo "通らなかったもの:$FAILED_STEPS"
  echo "回帰試験は通りませんでした。"
  exit 1
fi
if [ $SKIP -gt 0 ]; then
  echo "通りましたが、上のものは確かめていません。"
else
  echo "すべて通りました。"
fi
exit 0
