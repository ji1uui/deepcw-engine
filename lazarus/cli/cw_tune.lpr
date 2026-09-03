program cw_tune;

{ 同調（周波数変換）の検証用ツールです。

  受信機の音程がモデルの通過帯域から外れていても読めることを、合成した符号で
  確かめます。ウォーターフォールも音声装置も使わずに FR-D.1〜D.3 を測れます。

  試験は 4 つあります。
    sweep     音程ごとの復号精度。変換の行き先を決める根拠になります。
    shift     さまざまな音程を変換して読めるかどうか。
    image     解析信号を使う理由。単純な乗算との比較です。
    bandwidth 追加の帯域制限が効くかどうか。

  A harness for tuning by frequency translation. It checks with synthesised
  code that a signal is readable even when the receiver's pitch sits outside
  the model's passband, so FR-D.1 to D.3 can be measured without a waterfall
  or a sound card.

  There are four tests:
    sweep     accuracy against pitch, which is what fixes the target pitch
    shift     whether various pitches become readable after translation
    image     why the analytic signal is needed, against a plain multiply
    bandwidth whether extra band limiting helps }

{$mode objfpc}{$H+}

uses
  SysUtils, DateUtils, Math, DeepCW.Types, DeepCW.Onnx, DeepCW.Wave,
  DeepCW.Decoder, DeepCW.Dsp, DeepCW.Morse, DeepCW.Tuner, DeepCW.Stream;

const
  { 試験に使う本文。実際の交信に出てくる形をなぞっています。
    Test messages, shaped like real on-air exchanges. }
  MESSAGES: array[0..2] of string = (
    'CQ CQ DE JH2XYZ JH2XYZ K',
    'JA1ABC DE JH2XYZ UR 599 599 QTH NAGOYA',
    'TNX FER QSO 73 ES GL DE JH2XYZ SK'
  );

var
  ModelPath: string = '';
  MetadataPath: string = '';
  RuntimePath: string = '';
  Tests: string = 'sweep,shift,image,bandwidth,stream,wide';
  { 合成に加える白色雑音の大きさ。差が出る水準を選びます。
    White noise level for the synthesis, picked so differences show. }
  Noise: Double = 0.30;
  { 送信速度。速いほど鍵操作の側波帯が広がり、狭い帯域幅の影響を受けます。
    Sending speed; the faster it is, the wider the keying sidebands and the
    more a narrow bandwidth matters. }
  Wpm: Double = 22;
  Decoder: TDeepCWDecoder;

{ 文字誤り率です。編集距離を参照文の長さで割ります。
  Character error rate: edit distance over the length of the reference. }
function CharErrorRate(const Reference, Actual: string): Double;
var
  Previous, Current: array of Integer;
  I, J, Cost: Integer;
begin
  if Length(Reference) = 0 then
    Exit(Ord(Length(Actual) > 0));
  SetLength(Previous, Length(Actual) + 1);
  SetLength(Current, Length(Actual) + 1);
  for J := 0 to Length(Actual) do
    Previous[J] := J;
  for I := 1 to Length(Reference) do
  begin
    Current[0] := I;
    for J := 1 to Length(Actual) do
    begin
      if Reference[I] = Actual[J] then
        Cost := 0
      else
        Cost := 1;
      Current[J] := Min(Min(Current[J - 1] + 1, Previous[J] + 1), Previous[J - 1] + Cost);
    end;
    for J := 0 to Length(Actual) do
      Previous[J] := Current[J];
  end;
  Result := Previous[Length(Actual)] / Length(Reference);
end;

{ 決まった種から符号を合成します。試験のたびに同じ雑音になります。
  Synthesises code from a fixed seed, so every run sees the same noise. }
function Synthesise(const Text: string; SampleRate: Integer;
  ToneHz, NoiseAmplitude: Double; Seed: Integer): TSingleArray;
var
  Timing: TCWTiming;
  Options: TCWToneOptions;
begin
  RandSeed := Seed;
  Timing := DefaultTiming;
  Timing.CharWpm := Wpm;
  Timing.TextWpm := Wpm;
  Options := DefaultToneOptions;
  Options.SampleRate := SampleRate;
  Options.ToneHz := ToneHz;
  Options.Amplitude := 0.5;
  Options.NoiseAmplitude := NoiseAmplitude;
  Options.LeadInSeconds := 0.4;
  Options.LeadOutSeconds := 0.4;
  Result := TextToPCM(Text, Timing, Options);
