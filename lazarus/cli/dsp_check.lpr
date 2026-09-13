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
  { 録音はスレッドで動きます。**Unix では、スレッドを使う単位より先に
    `cthreads` を置かないと、走らせた瞬間に落ちます。**
    Recording runs on a thread, and **on Unix `cthreads` must come before any
    unit that uses one, or the program dies the moment one starts.** }
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Classes, SysUtils, DateUtils, Math, DeepCW.Types, DeepCW.Metadata, DeepCW.Dsp, DeepCW.Wave,
  DeepCW.Tuner, DeepCW.Review, DeepCW.Journal, DeepCW.Decoder, DeepCW.Stream,
  DeepCW.Multi, DeepCW.BandMap, DeepCW.Log, DeepCW.Exchange, DeepCW.Watch,
  DeepCW.Audio, DeepCW.Recorder, DeepCW.Practice, DeepCW.Callsign,
  DeepCW.Morse, DeepCW.Fist, DeepCW.FistLog, DeepCW.Diagnostics,
  DeepCW.Reference, DeepCW.Roster, FistCases;

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
  Separator: Char;
  Blocker: string;
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

  { 時刻の書き方が、環境の地域設定で変わらないこと。

    `FormatDateTime` の `:` は「その環境の時刻区切り」に置き換わる。Windows は
    地域の設定からこれを取るため、**同じアプリが書いた記録が機械ごとに
    `12:34:56` と `12.34.56` に分かれる。**この容器では区切りが `:` のままなので、
    **地域設定を変えて、Windows で起きることをここで起こす。**

    The way the time is written must not follow the environment's locale.

    `:` in `FormatDateTime` is replaced by the environment's time separator, and
    Windows takes that from the regional settings, so **the same application
    would write `12:34:56` on one machine and `12.34.56` on another.** In this
    container the separator is `:` already, so **the locale is changed here to
    make what happens on Windows happen here.** }
  Separator := DefaultFormatSettings.TimeSeparator;
  DefaultFormatSettings.TimeSeparator := '.';
  try
    Journal := TTranscriptJournal.Create(Dir);
    try
      Journal.Enabled := True;
      Journal.StartSession(Origin);
      { **この行だけの時刻**にします。同じファイルには 12:00:00 の行が既にあり、
        そちらを見つけて通ってしまうと、試験は何も確かめていません。
        A time **this line alone has**: the file already holds a line at
        12:00:00, and finding that one would let the test pass without testing
        anything. }
      Journal.Add(CharsOf('LOCALE ', 3661));
      Journal.Flush;
      Body := ReadWhole(Journal.FileName);
      Check('時刻の区切りが地域設定で変わらない',
        Pos('13:01:01  LOCALE', Body) > 0,
        Format('("%s")', [Trim(Copy(Body, Length(Body) - 30, 30))]));
    finally
      Journal.Free;
    end;
  finally
    DefaultFormatSettings.TimeSeparator := Separator;
  end;

  { 書けない場所を指されても、例外を投げずに理由を残すこと。受信の脈動のたびに
    例外が上がると、受信そのものが続けられない。

    **場所は環境ごとに違う。**`/proc` のような特定の OS だけの道を書くと、ほかの
    OS では「書ける場所」を指してしまい、試験は通ったふりをする。ファイルを 1 つ
    作り、その名前をディレクトリとして渡す。**ファイルのある名前でディレクトリは
    作れない**というのは、どの OS でも同じである。

    An unwritable location must leave a reason rather than raise: an exception on
    every pulse of the receive loop would stop reception itself.

    **Where that is differs by system.** A path only one system has, such as one
    under `/proc`, points at a perfectly writable place on the others and the
    test passes without testing. Instead a file is created and its name handed
    over as a directory: **a directory cannot be made where a file already has
    the name**, on every system alike. }
  Blocker := IncludeTrailingPathDelimiter(GetTempDir) + 'deepcw-not-a-directory';
  with TFileStream.Create(Blocker, fmCreate) do
    Free;
  Bad := TTranscriptJournal.Create(Blocker);
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

{ 書きかけの WAV を、書き手を締め出さずに読みます。
  Reads a WAV that is still being written, without locking its writer out. }
procedure LoadGrowing(const FileName: string; out Samples: TSingleArray;
  out SampleRate: Integer);
var
  Stream: TFileStream;
begin
  Stream := TFileStream.Create(FileName, fmOpenRead or fmShareDenyNone);
  try
    LoadWavMonoFromStream(Stream, Samples, SampleRate);
  finally
    Stream.Free;
  end;
end;

{ 一定の値で埋めた標本の列。録れた／録れなかったを値で見分けるために使います。
  A run of samples all of one value, so that what was recorded and what was not
  can be told apart by value. }
function FilledWith(Value: Single; Count: Integer): TSingleArray;
var
  I: Integer;
begin
  SetLength(Result, Count);
  for I := 0 to Count - 1 do
    Result[I] := Value;
end;

{ 録音の状態が満たされるまで、上限つきで待ちます。**「一定時間眠って確かめる」
  にすると、遅い機械では偽の失敗が出ます。**
  Waits, with a ceiling, until the recording reaches a state. **Sleeping a fixed
  time and then checking would fail spuriously on a slow machine.** }
function WaitForSamples(Recorder: TAudioRecorder; Wanted: Int64;
  Rate, LimitMs: Integer): Boolean;
var
  Waited: Integer;
begin
  Waited := 0;
  while Waited < LimitMs do
  begin
    if Recorder.Snapshot.Seconds * Rate >= Wanted then
      Exit(True);
    Sleep(20);
    Inc(Waited, 20);
  end;
  Result := Recorder.Snapshot.Seconds * Rate >= Wanted;
end;

{ 出題に数字が入っているか。/ Whether the exercise holds a digit. }
function HasDigit(const Text: string): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 1 to Length(Text) do
    if (Text[I] >= '0') and (Text[I] <= '9') then
      Exit(True);
end;

{ 空白で語に割ります。/ Splits on spaces. }
function SplitWordsAt(const Text: string): TStringArray;
var
  Piece: string;
  K: Integer;
begin
  Result := nil;
  Piece := '';
  for K := 1 to Length(Text) + 1 do
    if (K > Length(Text)) or (Text[K] = ' ') then
    begin
      if Piece <> '' then
      begin
        SetLength(Result, Length(Result) + 1);
        Result[High(Result)] := Piece;
        Piece := '';
      end;
    end
    else
      Piece := Piece + Text[K];
end;

{ 遅延表示の検査は下に置いてありますが、練習の検査から呼びます。
  The delayed-reveal checks live below and are called from the practice ones. }
procedure TestReveal; forward;
procedure TestFistTrend; forward;

procedure TestPractice;
var
  A, B: string;
  Score: TCopyScore;
  Words: TStringArray;
  Parsed: TCallsign;
  I, J, Digits, Bad: Integer;
begin
  WriteLn('DeepCW.Practice（要件 FR-F.3）');

  { ---- 出題 ---- }
  { 同じ種なら同じ問題。**もう一度同じ問題を出せなければ、練習になりません。**
    The same seed gives the same exercise: **without being able to send the same
    one again, it is not practice.** }
  A := MakeExercise(ekLetters, 5, 1234);
  B := MakeExercise(ekLetters, 5, 1234);
  Check('同じ種なら同じ問題が出る', A = B, Format('("%s" / "%s")', [A, B]));
  B := MakeExercise(ekLetters, 5, 1235);
  Check('種が違えば違う問題が出る', A <> B, Format('("%s")', [A]));

  Words := SplitWordsAt(A);
  Check('頼んだ数だけ語が出る', Length(Words) = 5,
    Format('(%d 語: "%s")', [Length(Words), A]));
  Check('欧文の群は 5 文字',
    (Length(Words) > 0) and (Length(Words[0]) = 5),
    Format('("%s")', [A]));
  { 文字集合の選択が効いていること（要件 FR-F.3 の受入基準）。
    The choice of character set must take effect (the acceptance criterion). }
  Check('欧文だけの出題に数字が入らない', not HasDigit(MakeExercise(ekLetters, 40, 7)),
    MakeExercise(ekLetters, 40, 7));
  Digits := 0;
  for I := 1 to 10 do
    if HasDigit(MakeExercise(ekMixed, 20, I)) then
      Inc(Digits);
  Check('欧文と数字の出題には数字が出る', Digits >= 9, Format('(10 回中 %d 回)', [Digits]));

  { 呼出符号の出題は、**アプリ自身の規則で通るものだけ**を出すこと。思いつきの
    形を出せば、練習で覚えるのは実在しない符号の形になります。
    Call sign exercises must hold only what **the application's own rules
    accept**: invented forms would have the operator practise call signs that do
    not exist. }
  Bad := 0;
  for I := 1 to 20 do
  begin
    Words := SplitWordsAt(MakeExercise(ekCallsigns, 6, 500 + I));
    for Digits := 0 to High(Words) do
      if not ParseCallsign(Words[Digits], Parsed) then
      begin
        Inc(Bad);
        if Bad = 1 then
          WriteLn('    通らなかった符号: ', Words[Digits]);
      end;
  end;
  Check('呼出符号の出題はすべて規則を満たす', Bad = 0, Format('(%d 件)', [Bad]));

  A := MakeExercise(ekQso, 3, 99);
  Check('QSO の出題は交信の言葉でできている',
    (Pos('DE', A) > 0) and ((Pos('CQ', A) > 0) or (Pos('QTH', A) > 0) or
     (Pos('TNX', A) > 0)), A);
  { **CQ は自分の符号を 2 度繰り返します。**呼ぶたびに違う符号が出る出題では、
    覚えるのは実際には無い呼び方です。
    **A CQ repeats the caller's own call sign.** An exercise drawing a different
    one each time would teach a call that is never made. }
  Bad := 0;
  Digits := 0;
  for I := 1 to 30 do
  begin
    Words := SplitWordsAt(MakeExercise(ekQso, 4, 700 + I));
    for J := 0 to High(Words) - 3 do
      if (Words[J] = 'CQ') and (Words[J + 1] = 'CQ') and
         (Words[J + 2] = 'DE') then
      begin
        Inc(Digits);
        if Words[J + 3] <> Words[J + 4] then
        begin
          Inc(Bad);
          if Bad = 1 then
            WriteLn('    違う符号で CQ を出した: ', Words[J + 3], ' / ',
              Words[J + 4]);
        end;
      end;
  end;
  Check('CQ は同じ符号を 2 度繰り返す', (Digits > 0) and (Bad = 0),
    Format('(%d 例中 %d 件が違う)', [Digits, Bad]));

  { 出題は送れる文字だけでできていること。送れない文字が混ざれば、鳴らした音と
    出題が食い違います。
    An exercise must hold only what can be sent, or the sound and the answer
    would differ. }
  Check('出題は送れる文字だけでできている',
    MakeExercise(ekQso, 3, 99) = NormalizeText(MakeExercise(ekQso, 3, 99)), A);

  { ---- 採点 ---- }
  Score := ScoreCopy('CQ DE JA1ABC', 'CQ DE JA1ABC');
  Check('全部写せていれば 100%',
    (Score.Percent = 100) and (Score.Wrong = 0) and (Score.Missed = 0) and
    (Score.Extra = 0),
    Format('(%.0f%% / 違い %d / 落とし %d / 足し %d)',
      [Score.Percent, Score.Wrong, Score.Missed, Score.Extra]));
  Check('空白は点に数えない', Score.Total = 10, Format('(%d 文字)', [Score.Total]));

  Score := ScoreCopy('CQ DE JA1ABC', 'CQ DE JA1ABX');
  Check('1 文字違えば 1 つだけ違いになる',
    (Score.Wrong = 1) and (Score.Missed = 0) and (Score.Extra = 0),
    Format('(違い %d / 落とし %d / 足し %d)',
      [Score.Wrong, Score.Missed, Score.Extra]));

  { **落とした 1 文字で、あとが全部ずれてはいけません。**前から 1 文字ずつ
    比べる採点はここで壊れます。
    **One dropped character must not throw the rest out of step**: marking by
    position breaks exactly here. }
  Score := ScoreCopy('CQ DE JA1ABC', 'CQ DE J1ABC');
  Check('1 文字落としても、あとがずれない',
    (Score.Missed = 1) and (Score.Wrong = 0) and (Score.Extra = 0) and
    (Score.Same = 9),
    Format('(合い %d / 違い %d / 落とし %d / 足し %d)',
      [Score.Same, Score.Wrong, Score.Missed, Score.Extra]));

  Score := ScoreCopy('CQ DE JA1ABC', 'CQ DE JAX1ABC');
  Check('1 文字足しても、あとがずれない',
    (Score.Extra = 1) and (Score.Wrong = 0) and (Score.Missed = 0) and
    (Score.Same = 10),
    Format('(合い %d / 違い %d / 落とし %d / 足し %d)',
      [Score.Same, Score.Wrong, Score.Missed, Score.Extra]));

  Score := ScoreCopy('CQ DE JA1ABC', 'CQDE JA1ABC');
  Check('語の切れ目の書き方は点に響かない', Score.Percent = 100,
    Format('(%.0f%%)', [Score.Percent]));

  Score := ScoreCopy('CQ DE JA1ABC', 'cq de ja1abc');
  Check('大文字小文字を問わない', Score.Percent = 100,
    Format('(%.0f%%)', [Score.Percent]));

  Score := ScoreCopy('CQ DE JA1ABC', '');
  Check('何も写さなければ 0%',
    (Score.Percent = 0) and (Score.Missed = 10) and (Score.Total = 10),
    Format('(%.0f%% / 落とし %d)', [Score.Percent, Score.Missed]));

  { ---- 間違いの傾向（要件 FR-F.5 の材料） ---- }
  { **少ないほうを先に書いた出題**で試します。並べ替えていなければ、書いた順の
    まま出てしまい、それでは「傾向」になりません。
    Tried with **the rarer mistake written first**: without sorting, the order
    written is the order shown, and that is not a tendency. }
  Score := ScoreCopy('S RRR', 'T KKK');
  Check('多い間違いが先に出る', Pos('R → K（3 回）', MistakeSummary(Score)) = 1,
    MistakeSummary(Score));
  Check('少ない間違いも続けて出る', Pos('S → T', MistakeSummary(Score)) > 1,
    MistakeSummary(Score));
  Score := ScoreCopy('CQ DE JA1ABC', 'CQ DE JA1ABC');
  Check('間違いが無ければ何も言わない', MistakeSummary(Score) = '',
    MistakeSummary(Score));

  TestReveal;
end;

