program dsp_check;

{ DSP と同調まわりの数値的な正しさを、モデル無しで確かめます。

  復号の試験は、前処理の数値が多少狂っていても文字が出れば通ってしまいます。
  ここは**モデルに渡す前の数値そのもの**を、既知の入力に対する既知の答えと
  突き合わせます（要件 NFR-7.4）。

  Verifies the numerical correctness of the DSP and tuning, without the model.

  The decode tests pass as long as characters come out, even when the
  pre-processing numbers are slightly wrong. This checks **the numbers handed
  to the model** against known answers for known inputs (requirement
  NFR-7.4). }

{$mode objfpc}{$H+}

uses
  Classes, SysUtils, DateUtils, Math, DeepCW.Types, DeepCW.Metadata, DeepCW.Dsp, DeepCW.Wave,
  DeepCW.Tuner, DeepCW.Review, DeepCW.Journal, DeepCW.Decoder,
  DeepCW.Multi, DeepCW.BandMap;

var
  Meta: TDeepCWMetadata;
  Failures: Integer = 0;

procedure Check(const What: string; Passed: Boolean; const Detail: string = '');
begin
  if Passed then
    WriteLn('  ok   ', What)
  else
  begin
    WriteLn('  NG   ', What, '  ', Detail);
    Inc(Failures);
  end;
end;

{ 単一トーンを作ります。/ A single tone. }
function Tone(Hz: Double; SampleRate, Count: Integer): TSingleArray;
var I: Integer;
begin
  SetLength(Result, Count);
  for I := 0 to Count - 1 do
    Result[I] := Sin(2 * Pi * Hz * I / SampleRate);
end;

{ 配列の実効値。/ RMS of an array. }
function Rms(const A: TSingleArray): Double;
var I: Integer; S: Double;
begin
  S := 0;
  for I := 0 to High(A) do S := S + Sqr(A[I]);
  if Length(A) = 0 then Exit(0);
  Result := Sqrt(S / Length(A));
end;

{ 全体を平均したスペクトル。像がどこに立っているかを見るために使います。
  The spectrum averaged over the whole signal, for seeing where an image
  stands. }
function AverageSpectrum(const Samples: TSingleArray; FFTLength: Integer): TDoubleArray;
var
  FFT: TRealFFT;
  Window, Frame, Magnitudes: TDoubleArray;
  Bins, Frames, FrameIndex, I: Integer;
begin
  Bins := FFTLength div 2 + 1;
  SetLength(Result, Bins);
  for I := 0 to Bins - 1 do
    Result[I] := 0;
  if Length(Samples) < FFTLength then
    Exit;
  Frames := 1 + (Length(Samples) - FFTLength) div (FFTLength div 2);
  Window := HannWindow(FFTLength);
  SetLength(Frame, FFTLength);
  SetLength(Magnitudes, Bins);
  FFT := TRealFFT.Create(FFTLength);
  try
    for FrameIndex := 0 to Frames - 1 do
    begin
      for I := 0 to FFTLength - 1 do
        Frame[I] := Samples[FrameIndex * (FFTLength div 2) + I] * Window[I];
      FFT.MagnitudeSpectrum(Frame, 0, Bins, Magnitudes);
      for I := 0 to Bins - 1 do
        Result[I] := Result[I] + Magnitudes[I];
    end;
  finally
    FFT.Free;
  end;
  for I := 0 to Bins - 1 do
    Result[I] := Result[I] / Frames;
end;

{ スペクトルで最も強いビンの番号。/ The strongest bin of a spectrum. }
function PeakBin(const A: TDoubleArray): Integer;
var I: Integer; P: Double;
begin
  Result := 0; P := A[0];
  for I := 1 to High(A) do
    if A[I] > P then begin P := A[I]; Result := I; end;
end;

procedure TestQuantize;
begin
  WriteLn('QuantizeTone（12.5 Hz 格子）');
  Check('800 → 800', QuantizeTone(800) = 800);
  Check('806 → 800（近いほうへ）', QuantizeTone(806) = 800,
    Format('(%.1f)', [QuantizeTone(806)]));
  Check('807 → 812.5', QuantizeTone(807) = 812.5, Format('(%.1f)', [QuantizeTone(807)]));
  Check('負値も対称', QuantizeTone(-806) = -800, Format('(%.1f)', [QuantizeTone(-806)]));
end;

procedure TestResample;
var A, B: TSingleArray;
begin
  WriteLn('ResampleLinear');
  A := Tone(1000, 8000, 8000);
  B := ResampleLinear(A, 8000, 8000);
  Check('同じ周波数なら素通し', Length(B) = Length(A));
  B := ResampleLinear(A, 8000, 4000);
  Check('半分にすると長さも半分', Abs(Length(B) - 4000) <= 1,
    Format('(%d)', [Length(B)]));
  { 1000 Hz は 4000 Hz でもナイキスト以下。実効値が保たれること。
    1000 Hz is below Nyquist at 4000 too; RMS should hold. }
  Check('通過帯域の実効値が保たれる', Abs(Rms(B) - Rms(A)) < 0.05,
    Format('(%.3f vs %.3f)', [Rms(B), Rms(A)]));
