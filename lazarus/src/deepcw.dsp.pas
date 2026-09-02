unit DeepCW.Dsp;

{ DeepCW モデルへ渡す短時間フーリエ変換のフロントエンドです。

  窓、ホップ長、反射パディング、ビンの選択、log1p 圧縮といった構成は Python 版
  および Node.js 版のサンプルと完全に一致させています。ネットワークはこの表現で
  学習されており、わずかな差異にも敏感なためです。

  Short-time Fourier transform front end for the DeepCW model.

  The geometry (window, hop, reflect padding, bin selection, log1p compression)
  mirrors the Python and Node.js examples exactly, because the network was
  trained on that representation and is sensitive to any deviation. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Math, DeepCW.Types, DeepCW.Metadata;

type
  { 回転因子とビット反転表をあらかじめ用意した非再帰の基数 2 FFT です。
    同じ長さのフレームを繰り返し変換する際に初期化の費用がかかりません。

    Iterative radix-2 FFT with precomputed twiddle factors and a bit-reversal
    table, so repeated frames of the same length cost no setup. }
  TRealFFT = class
  private
    FSize: Integer;
    FLevels: Integer;
    FCosTable: TDoubleArray;
    FSinTable: TDoubleArray;
    FReverse: array of Integer;
    FRe: TDoubleArray;
    FIm: TDoubleArray;
  public
    constructor Create(ASize: Integer);
    { 長さ Size の Frame を変換し、[StartBin, StopBin) の範囲の |X[k]| を
      Magnitudes へ書き出します。

      Transforms Frame (length Size) and writes |X[k]| for k in
      [StartBin, StopBin) into Magnitudes. }
    procedure MagnitudeSpectrum(const Frame: TDoubleArray; StartBin, StopBin: Integer;
      var Magnitudes: TDoubleArray);
    property Size: Integer read FSize;
  end;

{ モデルが要求する [フレーム数 x ビン数] の log1p 振幅スペクトログラムを作ります。

  Builds the [Frames x Bins] log1p magnitude spectrogram the model expects. }
function ComputeSpectrogram(const Samples: TSingleArray; Meta: TDeepCWMetadata): TSpectrogram;

{ 周期型のハン窓です。numpy の np.hanning(N + 1)[:-1] と一致します。

  Periodic Hann window, matching numpy's np.hanning(N + 1)[:-1]. }
function HannWindow(Size: Integer): TDoubleArray;

{ 両端に同じ長さの反射パディングを施します。numpy の
  np.pad(..., mode='reflect') に相当します。

  numpy's np.pad(..., mode='reflect') for a symmetric pad on both ends. }
function ReflectPad(const Samples: TSingleArray; Pad: Integer): TDoubleArray;

{ 直線位相の窓関数付き sinc 低域通過フィルタです。

  サウンドカードが 44.1 kHz で録音する一方、モデルは 3.2 kHz で聴くため、線形
  リサンプラは 1.6 kHz を超える成分をネットワークが読む帯域へ折り返してしまい
  ます。先にこのフィルタを通すことで、ヒスノイズや話し声を CW の通過帯域から
  遠ざけられます。これはフロントエンド側の選択であり、モデルとの取り決めには
  含まれません。デコード経路そのものは Python 版および Node.js 版と同一です。

  Zero-phase windowed-sinc low-pass.

  Sound cards record at 44.1 kHz while the model listens at 3.2 kHz, and the
  linear resampler folds everything above 1.6 kHz back down into the band the
  network reads. Running this first keeps hiss and speech out of the CW
  passband. It is a front-end choice, not part of the model contract: the
  decode path itself stays identical to the Python and Node.js examples. }
function LowPassFilter(const Samples: TSingleArray; SampleRate: Integer;
  CutoffHz: Double; Taps: Integer = 63): TSingleArray;

implementation

function IsPowerOfTwo(Value: Integer): Boolean;
begin
  Result := (Value > 0) and ((Value and (Value - 1)) = 0);
end;

constructor TRealFFT.Create(ASize: Integer);
var
  I, J, Shift: Integer;
begin
  inherited Create;
  if not IsPowerOfTwo(ASize) then
    raise EDeepCW.CreateFmt('The FFT length must be a power of two, got %d.', [ASize]);
  FSize := ASize;
  FLevels := 0;
  while (1 shl FLevels) < FSize do
    Inc(FLevels);

  SetLength(FCosTable, FSize div 2);
  SetLength(FSinTable, FSize div 2);
  for I := 0 to (FSize div 2) - 1 do
  begin
    FCosTable[I] := Cos(2 * Pi * I / FSize);
    FSinTable[I] := Sin(2 * Pi * I / FSize);
  end;

  SetLength(FReverse, FSize);
  Shift := 32 - FLevels;
  for I := 0 to FSize - 1 do
  begin
    { I の下位 FLevels ビットを反転します。
       Reverse the low FLevels bits of I. }
    J := I;
    J := ((J and $55555555) shl 1) or ((J shr 1) and $55555555);
    J := ((J and $33333333) shl 2) or ((J shr 2) and $33333333);
    J := ((J and $0F0F0F0F) shl 4) or ((J shr 4) and $0F0F0F0F);
    J := ((J and $00FF00FF) shl 8) or ((J shr 8) and $00FF00FF);
    J := (J shl 16) or (J shr 16);
    FReverse[I] := Integer(LongWord(J) shr Shift);
  end;

  SetLength(FRe, FSize);
  SetLength(FIm, FSize);
end;

procedure TRealFFT.MagnitudeSpectrum(const Frame: TDoubleArray; StartBin, StopBin: Integer;
  var Magnitudes: TDoubleArray);
var
  I, BlockSize, HalfSize, TableStep, Start, J, K: Integer;
  TempRe, TempIm: Double;
begin
  if Length(Frame) <> FSize then
    raise EDeepCW.CreateFmt('The FFT frame must hold %d samples, got %d.', [FSize, Length(Frame)]);
  if (StartBin < 0) or (StopBin > FSize div 2 + 1) or (StopBin <= StartBin) then
    raise EDeepCW.Create('The requested FFT bin range is out of bounds.');

  for I := 0 to FSize - 1 do
  begin
    FRe[FReverse[I]] := Frame[I];
    FIm[FReverse[I]] := 0;
  end;

  BlockSize := 2;
  while BlockSize <= FSize do
  begin
    HalfSize := BlockSize div 2;
    TableStep := FSize div BlockSize;
    Start := 0;
    while Start < FSize do
    begin
      J := Start;
      K := 0;
      while J < Start + HalfSize do
      begin
        { 回転因子の共役を用いたバタフライ演算、すなわち順変換です。
          Butterfly with the conjugated twiddle, i.e. a forward transform. }
        TempRe := FRe[J + HalfSize] * FCosTable[K] + FIm[J + HalfSize] * FSinTable[K];
        TempIm := FIm[J + HalfSize] * FCosTable[K] - FRe[J + HalfSize] * FSinTable[K];
        FRe[J + HalfSize] := FRe[J] - TempRe;
        FIm[J + HalfSize] := FIm[J] - TempIm;
        FRe[J] := FRe[J] + TempRe;
        FIm[J] := FIm[J] + TempIm;
        Inc(J);
        Inc(K, TableStep);
      end;
      Inc(Start, BlockSize);
    end;
    if BlockSize = FSize then
      Break;
    BlockSize := BlockSize * 2;
  end;

  if Length(Magnitudes) <> StopBin - StartBin then
    SetLength(Magnitudes, StopBin - StartBin);
  for I := StartBin to StopBin - 1 do
    Magnitudes[I - StartBin] := Hypot(FRe[I], FIm[I]);
end;

function HannWindow(Size: Integer): TDoubleArray;
var
  I: Integer;
begin
  Result := nil;
  SetLength(Result, Size);
  for I := 0 to Size - 1 do
    Result[I] := 0.5 - 0.5 * Cos(2 * Pi * I / Size);
end;

function ReflectPad(const Samples: TSingleArray; Pad: Integer): TDoubleArray;
var
  I, Count: Integer;
begin
  Result := nil;
  Count := Length(Samples);
  if Count < Pad + 1 then
    raise EDeepCW.CreateFmt('Reflect padding by %d needs at least %d samples, got %d.',
      [Pad, Pad + 1, Count]);
  SetLength(Result, Count + 2 * Pad);
  for I := 0 to Pad - 1 do
  begin
    Result[I] := Samples[Pad - I];
    Result[Pad + Count + I] := Samples[Count - 2 - I];
  end;
  for I := 0 to Count - 1 do
    Result[Pad + I] := Samples[I];
end;

function LowPassFilter(const Samples: TSingleArray; SampleRate: Integer;
  CutoffHz: Double; Taps: Integer): TSingleArray;
var
  Kernel: TDoubleArray;
  Half, I, J, Source: Integer;
  Normalized, Sum, Accumulator, Argument: Double;
begin
  Result := nil;
  if (Length(Samples) = 0) or (SampleRate <= 0) then
    Exit(Samples);
  { 遮断周波数がナイキスト以上であれば取り除くものはありません。
    Nothing to remove once the cutoff sits at or above Nyquist. }
  if CutoffHz >= SampleRate / 2 then
    Exit(Samples);
  if not Odd(Taps) then
    Inc(Taps);
  Half := Taps div 2;
  if Length(Samples) <= Taps then
    Exit(Samples);

  Normalized := CutoffHz / SampleRate;
  SetLength(Kernel, Taps);
  Sum := 0;
  for I := 0 to Taps - 1 do
  begin
    if I = Half then
      Kernel[I] := 2 * Normalized
    else
    begin
      Argument := 2 * Pi * Normalized * (I - Half);
      Kernel[I] := Sin(Argument) / (Pi * (I - Half));
    end;
    { ハミング窓により阻止域を約 50 dB 下げます。
       Hamming window keeps the stop band about 50 dB down. }
    Kernel[I] := Kernel[I] * (0.54 - 0.46 * Cos(2 * Pi * I / (Taps - 1)));
    Sum := Sum + Kernel[I];
  end;
  for I := 0 to Taps - 1 do
    Kernel[I] := Kernel[I] / Sum;

  SetLength(Result, Length(Samples));
  for I := 0 to High(Samples) do
  begin
    Accumulator := 0;
    for J := 0 to Taps - 1 do
    begin
      { 両端は値を保持します。処理が軽く、CW の帯域では影響が分かりません。
         Clamp at the edges, which is cheap and inaudible for a CW passband. }
      Source := ClampInt(I + J - Half, 0, High(Samples));
      Accumulator := Accumulator + Kernel[J] * Samples[Source];
    end;
    Result[I] := Accumulator;
  end;
end;

function ComputeSpectrogram(const Samples: TSingleArray; Meta: TDeepCWMetadata): TSpectrogram;
var
  FFT: TRealFFT;
  Window, Padded, Frame, Magnitudes: TDoubleArray;
  FFTLength, HopLength, Pad, StartBin, StopBin, Bins, FrameIndex, I, Offset: Integer;
begin
  FFTLength := Meta.FFTLength;
  HopLength := Meta.HopLength;
  StartBin := Meta.StartBin;
  StopBin := Meta.StopBin;
  Bins := StopBin - StartBin;

  if Length(Samples) < FFTLength then
    raise EDeepCW.CreateFmt('The audio is too short for fft_length=%d.', [FFTLength]);

  Pad := FFTLength div 2;
  Padded := ReflectPad(Samples, Pad);
  Window := HannWindow(FFTLength);

  Result.Bins := Bins;
  Result.Frames := 1 + (Length(Padded) - FFTLength) div HopLength;
  SetLength(Result.Data, Result.Frames * Bins);

  SetLength(Frame, FFTLength);
  SetLength(Magnitudes, Bins);
  FFT := TRealFFT.Create(FFTLength);
  try
    for FrameIndex := 0 to Result.Frames - 1 do
    begin
      Offset := FrameIndex * HopLength;
      for I := 0 to FFTLength - 1 do
        Frame[I] := Padded[Offset + I] * Window[I];
      FFT.MagnitudeSpectrum(Frame, StartBin, StopBin, Magnitudes);
      for I := 0 to Bins - 1 do
        Result.Data[FrameIndex * Bins + I] := Ln(1 + Magnitudes[I]);
    end;
  finally
    FFT.Free;
  end;
end;

end.
