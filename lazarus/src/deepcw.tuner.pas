unit DeepCW.Tuner;

{ 聞きたい信号を、モデルが読める音程へ寄せるための周波数変換です。

  受信機から出てくる音の高さは運用者が決めるもので、モデルの通過帯域
  400〜1200 Hz に合っている保証はありません。そこで、ウォーターフォール上で
  選ばれた音程を、モデルが最もよく読む音程まで平行移動させます。運用者に
  見えるのは「クリックした信号が読める」ことだけです（要件 FR-D.1）。

  実数の信号にそのまま正弦波を掛けると、和と差の 2 つの成分が生まれ、負の
  周波数側が折り返して目的の音程に重なります。これを避けるため、ヒルベルト
  変換で解析信号を作ってから回転させます。

  Frequency translation that brings the wanted signal to a pitch the model
  reads.

  The pitch coming out of a receiver is the operator's choice and need not sit
  in the model's 400-1200 Hz passband, so the pitch picked on the waterfall is
  translated to the pitch the model reads best. All the operator sees is that
  the signal they clicked becomes readable (requirement FR-D.1).

  Multiplying a real signal by a sinusoid produces both a sum and a difference
  component, and the negative-frequency half folds back onto the wanted pitch.
  To avoid that, a Hilbert transform builds the analytic signal first and the
  rotation is applied to that. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Math, DeepCW.Types, DeepCW.Dsp, DeepCW.Wave;

const
  { 変換の行き先。モデルの通過帯域 400〜1200 Hz の中央です。
    Where signals are translated to: the centre of the 400-1200 Hz passband. }
  TUNER_TARGET_TONE_HZ = 800.0;

  { 同調の刻み。モデルのスペクトログラム 1 ビン分に等しくします
    （3200 Hz / 256 点 = 12.5 Hz）。これより細かく合わせても、モデルから
    見た絵は変わりません（要件 FR-D.2）。

    Tuning step, one bin of the model's spectrogram (3200 / 256 = 12.5 Hz).
    Anything finer leaves the picture the model sees unchanged
    (requirement FR-D.2). }
  TUNER_STEP_HZ = 12.5;

  { 同調できる下限。これより低いとヒルベルト変換の精度が落ち、受信機側の
    ハム音とも重なります。上限は録音のナイキスト周波数から決めます。

    Lowest pitch that can be tuned; below this the Hilbert transform loses
    accuracy and receiver hum starts to overlap. The upper limit comes from
    the capture Nyquist frequency. }
  TUNER_MIN_TONE_HZ = 150.0;
  { ナイキスト周波数からこれだけ下げたところを上限とします。
    The upper limit sits this far below Nyquist. }
  TUNER_TOP_MARGIN_HZ = 200.0;

  { 折り返し防止の遮断周波数。モデルの通過帯域 1200 Hz の少し上に置きます。
    サウンドカードの録音周波数はモデルより高いため、そのまま間引くと 1600 Hz
    より上の成分がモデルの帯域へ折り返してきます。

    Anti-alias cutoff, a little above the model's 1200 Hz passband. Sound
    cards record above the model's rate, so decimating without this folds
    everything above 1600 Hz down into the band the model reads. }
  TUNER_ANTI_ALIAS_CUTOFF_HZ = 1400.0;

  { ヒルベルト変換のタップ数。奇数で、群遅延は中央に来ます。
    Hilbert transformer length; odd, with the group delay at the centre. }
  TUNER_HILBERT_TAPS = 127;
  { 帯域通過フィルタのタップ数。モデルの周波数で掛けます。
    Band-pass length, applied at the model's sample rate. }
  TUNER_BANDPASS_TAPS = 127;

type
  { 帯域幅の選択。既定は自動で、運用者は何も選ばずに使えます（要件 FR-D.3）。
    Bandwidth choice; the default is automatic so nothing need be chosen
    (requirement FR-D.3). }
  TTunerBandwidth = (tbAuto, tbNarrow, tbNormal, tbWide);

{ 12.5 Hz の格子に丸めます。/ Snaps to the 12.5 Hz grid. }
function QuantizeTone(Hz: Double): Double;

{ 録音周波数のもとで同調できる音程の範囲です。
  The range of pitches that can be tuned at the given capture rate. }
function LowestTunable(SampleRate: Integer): Double;
function HighestTunable(SampleRate: Integer): Double;
function IsTunable(Hz: Double; SampleRate: Integer): Boolean;

{ 信号全体を ShiftHz だけ低い方へ動かします。負の値なら高い方へ動きます。
  群遅延は補正済みで、入力と出力の時刻は一致します。

  Moves the whole signal down by ShiftHz; a negative value moves it up. The
  group delay is compensated, so input and output times line up. }
function FrequencyShift(const Samples: TSingleArray; SampleRate: Integer;
  ShiftHz: Double; Taps: Integer = TUNER_HILBERT_TAPS): TSingleArray;

{ 直線位相の窓関数付き帯域通過フィルタです。通過帯域の中央で利得 1 に
  正規化します。

  Zero-phase windowed-sinc band-pass, normalised to unity gain at the centre
  of the passband. }
function BandPassFilter(const Samples: TSingleArray; SampleRate: Integer;
  LowHz, HighHz: Double; Taps: Integer = TUNER_BANDPASS_TAPS): TSingleArray;

{ 選んだ帯域幅の片側の広さ（Hz）です。0 なら帯域制限を掛けません。
  Half-width in Hz for the chosen bandwidth; 0 means no extra filtering. }
function BandwidthHalfWidth(Bandwidth: TTunerBandwidth): Double;

{ 設定画面に出す表示名です。/ Display name for the settings panel. }
function BandwidthCaption(Bandwidth: TTunerBandwidth): string;

{ 録音された音声を、モデルへ渡せる形に整えます。

  同調 → 折り返し防止 → 標本化周波数の変換 → 帯域制限、の順に行います。
  同調していない（TuneHz が 0）ときは、周波数変換も帯域制限も掛けません。
  ファイルからの復号と流し込み受信の両方がこの 1 か所を通ります。経路が
  分かれていると、片方だけを直したときに食い違うためです。

  Prepares captured audio for the model: translate, anti-alias, convert the
  sample rate, then band limit. With TuneHz at 0 neither the translation nor
  the band-pass runs. Both file decoding and streaming reception go through
  this single place, because separate paths drift apart as soon as only one
  of them is changed. }
function PrepareForModel(const Samples: TSingleArray; SourceRate, ModelRate: Integer;
  TuneHz: Double; Bandwidth: TTunerBandwidth; AntiAlias: Boolean): TSingleArray;

implementation

function QuantizeTone(Hz: Double): Double;
begin
  Result := Round(Hz / TUNER_STEP_HZ) * TUNER_STEP_HZ;
end;

function LowestTunable(SampleRate: Integer): Double;
begin
  Result := TUNER_MIN_TONE_HZ;
end;

function HighestTunable(SampleRate: Integer): Double;
begin
  Result := Max(TUNER_MIN_TONE_HZ, SampleRate / 2 - TUNER_TOP_MARGIN_HZ);
end;

function IsTunable(Hz: Double; SampleRate: Integer): Boolean;
begin
  Result := (Hz >= LowestTunable(SampleRate)) and (Hz <= HighestTunable(SampleRate));
end;

function FrequencyShift(const Samples: TSingleArray; SampleRate: Integer;
  ShiftHz: Double; Taps: Integer): TSingleArray;
var
  Kernel: TDoubleArray;
  Half, I, J, Source, M, First: Integer;
  Window, Quadrature, Angle, Increment, CosPart, SinPart: Double;
begin
  if (Length(Samples) = 0) or (SampleRate <= 0) then
    Exit(Samples);
  { 動かす量が 1 ビンに満たないなら、掛ける意味がありません。
    A shift below one bin is not worth the filtering. }
  if Abs(ShiftHz) < TUNER_STEP_HZ / 2 then
    Exit(Samples);
  if not Odd(Taps) then
    Inc(Taps);
  Half := Taps div 2;
  if Length(Samples) <= Taps then
    Exit(Samples);

  { ヒルベルト変換器の係数です。中心から奇数番目だけが値を持ちます。
    Hilbert transformer coefficients; only odd offsets from the centre are
    non-zero. }
  SetLength(Kernel, Taps);
  for I := 0 to Taps - 1 do
  begin
    M := I - Half;
    if (M = 0) or (not Odd(M)) then
      Kernel[I] := 0
    else
    begin
      { ハミング窓で通過域のうねりを抑えます。
        A Hamming window keeps the passband ripple down. }
      Window := 0.54 - 0.46 * Cos(2 * Pi * I / (Taps - 1));
      Kernel[I] := (2 / (Pi * M)) * Window;
    end;
  end;

  { 係数の半分は 0 なので、値のあるところだけを足します。畳み込みの手間が
    半分になります。
    Half the coefficients are zero, so only the non-zero ones are summed,
    which halves the work. }
  First := 0;
  while not Odd(First - Half) do
    Inc(First);

  SetLength(Result, Length(Samples));
  Increment := 2 * Pi * ShiftHz / SampleRate;
  for I := 0 to High(Samples) do
  begin
    Quadrature := 0;
    J := First;
    while J < Taps do
    begin
      { 畳み込みは y[k] = Σ h[m] x[k-m] です。両端は値を保持します。
        The convolution is y[k] = sum h[m] x[k-m]; the edges clamp. }
      Source := ClampInt(I - (J - Half), 0, High(Samples));
      Quadrature := Quadrature + Kernel[J] * Samples[Source];
      Inc(J, 2);
    end;
    { 解析信号 x + jH(x) を exp(-j2piFt) で回し、実部を取ります。
      Rotate the analytic signal x + jH(x) by exp(-j2*pi*F*t) and take the
      real part. }
    Angle := Increment * I;
    CosPart := Cos(Angle);
    SinPart := Sin(Angle);
    Result[I] := Samples[I] * CosPart + Quadrature * SinPart;
  end;
end;

function BandPassFilter(const Samples: TSingleArray; SampleRate: Integer;
  LowHz, HighHz: Double; Taps: Integer): TSingleArray;
var
  Kernel: TDoubleArray;
  Half, I, J, Source: Integer;
  EdgeLow, EdgeHigh, Centre, Gain, Accumulator, Window, Argument: Double;
begin
  if (Length(Samples) = 0) or (SampleRate <= 0) then
    Exit(Samples);
  EdgeLow := Max(0, LowHz) / SampleRate;
  EdgeHigh := Min(HighHz, SampleRate / 2) / SampleRate;
  { 通過帯域が録音全体を覆っているなら取り除くものはありません。
    Nothing to remove once the passband covers everything. }
  if (EdgeHigh <= EdgeLow) or ((EdgeLow <= 0) and (EdgeHigh >= 0.5)) then
    Exit(Samples);
  if not Odd(Taps) then
    Inc(Taps);
  Half := Taps div 2;
  if Length(Samples) <= Taps then
    Exit(Samples);

  Centre := (EdgeLow + EdgeHigh) / 2;
  SetLength(Kernel, Taps);
  for I := 0 to Taps - 1 do
  begin
    if I = Half then
      Kernel[I] := 2 * (EdgeHigh - EdgeLow)
    else
    begin
      Argument := Pi * (I - Half);
      Kernel[I] := (Sin(2 * EdgeHigh * Argument) - Sin(2 * EdgeLow * Argument)) / Argument;
    end;
    Window := 0.54 - 0.46 * Cos(2 * Pi * I / (Taps - 1));
    Kernel[I] := Kernel[I] * Window;
  end;

  { 低域通過と違い係数の総和は 0 に近いため、通過帯域の中央での利得で
    正規化します。
    Unlike a low-pass the coefficients nearly sum to zero, so normalise by
    the gain at the centre of the passband instead. }
  Gain := 0;
  for I := 0 to Taps - 1 do
    Gain := Gain + Kernel[I] * Cos(2 * Pi * Centre * (I - Half));
  if Abs(Gain) < 1E-12 then
    Exit(Samples);
  for I := 0 to Taps - 1 do
    Kernel[I] := Kernel[I] / Gain;

  SetLength(Result, Length(Samples));
  for I := 0 to High(Samples) do
  begin
    Accumulator := 0;
    for J := 0 to Taps - 1 do
    begin
      Source := ClampInt(I + J - Half, 0, High(Samples));
      Accumulator := Accumulator + Kernel[J] * Samples[Source];
    end;
    Result[I] := Accumulator;
  end;
end;

function BandwidthHalfWidth(Bandwidth: TTunerBandwidth): Double;
begin
  case Bandwidth of
    tbNarrow: Result := 125;
    tbNormal: Result := 250;
    tbWide: Result := 400;
  else
    { 自動。実測では、雑音だけなら帯域を絞っても絞らなくても差はありませんが、
      同調先の 300 Hz 隣に別の信号がいる場合、絞らないと文字誤り率 0.61 に
      対し ±250 Hz で 0.01 でした（22 WPM）。40 WPM でも 0.60 対 0.20 で、
      速い符号の側波帯を削る不利は現れません。よって自動は ±250 Hz とします
      （要件 FR-D.3、付録 E）。

      Automatic. Measurement found no difference with noise alone, but with
      another signal 300 Hz from the tuned one the error rate was 0.61
      unfiltered against 0.01 at +/-250 Hz (22 WPM). At 40 WPM it was 0.60
      against 0.20, so clipping the sidebands of fast code costs nothing
      measurable. Automatic therefore means +/-250 Hz
      (requirement FR-D.3, appendix E). }
    Result := 250;
  end;
end;

function PrepareForModel(const Samples: TSingleArray; SourceRate, ModelRate: Integer;
  TuneHz: Double; Bandwidth: TTunerBandwidth; AntiAlias: Boolean): TSingleArray;
var
  Half: Double;
begin
  Result := Samples;
  if (Length(Result) = 0) or (SourceRate <= 0) or (ModelRate <= 0) then
    Exit;

  { 同調しているなら、まず録音された周波数のまま音程を動かします。標本化を
    落としてからでは、モデルのナイキスト周波数より上にいた信号は既に
    失われています。

    When tuned, move the pitch first, while still at the capture rate. After
    the rate conversion, anything that was above the model's Nyquist frequency
    has already been lost. }
  if TuneHz > 0 then
    Result := FrequencyShift(Result, SourceRate, TuneHz - TUNER_TARGET_TONE_HZ);

  if AntiAlias and (SourceRate > 2 * Round(TUNER_ANTI_ALIAS_CUTOFF_HZ)) then
    Result := LowPassFilter(Result, SourceRate, TUNER_ANTI_ALIAS_CUTOFF_HZ);
  Result := ResampleLinear(Result, SourceRate, ModelRate);

  { 同調している音程の周りだけを残します。運用者がどの信号を読みたいのかを
    告げてくれた場合にだけ掛けられる絞り込みです（要件 FR-D.3）。

    Keep only what surrounds the tuned pitch. This narrowing is only possible
    once the operator has said which signal they want (requirement FR-D.3). }
  if TuneHz > 0 then
  begin
    Half := BandwidthHalfWidth(Bandwidth);
    if Half > 0 then
      Result := BandPassFilter(Result, ModelRate,
        TUNER_TARGET_TONE_HZ - Half, TUNER_TARGET_TONE_HZ + Half);
  end;
end;

function BandwidthCaption(Bandwidth: TTunerBandwidth): string;
begin
  case Bandwidth of
    tbNarrow: Result := '狭い（±125 Hz）';
    tbNormal: Result := '標準（±250 Hz）';
    tbWide: Result := '広い（±400 Hz）';
  else
    Result := '自動（推奨）';
  end;
end;

end.