end;

{ 単純な実数乗算による周波数変換です。解析信号を使わない場合との比較用で、
  ライブラリには置きません。

  Frequency translation by a plain real multiply, kept here only as the
  comparison for the analytic-signal method; it is not in the library. }
function NaiveShift(const Samples: TSingleArray; SampleRate: Integer;
  ShiftHz: Double): TSingleArray;
var
  I: Integer;
begin
  SetLength(Result, Length(Samples));
  for I := 0 to High(Samples) do
    Result[I] := 2 * Samples[I] * Cos(2 * Pi * ShiftHz * I / SampleRate);
end;

{ 変換したあとの、モデルへ渡すまでの経路です。受信経路と同じ順序で行います。
  The path from a translated signal to the model, in the same order as the
  receive path uses. }
function ToModelRate(const Samples: TSingleArray; SampleRate: Integer;
  HalfWidthHz: Double): TSingleArray;
begin
  Result := Samples;
  if SampleRate > 2 * Round(TUNER_ANTI_ALIAS_CUTOFF_HZ) then
    Result := LowPassFilter(Result, SampleRate, TUNER_ANTI_ALIAS_CUTOFF_HZ);
  Result := ResampleLinear(Result, SampleRate, Decoder.Metadata.SampleRate);
  if HalfWidthHz > 0 then
    Result := BandPassFilter(Result, Decoder.Metadata.SampleRate,
      TUNER_TARGET_TONE_HZ - HalfWidthHz, TUNER_TARGET_TONE_HZ + HalfWidthHz);
end;

{ 3 本の本文の平均文字誤り率です。/ Mean error rate over the three messages. }
function MeasureAt(SampleRate: Integer; ToneHz, ShiftHz, NoiseAmplitude,
  HalfWidthHz: Double; UseNaive: Boolean): Double;
var
  I: Integer;
  Audio: TSingleArray;
  Reference, Decoded: string;
  Total: Double;
begin
  Total := 0;
  for I := 0 to High(MESSAGES) do
  begin
    Reference := NormalizeText(MESSAGES[I]);
    Audio := Synthesise(Reference, SampleRate, ToneHz, NoiseAmplitude, 1000 + I);
    if Abs(ShiftHz) >= TUNER_STEP_HZ / 2 then
    begin
      if UseNaive then
        Audio := NaiveShift(Audio, SampleRate, ShiftHz)
      else
        Audio := FrequencyShift(Audio, SampleRate, ShiftHz);
    end;
    Audio := ToModelRate(Audio, SampleRate, HalfWidthHz);
    Decoded := Decoder.DecodeLongSamples(Audio, Decoder.Metadata.SampleRate);
    Total := Total + CharErrorRate(Reference, Decoded);
  end;
  Result := Total / Length(MESSAGES);
end;

{ 妨害となる別の信号を重ねます。/ Adds an interfering signal on top. }
function WithInterference(const Wanted: TSingleArray; SampleRate: Integer;
  InterferenceHz, Level: Double): TSingleArray;
var
  Noise: TSingleArray;
  I: Integer;
begin
  Noise := Synthesise('TEST DE INTERFERENCE TEST DE INTERFERENCE',
    SampleRate, InterferenceHz, 0, 4242);
  SetLength(Result, Length(Wanted));
  for I := 0 to High(Wanted) do
    if I <= High(Noise) then
      Result[I] := Wanted[I] + Level * Noise[I]
    else
      Result[I] := Wanted[I];
end;

procedure RunSweep;
var
  ToneHz, Error, Best, BestTone: Double;
begin
  WriteLn;
  WriteLn('sweep: 音程ごとの復号精度 / accuracy against pitch');
  WriteLn(Format('  変換の行き先を決めます。雑音 %.2f、%.0f WPM。', [Noise, Wpm]));
  WriteLn('  tone(Hz)   CER');
  Best := 1E9;
  BestTone := TUNER_TARGET_TONE_HZ;
  ToneHz := 425;
  while ToneHz <= 1175.01 do
  begin
    Error := MeasureAt(Decoder.Metadata.SampleRate, ToneHz, 0, Noise, 0, False);
    WriteLn(Format('  %8.1f   %5.3f', [ToneHz, Error]));
    if Error < Best then
    begin
      Best := Error;
      BestTone := ToneHz;
    end;
    ToneHz := ToneHz + 75;
  end;
  WriteLn(Format('  best %.1f Hz (CER %.3f); target in use %.1f Hz',
    [BestTone, Best, TUNER_TARGET_TONE_HZ]));
