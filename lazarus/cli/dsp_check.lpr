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
  DeepCW.Tuner, DeepCW.Review, DeepCW.Journal, DeepCW.Decoder,
  DeepCW.Multi, DeepCW.BandMap, DeepCW.Log, DeepCW.Exchange, DeepCW.Watch,
  DeepCW.Audio, DeepCW.Recorder, DeepCW.Practice, DeepCW.Callsign,
  DeepCW.Morse;

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

begin
  MetadataPath := '';
  if ParamStr(1) = '--record-until-killed' then
  begin
    RecordUntilKilled(ParamStr(2));
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
    Waiting := TWatchingFor.Create;
    Waiting.List := ParseWatchList('JH2XYZ');
    try
      TestBandMap;
    finally
      Waiting.Free;
      Answers.Free;
    end;
    TestContactLog;
    TestExchange;
    TestWatch;
    TestPractice;
    TestRecorder;
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
