#!/bin/sh
# 地方時が OS（`date`）と一致することを、時間帯の与え方ごとに確かめます
# （未解決 #20、付録 BW.4）。
#
# FPC 3.2.2 の Unix の RTL は、時差を自前で、起動時に 1 度だけ読みます。
# `TZ=Asia/Tokyo`（`:` の無い形）を無視し、「slim」形式の時間帯ファイルでは
# 時差 0 になります。`DeepCW.Platform.SyncLocalClock` がそれを OS に合わせます。
#
# `dsp_check --clock-probe` を時間帯ごとに走らせ、**合わせたあとの時差**が
# `date +%z` と同じこと、**UTC が動かない**ことを見ます。合わせる前の時差も
# 出します。**前から一致していた例ばかりなら、この検査は何も確かめていない**
# ので、「slim」のファイルで前が食い違うことも確かめます（`zic` があるとき）。
#
# Checks, for each way of giving the time zone, that local time agrees with
# the OS (`date`) (open question #20, appendix BW.4).
#
# FPC 3.2.2's Unix RTL reads the offset itself, once, at start-up: it ignores
# `TZ=Asia/Tokyo` (the form without the colon) and gets offset 0 from a "slim"
# zone file. `DeepCW.Platform.SyncLocalClock` aligns it with the OS.
#
# `dsp_check --clock-probe` is run per zone: **the offset after aligning** must
# equal `date +%z`, and **UTC must not move**. The offset before is shown too;
# **were every case already right before, this check would prove nothing**, so
# a "slim" file is also required to disagree before (when `zic` exists).
set -u
cd "$(dirname "$0")/.."

case "$(uname -s)" in
  Linux|Darwin) ;;
  *)
    echo "Unix 以外では RTL が OS に尋ねます（確かめるものがありません）"
    exit 0
    ;;
esac

EXE=./cli/dsp_check
if [ ! -x "$EXE" ]; then
  echo "dsp_check がありません"
  exit 2
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
FAIL=0
DIFFERED=0

# `date +%z`（+0930 など）を分へ。/ `date +%z` (such as +0930) in minutes.
minutes_of() {
  z=$1
  sign=$(printf '%s' "$z" | cut -c1)
  h=$(printf '%s' "$z" | cut -c2-3 | sed 's/^0//')
  m=$(printf '%s' "$z" | cut -c4-5 | sed 's/^0//')
  v=$(( h * 60 + m ))
  [ "$sign" = "-" ] && v=$(( -v ))
  echo "$v"
}

check() {
  tz=$1
  label=$2
  want=$(minutes_of "$(TZ=$tz date +%z)")
  line=$(TZ=$tz "$EXE" --clock-probe 2>&1 | grep '^CLOCK ')
  before=$(printf '%s' "$line" | sed -n 's/.*before=\([-0-9]*\).*/\1/p')
  after=$(printf '%s' "$line" | sed -n 's/.*after=\([-0-9]*\).*/\1/p')
  moved=$(printf '%s' "$line" | sed -n 's/.*utcmoved=\([0-9]*\).*/\1/p')
  if [ -z "$after" ] || [ -z "$moved" ]; then
    echo "  NG   $label: 報告がありません（$line）"
    FAIL=1
    return
  fi
  if [ "$after" = "$want" ] && [ "$moved" -le 1 ]; then
    echo "  ok   $label: 前 $before 分 → 後 $after 分（date は $want 分、UTC の動き $moved 秒）"
  else
    echo "  NG   $label: 前 $before 分 → 後 $after 分（date は $want 分、UTC の動き $moved 秒）"
    FAIL=1
  fi
  [ "$before" != "$want" ] && DIFFERED=$((DIFFERED + 1))
  LAST_BEFORE=$before
  LAST_WANT=$want
}

echo "地方時が OS と一致する（付録 BW.4）"
check ":Asia/Tokyo" "TZ=:Asia/Tokyo"
check "Asia/Tokyo" "TZ=Asia/Tokyo（: 無し）"
check "America/New_York" "TZ=America/New_York"
check "Asia/Kolkata" "TZ=Asia/Kolkata（+5:30）"
check "America/St_Johns" "TZ=America/St_Johns（-2:30 / -3:30）"
check "UTC" "TZ=UTC"

if command -v zic >/dev/null 2>&1; then
  cat >"$WORK/zones" <<'EOF'
Rule	US	2007	max	-	Mar	Sun>=8	2:00	1:00	D
Rule	US	2007	max	-	Nov	Sun>=1	2:00	0	S
Zone	Test/NY	-5:00	US	E%sT
Zone	Test/Tokyo	9:00	-	JST
EOF
  for b in fat slim; do
    mkdir -p "$WORK/$b"
    zic -b "$b" -d "$WORK/$b" "$WORK/zones" 2>/dev/null
  done
  check ":$WORK/fat/Test/NY" "fat 形式（ニューヨーク）"
  check ":$WORK/slim/Test/Tokyo" "slim 形式（東京）"
  # slim では、合わせる前は必ず食い違う（直していなければ見逃す例）。
  # With slim, the offset before must disagree (the case that would be missed).
  if [ "$LAST_BEFORE" = "$LAST_WANT" ]; then
    echo "  NG   slim 形式で、合わせる前から一致していた（検査が働いていない）"
    FAIL=1
  fi
  check ":$WORK/slim/Test/NY" "slim 形式（ニューヨーク）"
else
  echo "  --   zic が無いため slim 形式は確かめません"
fi

echo "合わせる前に OS と食い違っていた例: $DIFFERED"
if [ "$FAIL" -ne 0 ]; then
  echo "地方時が OS と一致しない例があります。"
  exit 1
fi
echo "地方時はどの与え方でも OS と一致しました。"