end;

procedure RunShift;
const
  TONES: array[0..7] of Double = (200, 400, 700, 1000, 1500, 2200, 3000, 3600);
var
  I, Rate: Integer;
  Plain, Tuned: Double;
begin
  Rate := 8000;
  WriteLn;
  WriteLn('shift: 音程を変換して読めるか / readability after translation');
  WriteLn(Format('  録音 %d Hz、雑音 %.2f、行き先 %.1f Hz。',
    [Rate, Noise, TUNER_TARGET_TONE_HZ]));
  WriteLn('  tone(Hz)  同調なし  同調あり  可否');
  for I := 0 to High(TONES) do
  begin
    Plain := MeasureAt(Rate, TONES[I], 0, Noise, 0, False);
    Tuned := MeasureAt(Rate, TONES[I], TONES[I] - TUNER_TARGET_TONE_HZ, Noise, 0, False);
    WriteLn(Format('  %8.1f     %5.3f     %5.3f  %s',
      [TONES[I], Plain, Tuned,
       BoolToStr(IsTunable(TONES[I], Rate), '対象内', '対象外')]));
  end;
end;

procedure RunImage;
const
  { 目的の信号を 400 Hz に置き、800 Hz へ持ち上げます。単純な乗算では
    和と差の両方が生まれるため、1200 Hz にいる妨害の差成分がちょうど
    800 Hz、すなわち目的の信号の上に落ちてきます。解析信号を使えば差の側
    しか生まれず、妨害は 1600 Hz へ動いて折り返し防止フィルタが取り除きます。

    The wanted signal sits at 400 Hz and is lifted to 800 Hz. A plain multiply
    produces both a sum and a difference, so the difference term of an
    interferer at 1200 Hz lands exactly on 800 Hz, on top of the wanted
    signal. With the analytic signal only one term exists, the interferer
    moves to 1600 Hz, and the anti-alias filter removes it. }
  WantedHz = 400.0;
  InterferenceHz = 1200.0;
  LEVELS: array[0..3] of Double = (0.2, 0.4, 0.6, 0.8);
var
  Rate, I, L: Integer;
  Reference, Decoded: string;
  Audio, Hilbert, Naive: TSingleArray;
  HilbertError, NaiveError, ShiftHz: Double;
begin
  Rate := 8000;
  ShiftHz := WantedHz - TUNER_TARGET_TONE_HZ;
  WriteLn;
  WriteLn('image: 解析信号を使う理由 / why the analytic signal is needed');
  WriteLn(Format('  目的の信号 %.0f Hz、妨害 %.0f Hz、移動量 %.0f Hz。',
    [WantedHz, InterferenceHz, ShiftHz]));
  WriteLn(Format('  単純な乗算では妨害が %.0f Hz へ折り返し、目的の信号に重なります。',
    [Abs(InterferenceHz + ShiftHz)]));
  WriteLn('  妨害の強さ  解析信号  単純な乗算');
  for L := 0 to High(LEVELS) do
  begin
    HilbertError := 0;
    NaiveError := 0;
    for I := 0 to High(MESSAGES) do
    begin
      Reference := NormalizeText(MESSAGES[I]);
      Audio := Synthesise(Reference, Rate, WantedHz, Noise, 2000 + I);
      Audio := WithInterference(Audio, Rate, InterferenceHz, LEVELS[L]);
      Hilbert := ToModelRate(FrequencyShift(Audio, Rate, ShiftHz), Rate, 0);
      Naive := ToModelRate(NaiveShift(Audio, Rate, ShiftHz), Rate, 0);
      Decoded := Decoder.DecodeLongSamples(Hilbert, Decoder.Metadata.SampleRate);
      HilbertError := HilbertError + CharErrorRate(Reference, Decoded);
      Decoded := Decoder.DecodeLongSamples(Naive, Decoder.Metadata.SampleRate);
      NaiveError := NaiveError + CharErrorRate(Reference, Decoded);
    end;
    WriteLn(Format('  %9.2f     %5.3f      %5.3f',
      [LEVELS[L], HilbertError / Length(MESSAGES), NaiveError / Length(MESSAGES)]));
  end;