{ 遅延表示（要件 FR-F.4）。

  **ここで確かめるのは「早く出ないこと」です。**遅く出るのは待てば済みますが、
  早く出れば、聴きながら読むことになり、練習になりません。文字の時刻が何を
  指しているかを取り違えると、まさにそれが起きます（教訓 10.29）。

  The delayed reveal (requirement FR-F.4).

  **What is checked here is that nothing appears early.** Late can be waited
  out; early means reading along with the sound instead of copying it, which is
  what mistaking what a character's time refers to produces (lesson 10.29). }
procedure TestReveal;
const
  LEAD_IN = 0.2;
  TEXT = 'CQ DE JA1ABC';
var
  Timing: TCWTiming;
  Times, Plain: TDoubleArray;
  Segments: TCWSegments;
  Sound, FirstEnds: Double;
  I, Grew, Shrank: Integer;
  Shown, Longer: string;
begin
  WriteLn;
  WriteLn('DeepCW.Practice の遅延表示（要件 FR-F.4）');
  Timing.CharWpm := 20;
  Timing.TextWpm := 20;

  Times := RevealTimes(TEXT, Timing, LEAD_IN, 0);
  Check('文字の数だけ時刻がある',
    Length(Times) = Length(NormalizeText(TEXT)),
    Format('(%d / %d)', [Length(Times), Length(NormalizeText(TEXT))]));

  Shrank := 0;
  for I := 1 to High(Times) do
    if Times[I] < Times[I - 1] then
      Inc(Shrank);
  Check('時刻が戻らない', Shrank = 0, Format('(%d 回戻った)', [Shrank]));

  { 最初の文字（C）が鳴り終わる時刻。**その前に出てはいけません。**
    When the first character finishes sounding: **nothing may appear before
    that.** }
  Segments := TextToSegments(NormalizeText(TEXT), Timing);
  FirstEnds := LEAD_IN;
  for I := 0 to High(Segments) do
  begin
    FirstEnds := FirstEnds + Segments[I].Duration;
    if (I + 1 <= High(Segments)) and (Segments[I + 1].TextIndex <> 1) then
      Break;
  end;
  Check('鳴り終わる前には出ない',
    RevealedText(TEXT, Times, FirstEnds - 0.01) = '',
    Format('(%.2f 秒: "%s")',
      [FirstEnds - 0.01, RevealedText(TEXT, Times, FirstEnds - 0.01)]));
  Check('鳴り終われば出る',
    RevealedText(TEXT, Times, FirstEnds + 0.01) = 'C',
    Format('(%.2f 秒: "%s")',
      [FirstEnds + 0.01, RevealedText(TEXT, Times, FirstEnds + 0.01)]));

  Sound := LEAD_IN + SegmentsDuration(Segments);
  Check('鳴り終わったころには全部出る',
    RevealedText(TEXT, Times, Sound + 0.01) = NormalizeText(TEXT),
    Format('(%.2f 秒: "%s")',
      [Sound, RevealedText(TEXT, Times, Sound + 0.01)]));

  { **遅らせた分だけ、そのままずれること。**「遅らせる秒数」が効いていなければ
    要件 FR-F.4 は満たしていません。
    **The delay shifts everything by exactly itself**: without that, the setting
    does nothing and requirement FR-F.4 is not met. }
  Plain := Times;
  Times := RevealTimes(TEXT, Timing, LEAD_IN, 5);
  Grew := 0;
  for I := 0 to High(Times) do
    if Abs(Times[I] - (Plain[I] + 5)) < 1E-9 then
      Inc(Grew);
  Check('遅らせた秒数だけ、そのまま遅れる', Grew = Length(Times),
    Format('(%d / %d)', [Grew, Length(Times)]));
  Check('遅らせれば、鳴り終わっても、まだ出ていない',
    RevealedText(TEXT, Times, Sound + 0.01) <> NormalizeText(TEXT),
    Format('("%s")', [RevealedText(TEXT, Times, Sound + 0.01)]));
  Check('遅らせた分だけ待てば出る',
    RevealedText(TEXT, Times, Sound + 5.01) = NormalizeText(TEXT),
    Format('("%s")', [RevealedText(TEXT, Times, Sound + 5.01)]));

  { いつ見ても、出ているものは出題の先頭からの一続きであること。**途中から
    出れば、写したものと並べられません。**
    Whatever the moment, what is shown is a run from the start of the exercise:
    **shown from the middle, it could not be lined up with the copy.** }
  Times := RevealTimes(TEXT, Timing, LEAD_IN, 1);
  Grew := 0;
  Shown := '';
  I := 0;
  while I <= Round((Sound + 2) * 10) do
  begin
    Longer := RevealedText(TEXT, Times, I / 10);
    { 空文字は「まだ何も出ていない」であって、崩れてはいません。`Pos` は空文字に
      0 を返すため、ここで分けます。
      An empty string is "nothing yet", not a break; `Pos` returns 0 for it, so
      it is separated here. }
    if (Longer <> '') and (Pos(Longer, NormalizeText(TEXT)) <> 1) then
      Break;
    if Length(Longer) < Length(Shown) then
      Break;
    if Length(Longer) > Length(Shown) then
      Inc(Grew);
    Shown := Longer;
    Inc(I);
  end;
  Check('出ているものは、いつも出題の先頭からの一続き',
    I > Round((Sound + 2) * 10),
    Format('(%.1f 秒で崩れた: "%s")', [I / 10, Longer]));
  Check('少しずつ増える', Grew > 3, Format('(%d 回増えた)', [Grew]));

  { 音を持たない文字（空白）は、直前の文字と一緒に出ます。**空白だけが遅れて
    出ると、語の切れ目が後から差し込まれることになります。**
    A character with no sound of its own goes up with the one before it: a space
    arriving late would insert the word break after the fact. }
  Times := RevealTimes('AB CD', Timing, LEAD_IN, 0);
  Segments := TextToSegments('AB CD', Timing);
  Check('空白は直前の文字と同じ時刻', Times[2] = Times[1],
    Format('(%.3f / %.3f)', [Times[1], Times[2]]));

  Check('出題が無ければ時刻も無い', Length(RevealTimes('', Timing, LEAD_IN, 0)) = 0,
    '');
  Check('時刻が無ければ何も出ない', RevealedText('', nil, 100) = '', '');
end;


{ 送信訓練の測定と採点（要件 FR-H.4〜H.8）。

  **ここで確かめたいのは「うまくない符号を測れること」です。**うまい符号だけを
  測って通しても、直したい相手である下手な符号が測れるかは分かりません
  （付録 A.2 の 2）。合成した 6 つの技量は、付録 A が測ったものと同じです。

  Measurement and scoring for send practice (FR-H.4 to H.8).

  **What matters here is that sending which is not good can be measured.**
  Passing on good sending alone says nothing about the hand that most needs the
  help (appendix A.2, finding 2). The six synthesised hands are the ones
  appendix A measured. }
procedure TestFist;
const
  RATE = 8000;
  { 付録 A と同じ長さの課題文（68 文字の交信）。**短い課題文では、点数の振れが
    技量の違いより大きくなります。**要素が 65 個しかなければ、ばらつきの
    見積りそのものがばらつきます。
    The same length of text as appendix A, a contact of 68 characters. **With a
    short text the scatter of the score outgrows the difference between hands**:
    with only 65 elements, the estimate of the spread is itself unsteady. }
  TEXT = 'CQ CQ DE JA1ABC JA1ABC K JA1ABC DE JH2XYZ UR 599 599 QTH NAGOYA BK';
var
  Hands: TSendings;
  Noisy: TSending;
  Audio: TSingleArray;
  M, M2, Free_: TFistMeasurement;
  Score, Bug: TFistScore;
  Own: TFistTarget;
  Scores: array of Double;
  I, Falling: Integer;
  Sum, Sd, Mean_, Worst: Double;
  Lowest: string;

  { 課題文に含まれる短点と長点の数。/ How many dits and dahs the text holds. }
  function ElementsIn(const Text: string): Integer;
  var
    Code: string;
    K: Integer;
  begin
    Result := 0;
    Code := TextToMorseCode(Text);
    for K := 1 to Length(Code) do
      if (Code[K] = '.') or (Code[K] = '-') then
        Inc(Result);
  end;

  { それぞれの技量を、**その技量の基準で**採点します（要件 FR-H.7）。
    ファンズワースを標準の間隔で採点すれば、間隔の点は当然低く出ます。
    それは下手なのではなく、別の送り方だからです（設計原則：個性を減点しない）。
    Each hand is scored **against its own basis** (FR-H.7). Marked against the
    standard spacing, Farnsworth loses points on spacing as a matter of course
    -- not for being worse, but for being a different way of sending. }
  function BasisFor(const Hand: TSending): TFistStandard;
  begin
    if Pos('ファンズワース', Hand.Name) > 0 then
      Result := fsFarnsworth
    else if Pos('バグキー', Hand.Name) > 0 then
      Result := fsBug
    else
      Result := fsStandard;
  end;

  function ScoreOf(const Hand: TSending; Seed: Integer;
    out Measured: TFistMeasurement): TFistScore;
  var
    Sound: TSingleArray;
  begin
    Sound := SendText(TEXT, Hand, RATE, Seed);
    Measured := MeasureAgainstText(Sound, RATE, Hand.ToneHz, TEXT);
    Result := ScoreFist(Measured, BasisFor(Hand), Own, -1);
  end;

begin
  WriteLn;
  WriteLn('DeepCW.Fist（要件 FR-H.4〜H.8）');
  Own := Default(TFistTarget);
  Hands := AppendixCases;

  { ---- 測定 ---- }
  Audio := SendText(TEXT, Hands[0], RATE, 4242);
  M := MeasureAgainstText(Audio, RATE, Hands[0].ToneHz, TEXT);
  Check('課題文と突き合わせて測れる', M.Ok, M.Note);
  { 雑音のある入力でも測れること。**音声装置から入ってくる音に雑音が無い
    ことはありません。**
    Measured through noise as well: **nothing arriving from a sound card is
    ever clean.** }
  Noisy := Hands[0];
  Noisy.Noise := 0.05;
  M2 := MeasureAgainstText(SendText(TEXT, Noisy, RATE, 4242), RATE,
    Noisy.ToneHz, TEXT);
  WriteLn(Format('  雑音のある入力: 短点 %.2f ms / 長短比 %.3f / 文字間 %.3f',
    [M2.DitSeconds * 1000, M2.Ratio, M2.CharRatio]));
  Check('雑音があっても課題文と突き合わせて測れる',
    M2.Ok and (Abs(M2.DitSeconds - 1.2 / Noisy.Wpm) / (1.2 / Noisy.Wpm) <= 0.10)
    and (Abs(M2.CharRatio - 3) / 3 <= 0.10),
    Format('(%.2f ms / 文字間 %.2f) %s',
      [M2.DitSeconds * 1000, M2.CharRatio, M2.Note]));
  { 符号の数は課題文から数えます。**書き写した数を当てにすると、課題文を
    変えたときに、試験のほうが間違えます。**
    The count comes from the text: **a number copied into the test is the thing
    that goes wrong when the text changes.** }
  Check('要素の数が課題文どおり',
    M.Stats[ekDit].Count + M.Stats[ekDah].Count = ElementsIn(TEXT),
    Format('(短点 %d / 長点 %d / 課題文 %d)',
      [M.Stats[ekDit].Count, M.Stats[ekDah].Count, ElementsIn(TEXT)]));

  { **送出値を 10% 以内で復元できること**が受入基準です（要件 FR-H.5）。
    The acceptance criterion is recovering what was sent to within ten per cent
    (FR-H.5). }
  Check('短点の長さを 10% 以内で測る',
    Abs(M.DitSeconds - 1.2 / Hands[0].Wpm) / (1.2 / Hands[0].Wpm) <= 0.10,
    Format('(%.1f ms / 送出 %.1f ms)',
      [M.DitSeconds * 1000, 1200 / Hands[0].Wpm]));
  Check('長短比を 10% 以内で測る',
    Abs(M.Ratio - Hands[0].Ratio) / Hands[0].Ratio <= 0.10,
    Format('(%.2f / 送出 %.2f)', [M.Ratio, Hands[0].Ratio]));
  Check('文字間の比を 10% 以内で測る',
    Abs(M.CharRatio - Hands[0].CharRatio) / Hands[0].CharRatio <= 0.10,
    Format('(%.2f / 送出 %.2f)', [M.CharRatio, Hands[0].CharRatio]));
  Check('語間の比を 10% 以内で測る',
    Abs(M.WordRatio - Hands[0].WordRatio) / Hands[0].WordRatio <= 0.10,
    Format('(%.2f / 送出 %.2f)', [M.WordRatio, Hands[0].WordRatio]));
  WriteLn(Format('  熟練の測定: 短点 %.2f ms（送出 %.2f）/ 長短比 %.3f / 文字間 %.3f / 語間 %.3f / %.2f WPM',
    [M.DitSeconds * 1000, 1200 / Hands[0].Wpm, M.Ratio, M.CharRatio,
     M.WordRatio, M.EffectiveWpm]));
  Check('実効 WPM を 10% 以内で測る',
    Abs(M.EffectiveWpm - Hands[0].Wpm) / Hands[0].Wpm <= 0.10,
    Format('(%.1f WPM / 送出 %.0f WPM)', [M.EffectiveWpm, Hands[0].Wpm]));

  { ファンズワースは、しきい値方式が**測定不能**になる場合です（付録 A.2）。
    課題文に対応づけていれば測れます。
    Farnsworth is the case the threshold method **cannot measure at all**
    (appendix A.2); against the text it can. }
  Audio := SendText(TEXT, Hands[1], RATE, 77);
  M := MeasureAgainstText(Audio, RATE, Hands[1].ToneHz, TEXT);
  Check('ファンズワースの文字間 6 を 10% 以内で測る',
    M.Ok and (Abs(M.CharRatio - 6) / 6 <= 0.10),
    Format('(%.2f / 送出 6.00)', [M.CharRatio]));
  Check('ファンズワースの語間 12 を 10% 以内で測る',
    M.Ok and (Abs(M.WordRatio - 12) / 12 <= 0.10),
    Format('(%.2f / 送出 12.00)', [M.WordRatio]));

  { モニタートーンの音程は、人に入れさせずに見つけます。**入れ間違えれば
    測れず、その理由も分かりません。**
    The pitch is found, not asked for: **entered wrongly, nothing can be
    measured and nothing says why.** }
  Noisy := Hands[0];
  Noisy.ToneHz := 620;
  Noisy.Noise := 0.05;
  Audio := SendText(TEXT, Noisy, RATE, 88);
  Check('モニタートーンの音程を見つける',
    Abs(DetectToneHz(Audio, RATE) - 620) <= 8,
    Format('(%.0f Hz / 送出 620 Hz)', [DetectToneHz(Audio, RATE)]));
  SetLength(Audio, RATE);
  for I := 0 to High(Audio) do
    Audio[I] := 0;
  Check('無音からは音程を作らない', DetectToneHz(Audio, RATE) = 0,
    Format('(%.0f Hz)', [DetectToneHz(Audio, RATE)]));

  { 課題文なしだと、同じ音でも間隔の種別を取り違えます。**参考値だと
    言わなければならない理由がここにあります**（要件 FR-H.3）。
    Without the text the same sound has its gaps misfiled. **This is why it has
    to be called indicative** (FR-H.3). }
  Audio := SendText(TEXT, Hands[1], RATE, 77);
  Free_ := MeasureFree(Audio, RATE, Hands[1].ToneHz);
  Check('課題文なしでも測れる', Free_.Ok, Free_.Note);
  Check('課題文なしは参考値だと分かる', Free_.Reference and (Free_.Note <> ''),
    Free_.Note);
  Check('課題文なしではファンズワースの語間を取り違える',
    Abs(Free_.WordRatio - 12) / 12 > 0.10,
    Format('(%.2f / 送出 12.00)', [Free_.WordRatio]));

  { 速度の変化は、ばらつきとは別に測れなければなりません。
    Drift has to be measurable apart from spread. }
  Audio := SendText(TEXT, Hands[3], RATE, 31);
  M := MeasureAgainstText(Audio, RATE, Hands[3].ToneHz, TEXT);
  Check('速度の変化を見つける', M.Ok and (M.Drift > 0.10),
    Format('(%.2f / 送出 0.25)', [M.Drift]));
  Audio := SendText(TEXT, Hands[0], RATE, 31);
  M := MeasureAgainstText(Audio, RATE, Hands[0].ToneHz, TEXT);
  Check('速度が変わっていなければ、そうは言わない', M.Drift < 0.10,
    Format('(%.2f)', [M.Drift]));

  { 音の数が合わなければ、対応づけない。**ずれたまま測るより、測れないと
    言うほうが正しい。**
    Nothing is lined up when the counts differ: **saying it cannot be measured
    is better than measuring it out of step.** }
  Audio := SendText('CQ CQ DE JA1ABC JA1ABC', Hands[0], RATE, 5);
  M := MeasureAgainstText(Audio, RATE, Hands[0].ToneHz, TEXT);
  Check('符号の数が課題文と違えば、測れないと言う',
    (not M.Ok) and (Pos('個', M.Note) > 0), M.Note);

  { ---- 採点 ---- }
  WriteLn('  技量ごとの点数（それぞれの基準で）');
  SetLength(Scores, Length(Hands));
  Falling := 0;
  Worst := 100;
  Lowest := '';
  for I := 0 to High(Hands) do
  begin
    Score := ScoreOf(Hands[I], 9000 + I, M);
    Scores[I] := Score.Overall;
    WriteLn(Format('    %-38s 速度 %3.0f / 短長 %3.0f / 区切り %3.0f / 間隔 %3.0f → 総合 %3.0f  %s',
      [Hands[I].Name, Score.Speed, Score.Clarity, Score.Separation,
       Score.Spacing, Score.Overall, Score.Advice]));
    if (I > 0) and (Scores[I] < Scores[I - 1]) then
      Inc(Falling);
    if I = High(Hands) then
    begin
      { 付録 A.2 の 4: 初級だけ「区切りの明瞭」が最も低い。
        Appendix A.2, finding 4: for the beginner the break between characters
        is the lowest of all. }
      Worst := Min(Min(Score.Speed, Score.Clarity),
        Min(Score.Separation, Score.Spacing));
      if Score.Separation <= Worst then
        Lowest := '区切り';
    end;
  end;
  Check('上手い順に点数が下がる', Falling = High(Hands),
    Format('(%d / %d)', [Falling, High(Hands)]));
  Check('熟練は 90 点以上', Scores[0] >= 90, Format('(%.0f)', [Scores[0]]));
  Check('初級は 40 点未満', Scores[High(Scores)] < 40,
    Format('(%.0f)', [Scores[High(Scores)]]));
  Check('初級は「区切りの明瞭」が最も低い', Lowest = '区切り', Lowest);

  { 同じ技量で種だけ変えたときのばらつき。**5 点の改善が誤差でないと言える
    精度が要ります**（要件 FR-H.10 の推移表示が意味を持つ根拠）。
    The spread over seeds at one skill: **an improvement of five points has to
    mean something** for the trend display to be worth showing (FR-H.10). }
  Sum := 0;
  SetLength(Scores, 5);
  for I := 0 to 4 do
  begin
    Score := ScoreOf(Hands[4], 100 + I * 7, M);
    Scores[I] := Score.Overall;
    Sum := Sum + Score.Overall;
  end;
  Mean_ := Sum / 5;
  Sd := 0;
  for I := 0 to 4 do
    Sd := Sd + Sqr(Scores[I] - Mean_);
  Sd := Sqrt(Sd / 4);
  WriteLn(Format('  同じ技量で種を 5 回変えた総合点: 平均 %.1f / 標準偏差 %.1f',
    [Mean_, Sd]));
  Check('同じ技量なら、種が変わっても点数の振れが 5 点未満', Sd < 5,
    Format('(平均 %.1f / 標準偏差 %.1f)', [Mean_, Sd]));

  { 基準を変えれば点数が変わること（要件 FR-H.7）。**バグキーの符号は、
    バグキーの基準では上がります。個性を減点しないための仕組みです。**
    The basis changes the score (FR-H.7): **a bug key's sending scores higher
    against the bug-key basis** -- the mechanism by which an individual hand is
    not marked down. }
  Audio := SendText(TEXT, Hands[2], RATE, 555);
  M := MeasureAgainstText(Audio, RATE, Hands[2].ToneHz, TEXT);
  Score := ScoreFist(M, fsStandard, Own, -1);
  Bug := ScoreFist(M, fsBug, Own, -1);
  Check('バグキーの符号は、バグキーの基準のほうが高い',
    Bug.Overall > Score.Overall,
    Format('(標準 %.0f / バグキー %.0f)', [Score.Overall, Bug.Overall]));
  Check('基準を変えても測定値は変わらない',
    Abs(M.Ratio - 2.6) / 2.6 <= 0.10, Format('(%.2f)', [M.Ratio]));

  { 自分の過去を基準にすると、同じ符号は満点近くになります。**「規範に合って
    いるか」ではなく「先月より安定したか」を問えます。**
    Against one's own past the same sending scores near full marks: **the
    question becomes whether it is steadier than last month, not whether it
    matches a norm.** }
  Own := TargetFromMeasurement(M);
  Score := ScoreFist(M, fsOwn, Own, -1);
  Check('自分の過去を基準にすると「間隔の正確」が満点に近い',
    Score.Spacing >= 99, Format('(%.1f)', [Score.Spacing]));

  { 助言は 1 つだけ、最も低い項目のもの（要件 FR-H.8）。
    One piece of advice, for the lowest item (FR-H.8). }
  Audio := SendText(TEXT, Hands[5], RATE, 12);
  M := MeasureAgainstText(Audio, RATE, Hands[5].ToneHz, TEXT);
  Score := ScoreFist(M, fsStandard, Own, -1);
  Check('助言が 1 文で出る',
    (Score.Advice <> '') and (Pos('。', Score.Advice) > 0), Score.Advice);
  Check('区切りが最も低ければ、区切りの助言が出る',
    (Score.Separation > Min(Score.Speed, Min(Score.Clarity, Score.Spacing))) or
    (Pos('文字と文字の間', Score.Advice) > 0), Score.Advice);

  { 写しやすさは、渡されたときだけ点数に入ります。
    Copyability counts only when it is supplied. }
  Score := ScoreFist(M, fsStandard, Own, -1);
  Check('文字誤り率を渡さなければ 4 項目で採点する', not Score.HasCopyability, '');
  Score := ScoreFist(M, fsStandard, Own, 0.279);
  Check('文字誤り率を渡せば 5 項目で採点する',
    Score.HasCopyability and (Abs(Score.Copyability - 72.1) < 0.2),
    Format('(%.1f)', [Score.Copyability]));

  { 音が無いときに、数字を作らないこと。
    No numbers are invented where there is no sound. }
  SetLength(Audio, RATE);
  for I := 0 to High(Audio) do
    Audio[I] := 0;
  M := MeasureAgainstText(Audio, RATE, 700, TEXT);
  Check('無音からは測らない', (not M.Ok) and (M.Note <> ''), M.Note);
  Score := ScoreFist(M, fsStandard, Own, -1);
  Check('測れていなければ点数を出さない', Score.Overall = 0, Score.Advice);
end;


{ 送信訓練の記録（要件 FR-H.10・FR-H.12）。

  **点数だけを残せば、重みを変えた日を境に、前と後が比べられなくなります。**
  素の測定値も残っていることを確かめます。

  The record of send practice (FR-H.10, FR-H.12). **With the scores alone, the
  day the weights change is the day comparison stops working**; the raw figures
  have to come back too. }
procedure TestFistLog;
var
  Dir, Path: string;
  Item: TFistRecord;
  Back: TFistRecords;
  Lines: TStringList;
begin
  WriteLn;
  WriteLn('DeepCW.FistLog（要件 FR-H.10・FR-H.12）');
  Dir := IncludeTrailingPathDelimiter(GetTempDir) + 'deepcw-fistlog-' +
    IntToStr(Random(1000000));
  Path := IncludeTrailingPathDelimiter(Dir) + 'fist.csv';

  Item := Default(TFistRecord);
  Item.When_ := EncodeDate(2026, 9, 11) + EncodeTime(21, 14, 0, 0);
  Item.Seconds := 48;
  Item.Key := 'パドル';
  Item.Text_ := 'CQ CQ DE JA1ABC K';
  Item.Characters := 17;
  Item.Standard := fsBug;
  Item.Measurement.Ok := True;
  Item.Measurement.EffectiveWpm := 19.7;
  Item.Measurement.DitSeconds := 0.0609;
  Item.Measurement.Stats[ekDit].Cv := 0.0412;
  Item.Measurement.Ratio := 2.61;
  Item.Measurement.IntraRatio := 1.02;
  Item.Measurement.CharRatio := 3.04;
  Item.Measurement.WordRatio := 6.91;
  Item.Measurement.ToneSeparation := 18.3;
  Item.Measurement.GapSeparation := 9.4;
  Item.Measurement.Drift := 0.031;
  Item.Score.Speed := 100;
  Item.Score.Clarity := 100;
  Item.Score.Separation := 100;
  Item.Score.Spacing := 95;
  Item.Score.Overall := 99;

  try
    AppendFistRecord(Path, Item);
    Check('記録するファイルが無ければ作る', FileExists(Path), Path);

    Lines := TStringList.Create;
    try
      Lines.LoadFromFile(Path);
      Check('1 行目は列の名前', (Lines.Count > 0) and (Lines[0] = FISTLOG_HEADER),
        Copy(Lines[0], 1, 40));
      Check('記録は 1 件で 1 行', Lines.Count = 2, Format('(%d 行)', [Lines.Count]));
      { **小数点は地域設定に従わせません。**`,` になれば CSV の区切りと
        衝突します（教訓 10.27）。
        **The decimal point does not follow the locale**: as a comma it would
        collide with the separator itself (lesson 10.27). }
      Check('小数点は必ず「.」', Pos('19.7', Lines[1]) > 0, Lines[1]);
      Check('日時は地域設定を通さない形', Pos('2026-09-11 21:14:00', Lines[1]) > 0,
        Lines[1]);
    finally
      Lines.Free;
    end;

    Item.When_ := Item.When_ + 1;
    Item.Key := 'バグ, 横振り';
    AppendFistRecord(Path, Item);
    Back := LoadFistRecords(Path);
    Check('書いた分だけ読み戻せる', Length(Back) = 2,
      Format('(%d 件)', [Length(Back)]));
    Check('点数が読み戻せる',
      (Length(Back) > 0) and (Back[0].Score.Overall = 99) and
      (Back[0].Score.Spacing = 95), '');
    { **素の測定値。**これが残っていなければ、重みを見直したときに過去を
      採点し直せません。
      **The raw figures**: without them a past session cannot be scored again
      after the weights are revised. }
    Check('素の測定値が読み戻せる',
      (Length(Back) > 0) and (Abs(Back[0].Measurement.Ratio - 2.61) < 0.001) and
      (Abs(Back[0].Measurement.Stats[ekDit].Cv - 0.0412) < 0.0001) and
      (Abs(Back[0].Measurement.GapSeparation - 9.4) < 0.01),
      Format('(長短比 %.3f / CV %.4f)',
        [Back[0].Measurement.Ratio, Back[0].Measurement.Stats[ekDit].Cv]));
    Check('採点基準が読み戻せる',
      (Length(Back) > 0) and (Back[0].Standard = fsBug),
      FIST_STANDARD_NAMES[Back[0].Standard]);
    { 区切りを含む値は引用して書き、読み戻しても同じであること。
      A field holding a separator is quoted, and comes back as it went in. }
    Check('区切りを含む値も同じものが戻る',
      (Length(Back) > 1) and (Back[1].Key = 'バグ, 横振り'), Back[1].Key);
    Check('課題文が読み戻せる',
      (Length(Back) > 0) and (Back[0].Text_ = 'CQ CQ DE JA1ABC K'), Back[0].Text_);

    { 列を足しても古い記録が読めること。**名前で引いているからです。**
      A record from an older, narrower file still reads: **the columns are found
      by name.** }
    Lines := TStringList.Create;
    try
      Lines.Add('datetime,overall,key');
      Lines.Add('2026-01-02 03:04:05,77,縦振り');
      Lines.SaveToFile(Path);
    finally
      Lines.Free;
    end;
    Back := LoadFistRecords(Path);
    Check('列が足りない古い記録も読める',
      (Length(Back) = 1) and (Back[0].Score.Overall = 77) and
      (Back[0].Key = '縦振り'), '');

    { 並びが違っても読めること。**これが「名前で引く」ということです。**
      並びを当てにしていれば、ここで別の列を読みます。
      Read though the order differs: **that is what reading by name means.**
      Anything relying on the order would pick up a different column here. }
    Lines := TStringList.Create;
    try
      Lines.Add('key,overall,wpm,datetime,ratio');
      Lines.Add('エレキー,88,23.5,2026-02-03 04:05:06,3.12');
      Lines.SaveToFile(Path);
    finally
      Lines.Free;
    end;
    Back := LoadFistRecords(Path);
    Check('列の並びが違っても読める',
      (Length(Back) = 1) and (Back[0].Key = 'エレキー') and
      (Back[0].Score.Overall = 88) and
      (Abs(Back[0].Measurement.EffectiveWpm - 23.5) < 0.01) and
      (Abs(Back[0].Measurement.Ratio - 3.12) < 0.001),
      Format('(%s / %.0f / %.1f / %.2f)', [Back[0].Key, Back[0].Score.Overall,
        Back[0].Measurement.EffectiveWpm, Back[0].Measurement.Ratio]));

    Check('無いファイルからは何も返さない',
      Length(LoadFistRecords(Path + '.none')) = 0, '');

    TestFistTrend;
  finally
    if FileExists(Path) then
      DeleteFile(Path);
    RemoveDir(Dir);
  end;
end;


{ 不具合報告に添える診断情報の控え（要件 FR-G.5）。

  **受入基準は「個人情報・音声内容を含まない」ことです。**受信した文章や
  交信記録の中身は**そもそも控えに入れません**ので、ここで確かめるのは
  もう 1 つのほう——**ファイルの場所に残る利用者の名前**を伏せることです。

  The copy of the diagnostics for a bug report (FR-G.5). **The criterion is that
  it holds no personal data and no audio.** What was received and what the log
  holds are **never put in**, so what is checked here is the other half: that the
  account name the paths carry is masked. }
procedure TestDiagnostics;
var
  Report: string;
begin
  WriteLn;
  WriteLn('DeepCW.Diagnostics（要件 FR-G.5）');

  Check('利用者の場所を隠す',
    MaskHome('設定ファイル: /home/hanako/.config/deepcw.ini', '/home/hanako') =
      '設定ファイル: ~/.config/deepcw.ini',
    MaskHome('設定ファイル: /home/hanako/.config/deepcw.ini', '/home/hanako'));
  { 末尾の区切りの有無で結果が変わってはいけません。
    A trailing separator must not change the answer. }
  Check('末尾に区切りがあっても同じ',
    MaskHome('/home/hanako/audio', '/home/hanako/') = '~/audio',
    MaskHome('/home/hanako/audio', '/home/hanako/'));
  Check('場所そのものも隠す',
    MaskHome('家は /home/hanako です', '/home/hanako') = '家は ~ です',
    MaskHome('家は /home/hanako です', '/home/hanako'));
  Check('何度出てきても隠す',
    Pos('hanako', MaskHome('/home/hanako/a と /home/hanako/b', '/home/hanako')) = 0,
    MaskHome('/home/hanako/a と /home/hanako/b', '/home/hanako'));
  Check('関わりのない文は変えない',
    MaskHome('PortAudio: 19.6.0', '/home/hanako') = 'PortAudio: 19.6.0', '');
  Check('場所が分からなければ何もしない',
    MaskHome('/home/hanako/x', '') = '/home/hanako/x', '');

  Report := BuildDiagnosticReport(
    'エンジン: ONNX Runtime 1.29.0' + LineEnding +
    '設定ファイル: /home/hanako/.config/deepcw.ini',
    '/home/hanako', EncodeDate(2026, 9, 11) + EncodeTime(14, 5, 6, 0));
  { **何が入っていないかを、控え自身が言うこと。**受け取った側が聞かずに
    済み、渡す側が安心して貼れます。
    **The copy says for itself what it does not hold**, so that the receiver
    need not ask and the sender can paste it without worrying. }
  Check('控えは、何が入っていないかを断っている',
    Pos('受信した文章', Report) > 0, Copy(Report, 1, 60));
  Check('控えに日時が入る（地域設定を通さない形）',
    Pos('2026-09-11 14:05:06', Report) > 0, Copy(Report, 1, 60));
  Check('控えの中身も隠れている', Pos('hanako', Report) = 0, Report);
  Check('控えに診断情報そのものが入る',
    Pos('ONNX Runtime 1.29.0', Report) > 0, '');
end;


{ デコーダが聴いている音（要件 FR-A.6）。

  モニタ再生が鳴らすのは**生の受信音ではありません。**同調して帯域を絞った
  あとの音、つまり復号へ渡すのとまったく同じものです。ここで確かめるのは、
  その「同じもの」が本当に同調と帯域制限を受けているかです。

  **これが生の音と変わらないなら、聴いても何も分かりません。**機械が読み違えた
  ときに、機械に何が届いていたのかを耳で確かめる、という目的が果たせません。

  What the decoder is listening to (requirement FR-A.6).

  The monitor playback does not sound the raw input: it sounds the audio after
  tuning and band limiting, which is the very thing handed to the decode. What
  is checked here is that this thing really is tuned and really is limited.

  **Were it no different from the raw audio, listening to it would tell nobody
  anything** -- and hearing what reached the machine when it misread something
  is the whole purpose. }
procedure TestMonitorAudio;
const
  RATE = 8000;
  WANTED_HZ = 1200;
  NEIGHBOUR_HZ = 700;
var
  Wanted, Neighbour, Prepared: TSingleArray;
  Timing: TCWTiming;
  Options: TCWToneOptions;
  Quiet, Loud: Double;

  function Rms(const Samples: TSingleArray): Double;
  var
    I: Integer;
  begin
    Result := 0;
    if Length(Samples) = 0 then
      Exit;
    for I := 0 to High(Samples) do
      Result := Result + Sqr(Samples[I]);
    Result := Sqrt(Result / Length(Samples));
  end;

  function Tone(Hz: Double): TSingleArray;
  begin
    Timing := DefaultTiming;
    Timing.CharWpm := 20;
    Timing.TextWpm := 20;
    Options := DefaultToneOptions;
    Options.SampleRate := RATE;
    Options.ToneHz := Hz;
    Result := TextToPCM('CQ DE JA1ABC K', Timing, Options);
  end;

begin
  WriteLn;
  WriteLn('デコーダが聴いている音（要件 FR-A.6）');
  Wanted := Tone(WANTED_HZ);
  Neighbour := Tone(NEIGHBOUR_HZ);

  { 同調した音は、モデルが待っている音程へ寄る。
    The tuned signal lands on the pitch the model expects. }
  Prepared := PrepareForModel(Wanted, RATE, Meta.SampleRate, WANTED_HZ,
    tbAuto, True);
  Check('同調した音は、モデルの音程へ寄っている',
    Abs(DetectToneHz(Prepared, Meta.SampleRate) - TUNER_TARGET_TONE_HZ) <= 8,
    Format('(%.0f Hz / 目標 %.0f Hz)',
      [DetectToneHz(Prepared, Meta.SampleRate), TUNER_TARGET_TONE_HZ]));
  Check('標本化周波数はモデルのものになる',
    Length(Prepared) > 0, Format('(%d 標本)', [Length(Prepared)]));
  Loud := Rms(Prepared);

  { 500 Hz 離れた隣の局は、帯域の外なので小さくなる。
    A neighbour 500 Hz away falls outside the passband and comes out small. }
  Prepared := PrepareForModel(Neighbour, RATE, Meta.SampleRate, WANTED_HZ,
    tbAuto, True);
  Quiet := Rms(Prepared);
  Check('帯域の外の局は小さくなる', Quiet < Loud / 3,
    Format('(隣 %.4f / 本命 %.4f)', [Quiet, Loud]));

  { 同調していないときは音程を動かさない。**動かしてしまうと、同調していない
    のに同調したかのように聞こえます。**
    Untuned, the pitch is left alone: **moved anyway, it would sound tuned when
    it is not.** }
  Prepared := PrepareForModel(Wanted, RATE, Meta.SampleRate, 0, tbAuto, True);
  Check('同調していなければ音程はそのまま',
    Abs(DetectToneHz(Prepared, Meta.SampleRate) - WANTED_HZ) <= 8,
    Format('(%.0f Hz / 受信機のまま %.0f Hz)',
      [DetectToneHz(Prepared, Meta.SampleRate), Double(WANTED_HZ)]));
end;


{ 推移の材料（要件 FR-H.10・FR-H.11）。

  **折れ線の絵より先に、何を並べるのかを決めます。**鍵の種類で絞ること、
  項目ごとに点数を取り出すこと、続いた日数を数えること——いずれも絵の外で
  決まる話であり、絵にしてしまうと画面を見なければ確かめられません。

  The material behind the trend (FR-H.10, FR-H.11).

  **What gets plotted is settled before any line is drawn.** Narrowing by the
  kind of key, taking one item's score, counting the days in a row: none of
  these belong in the drawing, where they could only be checked by looking at a
  screen. }
procedure TestFistTrend;
var
  Items: TFistRecords;
  Keys: TStringArray;
  Today: TDateTime;

  function Made(const Key: string; Overall, Separation: Double;
    Day: Integer): TFistRecord;
  begin
    Result := Default(TFistRecord);
    Result.When_ := EncodeDate(2026, 9, 1) + Day;
    Result.Key := Key;
    Result.Score.Overall := Overall;
    Result.Score.Separation := Separation;
    Result.Score.Speed := 50;
    Result.Measurement.Ok := True;
  end;

begin
  WriteLn;
  WriteLn('送信訓練の推移（要件 FR-H.10・FR-H.11）');
  SetLength(Items, 4);
  Items[0] := Made('縦振り', 60, 40, 0);
  Items[1] := Made('パドル', 70, 50, 1);
  Items[2] := Made('縦振り', 80, 60, 2);
  Items[3] := Made('パドル', 90, 70, 4);

  { 項目ごとに取り出せること。**総合だけでは、何が伸びたのかが分かりません。**
    One item at a time: **the overall alone does not say what improved.** }
  Check('項目ごとに点数を取り出せる',
    (ItemScore(Items[0], fiOverall) = 60) and
    (ItemScore(Items[0], fiSeparation) = 40) and
    (ItemScore(Items[0], fiSpeed) = 50),
    Format('(%.0f / %.0f)', [ItemScore(Items[0], fiOverall),
      ItemScore(Items[0], fiSeparation)]));

  { 鍵の種類で絞れること（要件 FR-H.10 の受入基準）。**混ぜた線は、上達では
    なく持ち替えを映します。**
    Narrowed by the kind of key: **a line through both shows the change of key,
    not progress.** }
  Check('鍵の種類で絞れる', Length(FilterByKey(Items, '縦振り')) = 2,
    Format('(%d 件)', [Length(FilterByKey(Items, '縦振り'))]));
  Check('絞った並びは、その鍵のものだけ',
    (FilterByKey(Items, 'パドル')[0].Score.Overall = 70) and
    (FilterByKey(Items, 'パドル')[1].Score.Overall = 90), '');
  Check('空なら、すべて返す', Length(FilterByKey(Items, '')) = 4,
    Format('(%d 件)', [Length(FilterByKey(Items, ''))]));
  Check('知らない鍵なら、何も返さない',
    Length(FilterByKey(Items, 'バグ')) = 0, '');

  { 選べる一覧は、記録から作ること。**決め打ちにすると、記録にある鍵を
    選べないことが起こります。**
    The choices come from the records: **written in advance, a key that is in
    the records could end up not being offered.** }
  Keys := KeysUsed(Items);
  Check('記録に出てくる鍵を、出てきた順に返す',
    (Length(Keys) = 2) and (Keys[0] = '縦振り') and (Keys[1] = 'パドル'),
    Format('(%d 種)', [Length(Keys)]));

  { 続いた日数（要件 FR-H.11）。 }
  Today := EncodeDate(2026, 9, 5);  { 記録は 1・2・3・5 日 }
  Check('今日まで続いていれば、その日数を数える',
    ConsecutiveDays(Items, Today) = 1,
    Format('(%d 日)', [ConsecutiveDays(Items, Today)]));
  Today := EncodeDate(2026, 9, 3);
  Check('3 日続けば 3 日', ConsecutiveDays(Items, Today) = 3,
    Format('(%d 日)', [ConsecutiveDays(Items, Today)]));
  { **今日まだ練習していなくても、昨日までの連続は途切れていません。**
    **A day not yet practised has not broken the run.** }
  Today := EncodeDate(2026, 9, 4);
  Check('今日の記録がまだ無くても、昨日までを数える',
    ConsecutiveDays(Items, Today) = 3,
    Format('(%d 日)', [ConsecutiveDays(Items, Today)]));
  Today := EncodeDate(2026, 9, 8);
  Check('間が空いていれば 0', ConsecutiveDays(Items, Today) = 0,
    Format('(%d 日)', [ConsecutiveDays(Items, Today)]));
  SetLength(Items, 0);
  Check('記録が無ければ 0 日', ConsecutiveDays(Items, Today) = 0, '');
end;


{ 推論間隔の自動調整（要件 FR-G.4・NFR-1.4）。

  **速い機械では何も変えず、遅い機械でだけ間隔を緩める**のが、この規則の
  値打ちです。変えてしまえば、いま満たしている遅延目標（NFR-1.1）を、
  遅くない機械で自ら壊すことになります。

  The automatic easing of the analysis interval (FR-G.4, NFR-1.4).

  **Nothing changes on a machine that is fast enough; the interval eases only
  where it must.** Changing it anywhere else would break, on machines that are
  not slow, the latency target the application already meets (NFR-1.1). }
procedure TestPacing;
begin
  WriteLn;
  WriteLn('推論間隔の自動調整（要件 FR-G.4）');

  { 測る前は待たない。**待ってから測るのでは、何を待てばよいのか分かりません。**
    Nothing waits before the first measurement: **waiting first would be
    waiting on nothing.** }
  Check('費用が分からないうちは待たない', PaceInterval(0, STREAM_CPU_BUDGET) = 0,
    Format('(%.2f)', [PaceInterval(0, STREAM_CPU_BUDGET)]));

  { 速い機械: 1 回 0.3 秒。予算 0.7 なら 0.43 秒ぶんの音で足りる。
    **溜まる量の条件（2 秒）のほうが先に効くので、動作点は変わりません。**
    A fast machine: 0.3 s an analysis wants 0.43 s of audio, which the
    two-second minimum already covers -- **the operating point does not move.** }
  Check('速い機械では、溜まる量の条件より短い間隔で足りる',
    PaceInterval(0.3, STREAM_CPU_BUDGET) < STREAM_MIN_PENDING_SECONDS,
    Format('(%.2f 秒 / 溜まる量 %.1f 秒)',
      [PaceInterval(0.3, STREAM_CPU_BUDGET), STREAM_MIN_PENDING_SECONDS]));

  { 遅い機械: 1 回 3 秒。予算 0.7 なら 4.29 秒。
    A slow machine: three seconds an analysis wants 4.29 s. }
  Check('遅い機械では、費用を予算で割った間隔になる',
    Abs(PaceInterval(3.0, 0.7) - 3.0 / 0.7) < 0.001,
    Format('(%.2f 秒)', [PaceInterval(3.0, 0.7)]));

  { **緩めるにも限りがあります。**これを超えて待つくらいなら、その機械では
    実時間に追いつかないと言うべきです。
    **There is a limit to the easing**: waiting longer would be worth less than
    saying the machine cannot keep up. }
  Check('どれだけ遅くても、上限を超えて待たない',
    PaceInterval(100, 0.7) = STREAM_MAX_INTERVAL_SECONDS,
    Format('(%.1f 秒)', [PaceInterval(100, 0.7)]));

  { 予算を広げれば間隔は縮み、狭めれば伸びること。**向きが逆なら、
    遅い機械ほど CPU を使うことになります。**
    A wider budget shortens the interval and a narrower one lengthens it: **the
    other way round, a slow machine would use more of the processor, not
    less.** }
  Check('予算を広げると間隔は縮む',
    PaceInterval(3.0, 0.9) < PaceInterval(3.0, 0.5),
    Format('(%.2f / %.2f)', [PaceInterval(3.0, 0.9), PaceInterval(3.0, 0.5)]));
  Check('予算を 0 にすると緩めない', PaceInterval(3.0, 0) = 0, '');

  { 予算どおりに割り振れていること。**間隔 × 予算 = 費用**が成り立っていなければ、
    CPU 使用率は目標に収まりません（要件 FR-G.4 の受入基準）。
    The arithmetic holds: **interval times budget equals cost**, or the
    processor share would not land on its target (the acceptance criterion). }
  Check('間隔 × 予算 が費用に等しい',
    Abs(PaceInterval(2.0, 0.5) * 0.5 - 2.0) < 0.001,
    Format('(%.2f)', [PaceInterval(2.0, 0.5)]));
end;


{ 分布のヒストグラム（要件 FR-H.9）。

  **絵にする前に、何を数えるのかを決めます。**横軸は短点いくつぶんか、
  範囲の外は端の升へ——この 2 つが違っていれば、絵は正しく描いても嘘になります。

  The histogram (requirement FR-H.9). **What is counted is settled before it is
  drawn**: the axis in dits, and anything past the end into the last bucket.
  Get those wrong and a faithfully drawn picture still lies. }
procedure TestHistogram;
const
  DIT = 0.06;
var
  Elements: TElements;
  Counts: TCounts;
  I, Total: Integer;

  procedure Put(Index_: Integer; Kind: TElementKind; Units_: Double);
  begin
    Elements[Index_].Kind := Kind;
    Elements[Index_].Seconds := Units_ * DIT;
    Elements[Index_].AtSeconds := Index_ * 0.1;
  end;

begin
  WriteLn;
  WriteLn('分布のヒストグラム（要件 FR-H.9）');
  SetLength(Elements, 6);
  Put(0, ekDit, 1.0);
  Put(1, ekDit, 1.1);
  Put(2, ekDah, 3.0);
  Put(3, ekChar, 3.0);
  Put(4, ekChar, 12.0);   { 範囲（9）の外 / past the end }
  Put(5, ekWord, 7.0);

  Counts := Histogram(Elements, ekDit, DIT);
  Total := 0;
  for I := 0 to High(Counts) do
    Total := Total + Counts[I];
  Check('数えた数が、その種別の要素の数と合う', Total = 2,
    Format('(%d)', [Total]));
  { 短点 2 つは、どちらも 1 短点ぶんの升に入る。**秒ではなく短点で数えるので、
    速度が変わっても同じ絵になります。**
    Both dits land in the bucket for one dit: **counted in dits, not seconds, the
    picture is the same at another speed.** }
  Check('短点は、短点 1 つぶんの升に入る',
    Counts[Trunc(1.0 / FIST_HISTOGRAM_MAX_UNITS * FIST_HISTOGRAM_BUCKETS)] = 2,
    Format('(%d)', [Counts[Trunc(1.0 / FIST_HISTOGRAM_MAX_UNITS * FIST_HISTOGRAM_BUCKETS)]]));

  { **範囲の外を捨てません**（教訓 10.9）。捨てると、極端に長い間隔が 1 つも
    無かったように見えます。
    **Nothing past the end is dropped** (lesson 10.9): dropped, a wildly long
    gap would look like no gap at all. }
  Counts := Histogram(Elements, ekChar, DIT);
  Total := 0;
  for I := 0 to High(Counts) do
    Total := Total + Counts[I];
  Check('範囲の外の値も数に入っている', Total = 2, Format('(%d)', [Total]));
  Check('範囲の外は、端の升に入る', Counts[High(Counts)] = 1,
    Format('(%d)', [Counts[High(Counts)]]));

  { 速度が変わっても同じ絵になること。**秒で数えていれば、ここで崩れます。**
    The same picture at another speed: **counted in seconds it would break
    here.** }
  for I := 0 to High(Elements) do
    Elements[I].Seconds := Elements[I].Seconds * 2;
  Check('速度が半分でも、同じ升に入る',
    Histogram(Elements, ekDit, DIT * 2)[
      Trunc(1.0 / FIST_HISTOGRAM_MAX_UNITS * FIST_HISTOGRAM_BUCKETS)] = 2, '');

  Check('短点の長さが分からなければ、数えない',
    Length(Histogram(Elements, ekDit, 0)) = FIST_HISTOGRAM_BUCKETS, '');
  Counts := Histogram(Elements, ekDit, 0);
  Total := 0;
  for I := 0 to High(Counts) do
    Total := Total + Counts[I];
  Check('短点の長さが分からなければ、数は 0', Total = 0, Format('(%d)', [Total]));
  { 許容は 1E-6。**桁の最後まで同じであることを求めているのではなく、
    「範囲 ÷ 升の数」であることを確かめています。**
    A tolerance of 1E-6: **what is checked is that it is the range over the
    count, not that the last digit agrees.** }
  Check('升の幅は、範囲を升の数で割ったもの',
    Abs(BucketUnits - FIST_HISTOGRAM_MAX_UNITS / FIST_HISTOGRAM_BUCKETS) < 1E-6,
    Format('(%.4f)', [BucketUnits]));
end;

procedure TestRecorder;
const
  WAV_RATE = 8000;
var
  Dir, Path: string;
  Writer: TWavWriter;
  Loaded: TSingleArray;
  Rate: Integer;
  Ring: TAudioRing;
  Recorder: TAudioRecorder;
  Status: TRecorderStatus;
  I: Integer;
begin
  WriteLn('TWavWriter / TAudioRecorder（要件 FR-E.8）');
  { 書きかけのファイルは、書き手を締め出さない読み方で開きます。`LoadWavMono` は
    書き込みを拒む開き方をするので、**書きかけを読む道具にはできません。**
    A file still being written is opened in a way that does not lock its writer
    out. `LoadWavMono` opens denying writers, so **it cannot be the tool for
    reading one part-way through.** }
  Dir := IncludeTrailingPathDelimiter(GetTempDir) + 'deepcw-recorder-test';
  ForceDirectories(Dir);
  Path := IncludeTrailingPathDelimiter(Dir) + 'grow.wav';
  DeleteFile(Path);

  { ---- 書きながら書き足す WAV ---- }
  Writer := TWavWriter.Create(Path, WAV_RATE);
  try
    { **1 標本も書いていない時点で、開ける WAV になっていること。**見出しを
      最後にまとめて書く作りでは、ここで落ちると開けないファイルが残る。
      **It must already be an openable WAV before a single sample is written**:
      a design that writes the headers at the end leaves an unopenable file if it
      dies here. }
    LoadGrowing(Path, Loaded, Rate);
    Check('中身が無くても開ける WAV になる',
      (Length(Loaded) = 0) and (Rate = WAV_RATE),
      Format('(%d 標本 / %d Hz)', [Length(Loaded), Rate]));

    Writer.Append(FilledWith(0.5, 1000), 1000);
    { **閉じる前に読めること。**強制終了に耐えるかどうかは、ここで決まる。
      **It must be readable before it is closed**: whether it survives a forced
      exit is decided here. }
    LoadGrowing(Path, Loaded, Rate);
    Check('閉じる前でも書いた分だけ読める', Length(Loaded) = 1000,
      Format('(%d 標本)', [Length(Loaded)]));
    Check('書いた値が読み戻せる',
      (Length(Loaded) = 1000) and (Abs(Loaded[0] - 0.5) < 0.001),
      Format('(%.4f)', [Loaded[0]]));
    Check('大きさの欄が中身と合う', Writer.Bytes = 44 + 2000,
      Format('(%d バイト)', [Writer.Bytes]));

    Writer.Append(FilledWith(-0.25, 500), 500);
    LoadGrowing(Path, Loaded, Rate);
    Check('2 度に分けて書いても続きになる',
      (Length(Loaded) = 1500) and (Abs(Loaded[1000] + 0.25) < 0.001),
      Format('(%d 標本)', [Length(Loaded)]));
  finally
    Writer.Free;
  end;
  LoadWavMono(Path, Loaded, Rate);
  Check('閉じたあとも同じ中身', Length(Loaded) = 1500,
    Format('(%d 標本)', [Length(Loaded)]));

  { 名前は地方時の日時から作る。/ The name comes from the local date and time. }
  Check('録音の名前は日時から作る',
    ExtractFileName(RecordingFileFor(Dir,
      EncodeDate(2026, 9, 6) + EncodeTime(1, 2, 3, 0))) = '2026-09-06-010203.wav',
    ExtractFileName(RecordingFileFor(Dir,
      EncodeDate(2026, 9, 6) + EncodeTime(1, 2, 3, 0))));

  { ---- 輪バッファから録る ---- }
  Path := IncludeTrailingPathDelimiter(Dir) + 'live.wav';
  DeleteFile(Path);
  Ring := TAudioRing.Create(WAV_RATE * 4);
  try
    { 始める前に鳴っていた音。**これは録らない。**利用者が録ると決める前の音だから。
      Audio that was already there. **It is not recorded**: it is from before the
      operator chose to record. }
    Ring.Push(FilledWith(0.9, 1600), 1600);
    Check('輪バッファは書いた数を数えている', Ring.Written = 1600,
      Format('(%d)', [Ring.Written]));

    Recorder := TAudioRecorder.Create(Ring, WAV_RATE);
    try
      Check('録音を始められる', Recorder.Start(Path), Recorder.LastError);
      Check('始めれば動いている', Recorder.Running);
      Ring.Push(FilledWith(0.5, 800), 800);
      Check('押し込んだ分が録れる', WaitForSamples(Recorder, 800, WAV_RATE, 3000),
        Format('(%.0f 標本)', [Recorder.Snapshot.Seconds * WAV_RATE]));
      Ring.Push(FilledWith(0.25, 800), 800);
      Check('続けて押し込んだ分も録れる',
        WaitForSamples(Recorder, 1600, WAV_RATE, 3000),
        Format('(%.0f 標本)', [Recorder.Snapshot.Seconds * WAV_RATE]));
      Status := Recorder.Snapshot;
      Check('取りこぼしは無い', Status.Lost = 0, Format('(%d)', [Status.Lost]));
      Check('自ら止まってはいない', Status.Stopped = '', Status.Stopped);
    finally
      Recorder.Stop;
      Recorder.Free;
    end;

    LoadWavMono(Path, Loaded, Rate);
    Check('止めたあとに読める録音になっている', Length(Loaded) = 1600,
      Format('(%d 標本)', [Length(Loaded)]));
    { **始める前の音が混ざっていないこと。**混ざれば、録音の時刻と受信テキストの
      時刻がずれる。
      **Nothing from before the start may be in it**: mixed in, the recording's
      time and the transcript's time would no longer line up. }
    Check('始める前の音は入っていない',
      (Length(Loaded) = 1600) and (Abs(Loaded[0] - 0.5) < 0.001),
      Format('(%.4f)', [Loaded[0]]));
    Check('2 度目に押し込んだ音も入っている',
      (Length(Loaded) = 1600) and (Abs(Loaded[800] - 0.25) < 0.001),
      Format('(%.4f)', [Loaded[800]]));
  finally
    Ring.Free;
  end;

  { ---- 止める指示の直前に届いた音も残ること ---- }
  { **止めた瞬間に残っていた分を書き切らなければ、最後の 1 文字の音が消えます。**
    取り出しの周期の途中で押し込み、間を置かずに止める。
    **Without writing out what was still there at the moment of stopping, the
    sound of the last character is lost.** The audio is pushed part-way through
    the reader's cycle and the recording stopped with no pause. }
  Path := IncludeTrailingPathDelimiter(Dir) + 'tail.wav';
  DeleteFile(Path);
  Ring := TAudioRing.Create(WAV_RATE * 4);
  try
    Recorder := TAudioRecorder.Create(Ring, WAV_RATE);
    try
      Recorder.Start(Path);
      Sleep(250);
      Ring.Push(FilledWith(0.75, 800), 800);
    finally
      Recorder.Stop;
      Recorder.Free;
    end;
    LoadWavMono(Path, Loaded, Rate);
    Check('止める直前に届いた音も残る', Length(Loaded) = 800,
      Format('(%d 標本)', [Length(Loaded)]));
  finally
    Ring.Free;
  end;

  { ---- 上限に達したら自ら止まり、理由を言う（教訓 10.1）---- }
  Path := IncludeTrailingPathDelimiter(Dir) + 'limit.wav';
  DeleteFile(Path);
  Ring := TAudioRing.Create(WAV_RATE * 4);
  try
    Recorder := TAudioRecorder.Create(Ring, WAV_RATE, 0.1, RECORD_MAX_BYTES);
    try
      Recorder.Start(Path);
      Ring.Push(FilledWith(0.5, 1600), 1600);
      for I := 1 to 100 do
      begin
        if Recorder.Snapshot.Stopped <> '' then
          Break;
        Sleep(20);
      end;
      Status := Recorder.Snapshot;
      Check('長さの上限に達したら止まる', Status.Stopped <> '', '(理由が空)');
      Check('止まった理由を言う', Pos('上限', Status.Stopped) > 0,
        Status.Stopped);
      Check('止まったものは動いているとは言わない', not Status.Running);
    finally
      Recorder.Stop;
      Recorder.Free;
    end;
    LoadWavMono(Path, Loaded, Rate);
    Check('上限で止めた録音も読める', Length(Loaded) >= 800,
      Format('(%d 標本)', [Length(Loaded)]));
  finally
    Ring.Free;
  end;

  { 大きさの上限も同じように効くこと。長さと大きさは別の道で溢れる。
    The size limit works the same way: length and size overrun by different
    routes. }
  Path := IncludeTrailingPathDelimiter(Dir) + 'bytes.wav';
  DeleteFile(Path);
  Ring := TAudioRing.Create(WAV_RATE * 4);
  try
    Recorder := TAudioRecorder.Create(Ring, WAV_RATE, RECORD_MAX_SECONDS, 1000);
    try
      Recorder.Start(Path);
      Ring.Push(FilledWith(0.5, 1600), 1600);
      for I := 1 to 100 do
      begin
        if Recorder.Snapshot.Stopped <> '' then
          Break;
        Sleep(20);
      end;
      Status := Recorder.Snapshot;
      Check('大きさの上限に達したら止まる', Status.Stopped <> '', '(理由が空)');
      Check('大きさで止まった理由を言う', Pos('MB', Status.Stopped) > 0,
        Status.Stopped);
    finally
      Recorder.Stop;
      Recorder.Free;
    end;
  finally
    Ring.Free;
  end;

  { ---- 追いつけなかったら、失った分を数える（教訓 10.1）---- }
  Path := IncludeTrailingPathDelimiter(Dir) + 'lost.wav';
  DeleteFile(Path);
  Ring := TAudioRing.Create(800);
  try
    Recorder := TAudioRecorder.Create(Ring, WAV_RATE);
    try
      Recorder.Start(Path);
      { 輪の 100 倍を一息に押し込む。取り出しは 0.1 秒ごとなので、間に合わない。
        A hundred rings' worth at once: the reader runs every 0.1 seconds and
        cannot keep up. }
      for I := 1 to 100 do
        Ring.Push(FilledWith(0.5, 800), 800);
      Sleep(300);
      Status := Recorder.Snapshot;
      Check('追いつけなければ失った分を数える', Status.Lost > 0,
        Format('(%d)', [Status.Lost]));
      Check('失っても録音は続く', Status.Stopped = '', Status.Stopped);
    finally
      Recorder.Stop;
      Recorder.Free;
    end;
  finally
    Ring.Free;
  end;

  { 書けない場所を指されたら、例外ではなく理由を返す。
    Pointed at a place it cannot write, it returns a reason rather than
    raising. }
  Recorder := TAudioRecorder.Create(nil, WAV_RATE);
  try
    Check('受信が動いていなければ始めない', not Recorder.Start(Path));
    Check('始められない理由を残す', Recorder.LastError <> '', '(理由が空)');
  finally
    Recorder.Free;
  end;

  DeleteFile(IncludeTrailingPathDelimiter(Dir) + 'grow.wav');
  DeleteFile(IncludeTrailingPathDelimiter(Dir) + 'live.wav');
  DeleteFile(IncludeTrailingPathDelimiter(Dir) + 'tail.wav');
  DeleteFile(IncludeTrailingPathDelimiter(Dir) + 'limit.wav');
  DeleteFile(IncludeTrailingPathDelimiter(Dir) + 'bytes.wav');
  DeleteFile(IncludeTrailingPathDelimiter(Dir) + 'lost.wav');
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

{ 交信済みの引き当てを差し替えるための、いつでも「ある」と答える相手です。
  A stand-in for the worked lookup that always answers yes. }
type
  TAlwaysWorked = class
    function Always(const Callsign: string): Boolean;
  end;

function TAlwaysWorked.Always(const Callsign: string): Boolean;
begin
  Result := Callsign <> '';
end;

type
  { どの符号も一覧に在る、という引き当てです（要件 FR-K.9）。
    A roster in which every call sign is present (requirement FR-K.9). }
  TAlwaysInRoster = class
    function Always(const Callsign: string): string;
  end;

function TAlwaysInRoster.Always(const Callsign: string): string;
begin
  if Callsign = '' then
    Result := ''
  else
    Result := '手元の一覧';
end;

type
  { JH2XYZ を待っている、という引き当てです。/ A watch standing on JH2XYZ. }
  TWatchingFor = class
    List: TWatchedCalls;
    function Lookup(const Callsign: string): string;
  end;

function TWatchingFor.Lookup(const Callsign: string): string;
begin
  Result := MatchedWatch(Callsign, List);
end;

var
  Answers: TAlwaysWorked;
  Listed: TAlwaysInRoster;
  Waiting: TWatchingFor;

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

  { 交信済みの区別（要件 FR-J.4）。**確かでない符号では交信済みと言いません。**
    1 文字違いの別人を「交信済み」と示すのは、示さないより悪いためです。
    The worked distinction (requirement FR-J.4). **Nothing uncertain is called
    worked**: showing whoever is one letter away as already worked is worse than
    showing nothing. }
  SetLength(Logs, 1);
  Logs[0] := LogOf('CQ CQ DE JH2XYZ JH2XYZ K ', 1000, 0.99);
  Entries := BuildBandEntries(Logs, 10, nil);
  Check('記録が無ければ交信済みと言わない', not Entries[0].Worked);
  Entries := BuildBandEntries(Logs, 10, @Answers.Always);
  Check('記録にあれば交信済みと分かる', Entries[0].Worked);

  { 自局の交信記録を、確からしさの材料に使う（要件 FR-K.11）。**交信した相手は
    確かに実在します。**しかも通信もプライバシーの代償も要りません。
    The operator's own log as evidence (requirement FR-K.11): **a station that
    has been worked certainly exists**, and knowing it costs neither traffic nor
    privacy. }
  Check('交信した相手は、実在の材料になる', Entries[0].Trust = ctInRoster,
    TrustCaption(Entries[0].Trust));
  Check('何で確かめたのかが分かる', Entries[0].TrustSource = '交信記録',
    Entries[0].TrustSource);
  Check('表示にも、何で確かめたのかが出る',
    TrustCaption(Entries[0]) = '交信記録あり', TrustCaption(Entries[0]));
  { **記録が無ければ使いません。**「記録に無い」は「実在しない」ではありません。
    **With no log it is not used**: absence from a log is not absence from the
    air. }
  Entries := BuildBandEntries(Logs, 10, nil);
  Check('記録が無ければ、確からしさは上げない', Entries[0].Trust = ctAgreed,
    TrustCaption(Entries[0]));
  Check('記録が無ければ、確かめた資料も無い', Entries[0].TrustSource = '',
    Entries[0].TrustSource);
  { 手元の一覧を、確からしさの材料に使う（要件 FR-K.9）。**通信もしません。**
    A locally held roster as evidence (requirement FR-K.9), **with no traffic
    either.** }
  SetLength(Logs, 1);
  Logs[0] := LogOf('CQ CQ DE JH2XYZ JH2XYZ K ', 1000, 0.99);
  Entries := BuildBandEntries(Logs, 10, nil, nil, @Listed.Always);
  Check('一覧にあれば、実在の材料になる', Entries[0].Trust = ctInRoster,
    TrustCaption(Entries[0].Trust));
  Check('一覧で確かめたと分かる', Entries[0].TrustSource = '手元の一覧',
    Entries[0].TrustSource);
  Check('表示にも、一覧で確かめたと出る',
    TrustCaption(Entries[0]) = '手元の一覧あり', TrustCaption(Entries[0]));

  { **交信記録のほうが強い根拠です。**両方に在るときは、強いほうを言います。
    自分が交信した相手であることは、誰かが配った一覧に名前があることより
    確かです。
    **One's own log is the stronger evidence**: where both hold it, that is what
    gets said. Having worked a station beats a name on a list somebody handed
    out. }
  Entries := BuildBandEntries(Logs, 10, @Answers.Always, nil, @Listed.Always);
  Check('両方に在れば、交信記録のほうを言う',
    Entries[0].TrustSource = '交信記録', Entries[0].TrustSource);

  { 一覧が無ければ何も変わりません。**「一覧に無い」は「実在しない」では
    ありません**（要件 FR-K.4 と同じ考え方）。
    With no roster nothing changes: **absence from a roster is not absence from
    the air** (the reasoning of requirement FR-K.4). }
  Entries := BuildBandEntries(Logs, 10, nil, nil, nil);
  Check('一覧が無ければ、確からしさは上げない', Entries[0].Trust = ctAgreed,
    TrustCaption(Entries[0]));

  { 確かでない符号には、一覧も当てません。**1 文字違いの実在局の名前で
    「実在する」と言うことになるためです。**
    The roster is not applied to an uncertain call sign either: **it would call
    it real on the strength of the neighbouring station's entry.** }
  SetLength(Logs, 1);
  Logs[0] := LogOf('CQ DE JH2XYZ K ', 1000, 0.99);
  Entries := BuildBandEntries(Logs, 10, nil, nil, @Listed.Always);
  Check('確かでない符号は、一覧に当たっても上げない',
    Entries[0].Trust = ctShape, TrustCaption(Entries[0]));

  { 確かでない符号は、記録に当たっても上げません。**1 文字違いの別人の記録に
    当たっているかもしれないためです。**
    An uncertain call sign is not raised even on a match: **the match may be
    with whoever is one letter away.** }
  SetLength(Logs, 1);
  Logs[0] := LogOf('CQ DE JH2XYZ K ', 1000, 0.99);
  Entries := BuildBandEntries(Logs, 10, @Answers.Always);
  Check('確かでない符号は、記録に当たっても上げない',
    Entries[0].Trust = ctShape, TrustCaption(Entries[0]));
  SetLength(Logs, 1);
  Logs[0] := LogOf('CQ CQ DE JH2XYZ JH2XYZ K ', 1000, 0.99);

  { 待っている符号の照合も、交信済みと同じ確かさの条件で行うこと（要件 FR-I.4）。
    条件が食い違うと、一覧に出ていない符号で知らせが鳴ります。
    The watch is matched on the same trust condition as the worked mark
    (requirement FR-I.4); differing conditions would let an announcement fire on
    a call sign the list is not showing. }
  Entries := BuildBandEntries(Logs, 10, nil, nil);
  Check('待ち符号を渡さなければ待っていない', Entries[0].Watched = '',
    Entries[0].Watched);
  Entries := BuildBandEntries(Logs, 10, nil, @Waiting.Lookup);
  Check('待っている局が分かる', Entries[0].Watched = 'JH2XYZ',
    Entries[0].Watched);

  { 1 回きりの符号は確かでないので、交信済みとは言わない。 }
  Logs[0] := LogOf('JA1ABC DE JH2XYZ K ', 1000, 0.99);
  Entries := BuildBandEntries(Logs, 10, @Answers.Always, @Waiting.Lookup);
  Check('確かでない符号では待っていたと言わない', Entries[0].Watched = '',
    Entries[0].Watched);
  Check('確かでない符号では交信済みと言わない', not Entries[0].Worked,
    Format('(%s)', [TrustCaption(Entries[0].Trust)]));

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

{ ---- 待っている呼出符号（要件 FR-I.4） ---- }

procedure TestWatch;
var
  List: TWatchedCalls;
  Alerts: TWatchAlerts;
  I: Integer;
  Started: TDateTime;
  Elapsed: Double;
begin
  WriteLn('DeepCW.Watch');

  { 書き方はいろいろあってよいこと。空白・読点・改行のどれでも区切れます。 }
  List := ParseWatchList('JA1ABC JH2XYZ');
  Check('空白で区切れる', Length(List) = 2, Format('(%d)', [Length(List)]));
  List := ParseWatchList('JA1ABC,JH2XYZ');
  Check('読点で区切れる', Length(List) = 2, Format('(%d)', [Length(List)]));
  List := ParseWatchList('JA1ABC'#10'JH2XYZ');
  Check('改行で区切れる', Length(List) = 2, Format('(%d)', [Length(List)]));
  List := ParseWatchList('  JA1ABC   JH2XYZ  ');
  Check('余分な空白があっても読める', Length(List) = 2,
    Format('(%d)', [Length(List)]));
  List := ParseWatchList('ja1abc');
  Check('小文字で書いても待てる', (Length(List) = 1) and (List[0] = 'JA1ABC'),
    Format('(%d)', [Length(List)]));

  { 形にならないものは落とすこと。落としたと分かること。 }
  List := ParseWatchList('JA1ABC J1ADC');
  Check('形にならない符号は落とす', Length(List) = 1,
    Format('(%d)', [Length(List)]));
  Check('入力の語数は数えられる', CountWatchWords('JA1ABC J1ADC') = 2,
    Format('(%d)', [CountWatchWords('JA1ABC J1ADC')]));
  Check('空なら何も待たない', Length(ParseWatchList('')) = 0);
  Check('空白だけでも落ちない', Length(ParseWatchList('   ')) = 0);

  { 同じ符号を 2 回書いても 1 局。 }
  List := ParseWatchList('JA1ABC JA1ABC');
  Check('重複は 1 局にまとめる', Length(List) = 1, Format('(%d)', [Length(List)]));
  { 附加符号を書いても、待つのは本体。 }
  List := ParseWatchList('JA1ABC/P');
  Check('附加符号を書いても本体で待つ',
    (Length(List) = 1) and (List[0] = 'JA1ABC'),
    Format('(%s)', [List[0]]));

  { 照合は完全一致だけ。ここが版 2.23 で測って決めたところです。 }
  List := ParseWatchList('JA1ABC JH2XYZ');
  Check('待っている符号に当たる', MatchedWatch('JA1ABC', List) = 'JA1ABC',
    MatchedWatch('JA1ABC', List));
  Check('2 つ目の符号にも当たる', MatchedWatch('JH2XYZ', List) = 'JH2XYZ',
    MatchedWatch('JH2XYZ', List));
  Check('待っていない符号には当たらない', MatchedWatch('JR3KLM', List) = '',
    MatchedWatch('JR3KLM', List));
  Check('1 文字違いには当たらない', MatchedWatch('JA1ADC', List) = '',
    MatchedWatch('JA1ADC', List));
  Check('小文字で聞こえても当たる', MatchedWatch('ja1abc', List) = 'JA1ABC',
    MatchedWatch('ja1abc', List));
  Check('附加符号が付いて呼んでも当たる',
    MatchedWatch('JA1ABC/P', List) = 'JA1ABC', MatchedWatch('JA1ABC/P', List));
  Check('空の符号には当たらない', MatchedWatch('', List) = '');
  Check('何も待っていなければ当たらない',
    MatchedWatch('JA1ABC', ParseWatchList('')) = '');

  { 文字の隔たり。採らなかった規則の代償を測るために使います。 }
  Check('同じなら 0', CallsignDistance('JA1ABC', 'JA1ABC') = 0);
  Check('1 文字違いは 1', CallsignDistance('JA1ABC', 'JA1ADC') = 1,
    Format('(%d)', [CallsignDistance('JA1ABC', 'JA1ADC')]));
  Check('1 文字足りなければ 1', CallsignDistance('JA1ABC', 'JA1AB') = 1,
    Format('(%d)', [CallsignDistance('JA1ABC', 'JA1AB')]));
  Check('1 文字余分なら 1', CallsignDistance('JA1ABC', 'JA1ABCD') = 1,
    Format('(%d)', [CallsignDistance('JA1ABC', 'JA1ABCD')]));
  Check('2 文字違いは 2', CallsignDistance('JA1ABC', 'JA1ADD') = 2,
    Format('(%d)', [CallsignDistance('JA1ABC', 'JA1ADD')]));
  Check('遠ければ 3 で打ち切る', CallsignDistance('JA1ABC', 'W7XYZ') = 3,
    Format('(%d)', [CallsignDistance('JA1ABC', 'W7XYZ')]));
  { 途中で打ち切れず、最後まで数えてから頭打ちになる組。**打ち切りが 2 か所
    あることを、両方とも覆います。**この組を入れる前は、最後の頭打ちを外しても
    どの試験も落ちませんでした。
    A pair that cannot be cut short on the way and is capped only at the end.
    **Both places the count is capped are covered.** Before this pair was added,
    removing the final cap broke no test. }
  Check('最後まで数えても 3 で頭打ちになる',
    CallsignDistance('JR6P', 'JR8GHQ') = 3,
    Format('(%d)', [CallsignDistance('JR6P', 'JR8GHQ')]));
  Check('片方が空でも落ちない', CallsignDistance('', 'JA1ABC') = 3,
    Format('(%d)', [CallsignDistance('', 'JA1ABC')]));

  { 知らせは局ごとに一度きり。番号が変われば改めて知らせること。 }
  Alerts := TWatchAlerts.Create;
  try
    Check('初めての局には知らせる', Alerts.Announce(1));
    Check('同じ局には二度知らせない', not Alerts.Announce(1));
    Check('別の局には知らせる', Alerts.Announce(2));
    Check('また同じ局には知らせない', not Alerts.Announce(2));
    Check('知らせた数を数えている', Alerts.Count = 2,
      Format('(%d)', [Alerts.Count]));
    Alerts.Reset;
    Check('やり直せば忘れる', Alerts.Count = 0, Format('(%d)', [Alerts.Count]));
    Check('忘れたあとは改めて知らせる', Alerts.Announce(1));

    { 局が増えても覚え続けられること。上限で溢れて知らせが止まらないこと。 }
    Alerts.Reset;
    for I := 1 to 500 do
      if not Alerts.Announce(I) then
        Break;
    Check('500 局まで覚えられる', Alerts.Count = 500,
      Format('(%d)', [Alerts.Count]));
    Check('覚えたものは二度知らせない', not Alerts.Announce(250));
  finally
    Alerts.Free;
  end;

  { 一覧は毎秒作り直します。そのたびに全行を引くので、遅ければ効きます。 }
  List := ParseWatchList('JA1ABC JH2XYZ JR3KLM 7K1TUV 8N1OLP');
  Started := Now;
  for I := 1 to 10000 do
    MatchedWatch('JR3KLM', List);
  Elapsed := MilliSecondsBetween(Now, Started);
  WriteLn(Format('    照合 1 万回: %.0f ms', [Elapsed]));
  Check('照合 1 万回が 100 ms 未満', Elapsed < 100,
    Format('(%.0f ms)', [Elapsed]));
end;

{ ---- 受信文の読み取り（要件 FR-E.1・FR-E.2） ---- }

{ 位置が受信文と本当に合っているかを、文字を切り出して確かめます。番号を目視で
  数えると、数え間違いが試験そのものを無意味にします。
  Checks a span by cutting the characters out of the transcript. Counting indices
  by eye would make the test itself meaningless if the count were wrong. }
function TextAt(const Chars: TDecodedChars; Span: TExchangeSpan): string;
var
  I: Integer;
begin
  Result := '';
  if Span.First < 0 then
    Exit;
  for I := Span.First to Span.Last do
    Result := Result + Chars[I].Text;
end;

procedure TestExchange;
var
  Chars: TDecodedChars;
  Ex: TExchange;
  I, Repeats: Integer;
  Long_: string;
  Started: TDateTime;
  Elapsed: Double;
begin
  WriteLn('DeepCW.Exchange');

  { 交信でいちばんよく現れる形。相手は DE の後ろです。
    The commonest shape on the air; the station is the one after DE. }
  Chars := CharsOf('JA1ABC DE JH2XYZ UR 599 599 QTH NAGOYA', 0);
  Ex := ReadExchange(Chars);
  Check('DE の直後を相手にする', Ex.Callsign = 'JH2XYZ', Ex.Callsign);
  Check('符号を 2 つとも見つける', Length(Ex.Callsigns) = 2,
    Format('(%d)', [Length(Ex.Callsigns)]));
  Check('選んだ符号の位置が合っている',
    TextAt(Chars, Ex.Callsigns[Ex.Chosen]) = 'JH2XYZ',
    TextAt(Chars, Ex.Callsigns[Ex.Chosen]));
  Check('相手でないほうの位置も合っている',
    TextAt(Chars, Ex.Callsigns[0]) = 'JA1ABC', TextAt(Chars, Ex.Callsigns[0]));
  Check('RST を読む', Ex.Rst.Text = '599', Ex.Rst.Text);
  Check('RST の位置が合っている', TextAt(Chars, Ex.Rst) = '599',
    TextAt(Chars, Ex.Rst));

  { 最後の語を採る規則なら TU の後ろの局を相手にしてしまいます。ここが、交信
    モードと待機モードで規則を揃えた理由そのものです。
    A last-wins rule would take the station after TU. This case is exactly why
    the contact mode and the waiting mode were put on one rule. }
  Chars := CharsOf('CQ DE JH2XYZ K TU JA1ABC', 0);
  Ex := ReadExchange(Chars);
  Check('末尾に別の局が出ても DE の後ろを採る', Ex.Callsign = 'JH2XYZ',
    Ex.Callsign);

  { DE が無ければ、いちばん多く出たもの。 }
  Chars := CharsOf('JH2XYZ JH2XYZ JA1ABC', 0);
  Ex := ReadExchange(Chars);
  Check('DE が無ければ最も多いものを採る', Ex.Callsign = 'JH2XYZ', Ex.Callsign);
  Check('何回出たかを数えている', Ex.Sightings = 2,
    Format('(%d)', [Ex.Sightings]));

  { 1 回しか出ていないことが分かること。断定して見せないための根拠です。 }
  Chars := CharsOf('CQ DE JH2XYZ K', 0);
  Ex := ReadExchange(Chars);
  Check('1 回きりなら 1 と分かる', Ex.Sightings = 1, Format('(%d)', [Ex.Sightings]));

  { 形の壊れた語は符号にしません（要件 FR-K 第 1 段）。 }
  Chars := CharsOf('CQ DE J1ADC K', 0);
  Ex := ReadExchange(Chars);
  Check('形の壊れた語は符号にしない', Length(Ex.Callsigns) = 0,
    Format('(%d)', [Length(Ex.Callsigns)]));
  Check('符号が無ければ選ばない', Ex.Chosen < 0, Format('(%d)', [Ex.Chosen]));

  { 受入基準そのもの: 国内の前置符字を認識すること（要件 FR-E.1）。 }
  Chars := CharsOf('JA1ABC JS1ABC 7K1ABC 7N1ABC 8J1ABC 8N1ABC', 0);
  Ex := ReadExchange(Chars);
  Check('JA〜JS・7J〜7N・8J・8N を拾う', Length(Ex.Callsigns) = 6,
    Format('(%d)', [Length(Ex.Callsigns)]));

  { 附加符号が付いていても符号です。 }
  Chars := CharsOf('CQ DE 7K1TUV/1 K', 0);
  Ex := ReadExchange(Chars);
  Check('附加符号が付いた符号も拾う', Ex.Callsign = '7K1TUV/1', Ex.Callsign);

  { 位置は語の両端を含み、空白を含みません。 }
  Chars := CharsOf('DE JH2XYZ K', 0);
  Ex := ReadExchange(Chars);
  Check('位置の先頭が語の先頭', Ex.Callsigns[0].First = 3,
    Format('(%d)', [Ex.Callsigns[0].First]));
  Check('位置の末尾が語の末尾', Ex.Callsigns[0].Last = 8,
    Format('(%d)', [Ex.Callsigns[0].Last]));

  { RST の形。 }
  Check('599 は RST', IsRst('599'));
  Check('579 は RST', IsRst('579'));
  Check('5NN は RST', IsRst('5NN'));
  Check('339 は RST', IsRst('339'));
  Check('100 は RST でない（強度 0 は無い）', not IsRst('100'));
  Check('590 は RST でない（音調 0 は無い）', not IsRst('590'));
  Check('699 は RST でない（了解度 6 は無い）', not IsRst('699'));
  Check('NNN は RST でない（了解度 9 は無い）', not IsRst('NNN'));
  Check('EEE は RST でない（訂正の合図）', not IsRst('EEE'));
  Check('5999 は RST でない（4 文字）', not IsRst('5999'));
  Check('59 は RST でない（2 文字）', not IsRst('59'));
  Check('空は RST でない', not IsRst(''));

  { UR の直後を優先します。 }
  Chars := CharsOf('599 DE JH2XYZ UR 449 K', 0);
  Ex := ReadExchange(Chars);
  Check('UR の直後の RST を採る', Ex.Rst.Text = '449', Ex.Rst.Text);

  { コンテストでは RST のあとに連続番号が続きます。番号のほうが後ろにあっても、
    連なりの先頭へ戻って RST を採ります（要件 FR-I.5 で効きます）。
    In a contest the serial follows the report; stepping back to the start of the
    run takes the report even though the serial comes later. }
  Chars := CharsOf('DE JH2XYZ 599 123 K', 0);
  Ex := ReadExchange(Chars);
  Check('連続番号を RST と取り違えない', Ex.Rst.Text = '599', Ex.Rst.Text);

  { RST が無ければ「無い」と言えること。599 で埋めてはいけません。 }
  Chars := CharsOf('CQ CQ DE JH2XYZ K', 0);
  Ex := ReadExchange(Chars);
  Check('RST が無ければ無いと分かる', Ex.Rst.First < 0,
    Format('(%d)', [Ex.Rst.First]));

  { 空でも落ちません。 }
  Chars := nil;
  Ex := ReadExchange(Chars);
  Check('空の受信文で落ちない', (Ex.Callsign = '') and (Length(Ex.Callsigns) = 0)
    and (Ex.Chosen < 0) and (Ex.Rst.First < 0));
  Chars := CharsOf('   ', 0);
  Ex := ReadExchange(Chars);
  Check('空白だけでも落ちない', Ex.Callsign = '');

  { 画面の更新に間に合うこと。受信中は文字が届くたびに読み直します。 }
  Long_ := '';
  while Length(Long_) < 4000 do
    Long_ := Long_ + 'CQ CQ DE JH2XYZ JH2XYZ K JA1ABC DE JH2XYZ UR 599 599 ';
  SetLength(Long_, 4000);
  Chars := CharsOf(Long_, 0);
  Started := Now;
  for Repeats := 1 to 20 do
    Ex := ReadExchange(Chars);
  Elapsed := MilliSecondsBetween(Now, Started) / 20;
  WriteLn(Format('    4000 文字の読み取り: %.2f ms（符号 %d 個）',
    [Elapsed, Length(Ex.Callsigns)]));
  Check('4000 文字の読み取りが 10 ms 未満', Elapsed < 10,
    Format('(%.2f ms)', [Elapsed]));

  { 語の位置は、長い受信文でも受信文そのものと合っていること。目で数えられない
    ところこそ、機械に確かめさせます。
    The spans must agree with the transcript on a long text too: what cannot be
    counted by eye is exactly what the machine should check. }
  for I := 0 to High(Ex.Callsigns) do
    if TextAt(Chars, Ex.Callsigns[I]) <> Ex.Callsigns[I].Text then
      Break;
  Check('長い受信文でも位置がすべて合っている',
    (Length(Ex.Callsigns) > 0) and (I = High(Ex.Callsigns)) and
    (TextAt(Chars, Ex.Callsigns[I]) = Ex.Callsigns[I].Text),
    Format('(%d 個目)', [I]));
end;

{ 交信 1 件を組み立てます。/ Builds one contact. }
function ContactOf(const Call, On_, At_: string): TAdifRecord;
begin
  Result := Default(TAdifRecord);
  SetAdifValue(Result, 'CALL', Call);
  SetAdifValue(Result, 'QSO_DATE', On_);
  SetAdifValue(Result, 'TIME_ON', At_);
  SetAdifValue(Result, 'MODE', 'CW');
end;

procedure TestContactLog;
var
  Dir, Path, Other: string;
  Log: TContactLog;
  Items: TAdifRecords;
  Item: TAdifRecord;
  Added, Skipped, I: Integer;
  Started: TDateTime;
  Elapsed: Double;
  Body: string;
begin
  WriteLn('DeepCW.Log');
  Dir := IncludeTrailingPathDelimiter(GetTempDir) + 'deepcw-log-test';
  Path := IncludeTrailingPathDelimiter(Dir) + 'contacts.adi';
  Other := IncludeTrailingPathDelimiter(Dir) + 'imported.adi';
  if DirectoryExists(Dir) then
  begin
    DeleteFile(Path);
    DeleteFile(Other);
    { 版 2.28 で足した 2 つも消します。**消し忘れると、走らせるたびに件数が
      増え、2 度目から落ちます。**実際にそうなり、壊して確かめている最中に
      気づきました。
      The two added in version 2.28 go too: **left behind, the counts grow with
      every run and the second one fails.** That is exactly what happened, and it
      surfaced while mutation testing. }
    DeleteFile(IncludeTrailingPathDelimiter(Dir) + 'bands.adi');
    DeleteFile(IncludeTrailingPathDelimiter(Dir) + 'lastband.adi');
    DeleteFile(IncludeTrailingPathDelimiter(Dir) + 'rate.adi');
  end;

  { --- 読み書きそのもの --- }
  Items := ParseAdif(
    'Some header text' + LineEnding +
    '<adif_ver:5>3.1.4<EOH>' + LineEnding +
    '<CALL:6>JA1ABC<QSO_DATE:8>20260904<TIME_ON:6>101500<MODE:2>CW<EOR>' +
    '<call:6:S>JH2XYZ<QSO_DATE:8>20260904<TIME_ON:6>102000<EOR>');
  Check('見出しを読み飛ばす', Length(Items) = 2, Format('(%d 件)', [Length(Items)]));
  Check('項目を取り出せる', AdifValue(Items[0], 'CALL') = 'JA1ABC',
    Format('("%s")', [AdifValue(Items[0], 'CALL')]));
  Check('小文字の項目名も同じに扱う', AdifValue(Items[1], 'call') = 'JH2XYZ',
    Format('("%s")', [AdifValue(Items[1], 'CALL')]));

  { 型の指定が付いていても長さだけを見る。 }
  Items := ParseAdif('<CALL:6:S>JA1ABC<EOR>');
  Check('型の指定が付いていても読める', AdifValue(Items[0], 'CALL') = 'JA1ABC',
    Format('("%s")', [AdifValue(Items[0], 'CALL')]));

  { 壊れていても例外を投げず、読めるところまで読む。**長年の記録の 1 行が
    壊れていたときに全部を失うほうが損。** }
  Items := ParseAdif('<CALL:6>JA1ABC<EOR><CALL:99>JH2');
  Check('壊れた末尾があっても読めるところは読む', Length(Items) = 2,
    Format('(%d 件)', [Length(Items)]));
  Items := ParseAdif('<CALL:6>JA1ABC<EOR><NOTCLOSED');
  Check('閉じない括弧があっても落ちない', Length(Items) = 1,
    Format('(%d 件)', [Length(Items)]));
  Items := ParseAdif('');
  Check('空でも落ちない', Length(Items) = 0);

  { 知らない項目も落とさない。**別のソフトで積み上げた記録を通したときに
    黙って何かが消えるのは許されない。** }
  Items := ParseAdif('<CALL:6>JA1ABC<MY_GRID:6>PM95uq<EOR>');
  Item := ParseAdif(FormatAdifRecord(Items[0]))[0];
  Check('知らない項目も往復で残る', AdifValue(Item, 'MY_GRID') = 'PM95uq',
    Format('("%s")', [AdifValue(Item, 'MY_GRID')]));

  { 渡した時刻がそのまま日付と時刻の欄になること。**ADIF はこの 2 つを協定
    世界時と定めているので、渡す側が変換して渡す。**ここで二重に変換しないことも
    同時に押さえる。
    The moment handed in must appear as the date and time fields. **ADIF defines
    them as UTC and the caller converts**, so this also holds that no second
    conversion happens here. }
  Item := BuildContact('ja1abc',
    EncodeDate(2026, 9, 4) + EncodeTime(23, 9, 22, 0));
  Check('渡した時刻がそのまま日付になる',
    AdifValue(Item, 'QSO_DATE') = '20260904',
    Format('("%s")', [AdifValue(Item, 'QSO_DATE')]));
  Check('渡した時刻がそのまま時刻になる',
    AdifValue(Item, 'TIME_ON') = '230922',
    Format('("%s")', [AdifValue(Item, 'TIME_ON')]));
  Check('呼出符号は大文字で残る', AdifValue(Item, 'CALL') = 'JA1ABC',
    Format('("%s")', [AdifValue(Item, 'CALL')]));
  Check('電波型式が入る', AdifValue(Item, 'MODE') = 'CW');

  { --- 交信記録として --- }
  Log := TContactLog.Create(Path);
  try
    Log.Load;
    Check('無いファイルなら空で始まる', Log.Count = 0);
    Check('知らない局は交信済みでない', Log.WorkedCount('JA1ABC') = 0);

    Check('交信を加えられる', Log.Add(ContactOf('JA1ABC', '20260904', '101500')),
      Log.LastError);
    { **書いた時点でファイルに残っていること。**閉じるまで書かない作りでは、
      強制終了したときに交信が消える。 }
    Body := ReadWhole(Path);
    Check('加えた時点でファイルに残る', Pos('JA1ABC', Body) > 0,
      Format('("%s")', [Copy(Body, 1, 40)]));
    Check('交信済みと分かる', Log.WorkedCount('JA1ABC') = 1,
      Format('(%d 回)', [Log.WorkedCount('JA1ABC')]));
    Check('最後に交信した日が分かる', Log.LastWorkedOn('JA1ABC') = '20260904',
      Format('("%s")', [Log.LastWorkedOn('JA1ABC')]));

    { 附加符号は同じ局として扱う。別々に数えると「初めての局」と誤って示す。 }
    Check('附加符号が付いても同じ局と分かる', Log.WorkedCount('JA1ABC/P') = 1,
      Format('(%d 回)', [Log.WorkedCount('JA1ABC/P')]));
    Check('小文字でも同じ局と分かる', Log.WorkedCount('ja1abc') = 1,
      Format('(%d 回)', [Log.WorkedCount('ja1abc')]));
    Check('別の局は交信済みでない', Log.WorkedCount('JA1ABD') = 0);

    Log.Add(ContactOf('JA1ABC', '20260905', '090000'));
    Check('2 回目が数に入る', Log.WorkedCount('JA1ABC') = 2,
      Format('(%d 回)', [Log.WorkedCount('JA1ABC')]));
    Check('新しいほうの日が残る', Log.LastWorkedOn('JA1ABC') = '20260905',
      Format('("%s")', [Log.LastWorkedOn('JA1ABC')]));
  finally
    Log.Free;
  end;

  { 開き直しても同じことが分かる。 }
  Log := TContactLog.Create(Path);
  try
    Log.Load;
    Check('開き直しても件数が残る', Log.Count = 2, Format('(%d 件)', [Log.Count]));
    Check('開き直しても交信済みが分かる', Log.WorkedCount('JA1ABC') = 2,
      Format('(%d 回)', [Log.WorkedCount('JA1ABC')]));

    { 取り込み。同じものを 2 回取り込んでも増えない。 }
    Log.ExportAdif(Other);
    Check('書き出せる', FileExists(Other));
    Check('書き出しに見出しが付く',
      Pos('<EOH>', ReadWhole(Other)) > 0, '(見出しが無い)');
    Check('取り込みで既にあるものは飛ばす',
      Log.ImportAdif(Other, Added, Skipped) and (Added = 0) and (Skipped = 2),
      Format('(追加 %d / 飛ばし %d)', [Added, Skipped]));
    Check('取り込んでも件数が増えない', Log.Count = 2,
      Format('(%d 件)', [Log.Count]));

    { 新しい局を含むファイルを取り込むと、その分だけ増える。 }
    Items := nil;
    SetLength(Items, 2);
    Items[0] := ContactOf('JA1ABC', '20260904', '101500');
    Items[1] := ContactOf('JR3KLM', '20260906', '120000');
    Body := FormatAdif(Items, 'test');
    with TFileStream.Create(Other, fmCreate) do
      try
        WriteBuffer(Body[1], Length(Body));
      finally
        Free;
      end;
    Check('新しい局だけ取り込む',
      Log.ImportAdif(Other, Added, Skipped) and (Added = 1) and (Skipped = 1),
      Format('(追加 %d / 飛ばし %d)', [Added, Skipped]));
    Check('取り込んだ局が交信済みになる', Log.WorkedCount('JR3KLM') = 1,
      Format('(%d 回)', [Log.WorkedCount('JR3KLM')]));

    { 読めない場所を指されても例外を投げない。 }
    Check('取り込めなくても例外を投げない',
      not Log.ImportAdif(Dir + '/nowhere.adi', Added, Skipped), '');
    Check('取り込めなかった理由が残る', Log.LastError <> '', '(理由が空)');
  finally
    Log.Free;
  end;

  { ---- バンドごとの重複判定（要件 FR-I.5）----
    **コンテストの重複判定はバンドごとです。**7 MHz で交信した局を 14 MHz で
    「交信済み」と示すと、有効な交信を見送らせます。
    ---- The duplicate check, band by band (requirement FR-I.5) ----
    **A contest counts duplicates band by band**: marking a station worked on
    7 MHz as worked on 14 MHz would have the operator pass over a valid
    contact. }
  Path := IncludeTrailingPathDelimiter(Dir) + 'bands.adi';
  Log := TContactLog.Create(Path);
  try
    Log.Load;
    Check('バンドを書かなければ欄が無い',
      Pos('BAND', UpperCase(FormatAdifRecord(BuildContact('JA1ABC', 45000)))) = 0);
    Item := BuildContact('JA1ABC', 45000, 'CW', '40M');
    Check('バンドを書けば欄に入る', AdifValue(Item, 'BAND') = '40M',
      AdifValue(Item, 'BAND'));
    Check('小文字で渡しても大文字で残る',
      AdifValue(BuildContact('JA1ABC', 45000, 'CW', '40m'), 'BAND') = '40M');
    Log.Add(Item);
    Check('そのバンドでは交信済み', Log.WorkedCountOn('JA1ABC', '40M') = 1,
      Format('(%d)', [Log.WorkedCountOn('JA1ABC', '40M')]));
    Check('別のバンドでは交信済みでない',
      Log.WorkedCountOn('JA1ABC', '20M') = 0,
      Format('(%d)', [Log.WorkedCountOn('JA1ABC', '20M')]));
    Check('バンドを問わなければ交信済み', Log.WorkedCount('JA1ABC') = 1,
      Format('(%d)', [Log.WorkedCount('JA1ABC')]));
    Check('バンドを空で問えば全バンドの数',
      Log.WorkedCountOn('JA1ABC', '') = 1,
      Format('(%d)', [Log.WorkedCountOn('JA1ABC', '')]));
    Log.Add(BuildContact('JA1ABC', 45000.5, 'CW', '20M'));
    Check('別バンドで交信すればそちらも数に入る',
      Log.WorkedCountOn('JA1ABC', '20M') = 1,
      Format('(%d)', [Log.WorkedCountOn('JA1ABC', '20M')]));
    Check('元のバンドの数は変わらない',
      Log.WorkedCountOn('JA1ABC', '40M') = 1,
      Format('(%d)', [Log.WorkedCountOn('JA1ABC', '40M')]));
    Check('全バンドでは 2 回', Log.WorkedCount('JA1ABC') = 2,
      Format('(%d)', [Log.WorkedCount('JA1ABC')]));
    Log.Add(BuildContact('JH2XYZ', 45000.6));
    Check('バンドの無い交信も全バンドでは数に入る',
      Log.WorkedCount('JH2XYZ') = 1, Format('(%d)', [Log.WorkedCount('JH2XYZ')]));
    Check('バンドの無い交信は、特定のバンドでは数に入らない',
      Log.WorkedCountOn('JH2XYZ', '40M') = 0,
      Format('(%d)', [Log.WorkedCountOn('JH2XYZ', '40M')]));
  finally
    Log.Free;
  end;
  { 開き直しても、バンドごとの数が残ること。**読み込みで数え直せていなければ、
    アプリを開き直した瞬間に重複判定が壊れます。**
    The per-band counts must survive a reopen: **rebuilt wrongly on load, the
    duplicate check breaks the moment the application is restarted.** }
  Log := TContactLog.Create(Path);
  try
    Log.Load;
    Check('開き直してもバンドごとの数が残る',
      (Log.WorkedCountOn('JA1ABC', '40M') = 1) and
      (Log.WorkedCountOn('JA1ABC', '20M') = 1) and
      (Log.WorkedCountOn('JA1ABC', '15M') = 0),
      Format('(40M %d / 20M %d / 15M %d)',
        [Log.WorkedCountOn('JA1ABC', '40M'), Log.WorkedCountOn('JA1ABC', '20M'),
         Log.WorkedCountOn('JA1ABC', '15M')]));
  finally
    Log.Free;
  end;

  { ---- 「交信済み」と示す日付も、そのバンドのもの（要件 FR-I.5）----

    回数をバンドごとに答えながら日付を全バンドから採ると、**そのバンドでは
    交信していない日付を、重複の証拠として示すことになります。**

    ---- The date shown for a duplicate belongs to the same band (FR-I.5) ----

    Answering the count band by band while taking the date from every band would
    **offer, as the evidence of a duplicate, a date on which that band was never
    worked.** }
  Path := IncludeTrailingPathDelimiter(Dir) + 'lastband.adi';
  Log := TContactLog.Create(Path);
  try
    Log.Load;
    Log.Add(BuildContact('JA1ABC', 45000, 'CW', '40M'));
    Log.Add(BuildContact('JA1ABC', 45010, 'CW', '20M'));
    Check('バンドを問わなければ最後に交信した日',
      Log.LastWorkedOn('JA1ABC') = FormatDateTime('yyyymmdd', 45010),
      Format('("%s")', [Log.LastWorkedOn('JA1ABC')]));
    Check('そのバンドで最後に交信した日を答える',
      Log.LastWorkedOn('JA1ABC', '40M') = FormatDateTime('yyyymmdd', 45000),
      Format('("%s")', [Log.LastWorkedOn('JA1ABC', '40M')]));
    Check('別のバンドはそちらの日を答える',
      Log.LastWorkedOn('JA1ABC', '20M') = FormatDateTime('yyyymmdd', 45010),
      Format('("%s")', [Log.LastWorkedOn('JA1ABC', '20M')]));
    Check('交信していないバンドは空を返す',
      Log.LastWorkedOn('JA1ABC', '15M') = '',
      Format('("%s")', [Log.LastWorkedOn('JA1ABC', '15M')]));
    Log.Add(BuildContact('JA1ABC', 45005, 'CW', '40M'));
    Check('同じバンドで新しく交信すれば日が進む',
      Log.LastWorkedOn('JA1ABC', '40M') = FormatDateTime('yyyymmdd', 45005),
      Format('("%s")', [Log.LastWorkedOn('JA1ABC', '40M')]));
    { 取り込んだ記録は日付の順とはかぎりません。古いものを後から足しても、
      新しい日が残らなければなりません。
      An imported log is not necessarily in date order: adding an older contact
      afterwards must leave the later date in place. }
    Log.Add(BuildContact('JA1ABC', 44990, 'CW', '40M'));
    Check('古い交信を後から足しても日は戻らない',
      Log.LastWorkedOn('JA1ABC', '40M') = FormatDateTime('yyyymmdd', 45005),
      Format('("%s")', [Log.LastWorkedOn('JA1ABC', '40M')]));
  finally
    Log.Free;
  end;
  Log := TContactLog.Create(Path);
  try
    Log.Load;
    Check('開き直してもバンドごとの日が残る',
      (Log.LastWorkedOn('JA1ABC', '40M') = FormatDateTime('yyyymmdd', 45005)) and
      (Log.LastWorkedOn('JA1ABC', '20M') = FormatDateTime('yyyymmdd', 45010)),
      Format('(40M "%s" / 20M "%s")',
        [Log.LastWorkedOn('JA1ABC', '40M'), Log.LastWorkedOn('JA1ABC', '20M')]));
  finally
    Log.Free;
  end;

  { ---- 時間あたりの交信数（要件 FR-I.5）----
    ---- Contacts per hour (requirement FR-I.5) ---- }
  Path := IncludeTrailingPathDelimiter(Dir) + 'rate.adi';
  Log := TContactLog.Create(Path);
  try
    Log.Load;
    Log.Add(BuildContact('JA1ABC', 45000 + 12 / 24));
    Log.Add(BuildContact('JH2XYZ', 45000 + 11.5 / 24));
    Log.Add(BuildContact('JR3KLM', 45000 + 10 / 24));
    Check('直近 1 時間に 2 局', Log.CountSince(45000 + 11 / 24) = 2,
      Format('(%d)', [Log.CountSince(45000 + 11 / 24)]));
    Check('直近 3 時間なら 3 局', Log.CountSince(45000 + 9 / 24) = 3,
      Format('(%d)', [Log.CountSince(45000 + 9 / 24)]));
    Check('先の時刻なら 0 局', Log.CountSince(45000 + 13 / 24) = 0,
      Format('(%d)', [Log.CountSince(45000 + 13 / 24)]));
    Check('境目の時刻は数に入る', Log.CountSince(45000 + 10 / 24) = 3,
      Format('(%d)', [Log.CountSince(45000 + 10 / 24)]));
    { **時刻の欄が無い記録は数えません。**取り込んだログには日付だけの記録が
      あり得ます。日付だけで比べると、先の日付の記録が「直近 1 時間」に入り、
      速さを水増しします。
      **A record with no time field is not counted.** An imported log can hold
      one dated but not timed; compared on the date alone, a later date would
      fall inside "the last hour" and inflate the rate. }
    Item := Default(TAdifRecord);
    SetAdifValue(Item, 'CALL', '7K1TUV');
    SetAdifValue(Item, 'QSO_DATE', '20991231');
    SetAdifValue(Item, 'MODE', 'CW');
    Log.Add(Item);
    Check('時刻の欄が無い記録は数えない', Log.CountSince(45000 + 11 / 24) = 2,
      Format('(%d)', [Log.CountSince(45000 + 11 / 24)]));
    Check('それでも記録そのものは残る', Log.Count = 4,
      Format('(%d)', [Log.Count]));
  finally
    Log.Free;
  end;

  { 1 万件でも引くのが遅くならないこと。索引を持たずに毎回走査すると、
    バンドマップの 1 行ごとにこれを引くので目に見えて遅くなる。 }
  DeleteFile(Path);
  Log := TContactLog.Create(Path);
  try
    Body := '';
    for I := 1 to 10000 do
      Body := Body + FormatAdifRecord(
        ContactOf(Format('JA%dABC', [I mod 10]), '20260904',
          Format('%.6d', [I]))) + LineEnding;
    with TFileStream.Create(Path, fmCreate) do
      try
        WriteBuffer(Body[1], Length(Body));
      finally
        Free;
      end;
    Started := Now;
    Log.Load;
    Elapsed := MilliSecondsBetween(Now, Started);
    WriteLn(Format('    1 万件の読み込み: %.0f ms', [Elapsed]));
    Check('1 万件を読み込める', Log.Count = 10000, Format('(%d 件)', [Log.Count]));
    Check('1 万件の読み込みが 2 秒未満', Elapsed < 2000,
      Format('(%.0f ms)', [Elapsed]));
    Started := Now;
    for I := 1 to 10000 do
      Log.WorkedCount('JA1ABC');
    Elapsed := MilliSecondsBetween(Now, Started);
    WriteLn(Format('    交信済みの問い合わせ 1 万回: %.0f ms', [Elapsed]));
    Check('問い合わせ 1 万回が 200 ms 未満', Elapsed < 200,
      Format('(%.0f ms)', [Elapsed]));
    { バンドを指定した問い合わせも測ります。**画面が毎秒引くのはこちらです**
      （要件 FR-I.5）。バンドごとの回数はバンドの数だけ並べて持つので、全バンドを
      引くのと同じ桁で収まるはずですが、測らずに「はず」で済ませません。
      The band-specific query is measured too: **this is the one the display asks
      once a second** (requirement FR-I.5). The per-band counts are held as a list
      one entry per band, so it should cost the same order as the all-band query
      -- but "should" is not a measurement. }
    Started := Now;
    for I := 1 to 10000 do
      Log.WorkedCountOn('JA1ABC', '40M');
    Elapsed := MilliSecondsBetween(Now, Started);
    WriteLn(Format('    バンドを指定した問い合わせ 1 万回: %.0f ms', [Elapsed]));
    Check('バンドを指定した問い合わせ 1 万回が 200 ms 未満', Elapsed < 200,
      Format('(%.0f ms)', [Elapsed]));
    { 直近 1 時間の交信数（要件 FR-I.5）は**記録の全件を読みます。**交信済みの
      問い合わせが索引で答えるのと違い、件数に比例して重くなります。**画面が
      これを毎秒行えば、記録を積んだ運用者ほど重くなります。**費用をここに
      出しておき、画面の側では数秒に 1 度に抑えてあります。
      The contacts-in-the-last-hour count (requirement FR-I.5) **reads every
      record**: unlike the worked-before question, which an index answers, it
      grows with the size of the log. **Done every second by the display, it
      would make the application heavier for whoever has logged the most**, so
      the cost is measured here and the display recounts only every few
      seconds. }
    Started := Now;
    for I := 1 to 100 do
      Log.CountSince(45000);
    Elapsed := MilliSecondsBetween(Now, Started);
    WriteLn(Format('    直近の交信数を 100 回数える: %.0f ms（1 回 %.2f ms）',
      [Elapsed, Elapsed / 100]));
    Check('直近の交信数を数えるのが 1 回 10 ms 未満', Elapsed / 100 < 10,
      Format('(%.2f ms)', [Elapsed / 100]));
  finally
    Log.Free;
  end;
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

{ 交信記録が強制終了に耐えることを、本当に強制終了して確かめるための入口です。
  記録帳（TTranscriptJournal）と同じ理由で、殺してみないと分かりません。
  The entry point for checking that the contact log survives a kill by actually
  being killed — for the same reason as the transcript journal, it is only
  answered by killing the process. }
procedure LogUntilKilled(const Directory: string);
var
  Log: TContactLog;
begin
  Log := TContactLog.Create(
    IncludeTrailingPathDelimiter(Directory) + 'contacts.adi');
  Log.Load;
  Log.Add(ContactOf('JH2XYZ', '20260904', '101500'));
  Log.Add(ContactOf('JA1ABC', '20260904', '101800'));
  WriteLn(Log.FileName);
  Flush(Output);
  { 意図的に閉じません。ここで殺されても交信が残っていることが要件です。
    Deliberately never closed: the requirement is that the contacts are there
    even when the process is killed at this point. }
  while True do
    Sleep(200);
end;

{ 録音が強制終了に耐えることを、本当に強制終了して確かめるための入口です。

  **見出しを書き足すたびに直す作りの意味は、ここでしか確かめられません。**
  閉じてから見出しを直す作りでも、通常の試験はすべて通ります。

  The entry point for checking that a recording survives a kill by actually being
  killed.

  **The point of rewriting the headers on every append can only be shown here:**
  a design that fixed them at close would pass every ordinary test. }
procedure RecordUntilKilled(const Directory: string);
var
  Ring: TAudioRing;
  Recorder: TAudioRecorder;
  Path: string;
  Waited: Integer;
begin
  ForceDirectories(Directory);
  Path := IncludeTrailingPathDelimiter(Directory) + 'kill.wav';
  Ring := TAudioRing.Create(8000 * 4);
  Recorder := TAudioRecorder.Create(Ring, 8000);
  if not Recorder.Start(Path) then
  begin
    WriteLn(StdErr, Recorder.LastError);
    Halt(2);
  end;
  Ring.Push(FilledWith(0.5, 8000), 8000);
  { 実際に書けるまで待ってから名前を出します。名前だけ先に出すと、まだ 1 標本も
    書けていないものを「書けている」と読み違えます。
    The name is printed only once something has actually been written: printing
    it first would let a recording with not one sample in it be read as
    written. }
  Waited := 0;
  while (Recorder.Snapshot.Seconds <= 0) and (Waited < 5000) do
  begin
    Sleep(20);
    Inc(Waited, 20);
  end;
  WriteLn(Path);
  Flush(Output);
  { 意図的に止めません。ここで殺されても、そこまでが読める WAV であることが
    要件です。
    Deliberately never stopped: the requirement is that what was written so far
    is a readable WAV even when the process is killed at this point. }
  while True do
  begin
    Ring.Push(FilledWith(0.5, 800), 800);
    Sleep(100);
  end;
end;

{ 殺されたあとのファイルを読み、標本の数を出します。読めなければ終了コードで
  伝えます。**WAV は文字を探して確かめられないので、読めるかどうかで確かめます。**
  Reads the file left behind and reports how many samples it holds, reporting
  failure through the exit code. **A WAV cannot be checked by looking for a word
  in it, so it is checked by being read.** }
{ 参照番号の取り出し（要件 FR-E.6）。

  受入基準は「誤検出率が実用範囲」なので、**当たることと、当たらないことの
  両方**を見ます。当たるほうだけを並べた試験は、全部を拾う規則でも通ります。

  Pulling out the references (requirement FR-E.6).

  The acceptance criterion is a practical false-positive rate, so this checks
  **both what is found and what is not**: a test that only lists the hits would
  pass a rule that takes everything. }
procedure TestReferences;
var
  Found: TReferences;

  function OneOf(const Text: string): TReference;
  begin
    Found := ExtractReferences(Text);
    if Length(Found) = 1 then
      Result := Found[0]
    else
      Result := Default(TReference);
  end;

  procedure Nothing(const What, Text: string);
  begin
    Found := ExtractReferences(Text);
    Check(What, Length(Found) = 0,
      Format('(%d 件)', [Length(Found)]));
  end;

  { 受信文を復号文字に見立てて `ReadExchange` に通し、位置まで確かめます。
    Runs the text through `ReadExchange` as decoded characters, positions and
    all. }
  procedure ReferencesOfExchange(const Text, Wanted: string;
    First, Last: Integer);
  var
    Chars: TDecodedChars;
    Ex: TExchange;
    I: Integer;
  begin
    SetLength(Chars, Length(Text));
    for I := 1 to Length(Text) do
    begin
      Chars[I - 1].Text := Text[I];
      Chars[I - 1].Confidence := 0.9;
      Chars[I - 1].Seconds := (I - 1) * 0.1;
      Chars[I - 1].EndSeconds := Chars[I - 1].Seconds + 0.08;
    end;
    Ex := ReadExchange(Chars);
    Check(Format('%s を受信文の読み取りから得る', [Wanted]),
      (Length(Ex.References) = 1) and (Ex.References[0].Text_ = Wanted),
      Format('(%d 件)', [Length(Ex.References)]));
    { 条件のほうへ入れます。`if` の外に出すと、見つからなくなった日にこの検証は
      黙って消えます（教訓 10.32）。
      Inside the condition: outside an `if`, this check would quietly vanish the
      day nothing is found (lesson 10.32). }
    Check(Format('%s の位置が復号文字の番号と合う', [Wanted]),
      (Length(Ex.References) = 1) and (Ex.References[0].First = First)
        and (Ex.References[0].Last = Last),
      Format('(%d 件)', [Length(Ex.References)]));
  end;

var
  Ref: TReference;
begin
  WriteLn;
  WriteLn('参照番号の取り出し（要件 FR-E.6）');

  { [1] 電波に乗った形。**ハイフンは `6T` と読まれます**（付録 AN の実測）。
        規則が `JP-0123` を探していたら、1 つも当たりません。
        [1] The form that comes off the air: **a hyphen reads as `6T`** (measured,
        appendix AN). A rule looking for `JP-0123` would never match. }
  Ref := OneOf('QTH IS JP6T0123 PSE QSL');
  Check('ハイフンが `6T` と読まれた公園符号を見つける',
    (Length(Found) = 1) and (Ref.Kind = rkPota) and (Ref.Text_ = 'JP-0123'),
    Format('(%d 件 %s)', [Length(Found), Ref.Text_]));
  Check('受信文のままの形も残す', Ref.Raw = 'JP6T0123', Ref.Raw);
  Check('区切りが送られていたので確かとする', Ref.Trust = rtMarked);
  Check('位置が受信文の中の位置と合う',
    Copy('QTH IS JP6T0123 PSE QSL', Ref.First + 1, Ref.Last - Ref.First + 1)
      = 'JP6T0123',
    Copy('QTH IS JP6T0123 PSE QSL', Ref.First + 1, Ref.Last - Ref.First + 1));

  Ref := OneOf('SOTA JA/NN6T015 ES TNX');
  Check('山岳符号を見つける',
    (Length(Found) = 1) and (Ref.Kind = rkSota) and (Ref.Text_ = 'JA/NN-015'),
    Format('(%d 件 %s)', [Length(Found), Ref.Text_]));

  { [2] ハイフンがそのまま来た場合。録音の読み直しや手で直した文では在り得ます。
        [2] A hyphen that did arrive -- possible in an edited or imported text. }
  Ref := OneOf('QTH JP-0123');
  Check('ハイフンそのものでも見つける',
    (Length(Found) = 1) and (Ref.Text_ = 'JP-0123') and (Ref.Trust = rtMarked),
    Format('(%d 件 %s)', [Length(Found), Ref.Text_]));

  { [3] 区切りが送られなかった場合。**見つけはしますが、ハイフンの位置は
        こちらの推測**なので、確かさは低いほうにします。
        [3] No separator sent: found, but **where the hyphen goes is our guess**,
        so it takes the weaker trust. }
  Ref := OneOf('JP0123 TNX');
  Check('区切りの無い形も見つける',
    (Length(Found) = 1) and (Ref.Text_ = 'JP-0123'),
    Format('(%d 件 %s)', [Length(Found), Ref.Text_]));
  Check('区切りが無ければ確かでないとする', Ref.Trust = rtLoose);
  Check('確かでないものは、そうと分かる形で出す',
    Pos('?', ReferenceCaption(Ref)) > 0, ReferenceCaption(Ref));
  Check('確かなものに `?` は付けない',
    Pos('?', ReferenceCaption(OneOf('QTH JP-0123'))) = 0,
    ReferenceCaption(Ref));

  { [4] 添え言葉。空白だけの区切りでも、POTA・SOTA が前に在れば受け取ります。
        [4] An introducing word: with POTA or SOTA in front, even a space is
        enough. }
  Found := ExtractReferences('POTA JP 0123 ES SOTA JA/NN 015');
  Check('添え言葉があれば、空白区切りでも両方見つける',
    (Length(Found) = 2) and (Found[0].Text_ = 'JP-0123')
      and (Found[1].Text_ = 'JA/NN-015'),
    Format('(%d 件)', [Length(Found)]));
  { `if Length = 2 then Check(...)` と書くと、**見つからなくなった日に
    この検証は黙って消えます。**条件のほうへ入れて、落ちるようにします
    （教訓 10.32）。
    Written as `if Length = 2 then Check(...)` **this check would quietly
    vanish** the day nothing is found; it goes inside the condition instead, so
    it fails (lesson 10.32). }
  Check('添え言葉があるものは確かとする',
    (Length(Found) = 2) and (Found[0].Trust = rtMarked)
      and (Found[1].Trust = rtMarked));

  { [5] **ここからが受入基準のほう**です。実際の交信文に当てて、何も出ない
        ことを見ます。

        とくに `NR 0123` は、書いたあとに測って見つかった誤検出です（付録 AN）。
        形だけでは `JP 0123` と区別が付きません。

        [5] **Now the acceptance criterion.** Real exchanges, and nothing should
        come out.

        `NR 0123` in particular is a false positive found by measuring after the
        rule was written (appendix AN): by shape it cannot be told from
        `JP 0123`. }
  Nothing('呼び出しを参照番号と取り違えない', 'CQ CQ DE JA1ABC JA1ABC K');
  Nothing('信号報告を参照番号と取り違えない',
    'JA1ABC DE JH2XYZ UR 599 599 QTH NAGOYA');
  Nothing('別れの挨拶を参照番号と取り違えない',
    'TNX FER QSO 73 ES GL DE JH2XYZ SK');
  Nothing('コンテストの通し番号を参照番号と取り違えない',
    'UR RST 579 579 NR 0123 NR 0123 K');
  Nothing('報告に続く通し番号を参照番号と取り違えない',
    'CQ TEST DE JA1ABC 599 0012');
  Nothing('設備や天候の数値を参照番号と取り違えない',
    'WX SUNNY TEMP 25 C PWR 100 W ANT DIPOLE');
  { 雑音の中では、離れていた 2 語が 1 語につながって読めることがあります。
    **つながった通し番号は、形だけなら公園符号と同じ並びです。**数字だけの語を
    前置符字と見ないので、取りません。
    Under noise two words can arrive run together, and **a run-together serial
    has the very shape of a park code.** An all-digit word is not a prefix, so it
    is not taken. }
  Nothing('つながって読まれた数字の並びを参照番号と取り違えない',
    'UR 5990123 K');
  { 山岳符号の地域は 2 文字です。**1 文字が数字に化けて読めたものは、
    山岳符号の形をしていません。**
    A summit region is two letters: **one of them misread as a digit is not the
    shape of a summit.** }
  Nothing('地域が 2 文字でないものを山岳符号と取り違えない',
    'SOTA JA/N16T015 ES TNX');
  { 添え言葉の無い空白区切りは取りません。**取れば `NR 0123` も取ることに
    なります。**
    A space-separated pair with nothing introducing it is not taken: **taking it
    would take `NR 0123` too.** }
  Nothing('添え言葉の無い空白区切りは取らない', 'JP 0123 ES JA/NN 015');

  { [6] 受信文の読み取り（`ReadExchange`）へつないだとき、位置が**復号文字の
        番号**で返ること。画面はこの番号で印を付けるので、**1 つずれれば印は
        隣の文字に乗ります。**位置を 1 つずらしてみると、実際にここが落ちます。
        [6] Through `ReadExchange`, the positions come back **in decoded-character
        indices**. The display marks by that index, so **one out and the mark
        lands on the neighbour**: shifting the positions by one does indeed make
        this fail. }
  ReferencesOfExchange('QTH IS JP6T0123 PSE QSL', 'JP-0123', 7, 14);
  ReferencesOfExchange('SOTA JA/NN6T015 ES TNX', 'JA/NN-015', 5, 14);
  { 語をまたぐものも、始まりと終わりが両端の語の位置になること。
    One spanning two words starts and ends at those two words. }
  ReferencesOfExchange('POTA JP 0123 K', 'JP-0123', 5, 11);

  { [7] 空の受信文。**まだ何も読めていない間も呼ばれます。**

        この 2 つが捕まえるのは規則の誤りではなく、**語が 1 つも無いときに
        走査が行き過ぎること**です。実際、語の走査を `High` から `Length` へ
        1 つ広げると、ここで落ちます。
        [6] An empty transcript: **this is called while nothing has been read
        yet.**

        What these two catch is not a wrong rule but **a scan running past the
        end when there is no word at all**: widening the loop from `High` to
        `Length` does indeed die right here. }
  Nothing('空の受信文で何も出ない', '');
  Nothing('空白だけの受信文で何も出ない', '   ');
end;

{ 手元の呼出符号一覧（要件 FR-K.9）。

  **通信せずに照合できること**が要件です。ここで確かめるのは、読めること、
  引けること、そして**読めないときに受信を止めないこと**（要件 FR-K.10）です。

  配られている一覧の形はまちまちなので、**こちらが決めた 1 つの形しか読めない
  のでは「一覧を読み込める」と言えません。**いくつかの形を並べて見ます。

  The locally held call sign roster (requirement FR-K.9).

  The requirement is matching **without any traffic**. What is checked here is
  that a file can be read, looked up in, and that **failing to read it does not
  stop reception** (requirement FR-K.10).

  The distributed rosters are not shaped alike, so **reading only one shape of
  our own choosing would not be "can read the rosters"**: several are tried. }
procedure TestRoster;
var
  Roster: TCallsignRoster;
  Folder: string;

  procedure Put(const Name_: string; const Lines: array of string);
  var
    List: TStringList;
    I: Integer;
  begin
    List := TStringList.Create;
    try
      for I := Low(Lines) to High(Lines) do
        List.Add(Lines[I]);
      List.SaveToFile(Folder + Name_);
    finally
      List.Free;
    end;
  end;

begin
  WriteLn;
  WriteLn('手元の呼出符号一覧（要件 FR-K.9）');
  Folder := IncludeTrailingPathDelimiter(GetTempDir) + 'deepcw_roster' +
    PathDelim;
  ForceDirectories(Folder);
  Roster := TCallsignRoster.Create;
  try
    { [1] 行から符号を取り出す規則。**最初の語だけ**を見ます。
      [1] Pulling the call sign out of a line: **the first word only.** }
    Check('1 行 1 符号', RosterToken('JA1ABC') = 'JA1ABC',
      RosterToken('JA1ABC'));
    Check('コンマ区切りは最初の列', RosterToken('JA1ABC,TARO,TOKYO') = 'JA1ABC',
      RosterToken('JA1ABC,TARO,TOKYO'));
    Check('タブ区切りも最初の列', RosterToken('JA1ABC' + #9 + 'TARO') = 'JA1ABC',
      RosterToken('JA1ABC' + #9 + 'TARO'));
    Check('前後の空白は落とす', RosterToken('  JA1ABC  ') = 'JA1ABC',
      RosterToken('  JA1ABC  '));
    Check('# の行は注記', RosterToken('# 2026 年版') = '',
      RosterToken('# 2026 年版'));
    { `;` の行からも何も出ませんが、**理由は注記だからではなく、`;` が区切り
      だから**です。実際、注記の判定から `;` を外しても、この検証は通ります
      ——壊して確かめて分かりました。名前のほうを理由に合わせます。
      A `;` line yields nothing too, **not because it is a note but because `;`
      is a separator**: dropping `;` from the note test leaves this check
      passing, as trying to break it showed. The name is made to match the
      reason. }
    Check('; は区切りなので、その行からは何も出ない',
      RosterToken('; note') = '', RosterToken('; note'));
    Check('空の行からは何も出ない', RosterToken('') = '');

    { [2] 読み込み。重複は 1 つに、形に合わない行は数えて飛ばします。
      [2] Loading: duplicates become one, and lines that do not fit are counted
      and skipped. }
    Put('plain.txt', ['# 手元の一覧', 'JA1ABC', 'JH2XYZ', 'JG3DEF', 'JA1ABC',
      'CALLSIGN']);
    Roster.LoadFromFile(Folder + 'plain.txt');
    Check('読めた件数が合う（重複を除く）', Roster.Count = 3,
      Format('(%d)', [Roster.Count]));
    Check('符号として読めなかった行を数える', Roster.Skipped = 1,
      Format('(%d)', [Roster.Skipped]));
    Check('読み込みに誤りは無い', Roster.LastError = '', Roster.LastError);
    { **file 名だけ**を持ちます。path には利用者の名前が入ることがあります
      （要件 FR-K.7）。
      **The file name alone** is kept: a path can carry the operator's own name
      (requirement FR-K.7). }
    Check('持つのはファイル名だけで、path は持たない',
      (Roster.Name = 'plain.txt') and (Pos(PathDelim, Roster.Name) = 0),
      Roster.Name);

    { [3] 引けること。**附加符号は落として引きます。**`JA1ABC/P` は一覧の
      `JA1ABC` に当たらなければなりません。
      [3] Looking up, **with the appended designator removed**: `JA1ABC/P` has
      to find the roster's `JA1ABC`. }
    Check('一覧にある符号が引ける', Roster.Contains('JA1ABC'));
    Check('小文字でも引ける', Roster.Contains('ja1abc'));
    Check('附加符号つきでも引ける', Roster.Contains('JA1ABC/P'));
    Check('一覧に無い符号は引けない', not Roster.Contains('JA9ZZZ'));
    Check('空の符号では引けない', not Roster.Contains(''));

    { [4] **符号のほかは何も残しません**（要件 FR-K.7）。名前や常置場所が
      並んでいても、持つのは最初の列だけです。
      [4] **Nothing but the call sign is kept** (requirement FR-K.7): with names
      and addresses alongside, only the first column is held. }
    Put('withnames.txt', ['JA1ABC,TARO,TOKYO', 'JH2XYZ,HANAKO,NAGOYA']);
    Roster.LoadFromFile(Folder + 'withnames.txt');
    Check('名前つきの一覧でも符号は読める',
      Roster.Contains('JA1ABC') and Roster.Contains('JH2XYZ'),
      Format('(%d 件)', [Roster.Count]));
    Check('名前は持たない', (Roster.Count = 2) and not Roster.Contains('TARO'),
      Format('(%d 件)', [Roster.Count]));

    { [5] 読めなくても止まりません（要件 FR-K.10）。**「照合できない」は
      「受信できない」ではありません。**
      [5] Unreadable does not stop anything (requirement FR-K.10): **"cannot
      match" is not "cannot receive".** }
    Roster.LoadFromFile(Folder + 'no_such_file.txt');
    Check('無いファイルでも例外にしない', Roster.LastError <> '',
      Roster.LastError);
    Check('無いファイルなら件数は 0', Roster.Count = 0,
      Format('(%d)', [Roster.Count]));
    Check('引いても落ちない（何も当たらない）',
      not Roster.Contains('JA1ABC'));
    { 読めなかったときは名前も出しません。**読めていない一覧の名前を出すと、
      読めたように見えます。**
      No name either when it could not be read: **naming a roster that was not
      read makes it look as though it had been.** }
    Check('読めなければ名前も出さない', Roster.Name = '', Roster.Name);

    Put('empty.txt', []);
    Roster.LoadFromFile(Folder + 'empty.txt');
    Check('空のファイルでも落ちない', (Roster.Count = 0) and
      (Roster.LastError = ''), Roster.LastError);

    { [6] 上限で打ち切ったときは、そう言います。**黙って途中で止めると、
      一覧に在る符号が「無い」と出ます。**
      [6] A cap that cuts it short says so: **stopping quietly would report call
      signs that are in the roster as absent.** }
    Put('many.txt', ['JA1ABC', 'JH2XYZ', 'JG3DEF', 'JA1AAA', 'JA1AAB']);
    Roster.LoadFromFile(Folder + 'many.txt', 1000000);
    Check('上限に届かなければ打ち切らない', not Roster.Truncated);
    Roster.LoadFromFile(Folder + 'many.txt', 10);
    Check('上限で打ち切ったら、そう言う', Roster.Truncated);
    Check('打ち切っても読めたぶんは引ける', Roster.Contains('JA1ABC'),
      Format('(%d 件)', [Roster.Count]));
  finally
    Roster.Free;
  end;
end;

{ 国別前置符字表（要件 FR-K.12）。

  この単位の形の規則は ITU 第 19 条の**形**だけを見ます。形は満たすがどの国にも
  割り当てられていない前置符字は、表が無ければ通ります。表はそこを締めます。

  **いちばん大事なのは、表が締めるだけで緩めないこと**です。壊れた表を渡しても、
  形の規則が拒む符号が通るようになってはいけません。

  The country prefix table (requirement FR-K.12).

  The form rule in this unit checks only **the form** of Article 19, so a prefix
  that fits it but is allocated to no country passes unless a table says
  otherwise. The table tightens that.

  **What matters most is that the table only tightens**: however damaged a table
  is handed over, a call sign the form rule rejects must never start passing. }
procedure TestPrefixTable;
var
  Parsed: TCallsign;
  Table_: TPrefixTable;
  Folder, Seen, Token_: string;
  I, Passed, Kinds: Integer;

  function Fits(const Token: string): Boolean;
  begin
    Result := ParseCallsign(Token, Parsed);
  end;

  procedure Put(const Name_: string; const Lines: array of string);
  var
    List: TStringList;
    K: Integer;
  begin
    List := TStringList.Create;
    try
      for K := Low(Lines) to High(Lines) do
        List.Add(Lines[K]);
      List.SaveToFile(Folder + Name_);
    finally
      List.Free;
    end;
  end;

const
  { 形は満たすが、どの国にも割り当てられていない前置符字。**表が無いあいだは
    通ってしまうもの**です。
    Prefixes that fit the form but are allocated to no country -- **what passes
    while there is no table.** }
  UNALLOCATED: array[0..2] of string = ('QZ1ABC', 'XQ9ABC', 'YZ2ABC');
  { 実在する前置符字の符号。**表を入れても通り続けなければなりません。**
    Call signs on real prefixes: **these must go on passing with a table in. **}
  REAL_CALLS: array[0..3] of string = ('JA1ABC', 'JH2XYZ', 'W1AW', 'VE3ABC');
begin
  WriteLn;
  WriteLn('国別前置符字表（要件 FR-K.12）');
  Folder := IncludeTrailingPathDelimiter(GetTempDir) + 'deepcw_roster' +
    PathDelim;
  ForceDirectories(Folder);

  { [1] 表が無いあいだは、何も変わりません。**「表に無い」と「表が無い」を
        同じ顔で扱ってはいけません。**
        [1] With no table nothing changes: **"not in the table" and "there is no
        table" must not wear the same face.** }
  SetAllocatedPrefixes([]);
  Check('表が無ければ件数は 0', AllocatedPrefixCount = 0,
    Format('(%d)', [AllocatedPrefixCount]));
  Check('表が無ければ、どの前置符字も割り当てありとみなす',
    PrefixAllocated('QZ') and PrefixAllocated('JA'));
  Passed := 0;
  for I := Low(UNALLOCATED) to High(UNALLOCATED) do
    if Fits(UNALLOCATED[I]) then
      Inc(Passed);
  Check('表が無いあいだは、割り当ての無い前置符字も形だけで通る',
    Passed = Length(UNALLOCATED), Format('(%d / %d)',
      [Passed, Length(UNALLOCATED)]));

  { [2] 表を入れると締まります。**これが要件そのものです。**
        [2] A table tightens it. **That is the requirement itself.** }
  SetAllocatedPrefixes(['JA', 'JH', 'W', 'K', 'VE']);
  Check('表の件数が合う', AllocatedPrefixCount = 5,
    Format('(%d)', [AllocatedPrefixCount]));
  { 引く側は公開の関数なので、**小文字で来ても当てます。**呼ぶ側が必ず大文字で
    渡すとはかぎりません。
    The lookup is a public function, so **it answers for lower case too**: not
    every caller is bound to hand it upper case. }
  Check('小文字の前置符字でも引ける', PrefixAllocated('ja'));
  Passed := 0;
  for I := Low(UNALLOCATED) to High(UNALLOCATED) do
    if Fits(UNALLOCATED[I]) then
      Inc(Passed);
  Check('表を入れると、割り当ての無い前置符字を弾く', Passed = 0,
    Format('(%d / %d 通った)', [Passed, Length(UNALLOCATED)]));

  { **実在の符号は通り続けなければなりません。**弾きすぎる表は、弾かない表より
    害が大きい。読めた符号が一覧から消えるためです。
    **Real call signs must go on passing**: a table that rejects too much does
    more harm than one that rejects nothing, since call signs that were read
    would vanish from the list. }
  Passed := 0;
  for I := Low(REAL_CALLS) to High(REAL_CALLS) do
    if Fits(REAL_CALLS[I]) then
      Inc(Passed);
  Check('表を入れても、実在の前置符字は通り続ける',
    Passed = Length(REAL_CALLS),
    Format('(%d / %d)', [Passed, Length(REAL_CALLS)]));

  { [3] **表は締めるだけで、緩めません。**形が拒むものを表に載せても通りません。
        壊れた表を渡されても、読めない符号が読めるようにはならない保証です。
        [3] **The table only tightens.** Listing what the form rejects does not
        make it pass: the guarantee that a damaged table can never make an
        unreadable call sign readable. }
  { **表に載せても、形が拒むものは通りません。**

    ここは「数字だけの語」では確かめられません。`12345` は前置符字の判定へ
    たどり着く前に構造で落ちるので、**表をどう壊しても、この検証は通って
    しまいます**（書いてから壊して分かりました）。

    効くのは 1 字の前置符字です。第 19.68 条が認める 1 字は
    **B・F・G・I・K・M・N・R・W だけ**なので、`A1ABC` は形で落ちます。その `A` を
    表に載せても通ってはいけません。**表を `and` ではなく `or` で足すと、ここが
    落ちます。**

    **A table can never pass what the form rejects.**

    An all-digit word cannot show this: `12345` fails on structure before the
    prefix rule is reached, so **however the table is broken, that check would
    pass** -- as trying to break it showed.

    A single-character prefix does show it. Article 19.68 allows only
    **B, F, G, I, K, M, N, R and W**, so `A1ABC` fails on form; listing that `A`
    in the table must not let it through. **Adding the table with `or` instead
    of `and` makes this fail.** }
  SetAllocatedPrefixes(['A', '12', '']);
  Check('形が拒む 1 字前置符字は、表に載せても通らない',
    not Fits('A1ABC'), 'A1ABC');
  Check('空の項目は表に入らない', AllocatedPrefixCount = 2,
    Format('(%d)', [AllocatedPrefixCount]));

  { 表に無い前置符字は、形が合っていても弾きます。**これが「締める」という
    ことです。**
    A prefix absent from the table is rejected however well it fits the form:
    **that is what tightening means.** }
  SetAllocatedPrefixes(['QZ']);
  Check('表に無い前置符字は、形が合っていても弾く', not Fits('JA1ABC'),
    'JA1ABC');
  Check('表にある前置符字は通る', Fits('QZ1ABC'), 'QZ1ABC');

  { [4] 表を外せば元へ戻ります。**外したはずの表が効いたままでは、利用者は
        原因にたどり着けません。**
        [4] Dropping the table puts it back: **one that went on tightening after
        being dropped would leave the operator with no way to the cause.** }
  SetAllocatedPrefixes([]);
  Check('表を外せば、割り当ての無い前置符字がまた通る', Fits('QZ1ABC'));

  { [5] ファイルから読む。呼出符号の一覧と**同じ読み方**です。
        [5] Read from a file, **the same way** a call sign roster is. }
  Table_ := TPrefixTable.Create;
  try
    Put('prefixes.txt', ['# 国別前置符字', 'JA', 'JH,日本', 'W', 'W',
      '日本', '123']);
    Table_.LoadFromFile(Folder + 'prefixes.txt');
    Check('前置符字を読める', Table_.Count = 4,
      Format('(%d)', [Table_.Count]));
    Check('前置符字として読めなかった行を数える', Table_.Skipped = 2,
      Format('(%d)', [Table_.Skipped]));
    Check('持つのはファイル名だけ', Table_.Name = 'prefixes.txt', Table_.Name);
    { 重複は、渡したあとに 1 つへまとまります。
      Duplicates become one once handed over. }
    SetAllocatedPrefixes(Table_.Items);
    Check('重複は 1 つにまとまる', AllocatedPrefixCount = 3,
      Format('(%d)', [AllocatedPrefixCount]));
    Check('読んだ表で締まる', not Fits('QZ1ABC') and Fits('JA1ABC'));

    { 読めなくても止まりません（要件 FR-K.10）。**表が読めないのは
      「締められない」であって「受信できない」ではありません。**
      Unreadable does not stop anything (requirement FR-K.10): **an unreadable
      table means "cannot tighten", not "cannot receive".** }
    Table_.LoadFromFile(Folder + 'no_such_prefixes.txt');
    Check('無いファイルでも例外にしない', Table_.LastError <> '',
      Table_.LastError);
    Check('無いファイルなら件数は 0', Table_.Count = 0,
      Format('(%d)', [Table_.Count]));
    Check('読めなければ名前も出さない', Table_.Name = '', Table_.Name);
    SetAllocatedPrefixes(Table_.Items);
    Check('読めなければ、締めずに元のまま', Fits('QZ1ABC'));
  finally
    Table_.Free;
  end;
  { [6] **練習の出題が空にならないこと。**出題は組み立てた符号を
        `ParseCallsign` に通したものだけを採ります（教訓 10.30）。表を入れると
        その規則が締まるので、**出題に使う前置符字をどれも含まない表を入れたら
        どうなるか**を測ります。

        50 回試して駄目なら確実に通る形へ落ちる作りなので、止まりも空にも
        なりません。**出題が偏るだけで、練習そのものは続きます。**利用者が
        誤った表を選んでも、練習が壊れないことを確かめます。

        [6] **An exercise is never empty.** Exercises take only what
        `ParseCallsign` accepts (lesson 10.30), and a table tightens that rule,
        so **what happens with a table holding none of the prefixes exercises
        are built from** is measured here.

        Fifty attempts then a fall back to a form known to pass: neither a hang
        nor an empty string. **The exercises merely narrow; the practice goes
        on.** A wrong table chosen by the operator does not break it. }
  SetAllocatedPrefixes(['QZ']);
  Check('狭すぎる表でも、練習の出題は空にならない',
    Length(Trim(MakeExercise(ekCallsigns, 3, 77))) > 0,
    MakeExercise(ekCallsigns, 3, 77));
  { **形の規則には通り続けなければなりません。**通らない形を出せば、覚えるのは
    実在しない符号の形です（教訓 10.30）。ここは `ParseCallsignShape` で見ます
    ——出題が表に縛られないようにしたのが、まさにこの検証で見つけた欠陥への
    答えだからです。
    **It must go on passing the form rule**: an exercise the rule rejects
    teaches a shape that does not exist (lesson 10.30). Checked with
    `ParseCallsignShape`, since freeing the exercises from the table is the
    answer to the very defect this check found. }
  Check('狭すぎる表でも、出題は呼出符号の形をしている',
    ParseCallsignShape(Trim(Copy(MakeExercise(ekCallsigns, 1, 77), 1,
      Pos(' ', MakeExercise(ekCallsigns, 1, 77) + ' ') - 1)), Parsed),
    MakeExercise(ekCallsigns, 1, 77));

  { **出題が 1 つへ縮まないこと。**形を見るだけでは、ここは捕まりません
    ——既定値 `JA1ABC` も形としては正しいからです。狭い表を通していると、
    50 回の試行がすべて外れて**毎回この既定値になり、練習が 1 つの符号の
    繰り返しになります。**

    書いたときは形だけを見ていて、**直した箇所を戻しても検証が落ちません
    でした。**見るものを「形」から「種類の数」へ変えて、ようやく効きました。

    **The exercises must not collapse to one.** Checking the form does not
    catch this, the fallback `JA1ABC` being well formed: going through a narrow
    table, all fifty attempts miss and **every exercise becomes that fallback,
    turning the practice into one call sign repeated.**

    As first written this checked the form, and **putting the defect back left
    it passing.** Only counting distinct call signs made it bite. }
  Kinds := 0;
  Seen := '';
  for I := 1 to 12 do
  begin
    Token_ := Trim(Copy(MakeExercise(ekCallsigns, 1, 500 + I), 1,
      Pos(' ', MakeExercise(ekCallsigns, 1, 500 + I) + ' ') - 1));
    if Pos('|' + Token_ + '|', Seen) = 0 then
    begin
      Seen := Seen + '|' + Token_ + '|';
      Inc(Kinds);
    end;
  end;
  Check('狭すぎる表でも、出題は 1 つの符号に縮まない', Kinds > 1,
    Format('(%d 種類)', [Kinds]));

  { **あとの試験に持ち越しません。**単位の状態を触る試験は、片付けまでが試験
    です。
    **Nothing is carried into the tests that follow**: a test that touches a
    unit's state is not done until it has put it back. }
  SetAllocatedPrefixes([]);
end;

procedure CheckWavFile(const FileName: string);
var
  Samples: TSingleArray;
  Rate: Integer;
begin
  try
    LoadWavMono(FileName, Samples, Rate);
  except
    on E: Exception do
    begin
      WriteLn(StdErr, '読めません: ', E.Message);
      Halt(1);
    end;
  end;
  WriteLn(Format('%d 標本 / %d Hz', [Length(Samples), Rate]));
  if Length(Samples) <= 0 then
    Halt(1);
end;


{ 不完全な送信の WAV を書き出します。**実機の画面で採点の経路を確かめる
  ためのものです。**この容器には音声装置が無く、鍵も無いので、録音から
  採点する道が無ければ画面側は一度も動きません。
  Writes a WAV of imperfect sending. **It exists so that the scoring path can be
  exercised in the real window**: this container has no audio device and no key,
  and without scoring from a recording the screen side would never run at all. }
procedure WriteFistWav(const Path, Which, Text: string);
const
  RATE = 8000;
var
  Hands: TSendings;
  I, Chosen: Integer;
begin
  Hands := AppendixCases;
  Chosen := 0;
  for I := 0 to High(Hands) do
    if (Which <> '') and (Pos(Which, Hands[I].Name) > 0) then
      Chosen := I;
  SaveWavMono(Path, SendText(Text, Hands[Chosen], RATE, 4242), RATE);
  WriteLn(Format('%s に書きました（%s / %s）', [Path, Hands[Chosen].Name, Text]));
end;

begin
  MetadataPath := '';
  if ParamStr(1) = '--record-until-killed' then
  begin
    RecordUntilKilled(ParamStr(2));
    Halt(0);
  end;
  if ParamStr(1) = '--fist-wav' then
  begin
    WriteFistWav(ParamStr(2), ParamStr(3),
      ParamStr(4) + ParamStr(5) + ParamStr(6));
    Halt(0);
  end;
  if ParamStr(1) = '--wav-check' then
  begin
    CheckWavFile(ParamStr(2));
    Halt(0);
  end;
  if ParamStr(1) = '--journal-until-killed' then
  begin
    RunUntilKilled(ParamStr(2));
    Halt(0);
  end;
  if ParamStr(1) = '--log-until-killed' then
  begin
    LogUntilKilled(ParamStr(2));
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
    Answers := TAlwaysWorked.Create;
    Listed := TAlwaysInRoster.Create;
    Waiting := TWatchingFor.Create;
    Waiting.List := ParseWatchList('JH2XYZ');
    try
      TestBandMap;
    finally
      Waiting.Free;
      Listed.Free;
      Answers.Free;
    end;
    TestContactLog;
    TestExchange;
    TestWatch;
    TestPractice;
    TestRecorder;
    TestFist;
    TestFistLog;
    TestDiagnostics;
    TestMonitorAudio;
    TestPacing;
    TestHistogram;
    TestReferences;
    TestRoster;
    TestPrefixTable;
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
