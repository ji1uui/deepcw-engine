unit DeepCW.Decoder;

{ DeepCW の受信経路です。音声を入力し、復号したテキストを返します。

  デコーダは ONNX セッションとメタデータをそれぞれ 1 つ保持します。スレッド
  安全ではないため、GUI ではワーカースレッドごとに 1 つのデコーダを持ちます。

  The DeepCW receive path: audio in, decoded text out.

  A decoder owns one ONNX session and one metadata object. Instances are not
  thread safe; the GUI keeps one decoder per worker thread. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Math, DeepCW.Types, DeepCW.Metadata, DeepCW.Dsp,
  DeepCW.Onnx, DeepCW.Wave;

const
  { モデルは 5〜20 秒の断片で学習されており、この範囲を外れると精度が落ちます。
    The model was trained on 5-20 second excerpts and degrades outside that. }
  DEEPCW_MIN_SECONDS = 5.0;
  DEEPCW_MAX_SECONDS = 20.0;

  { モデルが受け付ける長さを超える録音のための窓の設定です。窓は自身の長さより
    小さい間隔で進むため、隣り合う窓が共通のテキストを持ち、結合時の位置合わせに
    利用できます。

    Window geometry for recordings longer than the model accepts. The window
    advances by less than its own length so consecutive windows share text for
    the merge to align on. }
  DEEPCW_WINDOW_SECONDS = 15.0;
  DEEPCW_WINDOW_HOP_SECONDS = 11.0;

  { 窓の端からこの時間内に出力された文字は破棄します。文字の途中で始まったり
    終わったりする窓はその位置に誤った文字を生じますが、内側の端はいずれも
    隣の窓が補うためです。

    Characters emitted within this much of a window edge are discarded. A
    window that starts or ends part way through a character produces spurious
    letters there, and every interior edge is covered by a neighbouring
    window anyway. }
  DEEPCW_EDGE_GUARD_SECONDS = 0.8;

type
  { 復号した 1 文字と、CTC 経路がそれを出力した時刻の組です。

    One decoded character together with when the CTC path emitted it. }
  TDecodedChar = record
    Text: string;
    Seconds: Double;
  end;
  TDecodedChars = array of TDecodedChar;

  TDeepCWDecoder = class
  private
    FMetadata: TDeepCWMetadata;
    FSession: TOnnxSession;
    FLastSpectrogram: TSpectrogram;
    FLastSeconds: Double;
    function GreedyCtcDecode(const LogProbs: TOnnxFloatTensor;
      DurationSeconds: Double): TDecodedChars;
    function RunWindow(const Audio: TSingleArray): TDecodedChars;
  public
    constructor Create(const ModelPath, MetadataPath: string; IntraOpThreads: Integer = 1);
    destructor Destroy; override;

    { SourceRate で与えられたモノラルのサンプル列を復号します。モデルの周波数へ
      変換したのち、長さが 5〜20 秒に収まっている必要があります。

      Decodes mono samples given at SourceRate. After resampling to the model
      rate the audio must last between 5 and 20 seconds. }
    function DecodeSamples(const Samples: TSingleArray; SourceRate: Integer): string;

    { DecodeSamples と同じ処理に加え、各文字を受信した時刻も返します。

      As DecodeSamples, but also reports when each character was heard. }
    function DecodeSamplesTimed(const Samples: TSingleArray; SourceRate: Integer): TDecodedChars;

    { 重なりを持つ窓を滑らせ、窓ごとの結果をつなぎ合わせることで、任意の長さの
      録音を復号します。

      Decodes a recording of any length by sliding an overlapping window over
      it and stitching the per-window transcripts together. }
    function DecodeLongSamples(const Samples: TSingleArray; SourceRate: Integer): string;

    { WAV ファイルを読み込んで復号します。20 秒を超える場合は窓に分割します。

      Reads a WAV file and decodes it, windowing if it runs past 20 seconds. }
    function DecodeWavFile(const FileName: string): string;

    { 直近の窓のスペクトログラムです。ウォーターフォール表示に用います。

      The spectrogram of the most recent window, for the waterfall display. }
    property LastSpectrogram: TSpectrogram read FLastSpectrogram;
    property LastSeconds: Double read FLastSeconds;
    property Metadata: TDeepCWMetadata read FMetadata;
    property Session: TOnnxSession read FSession;
  end;

{ 復号した文字を連結して 1 つの文字列にします。

  Joins decoded characters into a plain string. }
function DecodedText(const Chars: TDecodedChars): string;

{ [LowSeconds, HighSeconds) の範囲で受信した文字だけを残します。

  Keeps only the characters heard in [LowSeconds, HighSeconds). }
function TrimDecoded(const Chars: TDecodedChars; LowSeconds, HighSeconds: Double): TDecodedChars;

{ NewText を Accumulated の末尾に連結します。その際、Accumulated の末尾と
  一致する NewText の先頭部分のうち最も長いものを取り除きます。

  窓が重なる区間の文字は繰り返し出力されます。最も長い重複をたたむことで、
  本格的な系列アライメントを用いずに読みやすい受信記録を保てます。

  Appends NewText to Accumulated, dropping the longest prefix of NewText that
  already appears as a suffix of Accumulated.

  Overlapping windows repeat the characters that fall in the overlap.
  Collapsing the largest such repeat keeps the running transcript readable
  without a full sequence alignment. }
function MergeOverlappingText(const Accumulated, NewText: string;
  MaxOverlap: Integer = 32): string;

implementation

constructor TDeepCWDecoder.Create(const ModelPath, MetadataPath: string;
  IntraOpThreads: Integer);
var
  ModelInput, ModelOutput: string;
begin
  inherited Create;
  FMetadata := TDeepCWMetadata.Create;
  FMetadata.LoadFromFile(MetadataPath);
  FSession := TOnnxSession.Create(ModelPath, IntraOpThreads);

  { メタデータとモデルの不一致は、分かりにくい Run のエラーになる前にここで
    検出します。
    Catch a metadata/model mismatch here rather than as a confusing Run error. }
  if FSession.InputCount <> 1 then
    raise EDeepCW.CreateFmt('Expected a single model input, found %d.', [FSession.InputCount]);
  ModelInput := FSession.InputName(0);
  if ModelInput <> FMetadata.InputName then
    raise EDeepCW.CreateFmt('The model input is "%s" but the metadata names "%s".',
      [ModelInput, FMetadata.InputName]);
  ModelOutput := FSession.OutputName(0);
  if ModelOutput <> FMetadata.OutputName then
    raise EDeepCW.CreateFmt('The model output is "%s" but the metadata names "%s".',
      [ModelOutput, FMetadata.OutputName]);
end;

destructor TDeepCWDecoder.Destroy;
begin
  FSession.Free;
  FMetadata.Free;
  inherited Destroy;
end;

function TDeepCWDecoder.GreedyCtcDecode(const LogProbs: TOnnxFloatTensor;
  DurationSeconds: Double): TDecodedChars;
var
  Frames, Classes, Frame, Klass, BestIndex, Previous, Count: Integer;
  BestValue, Value: Single;
  SecondsPerFrame: Double;
begin
  Result := nil;
  if Length(LogProbs.Shape) <> 3 then
    raise EDeepCW.CreateFmt('Expected a [batch, time, class] output, got %d dimensions.',
      [Length(LogProbs.Shape)]);
  if LogProbs.Shape[0] <> 1 then
    raise EDeepCW.CreateFmt('Expected batch size 1, got %d.', [LogProbs.Shape[0]]);

  Frames := Integer(LogProbs.Shape[1]);
  Classes := Integer(LogProbs.Shape[2]);
  if Classes <> FMetadata.NumClasses then
    raise EDeepCW.CreateFmt('The model emits %d classes but the metadata declares %d.',
      [Classes, FMetadata.NumClasses]);
  if Frames <= 0 then
    Exit;

  { グラフは時間方向に間引くため、出力フレームを窓上の時刻へ対応付けます。
    The graph strides in time, so map output frames back onto the window. }
  SecondsPerFrame := DurationSeconds / Frames;

  SetLength(Result, Frames);
  Count := 0;
  Previous := -1;
  for Frame := 0 to Frames - 1 do
  begin
    BestIndex := 0;
    BestValue := LogProbs.Data[Frame * Classes];
    for Klass := 1 to Classes - 1 do
    begin
      Value := LogProbs.Data[Frame * Classes + Klass];
      if Value > BestValue then
      begin
        BestValue := Value;
        BestIndex := Klass;
      end;
    end;

    if BestIndex = FMetadata.BlankIndex then
      Previous := -1
    else
    begin
      if BestIndex <> Previous then
      begin
        Result[Count].Text := FMetadata.Chars[BestIndex];
        Result[Count].Seconds := (Frame + 0.5) * SecondsPerFrame;
        Inc(Count);
      end;
      Previous := BestIndex;
    end;
  end;
  SetLength(Result, Count);
end;

function TDeepCWDecoder.RunWindow(const Audio: TSingleArray): TDecodedChars;
var
  Seconds: Double;
  Output: TOnnxFloatTensor;
begin
  Seconds := Length(Audio) / FMetadata.SampleRate;
  FLastSeconds := Seconds;
  if (Seconds < DEEPCW_MIN_SECONDS) or (Seconds > DEEPCW_MAX_SECONDS) then
    raise EDeepCW.CreateFmt(
      'The audio must last between %.0f and %.0f seconds at %d Hz, but it lasts %.2f seconds.',
      [DEEPCW_MIN_SECONDS, DEEPCW_MAX_SECONDS, FMetadata.SampleRate, Seconds]);

  FLastSpectrogram := ComputeSpectrogram(Audio, FMetadata);
  Output := FSession.RunFloat(FMetadata.InputName, FLastSpectrogram.Data,
    [Int64(1), Int64(FMetadata.ChannelCount), Int64(FLastSpectrogram.Frames),
     Int64(FLastSpectrogram.Bins)], FMetadata.OutputName);
  Result := GreedyCtcDecode(Output, Seconds);
end;

function TDeepCWDecoder.DecodeSamplesTimed(const Samples: TSingleArray;
  SourceRate: Integer): TDecodedChars;
begin
  Result := RunWindow(ResampleLinear(Samples, SourceRate, FMetadata.SampleRate));
end;

function TDeepCWDecoder.DecodeSamples(const Samples: TSingleArray; SourceRate: Integer): string;
begin
  Result := DecodedText(DecodeSamplesTimed(Samples, SourceRate));
end;

function TDeepCWDecoder.DecodeLongSamples(const Samples: TSingleArray;
  SourceRate: Integer): string;
var
  Audio, Window: TSingleArray;
  Chars: TDecodedChars;
  Rate, Total, WindowLength, Hop, Start, Stop: Integer;
  StartSeconds, StopSeconds, LowGuard, HighGuard, TotalSeconds: Double;
begin
  Rate := FMetadata.SampleRate;
  Audio := ResampleLinear(Samples, SourceRate, Rate);
  Total := Length(Audio);
  TotalSeconds := Total / Rate;

  if Total <= Round(DEEPCW_MAX_SECONDS * Rate) then
    Exit(DecodedText(RunWindow(Audio)));

  WindowLength := Round(DEEPCW_WINDOW_SECONDS * Rate);
  Hop := Round(DEEPCW_WINDOW_HOP_SECONDS * Rate);

  Result := '';
  Start := 0;
  repeat
    Stop := Min(Start + WindowLength, Total);
    { 最後の窓は短い断片を渡す代わりに、開始位置を手前へずらします。
      Pull the final window backwards rather than handing the model a stub. }
    if Stop - Start < Round(DEEPCW_MIN_SECONDS * Rate) then
      Start := Max(0, Stop - WindowLength);
    StartSeconds := Start / Rate;
    StopSeconds := Stop / Rate;

    Window := Copy(Audio, Start, Stop - Start);
    Chars := RunWindow(Window);

    { 端に生じる誤りを取り除きます。ただし録音全体の先頭と末尾は、補う窓が
      存在しないためそのまま残します。

      Discard the edge artifacts, except at the true start and end of the
      recording where there is no neighbouring window to cover them. }
    if Start = 0 then LowGuard := 0 else LowGuard := DEEPCW_EDGE_GUARD_SECONDS;
    if Stop = Total then HighGuard := StopSeconds - StartSeconds
    else HighGuard := (StopSeconds - StartSeconds) - DEEPCW_EDGE_GUARD_SECONDS;

    Result := MergeOverlappingText(Result,
      DecodedText(TrimDecoded(Chars, LowGuard, HighGuard)));
    Inc(Start, Hop);
  until Stop >= Total;

  FLastSeconds := TotalSeconds;
end;

function TDeepCWDecoder.DecodeWavFile(const FileName: string): string;
var
  Samples: TSingleArray;
  SampleRate: Integer;
begin
  LoadWavMono(FileName, Samples, SampleRate);
  Result := DecodeLongSamples(Samples, SampleRate);
end;

function DecodedText(const Chars: TDecodedChars): string;
var
  I: Integer;
  Builder: TStringBuilder;
begin
  Builder := TStringBuilder.Create;
  try
    for I := 0 to High(Chars) do
      Builder.Append(Chars[I].Text);
    Result := Builder.ToString;
  finally
    Builder.Free;
  end;
end;

function TrimDecoded(const Chars: TDecodedChars; LowSeconds, HighSeconds: Double): TDecodedChars;
var
  I, Count: Integer;
begin
  Result := nil;
  SetLength(Result, Length(Chars));
  Count := 0;
  for I := 0 to High(Chars) do
    if (Chars[I].Seconds >= LowSeconds) and (Chars[I].Seconds < HighSeconds) then
    begin
      Result[Count] := Chars[I];
      Inc(Count);
    end;
  SetLength(Result, Count);
end;

function MergeOverlappingText(const Accumulated, NewText: string;
  MaxOverlap: Integer): string;
var
  Limit, Overlap: Integer;
begin
  if Accumulated = '' then
    Exit(NewText);
  if NewText = '' then
    Exit(Accumulated);

  Limit := Min(MaxOverlap, Min(Length(Accumulated), Length(NewText)));
  for Overlap := Limit downto 1 do
    if Copy(Accumulated, Length(Accumulated) - Overlap + 1, Overlap) = Copy(NewText, 1, Overlap) then
      Exit(Accumulated + Copy(NewText, Overlap + 1, MaxInt));
  Result := Accumulated + NewText;
end;

end.
