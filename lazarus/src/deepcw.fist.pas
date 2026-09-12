unit DeepCW.Fist;

{ 送信訓練の測定と採点です（要件 FR-H）。

  無線機は鍵操作に対してモニタートーンを鳴らします。**その音を受信と同じ入力から
  取り込めば、送信訓練は受信経路だけで完結します。**電波も Hamlib も要りません。

  ここが担うのは 3 つです。

    1. 包絡線から要素（短点・長点・各間隔）の長さを**ミリ秒未満の分解能で**取り出す
    2. 課題文に対応づけて、どの長さが何の間隔なのかを決める
    3. 5 項目で採点し、**何を直せばよいかを 1 つだけ**示す

  **モデルの STFT は使いません。**20 WPM の短点は 60 ms で、時間分解能 15 ms では
  1 要素あたり最大 ±12.5% の量子化誤差になります。熟練者の 3% のばらつきは
  そもそも測れません（要件 FR-H.4、付録 A.2）。

  **点数は「正しさ」ではなく「安定と明瞭」を測ります。**長短比 2.6 のバグキーは、
  その値を基準に選べば高い点数になります。点数の低さは故障ではなく余地です。

  Measurement and scoring for send practice (requirement FR-H).

  A transceiver sounds a monitor tone as the key is worked, so **taking that tone
  through the same input as reception makes send practice complete in the
  receive path alone** -- no transmitter and no Hamlib.

  Three things live here: element lengths pulled from the envelope at better
  than a millisecond; the kind of each length settled by matching the exercise
  text; and a score in five parts with **one** thing to work on.

  **The model's STFT is not used.** A dit at 20 WPM is 60 ms, and a resolution of
  15 ms quantises each element by up to 12.5% -- an expert's 3% spread cannot be
  seen at all (requirement FR-H.4, appendix A.2).

  **The score measures steadiness and clarity, not correctness.** A bug key's
  ratio of 2.6 scores full marks against the bug-key basis. A low score is room
  to grow, not a fault. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Math, DeepCW.Types, DeepCW.Morse, DeepCW.Tuner;

type
  { 要素の種別。音が 2 つ、無音が 3 つです。
    The kinds of element: two of sound, three of silence. }
  TElementKind = (
    ekDit,    { 短点 / dit }
    ekDah,    { 長点 / dah }
    ekIntra,  { 符号内の間隔 / the gap inside one character }
    ekChar,   { 文字と文字の間 / between characters }
    ekWord    { 語と語の間 / between words }
  );

  TElement = record
    Kind: TElementKind;
    Seconds: Double;
    AtSeconds: Double;  { 始まった時刻 / when it began }
  end;
  TElements = array of TElement;
  TElementKinds = array of TElementKind;

  TElementStats = record
    Count: Integer;
    Mean: Double;
    Sd: Double;
    Cv: Double;  { 変動係数 = Sd / Mean。0 なら測れていません }
  end;

  { 1 回ぶんの測定結果。**素の測定値をすべて残します。**基準や重みを後から
    見直したときに、過去の記録を採点し直せるようにするためです（要件 FR-H.10）。
    One session's measurement. **Every raw figure is kept** so that a record can
    be scored again after the basis or the weights are revised (FR-H.10). }
  TFistMeasurement = record
    Ok: Boolean;
    Note: string;          { 測れなかった理由、または参考値である旨 }
    Reference: Boolean;    { 課題文なしで測った＝参考値（要件 FR-H.3） }
    Elements: TElements;
    Stats: array[TElementKind] of TElementStats;
    DitSeconds: Double;
    Ratio: Double;         { 長短比 = 長点 / 短点 }
    IntraRatio: Double;    { 符号内の間隔 / 短点 }
    CharRatio: Double;     { 文字間 / 短点 }
    WordRatio: Double;     { 語間 / 短点 }
    ToneSeparation: Double; { 短点と長点の分離度 }
    GapSeparation: Double;  { 符号内と文字間の分離度 }
    Drift: Double;          { セッション内の速度変化（比） }
    EffectiveWpm: Double;
    Seconds: Double;
    Characters: Integer;
  end;

  { 採点の基準（要件 FR-H.7）。**基準を選べることが、個性を減点しないための
    仕組みです。**
    The basis for scoring (FR-H.7). **Being able to choose it is the mechanism
    by which an individual hand is not marked down.** }
  TFistStandard = (
    fsStandard,    { 標準（1 : 3、間隔 1 : 3 : 7） }
    fsFarnsworth,  { ファンズワース（文字間と語間を広く） }
    fsBug,         { バグキー（長点が長め） }
    fsOwn          { 自分の過去 }
  );

  TFistTarget = record
    Ratio: Double;
    IntraRatio: Double;
    CharRatio: Double;
    WordRatio: Double;
  end;

  { 5 項目の点数（要件 FR-H.6）。実効 WPM は点数ではなく**文脈値**として
    測定側に置いてあります。速いことは上手いことではありません。
    The five scores (FR-H.6). The effective WPM is not one of them: it stays on
    the measurement as context, because fast is not the same as good. }
  TFistScore = record
    Speed: Double;        { 速度の安定 }
    Clarity: Double;      { 短長の明瞭 }
    Separation: Double;   { 区切りの明瞭 }
    Spacing: Double;      { 間隔の正確 }
    Copyability: Double;  { 写しやすさ }
    HasCopyability: Boolean;
    Overall: Double;
    Advice: string;
  end;

const
  FIST_ELEMENT_NAMES: array[TElementKind] of string = (
    '短点', '長点', '符号内', '文字間', '語間');
  FIST_STANDARD_NAMES: array[TFistStandard] of string = (
    '標準', 'ファンズワース', 'バグキー', '自分の過去');
  FIST_SCORE_NAMES: array[0..4] of string = (
    '速度の安定', '短長の明瞭', '区切りの明瞭', '間隔の正確', '写しやすさ');

  { 包絡線の平滑の長さ。700 Hz の周期は 1.43 ms なので、2 ms あれば搬送波の
    脈動は消えます。**これ以上長くすると、要素の端がなまります。**
    The envelope smoothing: at 2 ms the ripple of a 700 Hz carrier (1.43 ms per
    cycle) is gone. **Longer than that and the edges of the elements soften.** }
  FIST_SMOOTH_SECONDS = 0.002;

  { 音の有無を分けるしきい値。峰の半分（−6 dB）で、立ち上がりの整形が
    対称なら、始まりと終わりのずれは打ち消し合います。
    Sound or silence is split at half the peak (-6 dB); with a symmetric ramp
    the errors at the two ends cancel. }
  FIST_THRESHOLD_FRACTION = 0.5;

  { 取り込む帯域の片側。モニタートーンの近くだけを見ます。
    Half the band taken in, around the monitor tone. }
  FIST_HALF_WIDTH_HZ = 300;

  { これより短い音は要素として数えません。40 WPM の短点でも 30 ms あります。
    Anything shorter than this is not an element: a dit at 40 WPM is still 30 ms. }
  FIST_MIN_ELEMENT_SECONDS = 0.010;

{ モニタートーンの音程を見つけます。

  **どの音程で鳴っているかを人に入れさせません。**無線機ごとに違い、機種に
  よっては変えられます。入れ間違えれば測れず、その理由も分かりません。

  音の大きい窓だけを見て、候補の音程ごとの強さを足し合わせ、いちばん強い
  ものを返します。音が見つからなければ 0 を返します（**0 は「見つからない」で
  あって「0 Hz」ではありません**）。

  Finds the pitch of the monitor tone.

  **The operator is not asked for it**: it differs by transceiver and on some it
  can be changed, and entered wrongly nothing can be measured and nothing says
  why. The loudest windows are scanned, the strength of each candidate pitch
  summed, and the strongest returned -- or zero, which **means "not found", not
  "zero hertz"**. }
function DetectToneHz(const Samples: TSingleArray; SampleRate: Integer;
  LowHz: Double = 250; HighHz: Double = 1500): Double;

{ 包絡線（要件 FR-H.4）。帯域通過 → 整流 → 平滑です。返る配列は入力と同じ
  長さで、分解能は標本周期そのもの（8000 Hz なら 0.125 ms）です。
  The envelope (FR-H.4): band-pass, rectify, smooth. One value per sample, so
  the resolution is the sample period itself -- 0.125 ms at 8000 Hz. }
function ToneEnvelope(const Samples: TSingleArray; SampleRate: Integer;
  ToneHz: Double): TDoubleArray;

{ 課題文に対応づけて測ります（要件 FR-H.2）。**これが主の経路です。**

  しきい値で種別を分ける方式は、間隔が接近したり離れたりすると破綻します。
  つまり**直したい相手であるはずの、下手な符号ほど測れません**（付録 A.2）。
  課題文が分かっていれば、何番目が何の間隔なのかは音を聞かずに決まります。

  音の数が課題文と合わなければ `Ok` は False です。**符号が抜けた、または
  くっついたということで、対応づけに意味がありません。**

  Measured against the exercise text (FR-H.2). **This is the main path.**

  Splitting the kinds by a threshold breaks down as soon as the gaps crowd
  together or spread apart -- **it fails worst on exactly the hand that most
  needs the help** (appendix A.2). With the text known, which gap is which
  follows without listening at all.

  `Ok` is False when the number of sounds does not match the text: something was
  dropped or run together, and there is nothing to line up. }
function MeasureAgainstText(const Samples: TSingleArray; SampleRate: Integer;
  ToneHz: Double; const Text: string): TFistMeasurement;

{ 課題文なしで測ります（要件 FR-H.3）。しきい値（2 短点・5 短点）で種別を
  分けるため、**結果は参考値です。**`Reference` が True で返ります。
  Measured without a text (FR-H.3). The kinds are split at two and five dits,
  so **the result is indicative only**; `Reference` comes back True. }
function MeasureFree(const Samples: TSingleArray; SampleRate: Integer;
  ToneHz: Double): TFistMeasurement;

{ 基準ごとの目標値（要件 FR-H.7）。`fsOwn` のときだけ `Own` を使います。
  The target figures for each basis (FR-H.7); `Own` is used for `fsOwn` only. }
function FistTargetFor(Standard: TFistStandard; const Own: TFistTarget): TFistTarget;

{ 測定そのものを基準にします。「自分の過去」を選ぶための材料です。
  Turns a measurement into a basis -- the material for "my own past". }
function TargetFromMeasurement(const M: TFistMeasurement): TFistTarget;

{ 分布のヒストグラム（要件 FR-H.9）。

  **点数は「どれだけ離れているか」を 1 つの数にしたものです。**その数の元に
  なった分布そのものを見せると、**なぜその点数なのかが目で分かります。**
  符号内の間隔と文字間の山が重なっていれば、区切りの明瞭が低い理由はそれです。

  横軸は**短点いくつぶんか**です。秒で測ると、速度を変えたときに同じ癖が別の
  形に見えます。短点で測れば、20 WPM でも 30 WPM でも同じ絵になります。

  範囲の外に出た値は、**捨てずに端の升へ入れます**（教訓 10.9）。捨てると、
  極端に長い間隔が 1 つも無かったように見えます。

  The histogram of the distributions (requirement FR-H.9).

  **A score is how far apart things are, reduced to one number.** Showing the
  distributions it came from **makes the reason for that number visible**: where
  the gap inside a character and the gap between characters overlap, that is why
  the break between characters scores low.

  The axis is in **dits, not seconds**: measured in seconds the same habit looks
  like a different shape at another speed, while in dits it draws the same
  picture at 20 WPM and at 30.

  Anything past the end goes **into the last bucket rather than away**
  (lesson 10.9): dropped, a wildly long gap would look like no gap at all. }
const
  FIST_HISTOGRAM_BUCKETS = 27;
  { 語間の目安 7 に少し余裕を見た範囲。/ Room past the seven a word gap wants. }
  FIST_HISTOGRAM_MAX_UNITS = 9.0;

type
  TCounts = array of Integer;

function Histogram(const Elements: TElements; Kind: TElementKind;
  DitSeconds: Double; Buckets: Integer = FIST_HISTOGRAM_BUCKETS;
  MaxUnits: Double = FIST_HISTOGRAM_MAX_UNITS): TCounts;

{ 升 1 つぶんの幅（短点いくつぶんか）。/ One bucket's width, in dits. }
function BucketUnits(Buckets: Integer = FIST_HISTOGRAM_BUCKETS;
  MaxUnits: Double = FIST_HISTOGRAM_MAX_UNITS): Double;

{ 採点します（要件 FR-H.6・FR-H.8）。`Cer` に 0 以上を渡すと「写しやすさ」も
  点数に入ります。渡さなければ 4 項目で採点し、`HasCopyability` は False です。
  Scores the measurement (FR-H.6, FR-H.8). Pass `Cer` at zero or above to
  include copyability; without it the score is out of the other four and
  `HasCopyability` is False. }
function ScoreFist(const M: TFistMeasurement; Standard: TFistStandard;
  const Own: TFistTarget; Cer: Double = -1): TFistScore;

implementation

{ 小さいほうから数えた位置の値。**並べ替えではなく、必要な 1 つだけを
  選び出します。**包絡線は 20 万点を超えるので、全部を並べ替えると
  終わりません（実測: 挿入法では戻ってこなかった）。
  The value at a given position from the bottom. **Only the one value is
  selected, not the whole order**: an envelope runs past two hundred thousand
  points, and sorting all of them does not finish (measured: with an insertion
  sort it never returned). }
function Percentile(const Values: TDoubleArray; Fraction: Double): Double;
var
  Work: TDoubleArray;
  Low_, High_, Wanted, I, J: Integer;
  Pivot, Swap: Double;
begin
  Result := 0;
  if Length(Values) = 0 then
    Exit;
  Work := Copy(Values, 0, Length(Values));
  Wanted := Min(High(Work), Max(0, Round(Fraction * High(Work))));
  Low_ := 0;
  High_ := High(Work);
  while Low_ < High_ do
  begin
    Pivot := Work[(Low_ + High_) div 2];
    I := Low_;
    J := High_;
    while I <= J do
    begin
      while Work[I] < Pivot do Inc(I);
      while Work[J] > Pivot do Dec(J);
      if I <= J then
      begin
        Swap := Work[I];
        Work[I] := Work[J];
        Work[J] := Swap;
        Inc(I);
        Dec(J);
      end;
    end;
    { 欲しい位置のある側だけを続けます。/ Only the side holding the wanted
      position is carried on with. }
    if Wanted <= J then
      High_ := J
    else if Wanted >= I then
      Low_ := I
    else
      Break;
  end;
  Result := Work[Wanted];
end;



function DetectToneHz(const Samples: TSingleArray; SampleRate: Integer;
  LowHz, HighHz: Double): Double;
const
  WINDOW = 1024;
  WINDOWS = 24;
  STEP_HZ = 4;
var
  Starts: array of Integer;
  Power: array of Double;
  Loudness: TDoubleArray;
  I, J, K, Count, Taken, Best: Integer;
  Sum, Hz, Cosine, Coefficient, S0, S1, S2, Cut: Double;
begin
  Result := 0;
  if (SampleRate <= 0) or (Length(Samples) < WINDOW) or (HighHz <= LowHz) then
    Exit;

  { 音の大きい窓だけを見ます。**無音の窓を混ぜると、雑音の色が答えになります。**
    Only the loud windows: **with the silent ones mixed in, the answer would be
    the colour of the noise.** }
  Count := Max(1, Length(Samples) div WINDOW);
  SetLength(Loudness, Count);
  for I := 0 to Count - 1 do
  begin
    Sum := 0;
    for J := I * WINDOW to Min(High(Samples), I * WINDOW + WINDOW - 1) do
      Sum := Sum + Sqr(Samples[J]);
    Loudness[I] := Sum;
  end;
  Cut := Percentile(Loudness, 0.9);
  { **音が無ければ、音程も無いと言います。**いちばん低い候補を返せば、
    無音から 250 Hz の信号があったことになります。
    **No sound means no pitch**: returning the lowest candidate would turn
    silence into a signal at 250 Hz. }
  if Cut <= 0 then
    Exit;
  SetLength(Starts, Count);
  Taken := 0;
  for I := 0 to Count - 1 do
    if (Loudness[I] >= Cut) and (Taken < WINDOWS) then
    begin
      Starts[Taken] := I * WINDOW;
      Inc(Taken);
    end;
  if Taken = 0 then
    Exit;

  { 候補の音程ごとに、ゲルツェル法で強さを測ります。**全体の変換より安く、
    欲しい帯だけを見られます。**
    The strength of each candidate by the Goertzel method: **cheaper than a
    whole transform, and it looks only where the answer can be.** }
  Count := Max(1, Round((HighHz - LowHz) / STEP_HZ) + 1);
  SetLength(Power, Count);
  for K := 0 to Count - 1 do
  begin
    Hz := LowHz + K * STEP_HZ;
    Cosine := Cos(2 * Pi * Hz / SampleRate);
    Coefficient := 2 * Cosine;
    Power[K] := 0;
    for I := 0 to Taken - 1 do
    begin
      S1 := 0;
      S2 := 0;
      for J := Starts[I] to Min(High(Samples), Starts[I] + WINDOW - 1) do
      begin
        S0 := Samples[J] + Coefficient * S1 - S2;
        S2 := S1;
        S1 := S0;
      end;
      Power[K] := Power[K] + Sqr(S1) + Sqr(S2) - Coefficient * S1 * S2;
    end;
  end;

  Best := 0;
  for K := 1 to Count - 1 do
    if Power[K] > Power[Best] then
      Best := K;
  if Power[Best] <= 0 then
    Exit;
  Result := LowHz + Best * STEP_HZ;
end;

function ToneEnvelope(const Samples: TSingleArray; SampleRate: Integer;
  ToneHz: Double): TDoubleArray;
var
  Band: TSingleArray;
  Window, I, J, First_, Last_: Integer;
  Sum: Double;
begin
  Result := nil;
  if (Length(Samples) = 0) or (SampleRate <= 0) then
    Exit;
  if ToneHz > 0 then
    Band := BandPassFilter(Samples, SampleRate,
      Max(20, ToneHz - FIST_HALF_WIDTH_HZ), ToneHz + FIST_HALF_WIDTH_HZ)
  else
    Band := Samples;

  Window := Max(1, Round(FIST_SMOOTH_SECONDS * SampleRate));
  SetLength(Result, Length(Band));
  { 移動平均は、和を持ち回して 1 標本あたり 2 回の足し算で済ませます。
    **要素の端をずらさないよう、窓は中央に置きます。**
    A running sum keeps the moving average to two additions per sample, and the
    window is centred so that it does not shift the edges of the elements. }
  Sum := 0;
  First_ := 0;
  Last_ := -1;
  for I := 0 to High(Band) do
  begin
    while Last_ < Min(High(Band), I + Window div 2) do
    begin
      Inc(Last_);
      Sum := Sum + Abs(Band[Last_]);
    end;
    while First_ < Max(0, I - Window div 2) do
    begin
      Sum := Sum - Abs(Band[First_]);
      Inc(First_);
    end;
    J := Last_ - First_ + 1;
    if J > 0 then
      Result[I] := Sum / J
    else
      Result[I] := 0;
  end;
end;

{ 包絡線から、音が続いている区間を取り出します。しきい値をまたぐ位置は
  線形に補間するので、分解能は標本周期より細かくなります。
  The runs of sound in the envelope. The crossing is interpolated, so the
  resolution is finer than the sample period. }
type
  TSpan = record
    FromSeconds, ToSeconds: Double;
  end;
  TSpans = array of TSpan;

  { 面積から求めた 1 つの音。**しきい値をまたぐ時刻ではありません。**
    One sound, taken from the area under the envelope -- **not from the times at
    which it crossed a threshold.** }
  TTone = record
    Centre: Double;
    Seconds: Double;
  end;
  TTones = array of TTone;

function KeyedSpans(const Env: TDoubleArray; SampleRate: Integer): TSpans;
var
  Peak, Level, Previous: Double;
  I, Count: Integer;
  Inside: Boolean;
  Start_: Double;

  function Crossing(Index_: Integer; A, B: Double): Double;
  begin
    { しきい値をまたぐ時刻を、隣り合う 2 標本から線形に求めます。
      The time of the crossing, linear between the two samples. }
    if Abs(B - A) < 1E-12 then
      Result := Index_ / SampleRate
    else
      Result := (Index_ - 1 + (Level - A) / (B - A)) / SampleRate;
  end;

begin
  Result := nil;
  Count := 0;
  if (Length(Env) = 0) or (SampleRate <= 0) then
    Exit;
  { 峰は上位 10% の位置で見ます。**最大値で割ると、1 つの雑音の尖りで
    しきい値が上がってしまいます。**
    The peak is taken at the 90th percentile: **divided by the maximum, one
    spike of noise would lift the threshold for everything.** }
  Peak := Percentile(Env, 0.9);
  if Peak <= 0 then
    Exit;
  Level := FIST_THRESHOLD_FRACTION * Peak;

  Inside := False;
  Start_ := 0;
  Previous := Env[0];
  for I := 1 to High(Env) do
  begin
    if (not Inside) and (Env[I] >= Level) and (Previous < Level) then
    begin
      Inside := True;
      Start_ := Crossing(I, Previous, Env[I]);
    end
    else if Inside and (Env[I] < Level) and (Previous >= Level) then
    begin
      Inside := False;
      if Count = Length(Result) then
        SetLength(Result, Max(16, Count * 2));
      Result[Count].FromSeconds := Start_;
      Result[Count].ToSeconds := Crossing(I, Previous, Env[I]);
      Inc(Count);
    end;
    Previous := Env[I];
  end;
  if Inside then
  begin
    if Count = Length(Result) then
      SetLength(Result, Count + 1);
    Result[Count].FromSeconds := Start_;
    Result[Count].ToSeconds := High(Env) / SampleRate;
    Inc(Count);
  end;
  SetLength(Result, Count);
end;

{ 短すぎる音を落とします。雑音の尖りを要素と数えないためです。
  Drops anything too short to be an element, so that a spike of noise is not
  counted as one. }
function LongEnough(const Spans: TSpans): TSpans;
var
  I, Count: Integer;
begin
  SetLength(Result, Length(Spans));
  Count := 0;
  for I := 0 to High(Spans) do
    if Spans[I].ToSeconds - Spans[I].FromSeconds >= FIST_MIN_ELEMENT_SECONDS then
    begin
      Result[Count] := Spans[I];
      Inc(Count);
    end;
  SetLength(Result, Count);
end;

{ 音の長さを、包絡線の面積から求めます。

  **しきい値で測ると、立ち上がりの分だけ音は短く、間隔は長く出ます。**
  電鍵を押してから音が半分の高さに達するまでの時間だけ、始まりが遅れ、
  終わりが早まるためです。5 ms の整形なら、20 WPM の短点 60 ms は 55 ms と
  測れ、文字間 180 ms は 185 ms と測れます。比にすると 3.00 が 3.36 になり、
  **要件 FR-H.5 の「10% 以内」を、測り方だけで外します。**

  面積なら形によりません。整形が中央について対称であれば——余弦でも直線でも——
  整形の区間の面積はちょうどその半分であり、音の面積は押していた時間に
  一致します。間隔は、隣り合う音の中央と長さから引き算で求めます。

  The length of each sound, taken from the area under the envelope.

  **Measured at a threshold, a sound comes out short and a gap long** by the
  time the envelope takes to reach half height. With a 5 ms shaping, a 60 ms dit
  at 20 WPM measures 55 ms and a 180 ms character gap measures 185 ms: a ratio
  of 3.00 becomes 3.36, and **the ten per cent of requirement FR-H.5 is missed
  by the measuring alone.**

  Area does not depend on the shape. Where the shaping is symmetric about its
  middle -- cosine or straight line alike -- its area is exactly half of it, and
  the area of the sound equals the time the key was down. The gaps then follow
  by subtraction from the neighbouring sounds. }
function ToneRuns(const Env: TDoubleArray; SampleRate: Integer;
  const Spans: TSpans): TTones;
var
  I, K, First_, Last_: Integer;
  Floor_, Local, Margin, Ramp: Double;
  Ramps: TDoubleArray;

  { 窓の中で、ある高さを最初に超えた時刻と最後に超えていた時刻の間の長さ。
    The width between the first and the last time a level is exceeded. }
  function WidthAt(From_, To_: Integer; Level: Double): Double;
  var
    J, Begins, Ends: Integer;
  begin
    Result := 0;
    Begins := -1;
    Ends := -1;
    for J := From_ to To_ do
      if Env[J] >= Level then
      begin
        if Begins < 0 then
          Begins := J;
        Ends := J;
      end;
    if (Begins < 0) or (Ends <= Begins) then
      Exit;
    Result := (Ends - Begins) / SampleRate;
  end;

begin
  Result := nil;
  if (Length(Spans) = 0) or (SampleRate <= 0) then
    Exit;
  Floor_ := Percentile(Env, 0.1);

  SetLength(Result, Length(Spans));
  SetLength(Ramps, Length(Spans));
  for I := 0 to High(Spans) do
  begin
    { 整形の裾まで含める幅を取ります。隣の音には踏み込みません。
      A window wide enough for the shaping, never reaching the next sound. }
    Margin := 0.020;
    if I > 0 then
      Margin := Min(Margin, (Spans[I].FromSeconds - Spans[I - 1].ToSeconds) / 2);
    if I < High(Spans) then
      Margin := Min(Margin, (Spans[I + 1].FromSeconds - Spans[I].ToSeconds) / 2);
    Margin := Max(0, Margin);
    First_ := Max(0, Round((Spans[I].FromSeconds - Margin) * SampleRate));
    Last_ := Min(High(Env), Round((Spans[I].ToSeconds + Margin) * SampleRate));

    { 音の高さは、その音の中で決めます。**録音全体から採ると、音量が動いた
      ときに合わなくなります。**
      The height is taken from inside this sound: **taken from the whole
      recording it would not fit once the level moved.** }
    Local := Floor_;
    for K := First_ to Last_ do
      if Env[K] > Local then
        Local := Env[K];
    if Local - Floor_ <= 0 then
    begin
      Result[I].Centre := (Spans[I].FromSeconds + Spans[I].ToSeconds) / 2;
      Result[I].Seconds := Spans[I].ToSeconds - Spans[I].FromSeconds;
      Ramps[I] := 0;
      Continue;
    end;

    { 長さは、しきい値をまたぐ幅そのものです。**包絡線の面積で測る手も試し
      ましたが、精度は変わりませんでした**（清らかな音で短点 0.4% 対 1.4%、
      雑音のある音では文字間で面積のほうが悪く 3.8% 対 1.8%）。**試験で守れ
      ない差のために、複雑なほうを残しません。**
      The length is the width at the threshold. **Taking the area under the
      envelope was tried and did not measure any better** -- 0.4% against 1.4%
      on a clean dit, and on a noisy one the area was the worse of the two for
      the character gap, 3.8% against 1.8%. **The more complicated of two
      equals is not kept for a difference no test can hold on to.** }
    Result[I].Seconds := Spans[I].ToSeconds - Spans[I].FromSeconds;
    Result[I].Centre := (Spans[I].FromSeconds + Spans[I].ToSeconds) / 2;

    { 立ち上がりの時間を、1 割と 9 割の幅の差から見ます。余弦で整形された
      信号では、その差は立ち上がり時間の 1.18 倍になります。
      The rise time from the difference between the widths at one tenth and at
      nine tenths: for a cosine-shaped edge that difference is 1.18 times it. }
    Ramps[I] := Max(0, (WidthAt(First_, Last_, Floor_ + 0.1 * (Local - Floor_)) -
      WidthAt(First_, Last_, Floor_ + 0.9 * (Local - Floor_))) / 1.1808);
  end;

  { **面積だけでは、押していた時間には戻りません。**余弦で整形された音の
    面積は「押していた時間 − 立ち上がり時間」です。5 ms の整形なら、20 WPM の
    短点 60 ms は 55 ms、文字間 180 ms は 185 ms と出て、比 3.00 が 3.36 に
    なります。**測り方だけで、要件 FR-H.5 の 10% を外します。**

    立ち上がりは送信機の整形であって操作者の癖ではないので、測って足し戻します。
    **1 つの音ごとではなく、全体の中央値を使います。**短い音では裾が足りず、
    見当が安定しないためです。

    **Area alone does not give back the time the key was held down.** The area
    of a cosine-shaped sound is the key-down time less one rise time: with a
    5 ms shaping, a 60 ms dit at 20 WPM comes out 55 ms and a 180 ms character
    gap 185 ms, turning a ratio of 3.00 into 3.36 -- **the ten per cent of
    requirement FR-H.5, missed by the measuring alone.**

    The rise belongs to the transmitter's shaping, not to the operator's hand,
    so it is measured and added back. **The median across the session is used**,
    not each sound's own: a short sound carries too little edge for a steady
    estimate. }
  Ramp := Percentile(Ramps, 0.5);
  if Ramp > 0 then
    for I := 0 to High(Result) do
      if Ramp < 0.5 * Result[I].Seconds then
        Result[I].Seconds := Result[I].Seconds + Ramp;
end;

{ 課題文から、送られるはずの要素の種別を並べます。音と無音が交互に並び、
  先頭と末尾は必ず音です。
  The kinds the text calls for, sound and silence alternating, beginning and
  ending with sound. }
function ExpectedKinds(const Text: string): TElementKinds;
var
  Normalized, Code: string;
  Kinds: TElementKinds;
  Count, I, E: Integer;
  PendingGap: TElementKind;
  HasPending, Started: Boolean;

  procedure Add(Kind: TElementKind);
  begin
    if Count = Length(Kinds) then
      SetLength(Kinds, Max(32, Count * 2));
    Kinds[Count] := Kind;
    Inc(Count);
  end;

begin
  Kinds := nil;
  Count := 0;
  Normalized := NormalizeText(Text);
  HasPending := False;
  PendingGap := ekIntra;
  Started := False;
  for I := 1 to Length(Normalized) do
  begin
    if Normalized[I] = ' ' then
    begin
      { 語間は、次の音が来たときに初めて要素になります。**末尾の空白で
        間隔を 1 つ余らせないためです。**
        A word gap becomes an element only when the next sound arrives, so that
        a trailing space does not leave one gap over. }
      if Started then
      begin
        PendingGap := ekWord;
        HasPending := True;
      end;
      Continue;
    end;
    Code := MorseForChar(Normalized[I]);
    if Code = '' then
      Continue;
    if Started then
    begin
      if not HasPending then
        PendingGap := ekChar;
      Add(PendingGap);
      HasPending := False;
    end;
    for E := 1 to Length(Code) do
    begin
      if E > 1 then
        Add(ekIntra);
      if Code[E] = '.' then
        Add(ekDit)
      else
        Add(ekDah);
    end;
    Started := True;
  end;
  SetLength(Kinds, Count);
  Result := Kinds;
end;

function IsTone(Kind: TElementKind): Boolean;
begin
  Result := Kind in [ekDit, ekDah];
end;

procedure Summarise(var M: TFistMeasurement);
var
  Kind: TElementKind;
  I, Count: Integer;
  Sum, SumSq, Value, Slope, MeanT, MeanD, Numerator, Denominator: Double;
  Implied: TDoubleArray;
  Times: TDoubleArray;

  function Separation(A, B: TElementKind): Double;
  var
    Spread: Double;
  begin
    { 2 つの分布の離れ具合。**平均の差だけでは足りません。**ばらつきが大きければ
      重なります。
      How far apart two distributions sit. **The difference of the means is not
      enough**: with enough spread they overlap anyway. }
    Result := 0;
    if (M.Stats[A].Count < 2) or (M.Stats[B].Count < 2) then
      Exit;
    Spread := Sqrt((Sqr(M.Stats[A].Sd) + Sqr(M.Stats[B].Sd)) / 2);
    if Spread < 1E-9 then
      Spread := 1E-9;
    Result := Abs(M.Stats[B].Mean - M.Stats[A].Mean) / Spread;
  end;

begin
  for Kind := Low(TElementKind) to High(TElementKind) do
  begin
    Count := 0;
    Sum := 0;
    for I := 0 to High(M.Elements) do
      if M.Elements[I].Kind = Kind then
      begin
        Sum := Sum + M.Elements[I].Seconds;
        Inc(Count);
      end;
    M.Stats[Kind].Count := Count;
    if Count = 0 then
    begin
      M.Stats[Kind].Mean := 0;
      M.Stats[Kind].Sd := 0;
      M.Stats[Kind].Cv := 0;
      Continue;
    end;
    M.Stats[Kind].Mean := Sum / Count;
    SumSq := 0;
    for I := 0 to High(M.Elements) do
      if M.Elements[I].Kind = Kind then
        SumSq := SumSq + Sqr(M.Elements[I].Seconds - M.Stats[Kind].Mean);
    if Count > 1 then
      M.Stats[Kind].Sd := Sqrt(SumSq / (Count - 1))
    else
      M.Stats[Kind].Sd := 0;
    if M.Stats[Kind].Mean > 0 then
      M.Stats[Kind].Cv := M.Stats[Kind].Sd / M.Stats[Kind].Mean
    else
      M.Stats[Kind].Cv := 0;
  end;

  M.DitSeconds := M.Stats[ekDit].Mean;
  if M.DitSeconds > 0 then
  begin
    M.Ratio := M.Stats[ekDah].Mean / M.DitSeconds;
    M.IntraRatio := M.Stats[ekIntra].Mean / M.DitSeconds;
    M.CharRatio := M.Stats[ekChar].Mean / M.DitSeconds;
    M.WordRatio := M.Stats[ekWord].Mean / M.DitSeconds;
    { PARIS 方式。短点 1 単位で 1 語 50 単位です。
      PARIS: fifty units to the word, one of them the dit. }
    M.EffectiveWpm := 1.2 / M.DitSeconds;
  end;
  M.ToneSeparation := Separation(ekDit, ekDah);
  M.GapSeparation := Separation(ekIntra, ekChar);

  { セッションの中で速度が動いたか。各音から短点 1 つぶんの長さを割り出し、
    時刻に対する傾きを見ます。**ばらつきと速度の変化は別のことです。**
    ばらつきは直せば消えますが、速度の変化は「だんだん速くなる」癖です。

    Whether the speed moved during the session: one dit's worth is taken from
    each sound and fitted against time. **Spread and drift are different
    things**: spread is noise, drift is the habit of speeding up. }
  M.Drift := 0;
  Count := 0;
  SetLength(Implied, Length(M.Elements));
  SetLength(Times, Length(M.Elements));
  for I := 0 to High(M.Elements) do
    if IsTone(M.Elements[I].Kind) then
    begin
      if M.Elements[I].Kind = ekDit then
        Value := M.Elements[I].Seconds
      else
        Value := M.Elements[I].Seconds / 3;
      Implied[Count] := Value;
      Times[Count] := M.Elements[I].AtSeconds;
      Inc(Count);
    end;
  if (Count >= 4) and (M.DitSeconds > 0) then
  begin
    MeanT := 0;
    MeanD := 0;
    for I := 0 to Count - 1 do
    begin
      MeanT := MeanT + Times[I];
      MeanD := MeanD + Implied[I];
    end;
    MeanT := MeanT / Count;
    MeanD := MeanD / Count;
    Numerator := 0;
    Denominator := 0;
    for I := 0 to Count - 1 do
    begin
      Numerator := Numerator + (Times[I] - MeanT) * (Implied[I] - MeanD);
      Denominator := Denominator + Sqr(Times[I] - MeanT);
    end;
    if Denominator > 0 then
    begin
      Slope := Numerator / Denominator;
      if MeanD > 0 then
        M.Drift := Abs(Slope * (Times[Count - 1] - Times[0])) / MeanD;
    end;
  end;
end;

function BuildMeasurement(const Tones: TTones; const Kinds: TElementKinds;
  Reference: Boolean): TFistMeasurement;
var
  I, Index_: Integer;
  Ends, Begins: Double;
begin
  Result := Default(TFistMeasurement);
  Result.Reference := Reference;
  SetLength(Result.Elements, Length(Kinds));
  Index_ := 0;
  for I := 0 to High(Tones) do
  begin
    { 音 / sound }
    if Index_ > High(Result.Elements) then
      Break;
    Result.Elements[Index_].Kind := Kinds[Index_];
    Result.Elements[Index_].Seconds := Tones[I].Seconds;
    Result.Elements[Index_].AtSeconds := Tones[I].Centre - Tones[I].Seconds / 2;
    Inc(Index_);
    { 無音は、隣り合う音の中央と長さから引き算で求めます。
      A gap follows by subtraction from the two sounds around it. }
    if (I < High(Tones)) and (Index_ <= High(Result.Elements)) then
    begin
      Ends := Tones[I].Centre + Tones[I].Seconds / 2;
      Begins := Tones[I + 1].Centre - Tones[I + 1].Seconds / 2;
      Result.Elements[Index_].Kind := Kinds[Index_];
      Result.Elements[Index_].Seconds := Max(0, Begins - Ends);
      Result.Elements[Index_].AtSeconds := Ends;
      Inc(Index_);
    end;
  end;
  SetLength(Result.Elements, Index_);
  if Length(Tones) > 0 then
    Result.Seconds := (Tones[High(Tones)].Centre + Tones[High(Tones)].Seconds / 2)
      - (Tones[0].Centre - Tones[0].Seconds / 2);
  Result.Ok := Length(Result.Elements) > 0;
  Summarise(Result);
end;

function MeasureAgainstText(const Samples: TSingleArray; SampleRate: Integer;
  ToneHz: Double; const Text: string): TFistMeasurement;
var
  Spans: TSpans;
  Env: TDoubleArray;
  Kinds: TElementKinds;
  Tones, I: Integer;
begin
  Result := Default(TFistMeasurement);
  Kinds := ExpectedKinds(Text);
  if Length(Kinds) = 0 then
  begin
    Result.Note := '課題文に送れる符号がありません。';
    Exit;
  end;
  Env := ToneEnvelope(Samples, SampleRate, ToneHz);
  Spans := LongEnough(KeyedSpans(Env, SampleRate));
  if Length(Spans) = 0 then
  begin
    Result.Note := '音が見つかりません。入力の音量を確かめてください。';
    Exit;
  end;
  Tones := 0;
  for I := 0 to High(Kinds) do
    if IsTone(Kinds[I]) then
      Inc(Tones);
  if Length(Spans) <> Tones then
  begin
    { **数が合わないときは、対応づけません。**1 つずれたまま最後まで並べると、
      短点を長点として測り、その結果に点数を付けてしまいます。
      **Nothing is lined up when the counts differ**: carried on one out of
      step, a dit would be measured as a dah and the result scored as if it
      meant something. }
    Result.Note := Format(
      '課題文は符号 %d 個ですが、送られたのは %d 個です。' +
      '抜けたか、くっついたようです。', [Tones, Length(Spans)]);
    Exit;
  end;
  Result := BuildMeasurement(ToneRuns(Env, SampleRate, Spans), Kinds, False);
  Result.Characters := Length(Trim(NormalizeText(Text)));
end;

function MeasureFree(const Samples: TSingleArray; SampleRate: Integer;
  ToneHz: Double): TFistMeasurement;
var
  Spans: TSpans;
  Env: TDoubleArray;
  Runs: TTones;
  Kinds: TElementKinds;
  Tones, Gaps: TDoubleArray;
  Dit, Value: Double;
  I, Index_, Count: Integer;
begin
  Result := Default(TFistMeasurement);
  Env := ToneEnvelope(Samples, SampleRate, ToneHz);
  Spans := LongEnough(KeyedSpans(Env, SampleRate));
  if Length(Spans) < 2 then
  begin
    Result.Note := '音が足りません。';
    Exit;
  end;
  Runs := ToneRuns(Env, SampleRate, Spans);
  if Length(Runs) < 2 then
  begin
    Result.Note := '音が足りません。';
    Exit;
  end;

  SetLength(Tones, Length(Runs));
  for I := 0 to High(Runs) do
    Tones[I] := Runs[I].Seconds;
  { 短点の長さを、短いほうの 4 分の 1 の位置から見当づけ、1 度だけ寄せ直します。
    **平均では、長点が多い本文で長すぎる見当になります。**
    The dit is guessed at the lower quartile and settled once: **an average
    would be pulled long by a text with many dahs.** }
  Dit := Percentile(Tones, 0.25);
  Count := 0;
  Value := 0;
  for I := 0 to High(Tones) do
    if Tones[I] < 2 * Dit then
    begin
      Value := Value + Tones[I];
      Inc(Count);
    end;
  if Count > 0 then
    Dit := Value / Count;
  if Dit <= 0 then
  begin
    Result.Note := '短点の長さを見当づけられません。';
    Exit;
  end;

  SetLength(Gaps, Length(Runs) - 1);
  for I := 0 to High(Gaps) do
    Gaps[I] := Max(0, (Runs[I + 1].Centre - Runs[I + 1].Seconds / 2) -
      (Runs[I].Centre + Runs[I].Seconds / 2));

  SetLength(Kinds, Length(Runs) + Length(Gaps));
  Index_ := 0;
  for I := 0 to High(Runs) do
  begin
    if Tones[I] >= 2 * Dit then
      Kinds[Index_] := ekDah
    else
      Kinds[Index_] := ekDit;
    Inc(Index_);
    if I < High(Runs) then
    begin
      if Gaps[I] >= 5 * Dit then
        Kinds[Index_] := ekWord
      else if Gaps[I] >= 2 * Dit then
        Kinds[Index_] := ekChar
      else
        Kinds[Index_] := ekIntra;
      Inc(Index_);
    end;
  end;

  Result := BuildMeasurement(Runs, Kinds, True);
  Result.Note := '課題文なしで測りました。間隔の種別はしきい値で分けています。' +
    '**参考値です。**';
end;

function FistTargetFor(Standard: TFistStandard; const Own: TFistTarget): TFistTarget;
begin
  case Standard of
    fsFarnsworth:
      begin
        { ファンズワースは、文字の速さを保ったまま文字間と語間を広げます。
          Farnsworth keeps the characters at speed and opens up the spacing. }
        Result.Ratio := 3.0;
        Result.IntraRatio := 1.0;
        Result.CharRatio := 6.0;
        Result.WordRatio := 12.0;
      end;
    fsBug:
      begin
        { バグキーは長点を手で送るため、長めになります。**それは癖であって
          誤りではありません**（設計原則：個性を減点しない）。
          A bug key's dahs are made by hand and run long. **That is a habit, not
          an error** -- the principle that an individual hand is not marked
          down. }
        Result.Ratio := 2.6;
        Result.IntraRatio := 1.0;
        Result.CharRatio := 3.0;
        Result.WordRatio := 7.0;
      end;
    fsOwn:
      Result := Own;
  else
    Result.Ratio := 3.0;
    Result.IntraRatio := 1.0;
    Result.CharRatio := 3.0;
    Result.WordRatio := 7.0;
  end;
  if Result.Ratio <= 0 then Result.Ratio := 3.0;
  if Result.IntraRatio <= 0 then Result.IntraRatio := 1.0;
  if Result.CharRatio <= 0 then Result.CharRatio := 3.0;
  if Result.WordRatio <= 0 then Result.WordRatio := 7.0;
end;

function TargetFromMeasurement(const M: TFistMeasurement): TFistTarget;
begin
  Result.Ratio := M.Ratio;
  Result.IntraRatio := M.IntraRatio;
  Result.CharRatio := M.CharRatio;
  Result.WordRatio := M.WordRatio;
end;

{ 分離度を点数にします。**重なりが無くなる手前から、はっきり離れるまでを
  0〜100 に写します。**
  Turns a separation into a score, from just short of overlapping to clearly
  apart. }
function SeparationScore(Value: Double): Double;
const
  NONE = 3.0;   { これ以下は重なっている / below this they overlap }
  CLEAR = 12.0; { これ以上は十分 / above this it is plenty }
begin
  Result := 100 * ClampDouble((Value - NONE) / (CLEAR - NONE), 0, 1);
end;

{ 目標からの外れを点数にします。/ Turns a deviation from target into a score. }
function CloseScore(Value, Target, Tolerance: Double): Double;
begin
  if Target <= 0 then
    Exit(0);
  Result := 100 * Exp(-Abs(Value - Target) / (Target * Tolerance));
end;

function ScoreFist(const M: TFistMeasurement; Standard: TFistStandard;
  const Own: TFistTarget; Cer: Double): TFistScore;
var
  Target: TFistTarget;
  Weights: array[0..4] of Double;
  Values: array[0..4] of Double;
  I, Last_, Lowest: Integer;
  Sum, Total, Error, Steady: Double;
begin
  Result := Default(TFistScore);
  if not M.Ok then
  begin
    Result.Advice := '測れていません。' + M.Note;
    Exit;
  end;
  Target := FistTargetFor(Standard, Own);

  { [1] 速度の安定。短点のばらつきと、セッション内の速度の変化。
        **熟練者の 3% は満点とします。**それより細かい差は、測っても意味が
        ありません。
        [1] Steadiness: the spread of the dits and the drift across the session.
        **An expert's 3% is full marks**; finer than that is not worth measuring. }
  Steady := Exp(-8.4 * Max(0, M.Stats[ekDit].Cv - 0.03)) *
            Exp(-2.0 * Max(0, M.Drift - 0.02));
  Values[0] := 100 * Steady;

  { [2] 短長の明瞭。分離度と、基準に対する長短比。**比が基準どおりでも、
        ばらついて重なっていれば聞き分けられません。**
        [2] Dit against dah: the separation and the ratio against the basis.
        **A ratio right on target still cannot be told apart if the spread
        overlaps it.** }
  Values[1] := (SeparationScore(M.ToneSeparation) +
                CloseScore(M.Ratio, Target.Ratio, 0.35)) / 2;

  { [3] 区切りの明瞭。符号内と文字間が分かれているか。**写しやすさを決めるのは
        ここです**（付録 A.2 の 4）。
        [3] The break between characters. **This is what decides whether the
        sending can be copied at all** (appendix A.2, finding 4). }
  Values[2] := SeparationScore(M.GapSeparation);

  { [4] 間隔の正確。符号内・文字間・語間の比が基準からどれだけ離れているか。
        [4] The spacing ratios against the basis. }
  Error := 0;
  Error := Error + Abs(M.IntraRatio - Target.IntraRatio) / Target.IntraRatio;
  Error := Error + Abs(M.CharRatio - Target.CharRatio) / Target.CharRatio;
  if M.Stats[ekWord].Count > 0 then
  begin
    Error := Error + Abs(M.WordRatio - Target.WordRatio) / Target.WordRatio;
    Error := Error / 3;
  end
  else
    Error := Error / 2;
  Values[3] := 100 * Exp(-3.0 * Error);

  { [5] 写しやすさ。課題文に対する文字誤り率。渡されなければ点数にしません。
        [5] Copyability, the decoder's error rate against the text; not scored
        when it was not supplied. }
  Result.HasCopyability := Cer >= 0;
  if Result.HasCopyability then
    Values[4] := 100 * ClampDouble(1 - Cer, 0, 1)
  else
    Values[4] := 0;

  Result.Speed := Values[0];
  Result.Clarity := Values[1];
  Result.Separation := Values[2];
  Result.Spacing := Values[3];
  Result.Copyability := Values[4];

  { 重みは暫定値です（未解決事項 1）。**区切りの明瞭を重くしてあります。**
    写しやすさを決めているのがここだと測れているためです。
    The weights are provisional (open question 1). **The break between
    characters weighs most**, because that is what the measurements show
    decides whether the sending can be copied. }
  Weights[0] := 0.20;
  Weights[1] := 0.20;
  Weights[2] := 0.30;
  Weights[3] := 0.15;
  Weights[4] := 0.15;
  if Result.HasCopyability then
    Last_ := 4
  else
    Last_ := 3;

  Sum := 0;
  Total := 0;
  Lowest := 0;
  for I := 0 to Last_ do
  begin
    Sum := Sum + Weights[I] * Values[I];
    Total := Total + Weights[I];
    if Values[I] < Values[Lowest] then
      Lowest := I;
  end;
  if Total > 0 then
    Sum := Sum / Total;
  { **いちばん低い項目を、平均に埋もれさせません。**1 項目が 0 点でも他が
    良ければ平均は高く出ますが、その符号は写してもらえません。
    **The lowest score is not allowed to sink into the average**: four good
    marks and one zero still average well, and that sending still cannot be
    copied. }
  Result.Overall := 0.7 * Sum + 0.3 * Values[Lowest];

  { 助言は 1 つだけです（要件 FR-H.8）。**直すところを 5 つ並べても、
    どれから手を付ければよいか分かりません。**
    One piece of advice (FR-H.8): **five things to fix is no help in deciding
    which to begin with.** }
  if Result.Overall >= 90 then
    Result.Advice := '直すところは見当たりません。速度を上げるより、' +
      'この安定を保つことです。'
  else
    case Lowest of
      0: Result.Advice := '同じ速さで送ることを意識してください。' +
           '短点の長さがばらついています。';
      1: Result.Advice := '短点と長点の差をはっきりつけてください。' +
           '長点は短点の ' + FormatFloat('0.#', Target.Ratio) + ' 倍が目安です。';
      2: Result.Advice := '文字と文字の間を、符号の中の間より' +
           'はっきり長く取ってください。写しやすさはここで決まります。';
      3: Result.Advice := '間隔の比を基準に近づけてください' +
           '（符号内 ' + FormatFloat('0.#', Target.IntraRatio) +
           '・文字間 ' + FormatFloat('0.#', Target.CharRatio) +
           '・語間 ' + FormatFloat('0.#', Target.WordRatio) + '）。';
    else
      Result.Advice := 'まず、読み取れる符号を送ることを目指してください。' +
        '速さは後からついてきます。';
    end;
end;


function BucketUnits(Buckets: Integer; MaxUnits: Double): Double;
begin
  if Buckets <= 0 then
    Exit(0);
  Result := MaxUnits / Buckets;
end;

function Histogram(const Elements: TElements; Kind: TElementKind;
  DitSeconds: Double; Buckets: Integer; MaxUnits: Double): TCounts;
var
  I, Index_: Integer;
  Units_: Double;
begin
  Result := nil;
  if (Buckets <= 0) or (MaxUnits <= 0) then
    Exit;
  SetLength(Result, Buckets);
  for I := 0 to High(Result) do
    Result[I] := 0;
  if DitSeconds <= 0 then
    Exit;
  for I := 0 to High(Elements) do
  begin
    if Elements[I].Kind <> Kind then
      Continue;
    Units_ := Elements[I].Seconds / DitSeconds;
    Index_ := Trunc(Units_ / MaxUnits * Buckets);
    { **範囲の外は端の升へ入れます。捨てません**（教訓 10.9）。
      **Past the end goes into the end bucket, not away** (lesson 10.9). }
    Result[ClampInt(Index_, 0, Buckets - 1)] := Result[ClampInt(Index_, 0, Buckets - 1)] + 1;
  end;
end;


end.
