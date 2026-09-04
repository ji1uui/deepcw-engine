unit DeepCW.Wave;

{ 最小限の RIFF/WAVE 読み書きと、線形補間によるリサンプラです。

  一般的な録音ツールが出力する PCM および IEEE 浮動小数点形式を読み取り、常に
  [-1, 1] の範囲のモノラル Single 値として返します。これは DeepCW の他のユニット
  が共通で扱う表現です。

  Minimal RIFF/WAVE reader and writer plus a linear resampler.

  The reader accepts the PCM and IEEE-float encodings that ordinary recording
  tools produce and always returns mono Single samples in [-1, 1], which is the
  representation every other DeepCW unit works with. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Math, DeepCW.Types;

const
  WAVE_FORMAT_PCM = 1;
  WAVE_FORMAT_IEEE_FLOAT = 3;
  WAVE_FORMAT_EXTENSIBLE = $FFFE;

{ WAV ファイルを読み込み、モノラルのサンプル列とサンプリング周波数を返します。

  Reads a WAV file and returns mono samples together with its sample rate. }
procedure LoadWavMono(const FileName: string; out Samples: TSingleArray;
  out SampleRate: Integer);
procedure LoadWavMonoFromStream(Stream: TStream; out Samples: TSingleArray;
  out SampleRate: Integer);

{ モノラルのサンプル列を 16 bit PCM の WAV として書き出します。値は [-1, 1] に
  丸められます。

  Writes mono samples as a 16-bit PCM WAV file. Values are clipped to [-1, 1]. }
procedure SaveWavMono(const FileName: string; const Samples: TSingleArray;
  SampleRate: Integer);

{ 線形補間によるリサンプラです。Python 版および Node.js 版のサンプルと同一の
  処理とし、3 つの実装が同じ入力テンソルを生成するようにしています。

  Linear-interpolation resampler. Deliberately dependency free and identical to
  the Python and Node.js examples so all three produce the same input tensor. }
function ResampleLinear(const Samples: TSingleArray; SourceRate, TargetRate: Integer): TSingleArray;

{ 帯域制限した補間で標本化周波数を変えます。

  線形補間は、標本と標本のあいだを直線で結ぶことで**信号そのものを歪ませます。**
  歪みは信号の周波数の 2 乗で増え、変換の繰り返し周期に対応する像として現れます。
  8000 Hz を 6400 Hz へ落とす場合、像は f ± 1600 Hz に立ちます。

  1 局だけを聴いているうちは、これは表に出ません。信号が 1 つで、しかも同調の
  経路では帯域制限で高い成分を先に落としているためです。**帯域全体をそのまま
  扱う多局同時受信で初めて出ます。**実測では、4 局を鳴らしたときの像が本物の局と
  同じ高さ（31〜36 dB）で立ち、検出が偽の局を作りました（付録 N.2）。

  ここでは窓関数付き sinc を使います。標本化周波数の比は有理数なので、位相の
  種類は有限です。位相ごとに核をあらかじめ作っておけば、あとは積和だけで済みます。

  Changes the sample rate with band-limited interpolation.

  Linear interpolation joins samples with straight lines, which **distorts the
  signal itself.** The distortion grows with the square of the signal's
  frequency and appears as images at the repeat period of the conversion: taking
  8000 Hz down to 6400 Hz puts them at f +/- 1600 Hz.

  Listening to one station never shows this: there is a single signal, and the
  tuned path band-limits away the high content first. **It appears only when the
  whole passband is kept, as multi-station reception keeps it.** Measured with
  four stations transmitting, the images stood as tall as the real ones
  (31-36 dB) and the detector reported them as stations (appendix N.2).

  A windowed sinc is used here. The ratio of the rates is rational, so there are
  finitely many phases; building the kernel for each in advance leaves only
  multiply and accumulate. }
function ResampleBandLimited(const Samples: TSingleArray;
  SourceRate, TargetRate: Integer): TSingleArray;

implementation

type
  TRiffHeader = packed record
    RiffId: array[0..3] of AnsiChar;
    RiffSize: LongWord;
    WaveId: array[0..3] of AnsiChar;
  end;

  TChunkHeader = packed record
    ChunkId: array[0..3] of AnsiChar;
    ChunkSize: LongWord;
  end;

  TFormatChunk = packed record
    AudioFormat: Word;
    Channels: Word;
    SampleRate: LongWord;
    ByteRate: LongWord;
    BlockAlign: Word;
    BitsPerSample: Word;
  end;

procedure SetChunkId(var Id: array of AnsiChar; const Value: string);
var
  I: Integer;
begin
  for I := 0 to 3 do
    Id[I] := Value[I + 1];
end;

function ChunkIdEquals(const Id: array of AnsiChar; const Expected: string): Boolean;
var
  I: Integer;
begin
  Result := False;
  if Length(Expected) <> 4 then
    Exit;
  for I := 0 to 3 do
    if Id[I] <> Expected[I + 1] then
      Exit;
  Result := True;
end;

procedure LoadWavMono(const FileName: string; out Samples: TSingleArray;
  out SampleRate: Integer);
var
  Stream: TFileStream;
begin
  if not FileExists(FileName) then
    raise EDeepCW.CreateFmt('WAV file not found: %s', [FileName]);
  Stream := TFileStream.Create(FileName, fmOpenRead or fmShareDenyWrite);
  try
    LoadWavMonoFromStream(Stream, Samples, SampleRate);
  finally
    Stream.Free;
  end;
end;

procedure LoadWavMonoFromStream(Stream: TStream; out Samples: TSingleArray;
  out SampleRate: Integer);
var
  Riff: TRiffHeader;
  Chunk: TChunkHeader;
  Format: TFormatChunk;
  HaveFormat: Boolean;
  DataOffset: Int64;
  DataSize: LongWord;
  Payload: array of Byte;
  BytesPerSample, FrameCount, Frame, Channel, Offset: Integer;
  Sum: Double;
  SubFormat: Word;
  ExtraSize: Word;
  Next: Int64;
begin
  Samples := nil;
  SampleRate := 0;
  HaveFormat := False;
  DataOffset := -1;
  DataSize := 0;
  FillChar(Format, SizeOf(Format), 0);

  if Stream.Read(Riff, SizeOf(Riff)) <> SizeOf(Riff) then
    raise EDeepCW.Create('The file is too short to be a WAV file.');
  if (not ChunkIdEquals(Riff.RiffId, 'RIFF')) or (not ChunkIdEquals(Riff.WaveId, 'WAVE')) then
    raise EDeepCW.Create('Expected a RIFF/WAVE file.');

  while Stream.Position + SizeOf(Chunk) <= Stream.Size do
  begin
    if Stream.Read(Chunk, SizeOf(Chunk)) <> SizeOf(Chunk) then
      Break;
    Next := Stream.Position + Chunk.ChunkSize + (Chunk.ChunkSize and 1);

    if ChunkIdEquals(Chunk.ChunkId, 'fmt ') then
    begin
      if Chunk.ChunkSize < SizeOf(Format) then
        raise EDeepCW.Create('The WAV "fmt " chunk is truncated.');
      Stream.ReadBuffer(Format, SizeOf(Format));
      { WAVE_FORMAT_EXTENSIBLE は実際の符号化方式を拡張領域に持ちます。
        WAVE_FORMAT_EXTENSIBLE stores the real encoding in the extension. }
      if (Format.AudioFormat = WAVE_FORMAT_EXTENSIBLE) and (Chunk.ChunkSize >= SizeOf(Format) + 8) then
      begin
        Stream.ReadBuffer(ExtraSize, SizeOf(ExtraSize));
        Stream.Seek(6, soCurrent); { 有効ビット数とチャネルマスク分を読み飛ばします / valid bits + channel mask }
        Stream.ReadBuffer(SubFormat, SizeOf(SubFormat));
        Format.AudioFormat := SubFormat;
      end;
      HaveFormat := True;
    end
    else if ChunkIdEquals(Chunk.ChunkId, 'data') then
    begin
      DataOffset := Stream.Position;
      DataSize := Chunk.ChunkSize;
      if DataOffset + DataSize > Stream.Size then
        DataSize := LongWord(Stream.Size - DataOffset);
    end;

    if Next > Stream.Size then
      Break;
    Stream.Position := Next;
  end;

  if not HaveFormat then
    raise EDeepCW.Create('The WAV file has no "fmt " chunk.');
  if DataOffset < 0 then
    raise EDeepCW.Create('The WAV file has no "data" chunk.');
  if Format.Channels = 0 then
    raise EDeepCW.Create('The WAV file declares zero channels.');
  if (Format.AudioFormat <> WAVE_FORMAT_PCM) and (Format.AudioFormat <> WAVE_FORMAT_IEEE_FLOAT) then
    raise EDeepCW.CreateFmt('Only PCM and IEEE-float WAV files are supported. Got format %d.',
      [Format.AudioFormat]);

  BytesPerSample := Format.BitsPerSample div 8;
  if Format.AudioFormat = WAVE_FORMAT_PCM then
  begin
    if not (Format.BitsPerSample in [8, 16, 24, 32]) then
      raise EDeepCW.CreateFmt('Unsupported PCM bit depth: %d', [Format.BitsPerSample]);
  end
  else if Format.BitsPerSample <> 32 then
    raise EDeepCW.CreateFmt('Unsupported IEEE-float bit depth: %d', [Format.BitsPerSample]);

  FrameCount := DataSize div LongWord(BytesPerSample * Format.Channels);
  SetLength(Payload, DataSize);
  Stream.Position := DataOffset;
  if DataSize > 0 then
    Stream.ReadBuffer(Payload[0], DataSize);

  SetLength(Samples, FrameCount);
  for Frame := 0 to FrameCount - 1 do
  begin
    Sum := 0;
    for Channel := 0 to Format.Channels - 1 do
    begin
      Offset := (Frame * Format.Channels + Channel) * BytesPerSample;
      case Format.AudioFormat of
        WAVE_FORMAT_PCM:
          case Format.BitsPerSample of
            8: Sum := Sum + (Integer(Payload[Offset]) - 128) / 128;
            16: Sum := Sum + PSmallInt(@Payload[Offset])^ / 32768;
            24: Sum := Sum + (SarLongint(
                  (Integer(Payload[Offset]) or (Integer(Payload[Offset + 1]) shl 8) or
                   (Integer(Payload[Offset + 2]) shl 16)) shl 8, 8)) / 8388608;
            32: Sum := Sum + PLongint(@Payload[Offset])^ / 2147483648.0;
          end;
        WAVE_FORMAT_IEEE_FLOAT:
          Sum := Sum + PSingle(@Payload[Offset])^;
      end;
    end;
    Samples[Frame] := Sum / Format.Channels;
  end;

  SampleRate := Integer(Format.SampleRate);
end;

procedure SaveWavMono(const FileName: string; const Samples: TSingleArray;
  SampleRate: Integer);
var
  Stream: TFileStream;
  Riff: TRiffHeader;
  Chunk: TChunkHeader;
  Format: TFormatChunk;
  Payload: array of SmallInt;
  I: Integer;
  Value: Double;
  DataSize: LongWord;
begin
  if SampleRate <= 0 then
    raise EDeepCW.Create('The WAV sample rate must be positive.');

  SetLength(Payload, Length(Samples));
  for I := 0 to High(Samples) do
  begin
    Value := ClampDouble(Samples[I], -1.0, 1.0) * 32767.0;
    Payload[I] := SmallInt(Round(Value));
  end;
  DataSize := LongWord(Length(Payload) * SizeOf(SmallInt));

  Stream := TFileStream.Create(FileName, fmCreate);
  try
    SetChunkId(Riff.RiffId, 'RIFF');
    Riff.RiffSize := 4 + (8 + SizeOf(Format)) + (8 + DataSize);
    SetChunkId(Riff.WaveId, 'WAVE');
    Stream.WriteBuffer(Riff, SizeOf(Riff));

    SetChunkId(Chunk.ChunkId, 'fmt ');
    Chunk.ChunkSize := SizeOf(Format);
    Stream.WriteBuffer(Chunk, SizeOf(Chunk));

    Format.AudioFormat := WAVE_FORMAT_PCM;
    Format.Channels := 1;
    Format.SampleRate := LongWord(SampleRate);
    Format.BitsPerSample := 16;
    Format.BlockAlign := 2;
    Format.ByteRate := LongWord(SampleRate) * Format.BlockAlign;
    Stream.WriteBuffer(Format, SizeOf(Format));

    SetChunkId(Chunk.ChunkId, 'data');
    Chunk.ChunkSize := DataSize;
    Stream.WriteBuffer(Chunk, SizeOf(Chunk));
    if DataSize > 0 then
      Stream.WriteBuffer(Payload[0], DataSize);
  finally
    Stream.Free;
  end;
end;

{ 核の広がり（ゼロ交差の数）。多いほど阻止域が深くなり、費用は比例して増えます。
  The kernel's reach in zero crossings: more of them deepens the stop band and
  costs proportionally more. }
const
  RESAMPLE_ZERO_CROSSINGS = 16;

function ResampleBandLimited(const Samples: TSingleArray;
  SourceRate, TargetRate: Integer): TSingleArray;
var
  Kernels: array of TDoubleArray;
  Cutoff, Position, Offset, Argument, Accumulator, Weight, Total: Double;
  Phases, HalfTaps, Taps, Divisor, Phase, Index_, Tap, Source, Count: Integer;

  function GreatestCommonDivisor(A, B: Integer): Integer;
  var
    Remainder: Integer;
  begin
    while B <> 0 do
    begin
      Remainder := A mod B;
      A := B;
      B := Remainder;
    end;
    Result := A;
  end;

begin
  if (Length(Samples) = 0) or (SourceRate <= 0) or (TargetRate <= 0) then
    Exit(Samples);
  if SourceRate = TargetRate then
    Exit(Samples);

  { 遮断は、変換の前後で低いほうのナイキストに置きます。落とすときは折り返しを
    防ぐため、上げるときは像を作らないためです。元の標本の単位で表します。
    The cutoff sits at the lower of the two Nyquist frequencies: going down it
    prevents aliasing, going up it avoids creating images. It is expressed in
    units of the source sample rate. }
  Cutoff := 0.5 * Min(1.0, TargetRate / SourceRate);
  HalfTaps := Max(4, Ceil(RESAMPLE_ZERO_CROSSINGS / (2 * Cutoff)));
  Taps := 2 * HalfTaps + 1;

  { 位相の種類は、比を約分した分母の数だけあります。8000→6400 なら 4 種類です。
    There are as many phases as the reduced denominator of the ratio: four for
    8000 to 6400. }
  Divisor := GreatestCommonDivisor(SourceRate, TargetRate);
  Phases := Max(1, TargetRate div Divisor);

  SetLength(Kernels, Phases);
  for Phase := 0 to Phases - 1 do
  begin
    SetLength(Kernels[Phase], Taps);
    Total := 0;
    { この位相での、出力標本から見た直前の元標本までのずれ。
      How far this phase's output sits past the source sample below it. }
    Offset := Frac(Phase * (SourceRate / TargetRate));
    for Tap := 0 to Taps - 1 do
    begin
      Position := (Tap - HalfTaps) - Offset;
      if Abs(Position) < 1E-9 then
        Weight := 2 * Cutoff
      else
      begin
        Argument := 2 * Pi * Cutoff * Position;
        Weight := Sin(Argument) / (Pi * Position);
      end;
      { ブラックマン窓。ハミングより阻止域が深く、像を残さないために要ります。
        A Blackman window: its stop band is deeper than a Hamming's, which is
        what keeps the images out. }
      Argument := Pi * (Position + HalfTaps) / HalfTaps;
      Weight := Weight * (0.42 - 0.5 * Cos(Argument) + 0.08 * Cos(2 * Argument));
      Kernels[Phase][Tap] := Weight;
      Total := Total + Weight;
    end;
    { 直流の利得を 1 に揃えます。位相ごとに揃えないと、出力に位相の周期で
      うねりが乗ります。
      The direct-current gain is normalised to one. Left unequal between phases,
      the output would ripple at the phase period. }
    if Total <> 0 then
      for Tap := 0 to Taps - 1 do
        Kernels[Phase][Tap] := Kernels[Phase][Tap] / Total;
  end;

  Count := Max(1, Round(Int64(Length(Samples)) * TargetRate / SourceRate));
  SetLength(Result, Count);
  for Index_ := 0 to Count - 1 do
  begin
    Position := Index_ * (SourceRate / TargetRate);
    Phase := Index_ mod Phases;
    Accumulator := 0;
    for Tap := 0 to Taps - 1 do
    begin
      { 両端は値を保持します。LowPassFilter と同じ扱いで、CW の帯域では差が
        出ません。
        The edges hold their value, as LowPassFilter does; it makes no difference
        across a CW passband. }
      Source := ClampInt(Trunc(Position) + Tap - HalfTaps, 0, High(Samples));
      Accumulator := Accumulator + Kernels[Phase][Tap] * Samples[Source];
    end;
    Result[Index_] := Accumulator;
  end;
end;

function ResampleLinear(const Samples: TSingleArray; SourceRate, TargetRate: Integer): TSingleArray;
var
  TargetLength, I, Left, Right: Integer;
  Position, Fraction: Double;
begin
  if (SourceRate <= 0) or (TargetRate <= 0) then
    raise EDeepCW.Create('Resampling needs positive sample rates.');
  if (SourceRate = TargetRate) or (Length(Samples) = 0) then
    Exit(Samples);

  { 掛け算を Int64 で行わせます。64 ビットの対象では既にそうなりますが、
    32 ビットの対象では 1152000 × 6400 が桁あふれし、長さが黙って化けます。
    演算の順序は変えていないので、参照実装との一致は保たれます。
    The multiplication is forced into 64 bits. A 64-bit target already does this,
    but on a 32-bit one 1152000 x 6400 overflows and the length silently becomes
    nonsense. The order of operations is unchanged, so parity with the reference
    implementation is preserved. }
  TargetLength := Round(Int64(Length(Samples)) * TargetRate / SourceRate);
  SetLength(Result, TargetLength);
  for I := 0 to TargetLength - 1 do
  begin
    Position := Int64(I) * SourceRate / TargetRate;
    Left := Trunc(Position);
    if Left > High(Samples) then
      Left := High(Samples);
    Right := Min(Left + 1, High(Samples));
    Fraction := Position - Left;
    Result[I] := Samples[Left] * (1 - Fraction) + Samples[Right] * Fraction;
  end;
end;

end.
