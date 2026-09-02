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

function ResampleLinear(const Samples: TSingleArray; SourceRate, TargetRate: Integer): TSingleArray;
var
  TargetLength, I, Left, Right: Integer;
  Position, Fraction: Double;
begin
  if (SourceRate <= 0) or (TargetRate <= 0) then
    raise EDeepCW.Create('Resampling needs positive sample rates.');
  if (SourceRate = TargetRate) or (Length(Samples) = 0) then
    Exit(Samples);

  TargetLength := Round(Length(Samples) * TargetRate / SourceRate);
  SetLength(Result, TargetLength);
  for I := 0 to TargetLength - 1 do
  begin
    Position := I * SourceRate / TargetRate;
    Left := Trunc(Position);
    if Left > High(Samples) then
      Left := High(Samples);
    Right := Min(Left + 1, High(Samples));
    Fraction := Position - Left;
    Result[I] := Samples[Left] * (1 - Fraction) + Samples[Right] * Fraction;
  end;
end;

end.
