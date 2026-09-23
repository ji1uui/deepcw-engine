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

# **利用者の設定に触れません。**アプリは終わるときに設定を書き戻すので、本物の
# `~/.config` で走らせると試験のたびに書き換わり、結果もその設定に左右されます。
# **The operator's settings are left alone.** The application writes its
# settings back as it exits; run against the real `~/.config`, every test
# would rewrite them, and the outcome would depend on them.
# 組み立て（lazbuild）は本物の家が要るので、画面を開く段にだけ渡します。
# The build (lazbuild) needs the real home, so only the steps that open the
# screen are given this one.
GUI_HOME=$(mktemp -d)
trap 'rm -rf "$GUI_HOME"' EXIT
mkdir -p "$GUI_HOME/home" "$GUI_HOME/config"
gui_env() {
  env HOME="$GUI_HOME/home" XDG_CONFIG_HOME="$GUI_HOME/config" "$@"
}

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
  step "gui_probe（画面部品）" gui_env xvfb-run -a ./app/gui_probe
else
  skip "gui_probe（画面部品）" "xvfb-run がありません"
fi
step "強制終了しても記録が残る" ./tools/kill_safety_test.sh
# 配布物に許諾条項が入ること、入らないときは止まること（要件 NFR-8.2）。
# **配ってしまってからでは直せないものは、回帰試験に入れる。**
# A distribution carries the licence texts, and stops when it cannot
# (requirement NFR-8.2). **What cannot be fixed after shipping belongs in the
# regression.**
step "配布物に許諾条項が入る" ./tools/bundle_licence_test.sh
# macOS の `.app` が、配れる形に組み上がること（要件 FR-A.3、未解決 #22）。
# **`NSMicrophoneUsageDescription` が無ければ、macOS 10.14 以降は許可を訊かれる
# ことさえなく、マイクを開こうとした瞬間に OS がアプリを終了させます。**この
# 容器は Linux なので、確かめられるのは**並び**だけです（macOS での起動と署名は
# 未確認。付録 BJ）。
# The macOS `.app` is assembled in a shape that can be distributed (requirement
# FR-A.3, open question #22). **Without `NSMicrophoneUsageDescription`, macOS
# 10.14 and later terminate the application the moment it opens the microphone,
# with no prompt at all.** This container is Linux, so only **the arrangement**
# can be checked here (running and signing on macOS are NOT VERIFIED;
# appendix BJ).
step "macOS の .app が配れる形になる" ./tools/bundle_macos_test.sh
# CI の macOS が、**分かっている 1 つの失敗（#25）だけ**を通すこと（付録 BO）。
# 見分けが甘ければ、ずっと赤かった CI がずっと緑になるだけです。
# The CI's macOS job lets through **only the one known failure (#25)**
# (appendix BO); a loose match would just turn always-red into always-green.
step "CI が通すのは #25 のリンク失敗だけ" ./tools/known_link_failure_test.sh
# 画素密度の違う画面で、窓の組み方が破綻しないこと（要件 NFR-5.1）。
# **1 つの画面で見て回るだけでは、高 DPI の破綻は見つからない。**
# The layout holds on screens of different pixel density (requirement NFR-5.1).
# **Looking around one screen never finds the breakage on another.**
step "画素密度と言語を変えても組み方が崩れない" ./tools/layout_dpi_test.sh
# 訳した文言が元の日本語より目立って広くなっていないこと（要件 NFR-7.6）。
# **部品の大きさは日本語に合わせて決めてある。**訳が広ければ同じ枠には入らない。
# A translation has not grown noticeably wider than the Japanese it replaces
# (requirement NFR-7.6). **The controls were sized for the Japanese.**
if command -v xvfb-run >/dev/null 2>&1; then
  step "訳した文言が元より広くなっていない" \
    gui_env DEEPCW_TEXT_CHECK=1 xvfb-run -a ./app/deepcw_station
else
  skip "訳した文言が元より広くなっていない" "xvfb-run がありません"
fi
# `.po` が今のソースと合っていること（要件 NFR-7.6）。
# **足した文言が `.po` に無ければ、その文言だけが訳されずに残る。**しかも
# 画面を開くまで分からない。
# The `.po` matches the source (requirement NFR-7.6). **A string missing from
# it is simply left untranslated**, and that does not show until the screen is
# opened.
step "訳の一覧がソースと合っている" ./tools/po_sync_test.sh
# 画面に出る日本語が `resourcestring` の外に無いこと（要件 NFR-7.6、付録 BP）。
# **その場で組み立てる文言は、言語の往復検査には映りません。**ソースを見ます。
# No Japanese for the screen outside a `resourcestring` (NFR-7.6, appendix BP).
# **Words built on the spot never show in the round trip**, so the source is read.
step "日本語が resourcestring の外に無い" ./tools/literal_sweep_test.sh
# 差し込みが 2 つ以上の文言に番号が付いていること（要件 NFR-7.6）。
# **番号があっても、訳文で並べ替えることはできない**（LCL が黙って捨てる。
# 付録 BH.9）。番号は、並べ替えが本当に要るときの逃げ道
# （`#, no-object-pascal-format`）を開けておくためにある。
# Two or more placeholders carry indices (requirement NFR-7.6). **Indices do
# not let a translation reorder them** -- the LCL drops such a translation in
# silence (appendix BH.9). They keep open the one way out
# (`#, no-object-pascal-format`) for when reordering is genuinely needed.
step "文言の差し込みに番号が付いている" ./tools/format_index_test.sh
# `Format` に渡す引数の数が、文言の求める数と合っていること（要件 NFR-7.6）。
# **文言を `resourcestring` に移すと、綴りと呼び出しが離れます。**離れたものは
# 片方だけ直せてしまい、`Format` は**その行が画面に出ようとした瞬間に**例外を
# 投げます。滅多に出ない行ほど見つかりません。
# The argument count handed to `Format` matches what the string asks for
# (requirement NFR-7.6). **Moving words into a `resourcestring` separates the
# spelling from the call**, and one of them can then be changed alone; `Format`
# raises **at the moment that line is due on screen**, so the rarest lines are
# the last to be found.
step "文言に渡す引数の数が合っている" ./tools/format_args_test.sh
# 稼働中に言語を切り替えて、戻れること（要件 NFR-7.6）。
# **日本語へ戻す道は、英語へ行く道と違う。**取り違えると一度英語にしたら戻れず、
# 画面を開いて押してみるまで分からない。配布物と同じ並びで押す。
# The language can be changed while running, and come back (requirement
# NFR-7.6). **The way back is not the way out**; mistake it and the application
# cannot return, which shows only when someone tries. Tried in the layout the
# operator gets.
step "稼働中に言語を切り替えて戻れる" ./tools/lang_roundtrip_test.sh
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
