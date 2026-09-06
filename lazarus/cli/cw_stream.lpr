program cw_stream;

{ 流し込み受信の検証用ツールです。

  WAV を実時間と同じ刻みで少しずつ投入し、確定テキストと暫定テキストが
  どう育つかを表示します。サウンドカードなしに FR-B.2〜B.4 を確かめられます。

  A harness for the streaming receive path. It feeds a WAV file in
  real-time-sized chunks and shows how the confirmed and provisional text
  grow, so FR-B.2 to B.4 can be checked without a sound card. }

{$mode objfpc}{$H+}

uses
  SysUtils, Math, DeepCW.Types, DeepCW.Onnx, DeepCW.Wave, DeepCW.Decoder,
  DeepCW.Morse, DeepCW.Stream;

const
  { 要件 NFR-1.1・NFR-1.2 の目標。**数字をここに名前で置くのは、判定と表示が
    同じ値を使うためです。**別々に書けば、片方を直したときにもう片方が古い
    ままになります。
    The targets of requirements NFR-1.1 and NFR-1.2. **They are named here so
    that the verdict and the display use the same value**: written separately,
    changing one would leave the other stale. }
  TARGET_PENDING_SECONDS = 1.5;
  TARGET_CONFIRM_SECONDS = 5.0;

var
  ModelPath: string = '';
  MetadataPath: string = '';
  RuntimePath: string = '';
  WavPath: string = '';
  { 既定は画面と同じ刻みです。別の値にすると、目標を満たしているかどうかを
    実際の動作点で測らないことになります。
    The default is the interval the display uses; any other value measures at a
    point the product never runs at. }
  ChunkSeconds: Double = STREAM_FEED_SECONDS;
  Quiet: Boolean = False;
  NoAntiAlias: Boolean = False;
  Check: Boolean = False;
  Failed: Boolean = False;
  SourceText: string = '';
  MaxPending: Double = TARGET_PENDING_SECONDS;
  MaxConfirm: Double = TARGET_CONFIRM_SECONDS;
  Timing: TCWTiming;
  ToneOptions: TCWToneOptions;
  Decoder: TDeepCWDecoder;
  Stream: TStreamingDecoder;
  Samples, Chunk: TSingleArray;
  SampleRate, Position, Count, Index, ConfirmedCount, Rewrites: Integer;
  Key, Value, Previous, ConfirmedText: string;
  Elapsed, Delay: Double;
  Confirmed, Provisional: TDecodedChars;
  SeenConfirmed, SeenProvisional, I, J: Integer;
  ConfirmDelays, PendingDelays: array of Double;
  NewestPending: Double;

{ 遅延の 95 パーセンタイル。/ 95th percentile of the delays. }
function Percentile95(const Values: array of Double): Double;
var
  Sorted: array of Double;
  A, B: Integer;
  Swap: Double;
begin
  if Length(Values) = 0 then
    Exit(0);
  SetLength(Sorted, Length(Values));
  for A := 0 to High(Values) do
    Sorted[A] := Values[A];
  for A := 0 to High(Sorted) - 1 do
    for B := 0 to High(Sorted) - 1 - A do
      if Sorted[B] > Sorted[B + 1] then
      begin
        Swap := Sorted[B];
        Sorted[B] := Sorted[B + 1];
        Sorted[B + 1] := Swap;
      end;
  Result := Sorted[Min(High(Sorted), Round(0.95 * High(Sorted)))];
end;

