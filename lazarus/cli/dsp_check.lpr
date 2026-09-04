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
  DeepCW.Tuner, DeepCW.Review, DeepCW.Journal, DeepCW.Decoder;

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
    TestHistory;
    TestJournal;
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