end;

procedure RunBandwidth;
const
  { 雑音は差が出る水準まで上げます。低い水準ではどの帯域幅でも誤りが出ず、
    比べるものがありません。
    The noise is raised until differences appear; at low levels nothing errs
    at any bandwidth and there is nothing to compare. }
  NOISES: array[0..3] of Double = (1.75, 2.00, 2.25, 2.50);
  { 妨害は、変換後にモデルの帯域の内側へ落ちる位置に置きます。狭い帯域幅が
    役に立つとすれば、この場合です。
    The interferer is placed so that after translation it falls inside the
    model's band; if a narrow bandwidth ever helps, it helps here. }
  SOURCE_TONE_HZ = 1800.0;
  INTERFERENCE_OFFSET_HZ = 300.0;
var
  I, L, Rate: Integer;
  Bandwidth: TTunerBandwidth;
  Line, Reference, Decoded: string;
  Audio, Prepared: TSingleArray;
  ShiftHz, Total: Double;

  procedure Header(const Title: string);
  var
    Column: TTunerBandwidth;
  begin
    WriteLn;
    WriteLn(Title);
    Write('  雑音   ');
    for Column := Low(TTunerBandwidth) to High(TTunerBandwidth) do
      Write(Format('%-16s', [BandwidthCaption(Column)]));
    WriteLn;
  end;

begin
  Rate := 8000;
  ShiftHz := SOURCE_TONE_HZ - TUNER_TARGET_TONE_HZ;
  WriteLn;
  WriteLn('bandwidth: 追加の帯域制限が効くか / whether extra band limiting helps');
  WriteLn(Format('  音程 %.0f Hz を %.0f Hz へ変換、%.0f WPM。数字は文字誤り率。',
    [SOURCE_TONE_HZ, TUNER_TARGET_TONE_HZ, Wpm]));

  Header('  [1] 雑音のみ / noise only');
  for L := 0 to High(NOISES) do
  begin
    Line := Format('  %4.2f   ', [NOISES[L]]);
    for Bandwidth := Low(TTunerBandwidth) to High(TTunerBandwidth) do
      Line := Line + Format('%-16.3f',
        [MeasureAt(Rate, SOURCE_TONE_HZ, ShiftHz, NOISES[L],
                   BandwidthHalfWidth(Bandwidth), False)]);
    WriteLn(Line);
  end;

  Header(Format('  [2] 雑音と、変換後 %.0f Hz に落ちる妨害 / plus interference landing at %.0f Hz',
    [TUNER_TARGET_TONE_HZ + INTERFERENCE_OFFSET_HZ,
     TUNER_TARGET_TONE_HZ + INTERFERENCE_OFFSET_HZ]));
  for L := 0 to High(NOISES) do
  begin
    Line := Format('  %4.2f   ', [NOISES[L]]);
    for Bandwidth := Low(TTunerBandwidth) to High(TTunerBandwidth) do
    begin
      Total := 0;
      for I := 0 to High(MESSAGES) do
      begin
        Reference := NormalizeText(MESSAGES[I]);
        Audio := Synthesise(Reference, Rate, SOURCE_TONE_HZ, NOISES[L], 3000 + I);
        Audio := WithInterference(Audio, Rate,
          SOURCE_TONE_HZ + INTERFERENCE_OFFSET_HZ, 0.8);
        Prepared := ToModelRate(FrequencyShift(Audio, Rate, ShiftHz), Rate,
          BandwidthHalfWidth(Bandwidth));
        Decoded := Decoder.DecodeLongSamples(Prepared, Decoder.Metadata.SampleRate);
        Total := Total + CharErrorRate(Reference, Decoded);
      end;
      Line := Line + Format('%-16.3f', [Total / Length(MESSAGES)]);
    end;
    WriteLn(Line);
  end;
end;

{ 流し込み受信の経路をそのまま通します。他の試験と違い、確定と暫定の分割や
  帯域制限を掛ける位置まで含めて確かめられます。

  Runs the real streaming path, so unlike the other tests this also covers the
  confirmed/provisional split and where the filtering is applied. }
procedure RunStream;
const
  SOURCE_TONE_HZ = 2200.0;
  CHUNK_SECONDS = 0.5;
var
  Rate, I, Position, Count: Integer;
  Stream: TStreamingDecoder;
  Audio, Chunk: TSingleArray;
  Reference, Tuned, Untuned: string;
  Started: TDateTime;
  PlainMs, TunedMs, Steps: Double;

  function RunOnce(TuneHz: Double): string;
  begin
    Stream := TStreamingDecoder.Create(Decoder);
    try
      Stream.TuneHz := TuneHz;
      Position := 0;
      while Position < Length(Audio) do
      begin
        Count := Min(Round(CHUNK_SECONDS * Rate), Length(Audio) - Position);
        Chunk := Copy(Audio, Position, Count);
        Stream.Append(Chunk, Rate);
        Inc(Position, Count);
        if Stream.Ready then
        begin
          Stream.Step;
          Steps := Steps + 1;
        end;
      end;
      Stream.Finish;
      Result := Trim(DecodedText(Stream.ConfirmedChars));
    finally
      Stream.Free;
    end;
  end;

begin
  Rate := 8000;
  WriteLn;
  WriteLn('stream: 流し込み受信での同調 / tuning through the streaming path');
  WriteLn(Format('  音程 %.0f Hz、録音 %d Hz、%.1f 秒ずつ投入。',
    [SOURCE_TONE_HZ, Rate, CHUNK_SECONDS]));

  { 周波数変換そのものの費用を測ります。解析にかける上限の長さで行います。
    Cost of the translation itself, over the longest span ever analysed. }
  SetLength(Audio, Round(STREAM_MAX_SECONDS * Rate));
  for I := 0 to High(Audio) do
    Audio[I] := Sin(2 * Pi * SOURCE_TONE_HZ * I / Rate);
  Started := Now;
  Audio := FrequencyShift(Audio, Rate, SOURCE_TONE_HZ - TUNER_TARGET_TONE_HZ);
  WriteLn(Format('  周波数変換の費用: %.1f 秒ぶんで %d ms',
    [STREAM_MAX_SECONDS, MilliSecondsBetween(Now, Started)]));

  { 無音を先に流し込んでも文字が湧かないこと。信号が来ていないのに文字が出ると、
    受信できているのかどうかが分からなくなります（要件 FR-A.3）。
    Silence fed in first must not produce characters; text appearing with no
    signal leaves the operator unable to tell whether anything is being copied
    (requirement FR-A.3). }
  Reference := NormalizeText(MESSAGES[0]);
  SetLength(Audio, Round(12 * Rate));
  for I := 0 to High(Audio) do
    Audio[I] := 0;
  Untuned := RunOnce(0);
  WriteLn(Format('  12 秒の無音から出た文字: %d 個  %s',
    [Length(Untuned), BoolToStr(Untuned = '', '（湧かない）', '（湧いた）')]));

  { 無音のあとに符号が続く場合、無音で捨てた分だけ時刻がずれていないこと。
    After silence the code must still decode, with its timing unshifted by
    what the squelch dropped. }
  Audio := Synthesise(Reference, Rate, SOURCE_TONE_HZ, Noise, 5000);
  SetLength(Chunk, Round(8 * Rate) + Length(Audio));
  for I := 0 to High(Chunk) do
    Chunk[I] := 0;
  for I := 0 to High(Audio) do
    Chunk[Round(8 * Rate) + I] := Audio[I];
  Audio := Chunk;
  Tuned := RunOnce(SOURCE_TONE_HZ);
  WriteLn(Format('  8 秒の無音のあとの符号: %-42s %s',
    [Tuned, BoolToStr(Tuned = Reference, '一致', '不一致')]));

  for I := 0 to High(MESSAGES) do
  begin
    Reference := NormalizeText(MESSAGES[I]);
    Audio := Synthesise(Reference, Rate, SOURCE_TONE_HZ, Noise, 5000 + I);
    Steps := 0;
    Started := Now;
    Untuned := RunOnce(0);
    PlainMs := MilliSecondsBetween(Now, Started) / Max(1, Steps);
    Steps := 0;
    Started := Now;
    Tuned := RunOnce(SOURCE_TONE_HZ);
    TunedMs := MilliSecondsBetween(Now, Started) / Max(1, Steps);
    WriteLn(Format('  期待     : %s', [Reference]));
    WriteLn(Format('  同調なし : %-42s CER %.3f',
      [Untuned, CharErrorRate(Reference, Untuned)]));
    WriteLn(Format('  同調あり : %-42s CER %.3f  %s',
      [Tuned, CharErrorRate(Reference, Tuned),
       BoolToStr(Tuned = Reference, '一致', '不一致')]));
    WriteLn(Format('  1 回の解析: 同調なし %.0f ms、同調あり %.0f ms',
      [PlainMs, TunedMs]));
  end;
end;

{ 帯域全体を 1 度に変換し、そこから局ごとに切り出して読めるかを確かめます。

  待機モードとコンテストモード（要件 FR-I）は、通過帯域にいる多数の局を同時に
  読むことを求めます。局ごとに周波数変換とリサンプルを掛け直すなら費用は局数に
  比例しますが、変換を 1 度で済ませられるなら話が変わります。**そこが成り立つか
  どうかで、この機能が実用になるかが決まります。**

  Checks whether the whole band can be transformed once and each station cut
  out of the result.

  The standby and contest modes (requirement FR-I) call for reading many
  stations across the passband at the same time. Translating and resampling
  per station makes the cost proportional to their number; sharing one
  transform changes that entirely, and whether it works decides whether the
  feature is practical at all. }
procedure RunWide(const TONES: array of Double; const Title: string);
const
  CAPTURE_RATE = 8000;
  WIDTHS: array[0..5] of Double = (0, 250, 175, 125, 87.5, 50);
var
  I, J, Station, WideRate, Total: Integer;
  Mixed, Audio, Prepared: TSingleArray;
  Wide, Slice: TSpectrogram;
  Reference, Sliced, Tuned: string;
  Seconds, Started, SharedMs, PerStationMs, TunedMs: Double;
  Begun: TDateTime;
begin
  WriteLn;
  WriteLn('wide: ', Title);
  WideRate := Decoder.Metadata.SampleRate * 2;
  WriteLn(Format('  録音 %d Hz を %d Hz へ変換し、FFT %d・ホップ %d で 1 度だけ解析。',
    [CAPTURE_RATE, WideRate, Decoder.Metadata.FFTLength * 2,
     Decoder.Metadata.HopLength * 2]));
  Write('  同時に出ている局: ');
  for I := 0 to High(TONES) do
    Write(Format('%.0f Hz  ', [TONES[I]]));
  WriteLn;

  { 4 局を同時に鳴らします。/ Four stations transmitting at once. }
  Mixed := nil;
  for I := 0 to High(TONES) do
  begin
    Audio := Synthesise(NormalizeText(MESSAGES[I mod Length(MESSAGES)]),
      CAPTURE_RATE, TONES[I], 0, 7000 + I);
    if Length(Audio) > Length(Mixed) then
    begin
      J := Length(Mixed);
      SetLength(Mixed, Length(Audio));
      while J <= High(Mixed) do
      begin
        Mixed[J] := 0;
        Inc(J);
      end;
    end;
    for J := 0 to High(Audio) do
      Mixed[J] := Mixed[J] + 0.5 * Audio[J];
  end;
  { 雑音は混ぜたあとに加えます。局ごとに足すと 4 倍になってしまいます。
    Noise is added after mixing; per station it would end up four times over. }
  RandSeed := 7777;
  for J := 0 to High(Mixed) do
    Mixed[J] := Mixed[J] + Noise * 0.25 * (Random + Random - 1);

  Seconds := Length(Mixed) / CAPTURE_RATE;
  WriteLn(Format('  長さ %.1f 秒。', [Seconds]));

  { 広帯域の変換は 1 度だけ。/ The wide transform runs once. }
  Begun := Now;
  Prepared := ResampleLinear(Mixed, CAPTURE_RATE, WideRate);
  Wide := ComputeWideSpectrogram(Prepared, WideRate, Decoder.Metadata);
  SharedMs := MilliSecondsBetween(Now, Begun);

  { 切り出したあと、中心の周りだけを残す幅を変えて比べます。隣の局を絵から
    追い出せるかどうかが、コンテストモードが成り立つかを決めます。
    The width kept around the centre is varied. Whether a neighbour can be
    pushed out of the picture decides whether contest mode is possible. }
  WriteLn('  残す幅        ' + '完全一致した局 / 例');
  for I := 0 to High(WIDTHS) do
  begin
    Total := 0;
    PerStationMs := 0;
    Sliced := '';
    for Station := 0 to High(TONES) do
    begin
      Reference := NormalizeText(MESSAGES[Station mod Length(MESSAGES)]);
      Begun := Now;
      Slice := SliceSpectrogram(Wide,
        WideBinFor(TONES[Station], WideRate, Decoder.Metadata.FFTLength * 2),
        Decoder.Metadata);
      if WIDTHS[I] > 0 then
        MaskSpectrogram(Slice, WIDTHS[I], Decoder.Metadata);
      Tuned := Trim(DecodedText(Decoder.DecodeSpectrogramTimed(Slice, Seconds)));
      PerStationMs := PerStationMs + MilliSecondsBetween(Now, Begun);
      if Tuned = Reference then
        Inc(Total);
      if Station = 0 then
        Sliced := Tuned;
    end;
    if WIDTHS[I] > 0 then
      Reference := Format('±%.0f Hz', [WIDTHS[I]])
    else
      Reference := '制限なし';
    WriteLn(Format('  %-12s  %d / %d   %s',
      [Reference, Total, Length(TONES), Copy(Sliced, 1, 44)]));
  end;

  { 同調経路（時間領域のフィルタ）との比較を 1 局ぶんだけ取ります。
    One station's worth of comparison against the tuned, time-domain path. }
  Begun := Now;
  Audio := ToModelRate(FrequencyShift(Mixed, CAPTURE_RATE,
    TONES[0] - TUNER_TARGET_TONE_HZ), CAPTURE_RATE, BandwidthHalfWidth(tbAuto));
  Tuned := Trim(Decoder.DecodeLongSamples(Audio, Decoder.Metadata.SampleRate));
  TunedMs := MilliSecondsBetween(Now, Begun);
  WriteLn(Format('  同調経路(±250)  %s   %s',
    [BoolToStr(Tuned = NormalizeText(MESSAGES[0]), '一致', '不一致'),
     Copy(Tuned, 1, 44)]));

  WriteLn(Format('  共通の変換 %.0f ms / 1 局あたり 切り出し %.0f ms・同調経路 %.0f ms',
    [SharedMs, PerStationMs / Length(TONES), TunedMs]));
end;

var
  Index: Integer;
  Key, Value: string;
begin
  Index := 1;
  while Index <= ParamCount do
  begin
    Key := ParamStr(Index);
    Value := '';
    if Index < ParamCount then
      Value := ParamStr(Index + 1);
    case Key of
      '--model': ModelPath := Value;
      '--metadata': MetadataPath := Value;
      '--onnxruntime': RuntimePath := Value;
      '--tests': Tests := Value;
      '--noise': Noise := StrToFloatDef(Value, 0.30);
      '--wpm': Wpm := StrToFloatDef(Value, 22);
    else
      begin
        WriteLn(StdErr, 'Unknown option: ', Key);
        Halt(2);
      end;
    end;
    Inc(Index, 2);
  end;

  if ModelPath = '' then
    ModelPath := LocateDataFile('model.onnx');
  if MetadataPath = '' then
    MetadataPath := LocateDataFile('model.onnx.json');

  try
    if RuntimePath <> '' then
      LoadOnnxRuntime(RuntimePath)
    else
      LoadOnnxRuntime;
    Decoder := TDeepCWDecoder.Create(ModelPath, MetadataPath, 1);
  except
    on E: Exception do
    begin
      WriteLn(StdErr, 'Could not start the engine: ', E.Message);
      Halt(1);
    end;
  end;

  try
    if Pos('sweep', Tests) > 0 then
      RunSweep;
    if Pos('shift', Tests) > 0 then
      RunShift;
    if Pos('image', Tests) > 0 then
      RunImage;
    if Pos('bandwidth', Tests) > 0 then
      RunBandwidth;
    if Pos('stream', Tests) > 0 then
      RunStream;
    if Pos('wide', Tests) > 0 then
    begin
      { 広く離れている場合と、コンテストのように詰まっている場合の両方を見ます。
        Both a well-spaced band and a contest-tight one. }
      RunWide([700, 1150, 1600, 2050],
        '離れた 4 局 / four well-spaced stations');
      RunWide([700, 850, 1000, 1150],
        'コンテスト並みに詰まった 4 局（150 Hz 間隔） / four at contest spacing');
      RunWide([700, 800, 900, 1000],
        'さらに詰まった 4 局（100 Hz 間隔） / four at 100 Hz spacing');
    end;
    WriteLn;
  finally
    Decoder.Free;
  end;
end.