begin
  Index := 1;
  while Index <= ParamCount do
  begin
    Key := ParamStr(Index);
    if Key = '--quiet' then
    begin
      Quiet := True;
      Inc(Index);
      Continue;
    end;
    if Key = '--no-antialias' then
    begin
      NoAntiAlias := True;
      Inc(Index);
      Continue;
    end;
    if Key = '--check' then
    begin
      Check := True;
      Inc(Index);
      Continue;
    end;
    Value := '';
    if Index < ParamCount then
      Value := ParamStr(Index + 1);
    case Key of
      '--model': ModelPath := Value;
      '--metadata': MetadataPath := Value;
      '--onnxruntime': RuntimePath := Value;
      '--wav': WavPath := Value;
      '--chunk': ChunkSeconds := StrToFloatDef(Value, STREAM_FEED_SECONDS);
      '--text': SourceText := Value;
      '--max-provisional': MaxPending := StrToFloatDef(Value, TARGET_PENDING_SECONDS);
      '--max-confirmed': MaxConfirm := StrToFloatDef(Value, TARGET_CONFIRM_SECONDS);
    else
      begin
        WriteLn(StdErr, 'Unknown option: ', Key);
        Halt(2);
      end;
    end;
    Inc(Index, 2);
  end;

  if (WavPath = '') and (SourceText = '') then
  begin
    WriteLn(StdErr, 'Usage: cw_stream (--wav <file> | --text <message>) ' +
      '[--chunk seconds] [--quiet] [--no-antialias] ' +
      '[--check] [--max-provisional s] [--max-confirmed s]');
    Halt(2);
  end;
  if ModelPath = '' then
    ModelPath := LocateDataFile('model.onnx');
  if MetadataPath = '' then
    MetadataPath := LocateDataFile('model.onnx.json');

  try
    LoadOnnxRuntime(RuntimePath);
    Decoder := TDeepCWDecoder.Create(ModelPath, MetadataPath);
    try
      Stream := TStreamingDecoder.Create(Decoder);
      try
        Stream.AntiAlias := not NoAntiAlias;
        if SourceText <> '' then
        begin
          { 本文から音を作れるようにしておくと、回帰試験が音声ファイルを
            持ち歩かずに済みます。**遅延は本文の語の長さで変わるため**
            （付録 C.5）、試験は本文を明示して測る必要があります。
            Synthesising from text lets the regression run carry no audio
            fixtures. **Latency depends on how long the words are**
            (appendix C.5), so a test has to name the text it measures. }
          SampleRate := 8000;
          Timing := DefaultTiming;
          Timing.CharWpm := 22;
          Timing.TextWpm := 22;
          ToneOptions := DefaultToneOptions;
          ToneOptions.SampleRate := SampleRate;
          ToneOptions.ToneHz := 700;
          ToneOptions.Amplitude := 0.5;
          ToneOptions.NoiseAmplitude := 0;
          Samples := TextToPCM(SourceText, Timing, ToneOptions);
        end
        else
          LoadWavMono(WavPath, Samples, SampleRate);
        Count := Max(1, Round(ChunkSeconds * SampleRate));
        Position := 0;
        Previous := '';
        Rewrites := 0;
        SeenConfirmed := 0;
        NewestPending := -1;
        ConfirmDelays := nil;
        PendingDelays := nil;

        while Position < Length(Samples) do
        begin
          Chunk := Copy(Samples, Position, Min(Count, Length(Samples) - Position));
          Inc(Position, Length(Chunk));
          Stream.Append(Chunk, SampleRate);
          Elapsed := Position / SampleRate;

          if not Stream.Ready then
            Continue;
          Stream.Step;

          { 音声上の時刻と、投入し終えた時刻の差が体感の遅延です（要件 NFR-1）。
            The gap between a character's time in the audio and the moment it
            appeared is the delay the operator feels (requirement NFR-1). }
          Confirmed := Stream.ConfirmedChars;
          for I := SeenConfirmed to High(Confirmed) do
            if Confirmed[I].Text <> ' ' then
            begin
              SetLength(ConfirmDelays, Length(ConfirmDelays) + 1);
              ConfirmDelays[High(ConfirmDelays)] := Elapsed - Confirmed[I].EndSeconds;
            end;
          SeenConfirmed := Length(Confirmed);

          Provisional := Stream.ProvisionalChars;
          SeenProvisional := Length(Stream.ConfirmedChars);
          for J := 0 to High(Provisional) do
            if (Provisional[J].Text <> ' ') and
               (Provisional[J].EndSeconds > NewestPending) then
            begin
              NewestPending := Provisional[J].EndSeconds;
              SetLength(PendingDelays, Length(PendingDelays) + 1);
              PendingDelays[High(PendingDelays)] := Elapsed - Provisional[J].EndSeconds;
            end;

          ConfirmedText := DecodedText(Confirmed);
          { 確定したテキストが書き換わっていないことを確かめます（要件 FR-B.2）。
            Check that confirmed text is never rewritten (requirement FR-B.2). }
          if (Previous <> '') and (Pos(Previous, ConfirmedText) <> 1) then
          begin
            Inc(Rewrites);
            WriteLn(StdErr, Format('  !! %6.1fs 確定部分が書き換わりました', [Elapsed]));
            WriteLn(StdErr, '     前: ', Previous);
            WriteLn(StdErr, '     後: ', ConfirmedText);
          end;
          Previous := ConfirmedText;

          if not Quiet then
            WriteLn(Format('%6.1fs  確定[%s] 暫定[%s]',
              [Elapsed, ConfirmedText, DecodedText(Stream.ProvisionalChars)]));
        end;

        { 最後に残った分を出し切ります。/ Flush whatever is left. }
        Stream.Finish;

        Stream.AllChars(ConfirmedCount);
        WriteLn;
        WriteLn('確定: ', DecodedText(Stream.ConfirmedChars));
        WriteLn('暫定: ', DecodedText(Stream.ProvisionalChars));
        WriteLn(Format('確定部分の書き換え: %d 回', [Rewrites]));
        WriteLn(Format('暫定文字の遅延 95%%: %.2f 秒（目標 %.2f 秒） %s',
          [Percentile95(PendingDelays), TARGET_PENDING_SECONDS,
           BoolToStr(Percentile95(PendingDelays) <= TARGET_PENDING_SECONDS,
             '達成', '未達')]));
        WriteLn(Format('確定文字の遅延 95%%: %.2f 秒（目標 %.2f 秒） %s',
          [Percentile95(ConfirmDelays), TARGET_CONFIRM_SECONDS,
           BoolToStr(Percentile95(ConfirmDelays) <= TARGET_CONFIRM_SECONDS,
             '達成', '未達')]));
        { --check を付けたときだけ、超えたら落ちます。**画面に「未達」と出す
          だけでは、回帰試験として働きません。**

          上限は呼ぶ側が渡せます。確定の遅延は本文の語の長さで変わり、
          コールサインの多い本文では目標を超えることが分かっている
          （付録 C.5）ためです。**分かっている未達を、それ以上悪くさせない
          天井として渡します。**黙って見逃すのでも、直せないものを落とし
          続けるのでもありません。

          With --check, exceeding the ceiling ends the run as a failure.
          **Printing "missed" is not enough to make this a regression test.**

          The ceilings are the caller's to give: the confirm latency follows the
          length of the words and is known to exceed the target on
          callsign-heavy text (appendix C.5). **A known shortfall is passed as a
          ceiling that stops it getting worse** -- neither ignored, nor left
          failing forever. }
        if Check then
        begin
          if Percentile95(PendingDelays) > MaxPending then
          begin
            WriteLn(Format('暫定文字の遅延が上限 %.2f 秒を超えました。',
              [MaxPending]));
            Failed := True;
          end;
          if Percentile95(ConfirmDelays) > MaxConfirm then
          begin
            WriteLn(Format('確定文字の遅延が上限 %.2f 秒を超えました。',
              [MaxConfirm]));
            Failed := True;
          end;
        end;
        if Rewrites > 0 then
          Halt(1);
        if Failed then
          Halt(1);
      finally
        Stream.Free;
      end;
    finally
      Decoder.Free;
    end;
  except
    on E: Exception do
    begin
      WriteLn(StdErr, E.Message);
      Halt(1);
    end;
  end;
end.