end;

procedure TestFrequencyShift;
var A, B: TSingleArray;
begin
  WriteLn('FrequencyShift');
  A := Tone(1500, 8000, 8000);
  B := FrequencyShift(A, 8000, 0);
  Check('0 Hz の移動は素通し', (Length(B) = Length(A)) and (B[100] = A[100]));

  { 1500 Hz を -700 Hz 動かすと 800 Hz。スペクトルで確かめる。
    Shifting 1500 Hz by -700 gives 800 Hz; confirmed via the spectrum. }
  B := FrequencyShift(A, 8000, 1500 - 800);
  Check('移動後の実効値が保たれる（±0.1）', Abs(Rms(B) - Rms(A)) < 0.1,
    Format('(%.3f vs %.3f)', [Rms(B), Rms(A)]));
end;

procedure TestWideSlice;
var
  A, Prepared: TSingleArray;
  Wide, Slice, Direct: TSpectrogram;
  WideRate, Centre, F, B, MaxDiff, D: Integer;
  Diff: Double;
begin
  WriteLn('広帯域スペクトログラムの切り出し（FR-I の土台）');
  WideRate := Meta.SampleRate * 2;
  { 800 Hz のトーンを 6400 Hz で合成。/ An 800 Hz tone at 6400 Hz. }
  A := Tone(800, WideRate, WideRate * 6);
  Wide := ComputeWideSpectrogram(A, WideRate, Meta);
  Centre := WideBinFor(800, WideRate, Meta.FFTLength * 2);
  Slice := SliceSpectrogram(Wide, Centre, Meta);
  Check('切り出しのビン数がモデルと一致',
    Slice.Bins = Meta.StopBin - Meta.StartBin,
    Format('(%d)', [Slice.Bins]));

  { 同じ 800 Hz を、モデルの周波数で直接スペクトログラムにする。
    切り出したものと、山の位置（中央ビン）が一致するはず。
    The same 800 Hz made directly at the model rate; the peak bin should line
    up with the slice's centre. }
  Prepared := ResampleLinear(A, WideRate, Meta.SampleRate);
  Direct := ComputeSpectrogram(Prepared, Meta);
  Check('切り出しと直接生成のフレーム数がほぼ一致',
    Abs(Slice.Frames - Direct.Frames) <= 2,
    Format('(%d vs %d)', [Slice.Frames, Direct.Frames]));

  { 中ほどのフレームで、切り出し・直接生成の山のビンが一致すること。
    In a mid frame the peak bin of slice and direct should match. }
  F := Slice.Frames div 2;
  MaxDiff := 0;
  if (F < Direct.Frames) then
  begin
    D := 0;
    for B := 0 to Slice.Bins - 1 do
    begin
      Diff := Abs(Slice.Data[F * Slice.Bins + B] -
                  Direct.Data[F * Direct.Bins + B]);
      if Diff > 0.5 then Inc(D);
    end;
    MaxDiff := D;
  end;
  Check('切り出しと直接生成が概ね一致（差の大きいビンが少数）',
    MaxDiff <= 5, Format('(%d ビンで差>0.5)', [MaxDiff]));
end;

procedure TestTrackTone;
var
  Mag: TDoubleArray;
  BinHz, NewHz: Double;
  I, Centre: Integer;
  Moved: Boolean;
begin
  WriteLn('TrackTone（信号追跡）');
  BinHz := 12.5;
  SetLength(Mag, 200);   { 0〜2500 Hz }
  for I := 0 to High(Mag) do Mag[I] := 0.01;   { 一様な雑音 }

  { 山を 900 Hz（ビン 72）より少し上、912.5 Hz（ビン 73）に立てる。
    同調点 900 Hz から、山のほうへ 1 歩寄るはず。
    A peak at 912.5 Hz (bin 73), one bin above the 900 Hz tuning; tracking
    should step towards it. }
  Centre := Round(900 / BinHz);
  Mag[Centre + 1] := 1.0;
  Moved := TrackTone(Mag, BinHz, 900, NewHz);
  Check('山のほうへ寄る', Moved and (NewHz > 900) and (NewHz <= 912.5 + 0.01),
    Format('(moved=%s new=%.1f)', [BoolToStr(Moved, True), NewHz]));

  { 一様な雑音（山なし）では動かないこと。
    Flat noise (no peak) must not move. }
  for I := 0 to High(Mag) do Mag[I] := 0.01;
  Moved := TrackTone(Mag, BinHz, 900, NewHz);
  Check('山が無ければ動かない', (not Moved) and (NewHz = 900),
    Format('(moved=%s new=%.1f)', [BoolToStr(Moved, True), NewHz]));

  { 遠くの山（+300 Hz）でも 1 歩（12.5 Hz）しか動かないこと。乗り移り防止。
    A far peak (+300 Hz) must still move only one step; anti-walk. }
  for I := 0 to High(Mag) do Mag[I] := 0.01;
  Mag[Round((900 + 300) / BinHz)] := 1.0;
  Moved := TrackTone(Mag, BinHz, 900, NewHz);
  Check('探索範囲の外の山には動かない', (not Moved) or (Abs(NewHz - 900) <= 12.5 + 0.01),
    Format('(moved=%s new=%.1f)', [BoolToStr(Moved, True), NewHz]));

  { 同調していない（0）ときは何もしないこと。
    With no tuning (0) it must do nothing. }
  Moved := TrackTone(Mag, BinHz, 0, NewHz);
  Check('同調していなければ何もしない', not Moved);
end;

procedure TestBandPass;
var A, B: TSingleArray;
begin
  WriteLn('BandPassFilter');
  { 800 Hz を ±250 Hz の帯域に通せば、ほぼ保たれる。
    800 Hz through a +/-250 Hz band should mostly survive. }
  A := Tone(800, 3200, 3200);
  B := BandPassFilter(A, 3200, 550, 1050);
  Check('通過帯域の中央は保たれる', Rms(B) > 0.5 * Rms(A),
    Format('(%.3f vs %.3f)', [Rms(B), Rms(A)]));
  { 300 Hz は同じ帯域では大きく減衰する。
    300 Hz is well outside and should be strongly attenuated. }
  A := Tone(300, 3200, 3200);
  B := BandPassFilter(A, 3200, 550, 1050);
  Check('帯域外は大きく減衰する', Rms(B) < 0.3 * Rms(A),
    Format('(%.3f vs %.3f)', [Rms(B), Rms(A)]));
end;

{ 番号そのものを値に入れた音声。取り出した中身が、狙った区間のものかどうかを
  一目で確かめられます。
  Audio whose value is its own index, so that what comes back can be checked
  against the stretch that was asked for. }
function Ramp(First, Count: Integer): TSingleArray;
var I: Integer;
begin
  SetLength(Result, Count);
  for I := 0 to Count - 1 do
    Result[I] := First + I;
end;

{ スペクトルの中で、指定した周波数のビンの大きさを返します。
  The magnitude of the bin at a given frequency. }
function BinLevel(const Spec: TDoubleArray; Hz: Double; Rate, FFTLength: Integer): Double;
var
  Bin: Integer;
begin
  Bin := Round(Hz * FFTLength / Rate);
  if (Bin < 0) or (Bin > High(Spec)) then
    Exit(0);
  Result := Spec[Bin];
end;

procedure TestResampleBandLimited;
const
  RATE = 8000;
  TARGET = 6400;
var
  A, B: TSingleArray;
  Spec: TDoubleArray;
  I: Integer;
  Signal_, Image: Double;
begin
  WriteLn('ResampleBandLimited');

  { 長さが比のとおりになること。
    The length must follow the ratio. }
  A := Tone(800, RATE, RATE);
  B := ResampleBandLimited(A, RATE, TARGET);
  Check('長さが比のとおりになる', Abs(Length(B) - TARGET) <= 1,
    Format('(%d)', [Length(B)]));

  { 通過帯域の実効値が保たれること。
    The passband's RMS must survive. }
  Check('通過帯域の実効値が保たれる', Abs(Rms(B) - Rms(A)) < 0.05 * Rms(A),
    Format('(%.4f vs %.4f)', [Rms(B), Rms(A)]));

  { 同じ周波数なら素通し。
    The same rate passes through untouched. }
  B := ResampleBandLimited(A, RATE, RATE);
  Check('同じ周波数なら素通し', Length(B) = Length(A));

  { **本題。**2 つの強い音を同時に落としたとき、変換が作る像が十分に低いこと。
    線形補間では f ± 1600 Hz に本物と同じ高さの像が立ち、多局同時受信の検出が
    偽の局を作りました（付録 N.2）。ここでは 2050 Hz の像が立つ 450 Hz を見ます。

    **The point of this test.** Two strong tones taken down together must not
    leave the images the conversion can create. Linear interpolation raises them
    at f +/- 1600 Hz as tall as the real tones, and multi-station detection then
    reports stations that are not there (appendix N.2). The image of 2050 Hz,
    at 450 Hz, is what is measured. }
  SetLength(A, 2 * RATE);
  for I := 0 to High(A) do
    A[I] := 0.5 * Sin(2 * Pi * 700 * I / RATE) + 0.5 * Sin(2 * Pi * 2050 * I / RATE);

  B := ResampleLinear(A, RATE, TARGET);
  Spec := AverageSpectrum(B, 1024);
  Signal_ := BinLevel(Spec, 700, TARGET, 1024);
  Image := BinLevel(Spec, 450, TARGET, 1024);
  WriteLn(Format('    線形補間    : 700 Hz に対する 450 Hz の像 %.1f dB',
    [20 * Log10(Max(1E-12, Image) / Max(1E-12, Signal_))]));

  B := ResampleBandLimited(A, RATE, TARGET);
  Spec := AverageSpectrum(B, 1024);
  Signal_ := BinLevel(Spec, 700, TARGET, 1024);
  Image := BinLevel(Spec, 450, TARGET, 1024);
  WriteLn(Format('    帯域制限    : 700 Hz に対する 450 Hz の像 %.1f dB',
    [20 * Log10(Max(1E-12, Image) / Max(1E-12, Signal_))]));
  { 局の検出は雑音面から 6 dB で局と認めます。像がそれより十分下、すなわち
    -40 dB より下にいれば、像が局になることはありません。
    Detection calls a peak a station at 6 dB above the noise floor, so an image
    below -40 dB can never become one. }
  Check('変換が作る像が -40 dB より下',
    20 * Log10(Max(1E-12, Image) / Max(1E-12, Signal_)) < -40,
    Format('(%.1f dB)', [20 * Log10(Max(1E-12, Image) / Max(1E-12, Signal_))]));
end;

procedure TestHistory;
const
  RATE = 8000;
var
  History: TAudioHistory;
  Got: TSingleArray;
  From_, To_: Double;
  R, I: Integer;
  Ok: Boolean;
begin
  WriteLn('TAudioHistory');
  { 60 秒 = 480000 標本を保持する。/ Sixty seconds is 480000 samples. }
  History := TAudioHistory.Create(60, RATE);
  try
    { 10 秒ぶんを 0 秒から足す。/ Ten seconds in, starting at zero. }
    History.Append(Ramp(0, 10 * RATE), RATE, 0);
    Check('入れた長さがそのまま残る',
      SameValue(History.RetainedSeconds, 10, 1E-6),
      Format('(%.3f 秒)', [History.RetainedSeconds]));
    Check('いちばん古い時刻は 0', SameValue(History.EarliestSeconds, 0, 1E-9));
    Check('いちばん新しい時刻は 10', SameValue(History.LatestSeconds, 10, 1E-9));

    { 3.0〜4.0 秒を取り出すと、24000 番から 32000 番の手前まで。
      Three to four seconds is sample 24000 up to 32000. }
    Got := History.Extract(3, 4, From_, To_, R);
    Check('求めた長さで返る', Length(Got) = RATE, Format('(%d)', [Length(Got)]));
    Check('求めた区間の中身が返る',
      (Length(Got) = RATE) and (Got[0] = 3 * RATE) and (Got[RATE - 1] = 4 * RATE - 1),
      Format('(%.0f..%.0f)', [Got[0], Got[High(Got)]]));
    Check('返した区間を申告する',
      SameValue(From_, 3, 1E-6) and SameValue(To_, 4, 1E-6),
      Format('(%.3f..%.3f)', [From_, To_]));
    Check('録音周波数を申告する', R = RATE);

    { 保持を超えて足す。合計 70 秒ぶんで、古い 10 秒は消える。
      Past the retention: seventy seconds in total, so the first ten go. }
    History.Append(Ramp(10 * RATE, 60 * RATE), RATE, 10);
    Check('保持時間を超えない',
      SameValue(History.RetainedSeconds, 60, 1E-6),
      Format('(%.3f 秒)', [History.RetainedSeconds]));
    Check('消えたぶんだけ古い時刻が進む',
      SameValue(History.EarliestSeconds, 10, 1E-6),
      Format('(%.3f 秒)', [History.EarliestSeconds]));
    Check('新しい時刻は足した合計のまま',
      SameValue(History.LatestSeconds, 70, 1E-6),
      Format('(%.3f 秒)', [History.LatestSeconds]));

    { 環が一周したあとでも、時刻と中身の対応は崩れない。
      The mapping from time to content survives the wrap. }
    Got := History.Extract(65, 66, From_, To_, R);
    Ok := Length(Got) = RATE;
    if Ok then
      for I := 0 to RATE - 1 do
        if Got[I] <> 65 * RATE + I then
        begin
          Ok := False;
          Break;
        end;
    Check('一周したあとも時刻と中身が合う', Ok);

    { 消えた区間を求めたら、残っているところまで切り詰めて返す。
      A request reaching into what has gone is clipped to what remains. }
    Got := History.Extract(5, 12, From_, To_, R);
    Check('消えた区間は切り詰めて返す',
      (Length(Got) = 2 * RATE) and SameValue(From_, 10, 1E-6),
      Format('(%d 標本, %.3f 秒から)', [Length(Got), From_]));
    { 完全に消えた区間は、黙って別の音を返さず空で返す。
      A stretch that has gone entirely comes back empty, not as some other
      audio. }
    Got := History.Extract(0, 5, From_, To_, R);
    Check('完全に消えた区間は空で返す', Length(Got) = 0,
      Format('(%d 標本)', [Length(Got)]));
    { まだ来ていない先も同じ。/ The same for a stretch not yet received. }
    Got := History.Extract(80, 90, From_, To_, R);
    Check('まだ来ていない区間は空で返す', Length(Got) = 0,
      Format('(%d 標本)', [Length(Got)]));

    { 時刻が飛んだら、繋げずに数え直す。呼び出し側が受信をやり直した合図であり、
      **黙って繋げると、以後ずっと別の場所が鳴る。**
      A jump in the time restarts the count rather than joining: it signals that
      the caller restarted reception, and **joining silently would play the
      wrong place from then on.** }
    History.Append(Ramp(0, RATE), RATE, 500);
    Check('時刻が飛んだら数え直す',
      SameValue(History.EarliestSeconds, 500, 1E-6) and
      SameValue(History.LatestSeconds, 501, 1E-6),
      Format('(%.3f..%.3f)', [History.EarliestSeconds, History.LatestSeconds]));
    Check('数え直したあとは前の音を返さない',
      Length(History.Extract(60, 70, From_, To_, R)) = 0,
      '(前の音が返った)');
    { 時刻が戻ってもよい。受信のやり直しは 0 から始まる。
      Time may also go back: a fresh reception starts at zero. }
    History.Append(Ramp(0, RATE), RATE, 0);
    Check('時刻が戻っても数え直す',
      SameValue(History.EarliestSeconds, 0, 1E-6) and
      SameValue(History.LatestSeconds, 1, 1E-6),
      Format('(%.3f..%.3f)', [History.EarliestSeconds, History.LatestSeconds]));

    { 半標本より小さい食い違いは、丸めの誤差として繋げる。ここで数え直すと、
      正常な受信が 1 回ごとに中身を捨ててしまう。
      A disagreement below half a sample is rounding and is joined: restarting
      there would make an ordinary reception discard its contents every time. }
    History.Append(Ramp(0, RATE), RATE, 1 + 0.4 / RATE);
    Check('丸め程度のずれは繋げる',
      SameValue(History.RetainedSeconds, 2, 1E-6),
      Format('(%.3f 秒)', [History.RetainedSeconds]));

    { 一度に容量を超える量が来ても、末尾が残り時刻は合う。
      More than the capacity at once keeps the tail and the clock still adds
      up. }
    History.Clear;
    History.Append(Ramp(0, 100 * RATE), RATE, 0);
    Check('容量超えの一括入力でも保持時間を守る',
      SameValue(History.RetainedSeconds, 60, 1E-6),
      Format('(%.3f 秒)', [History.RetainedSeconds]));
    Check('容量超えの一括入力でも時刻が合う',
      SameValue(History.LatestSeconds, 100, 1E-6) and
      SameValue(History.EarliestSeconds, 40, 1E-6),
      Format('(%.3f..%.3f)', [History.EarliestSeconds, History.LatestSeconds]));
    Got := History.Extract(99, 100, From_, To_, R);
    Check('容量超えの一括入力でも末尾が残る',
      (Length(Got) = RATE) and (Got[0] = 99 * RATE),
      Format('(%.0f)', [Got[0]]));

    { 録音周波数が変わったら、中身は手放して渡された時刻から数え直す。
      A change of rate releases the contents and counts from the time given. }
    History.Append(Ramp(0, 16000), 16000, 100);
    Check('周波数が変わったら中身を手放す',
      SameValue(History.RetainedSeconds, 1, 1E-6),
      Format('(%.3f 秒)', [History.RetainedSeconds]));
    Check('周波数が変わっても時刻は続く',
      SameValue(History.LatestSeconds, 101, 1E-6),
      Format('(%.3f 秒)', [History.LatestSeconds]));
    Check('新しい周波数を申告する', History.SampleRate = 16000);
    Check('確保できた保持時間に不足がない',
      SameValue(History.ShortfallSeconds, 0, 1E-6),
      Format('(%.1f 秒足りない)', [History.ShortfallSeconds]));
  finally
    History.Free;
  end;
end;

{ 文字列を、時刻の付いた確定文字の並びへ直します。時刻は 1 文字 0.1 秒。
  Turns a string into timed confirmed characters, a tenth of a second each. }
function CharsOf(const Text: string; StartSeconds: Double): TDecodedChars;
var
  I: Integer;
begin
  SetLength(Result, Length(Text));
  for I := 1 to Length(Text) do
  begin
    Result[I - 1].Text := Text[I];
    Result[I - 1].Seconds := StartSeconds + (I - 1) * 0.1;
    Result[I - 1].EndSeconds := Result[I - 1].Seconds + 0.08;
    Result[I - 1].Confidence := 0.99;
  end;
end;

{ ファイルの中身を読みます。記録の途中でも読めることを確かめるために使います。
  Reads the file's contents, used to check that the record is readable while it
  is still being written. }
function ReadWhole(const FileName: string): string;
var
  Stream: TFileStream;
begin
  Result := '';
  if not FileExists(FileName) then
    Exit;
  Stream := TFileStream.Create(FileName, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Result, Stream.Size);
    if Stream.Size > 0 then
      Stream.ReadBuffer(Result[1], Stream.Size);
  finally
    Stream.Free;
  end;
end;

procedure TestJournal;
var
  Dir: string;
  Journal: TTranscriptJournal;
  Origin: TDateTime;
  Body: string;
  Bad: TTranscriptJournal;
begin
  WriteLn('TTranscriptJournal');
  Dir := IncludeTrailingPathDelimiter(GetTempDir) + 'deepcw-journal-test';
  if DirectoryExists(Dir) then
    DeleteFile(JournalFileFor(Dir, EncodeDate(2026, 9, 4)));

  Origin := EncodeDate(2026, 9, 4) + EncodeTime(12, 0, 0, 0);
  Journal := TTranscriptJournal.Create(Dir);
  try
    Journal.Enabled := True;
    Journal.StartSession(Origin);

    { 語間が来るまでは書きません。1 文字ずつ書いた記録は読めません。
      Nothing is written until a word space: a record written character by
      character would be unreadable. }
    Journal.Add(CharsOf('CQ', 0));
    Check('語の途中では書かない', Journal.LinesWritten = 0,
      Format('(%d 行)', [Journal.LinesWritten]));

    { **語間が来たら、その場でファイルに残っていること。**閉じるまで書かない
      作りでは、強制終了したときに何も残らない（要件 FR-B.6）。
      **A word space must put the line on disk there and then.** A design that
      writes at close leaves nothing behind when the exit is not clean
      (requirement FR-B.6). }
    Journal.Add(CharsOf(' ', 0.3));
    Body := ReadWhole(Journal.FileName);
    Check('語間で 1 行が確定する', Journal.LinesWritten = 1,
      Format('(%d 行)', [Journal.LinesWritten]));
    Check('閉じる前にファイルへ残っている', Pos('CQ', Body) > 0,
      Format('(中身: "%s")', [Trim(Body)]));

    { 時刻は、受信開始の実時刻に経過秒を足したもの。書いた瞬間ではない。
      The time is the reception's wall clock plus the elapsed seconds, not the
      moment of writing. }
    Check('行の時刻が受信開始からの経過で付く',
      Pos('2026-09-04 12:00:00  CQ', Body) > 0,
      Format('(中身: "%s")', [Trim(Body)]));

    { 経過秒がそのまま時刻に効くこと。90 秒後の語は 12:01:30。
      Elapsed seconds must reach the timestamp: a word at 90 seconds is
      12:01:30. }
    Journal.Add(CharsOf('DE JH2XYZ ', 90));
    Body := ReadWhole(Journal.FileName);
    Check('経過秒が時刻に反映される',
      Pos('2026-09-04 12:01:30  DE', Body) > 0,
      Format('(中身: "%s")', [Trim(Body)]));

    { 語間で終わらない末尾は、Flush で出す。交信の最後がここに当たる。
      A tail not ending on a word space is written by Flush, which is where the
      end of a contact falls. }
    Journal.Add(CharsOf('SK', 120));
    Check('書き残しは Flush まで書かない', Journal.LinesWritten = 3,
      Format('(%d 行)', [Journal.LinesWritten]));
    Journal.Flush;
    Body := ReadWhole(Journal.FileName);
    Check('Flush で末尾が残る', Pos('SK', Body) > 0,
      Format('(中身: "%s")', [Trim(Body)]));

    { 記録を止めるときも、抱えている行は出す。捨てると 1 語だけ落ちる。
      Switching off writes the waiting line: dropping it would lose exactly one
      word. }
    Journal.Add(CharsOf('TNX', 130));
    Journal.Enabled := False;
    Body := ReadWhole(Journal.FileName);
    Check('記録を止めるときに書き残しを出す', Pos('TNX', Body) > 0,
      Format('(中身: "%s")', [Trim(Body)]));
    Journal.Add(CharsOf('NIL ', 140));
    Body := ReadWhole(Journal.FileName);
    Check('止めたあとは書かない', Pos('NIL', Body) = 0,
      Format('(中身: "%s")', [Trim(Body)]));

    { 語間が来ないまま延々と続いても、上限で折る。折らないと、落ちたときに
      失われる量に限りがなくなる。
      A run with no word space is broken at the limit; without one there would be
      no bound on how much is lost. }
    Journal.Enabled := True;
    Journal.Add(CharsOf(StringOfChar('X', JOURNAL_MAX_LINE + 5), 200));
    Check('語間が来なくても上限で折る', Journal.LinesWritten >= 5,
      Format('(%d 行)', [Journal.LinesWritten]));
  finally
    Journal.Free;
  end;

  { 書けない場所を指されても、例外を投げずに理由を残すこと。受信の脈動のたびに
    例外が上がると、受信そのものが続けられない。
    An unwritable location must leave a reason rather than raise: an exception on
    every pulse of the receive loop would stop reception itself. }
  Bad := TTranscriptJournal.Create('/proc/deepcw-cannot-write-here');
  try
    Bad.Enabled := True;
    Bad.StartSession(Origin);
    try
      Bad.Add(CharsOf('CQ ', 0));
      Check('書けなくても例外を投げない', True);
    except
      on E: Exception do
        Check('書けなくても例外を投げない', False, E.Message);
    end;
    Check('書けなかった理由を残す', Bad.LastError <> '', '(理由が空)');
    Check('書けなくても行数は増えない', Bad.LinesWritten = 0,
      Format('(%d 行)', [Bad.LinesWritten]));
  finally
    Bad.Free;
  end;
end;

{ 文字列から、確からしさを指定した局の記録を 1 件作ります。
  Builds one station record from a string, with a given confidence. }
function LogOf(const Text: string; Hz: Double; Sure: Single): TStationLog;
var
  I: Integer;
begin
  Result := Default(TStationLog);
  Result.Id := Round(Hz);
  Result.Hz := Hz;
  Result.LevelDb := 30;
  Result.Analysed := True;
  SetLength(Result.Chars, Length(Text));
  for I := 1 to Length(Text) do
  begin
    Result.Chars[I - 1].Text := Text[I];
    Result.Chars[I - 1].Seconds := (I - 1) * 0.2;
    Result.Chars[I - 1].EndSeconds := Result.Chars[I - 1].Seconds;
    Result.Chars[I - 1].Confidence := Sure;
  end;
  Result.LastSeconds := Length(Text) * 0.2;
end;

procedure TestBandMap;
var
  Logs: TStationLogs;
  Entries: TBandEntries;
  Started: TDateTime;
  I, Repeats: Integer;
  Elapsed: Double;
begin
  WriteLn('DeepCW.BandMap');

  { 交信の形。DE の後ろが送信している局です。**相手局の符号を自局として
    出してはいけません。** }
  SetLength(Logs, 1);
  Logs[0] := LogOf('JA1ABC DE JH2XYZ JH2XYZ K ', 1000, 0.99);
  Entries := BuildBandEntries(Logs, 10);
  Check('DE の後ろを送信局として採る', Entries[0].Callsign = 'JH2XYZ',
    Format('("%s")', [Entries[0].Callsign]));
  Check('2 回出たので一致と見なす', Entries[0].Trust = ctAgreed,
    Format('(%d 回)', [Entries[0].Sightings]));

  { 1 度しか出ていないものは、事実として出してはいけません（要件 FR-J.7）。 }
  Logs[0] := LogOf('JA1ABC DE JH2XYZ K ', 1000, 0.99);
  Entries := BuildBandEntries(Logs, 10);
  Check('1 回きりなら「確認中」どまり', Entries[0].Trust = ctShape,
    Format('(%d 回、%s)', [Entries[0].Sightings,
      TrustCaption(Entries[0].Trust)]));

  { 形が合わないものは候補になりません。 }
  Logs[0] := LogOf('TNX FER QSO 73 ES GL ', 1000, 0.99);
  Entries := BuildBandEntries(Logs, 10);
  Check('呼出符号が無ければ候補も無い', Entries[0].Trust = ctNone,
    Format('("%s")', [Entries[0].Callsign]));

  { CQ を出しているかどうか（要件 FR-J.2）。根拠が古くなれば消えます。 }
  Logs[0] := LogOf('CQ CQ DE JH2XYZ JH2XYZ K ', 1000, 0.99);
  Entries := BuildBandEntries(Logs, 10);
  Check('CQ を出していると分かる', Entries[0].Calling);
  Entries := BuildBandEntries(Logs, 10 + BANDMAP_CALLING_SECONDS + 1);
  Check('根拠が古くなれば CQ の区別が消える', not Entries[0].Calling);

  { 確からしさは、いちばん良かった一度のものを採ります。 }
  Logs[0] := LogOf('CQ DE JH2XYZ JH2XYZ K ', 1000, 0.55);
  Entries := BuildBandEntries(Logs, 10);
  Check('文字の確からしさが伝わる',
    SameValue(Entries[0].Confidence, 0.55, 0.01),
    Format('(%.2f)', [Entries[0].Confidence]));

  { 直近の文字が添えられること。全文は行を選んだときに出します。 }
  Logs[0] := LogOf('CQ CQ DE JH2XYZ JH2XYZ K TNX FER QSO 73 ES GL SK ', 1000, 0.99);
  Entries := BuildBandEntries(Logs, 10);
  Check('直近の文字が添えられる',
    (Length(Entries[0].Recent) > 0) and
    (Length(Entries[0].Recent) <= BANDMAP_RECENT_CHARS),
    Format('("%s")', [Entries[0].Recent]));

  { 密集がそのまま伝わること（要件 FR-J.6）。 }
  SetLength(Logs, 1);
  Logs[0] := LogOf('CQ DE JH2XYZ ', 1000, 0.99);
  Logs[0].Crowded := 2;
  Entries := BuildBandEntries(Logs, 10);
  Check('密集が伝わる', Entries[0].Crowded = 2);

  { **「能力の都合で読んでいない」と「送信を止めた」を取り違えないこと**
    （要件 FR-I.7）。取り違えると、止めただけの局を「切り捨てた」と見せます。
    **Not being read for want of capacity must not be confused with having
    stopped** (requirement FR-I.7); confusing them shows a station that merely
    stopped as one that was cut. }
  Logs[0] := LogOf('CQ DE JH2XYZ ', 1000, 0.99);
  Logs[0].Heard := True;
  Logs[0].Analysed := False;
  Entries := BuildBandEntries(Logs, 10);
  Check('聞こえていて読んでいなければ切り捨て', Entries[0].Cut);

  Logs[0] := LogOf('CQ DE JH2XYZ ', 1000, 0.99);
  Logs[0].Heard := False;
  Logs[0].Analysed := False;
  Entries := BuildBandEntries(Logs, 10);
  Check('聞こえていなければ切り捨てではない', not Entries[0].Cut);

  Logs[0] := LogOf('CQ DE JH2XYZ ', 1000, 0.99);
  Logs[0].Heard := True;
  Logs[0].Analysed := True;
  Entries := BuildBandEntries(Logs, 10);
  Check('読んでいれば切り捨てではない', not Entries[0].Cut);

  { 24 局 × 4000 文字でも、翻訳が目に見える遅れにならないこと。一覧は毎秒
    作り直します。
    The translation must stay imperceptible at 24 stations of 4000 characters;
    the list is rebuilt every second. }
  SetLength(Logs, 24);
  for I := 0 to 23 do
  begin
    Logs[I] := LogOf(
      StringOfChar(' ', 0) + 'CQ CQ DE JH2XYZ JH2XYZ K ', 800 + I * 100, 0.99);
    while Length(Logs[I].Chars) < 4000 do
      Logs[I].Chars := Concat(Logs[I].Chars, Logs[I].Chars);
    SetLength(Logs[I].Chars, 4000);
  end;
  Started := Now;
  for Repeats := 1 to 5 do
    Entries := BuildBandEntries(Logs, 1000);
  Elapsed := MilliSecondsBetween(Now, Started) / 5;
  WriteLn(Format('    24 局 × 4000 文字の翻訳: %.1f ms', [Elapsed]));
  Check('24 局 × 4000 文字でも 100 ms 未満', Elapsed < 100,
    Format('(%.1f ms)', [Elapsed]));
end;

var
  ModelMeta, MetadataPath: string;
{ 強制終了に耐えることを、本当に強制終了して確かめるための入口です。

  「閉じる前にファイルに残っている」ところまでは通常の試験で押さえられますが、
  **本当に kill されたときに残るか**は、プロセスを殺してみないと分かりません。
  この引数を渡すと、記録を数行書いてから終わらずに待ちます。外から殺して、
  ファイルの中身を見てください（要件 FR-B.6、`tools/journal_kill_test.sh`）。

  The entry point for checking survival of a kill by actually being killed.

  An ordinary test can show that the bytes reach the file before it is closed,
  but **whether they survive a real kill** is only answered by killing the
  process. Given this argument, a few lines are journalled and then the program
  waits to be killed from outside and the file inspected (requirement FR-B.6,
  `tools/journal_kill_test.sh`). }
procedure RunUntilKilled(const Directory: string);
var
  Journal: TTranscriptJournal;
begin
  Journal := TTranscriptJournal.Create(Directory);
  Journal.Enabled := True;
  Journal.StartSession(EncodeDate(2026, 9, 4) + EncodeTime(12, 0, 0, 0));
  Journal.Add(CharsOf('CQ CQ DE JH2XYZ K ', 0));
  WriteLn(Journal.FileName);
  Flush(Output);
  { 意図的に閉じません。ここで殺されても行が残っていることが要件です。
    Deliberately never closed: the requirement is that the lines are there even
    when the process is killed at this point. }
  while True do
    Sleep(200);
end;

begin
  MetadataPath := '';
  if ParamStr(1) = '--journal-until-killed' then
  begin
    RunUntilKilled(ParamStr(2));
    Halt(0);
  end;
  if ParamCount >= 1 then MetadataPath := ParamStr(1);
  if MetadataPath = '' then MetadataPath := LocateDataFile('model.onnx.json');

  Meta := TDeepCWMetadata.Create;
  try
    Meta.LoadFromFile(MetadataPath);
  except
    on E: Exception do
    begin
      WriteLn(StdErr, 'メタデータを読めません: ', E.Message);
      Halt(2);
    end;
  end;

  WriteLn('DSP と同調の数値検証 / DSP and tuning numeric checks');
  WriteLn;
  try
    TestQuantize;
    TestResample;
    TestFrequencyShift;
    TestWideSlice;
    TestTrackTone;
    TestBandPass;
    TestResampleBandLimited;
    TestHistory;
    TestJournal;
    TestBandMap;
  finally
    Meta.Free;
  end;

  WriteLn;
  if Failures = 0 then
    WriteLn('すべての数値検証に通りました。')
  else
    WriteLn(Format('%d 件が通りませんでした。', [Failures]));
  Halt(Ord(Failures > 0));
  ModelMeta := ModelMeta;
end.
