unit DeepCW.Morse;

{ 送信経路です。テキストからモールスの時間構成を求め、側音の波形を作ります。

  時間の基準は PARIS に従います。短点を 1 単位、長点を 3 単位、文字内の間隔を
  1 単位、文字間を 3 単位、語間を 7 単位とします。ファンズワース間隔では文字
  自体を CharWpm のまま送りつつ、文字間と語間を引き伸ばして全体の速度を
  TextWpm まで落とします。初学者の練習で広く使われる方式です。

  The transmit path: text to Morse timing to a sidetone waveform.

  Timing follows PARIS: a dit is one unit, a dah three, the gap inside a
  character one, between characters three and between words seven. Farnsworth
  spacing keeps the characters at CharWpm while stretching the inter-character
  and inter-word gaps so the overall rate drops to TextWpm, which is how
  beginners are usually trained. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Math, DeepCW.Types;

type
  { 送信の中の、電鍵を押している区間または無音の区間 1 つを表します。

    One keyed or silent interval of the transmission. }
  TCWSegment = record
    Tone: Boolean;
    Duration: Double;   { 秒 / seconds }
    TextIndex: Integer; { 元テキスト内の位置（1 起点）、語間は 0 / 1-based index, 0 for word gaps }
  end;
  TCWSegments = array of TCWSegment;

  TCWTiming = record
    CharWpm: Double;  { 個々の文字を送る速度 / speed the individual characters are sent at }
    TextWpm: Double;  { 全体の速度。CharWpm と同値ならファンズワース無効 / overall speed }
  end;

  TCWToneOptions = record
    SampleRate: Integer;
    ToneHz: Double;
    Amplitude: Double;  { 側音の振幅の最大値、0..1 / peak amplitude of the sidetone }
    RampMs: Double;     { 立ち上がりと立ち下がりの整形。クリック音を抑えます / raised-cosine ramp }
    NoiseAmplitude: Double; { 信号全体に加える白色雑音、0..1 / white noise added to the whole signal }
    LeadInSeconds: Double;
    LeadOutSeconds: Double;
  end;

function DefaultTiming: TCWTiming;
function DefaultToneOptions: TCWToneOptions;

{ 本ユニットにモールス符号の定義がある文字であれば True を返します。

  True when the character has a Morse representation in this unit. }
function IsSendable(Ch: Char): Boolean;

{ 1 文字分の '.-' 形式の符号を返します。定義が無い場合は空文字を返します。

  '.-' style code for one character, or '' when it has no representation. }
function MorseForChar(Ch: Char): string;

{ メッセージ全体を読みやすい符号列にします。語の区切りは '/' です。

  Human-readable code for a whole message, '/' between words. }
function TextToMorseCode(const Text: string): string;

{ 本ユニットが送出できる大文字の範囲に正規化します。対象外の文字は取り除き、
  連続する空白は 1 つにまとめます。

  Normalises to the upper-case subset this unit can key, dropping unsupported
  characters and collapsing runs of whitespace. }
function NormalizeText(const Text: string): string;

{ テキストを、電鍵を押す区間と無音の区間の列に展開します。

  Expands text into keyed and silent intervals. }
function TextToSegments(const Text: string; const Timing: TCWTiming): TCWSegments;

function SegmentsDuration(const Segments: TCWSegments): Double;

{ 区間の列をモノラルの波形に変換します。発振は連続させ、包絡線で断続させる
  ため、連続する符号要素の位相が揃います。

  Renders segments as a mono waveform. The oscillator runs continuously and is
  gated by the envelope, so successive elements stay phase coherent. }
function SegmentsToPCM(const Segments: TCWSegments; const Options: TCWToneOptions): TSingleArray;

{ テキストから音声までを一度に行う簡便な関数です。

  Convenience wrapper: text straight to audio. }
function TextToPCM(const Text: string; const Timing: TCWTiming;
  const Options: TCWToneOptions): TSingleArray;

{ 指定した速度における短点 1 つの長さ（秒）です。

  Seconds per dit at the given speed. }
function DitSeconds(Wpm: Double): Double;

implementation

const
  { 添字 0 が 'A' です。モデルの文字集合に含まれる文字と、書き出された
    文字集合が持つ約物のみを収めています。

    Index 0 is 'A'. Only characters the model alphabet contains are listed
    here plus the punctuation the exported alphabet includes. }
  LETTERS: array['A'..'Z'] of string = (
    '.-', '-...', '-.-.', '-..', '.', '..-.', '--.', '....', '..', '.---',
    '-.-', '.-..', '--', '-.', '---', '.--.', '--.-', '.-.', '...', '-',
    '..-', '...-', '.--', '-..-', '-.--', '--..');

  DIGITS: array['0'..'9'] of string = (
    '-----', '.----', '..---', '...--', '....-', '.....', '-....', '--...',
    '---..', '----.');

function DefaultTiming: TCWTiming;
begin
  Result.CharWpm := 20;
  Result.TextWpm := 20;
end;

function DefaultToneOptions: TCWToneOptions;
begin
  Result.SampleRate := 8000;
  Result.ToneHz := 700;
  Result.Amplitude := 0.6;
  Result.RampMs := 5;
  Result.NoiseAmplitude := 0;
  Result.LeadInSeconds := 0.3;
  Result.LeadOutSeconds := 0.3;
end;

function MorseForChar(Ch: Char): string;
begin
  Ch := UpCase(Ch);
  case Ch of
    'A'..'Z': Result := LETTERS[Ch];
    '0'..'9': Result := DIGITS[Ch];
    '.': Result := '.-.-.-';
    ',': Result := '--..--';
    '?': Result := '..--..';
    '/': Result := '-..-.';
  else
    Result := '';
  end;
end;

function IsSendable(Ch: Char): Boolean;
begin
  Result := (Ch = ' ') or (MorseForChar(Ch) <> '');
end;

function TextToMorseCode(const Text: string): string;
var
  Normalized: string;
  I: Integer;
  Builder: TStringBuilder;
begin
  Normalized := NormalizeText(Text);
  Builder := TStringBuilder.Create;
  try
    for I := 1 to Length(Normalized) do
    begin
      if I > 1 then
        Builder.Append(' ');
      if Normalized[I] = ' ' then
        Builder.Append('/')
      else
        Builder.Append(MorseForChar(Normalized[I]));
    end;
    Result := Builder.ToString;
  finally
    Builder.Free;
  end;
end;

function NormalizeText(const Text: string): string;
var
  I: Integer;
  Ch: Char;
  Builder: TStringBuilder;
  PendingSpace: Boolean;
begin
  Builder := TStringBuilder.Create;
  try
    PendingSpace := False;
    for I := 1 to Length(Text) do
    begin
      Ch := UpCase(Text[I]);
      if (Ch = ' ') or (Ch = #9) or (Ch = #10) or (Ch = #13) then
      begin
        PendingSpace := Builder.Length > 0;
        Continue;
      end;
      if MorseForChar(Ch) = '' then
        Continue;
      if PendingSpace then
      begin
        Builder.Append(' ');
        PendingSpace := False;
      end;
      Builder.Append(Ch);
    end;
    Result := Builder.ToString;
  finally
    Builder.Free;
  end;
end;

function DitSeconds(Wpm: Double): Double;
begin
  if Wpm <= 0 then
    raise EDeepCW.Create('The keying speed must be positive.');
  { PARIS は 50 短点分の長さであるため、短点 1 つは 1.2 / wpm 秒になります。
  PARIS is 50 dit units long, so 1.2 / wpm seconds per dit. }
  Result := 1.2 / Wpm;
end;

function TextToSegments(const Text: string; const Timing: TCWTiming): TCWSegments;
var
  Normalized, Code: string;
  Dit, CharGap, WordGap, Extra, CharSpeed, TextSpeed: Double;
  Count, I, E: Integer;

  procedure Add(ATone: Boolean; ADuration: Double; ATextIndex: Integer);
  begin
    if ADuration <= 0 then
      Exit;
    if Count = Length(Result) then
      SetLength(Result, Max(16, Count * 2));
    Result[Count].Tone := ATone;
    Result[Count].Duration := ADuration;
    Result[Count].TextIndex := ATextIndex;
    Inc(Count);
  end;

begin
  Result := nil;
  Count := 0;
  Normalized := NormalizeText(Text);
  if Normalized = '' then
    Exit;

  CharSpeed := Timing.CharWpm;
  TextSpeed := Timing.TextWpm;
  if CharSpeed <= 0 then
    raise EDeepCW.Create('The character speed must be positive.');
  if (TextSpeed <= 0) or (TextSpeed > CharSpeed) then
    TextSpeed := CharSpeed;

  Dit := DitSeconds(CharSpeed);
  { ARRL 方式のファンズワース間隔です。追加の遅延を文字間へ 3 単位分、語間へ
    7 単位分の割合で配分します。TextSpeed と CharSpeed が等しい場合は、通常の
    3 単位と 7 単位の間隔に一致します。

    ARRL Farnsworth: spread the extra delay over three units between characters
    and seven between words. With TextSpeed = CharSpeed this reduces to the
    plain 3 and 7 unit gaps. }
  Extra := (60 * CharSpeed - 37.2 * TextSpeed) / (CharSpeed * TextSpeed);
  CharGap := 3 * Extra / 19;
  WordGap := 7 * Extra / 19;

  for I := 1 to Length(Normalized) do
  begin
    if Normalized[I] = ' ' then
    begin
      Add(False, WordGap, 0);
      Continue;
    end;

    if (I > 1) and (Normalized[I - 1] <> ' ') then
      Add(False, CharGap, I);

    Code := MorseForChar(Normalized[I]);
    for E := 1 to Length(Code) do
    begin
      if E > 1 then
        Add(False, Dit, I);
      if Code[E] = '.' then
        Add(True, Dit, I)
      else
        Add(True, 3 * Dit, I);
    end;
  end;

  SetLength(Result, Count);
end;

function SegmentsDuration(const Segments: TCWSegments): Double;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to High(Segments) do
    Result := Result + Segments[I].Duration;
end;

{ 長さ RampSamples の傾斜のうち、Offset 番目のサンプルにおける利得を返します。

  Raised-cosine gain Offset samples into a ramp of RampSamples samples. }
function RampGain(Offset, RampSamples: Integer): Double;
begin
  if Offset >= RampSamples then
    Result := 1
  else
    Result := 0.5 - 0.5 * Cos(Pi * Offset / RampSamples);
end;

function SegmentsToPCM(const Segments: TCWSegments; const Options: TCWToneOptions): TSingleArray;
var
  SampleRate, Total, Position, Count, I, RampSamples, Index: Integer;
  Envelope, Shaped: TDoubleArray;
  Phase, PhaseStep, Gain, Value: Double;
  LeadIn, LeadOut, RunEnd, RunLength: Integer;
begin
  Result := nil;
  SampleRate := Options.SampleRate;
  if SampleRate <= 0 then
    raise EDeepCW.Create('The tone sample rate must be positive.');
  if (Options.ToneHz <= 0) or (Options.ToneHz >= SampleRate / 2) then
    raise EDeepCW.CreateFmt('The tone frequency must lie between 0 and %d Hz.', [SampleRate div 2]);

  LeadIn := Round(Max(0, Options.LeadInSeconds) * SampleRate);
  LeadOut := Round(Max(0, Options.LeadOutSeconds) * SampleRate);
  Total := LeadIn + LeadOut;
  for I := 0 to High(Segments) do
    Total := Total + Round(Segments[I].Duration * SampleRate);
  if Total <= 0 then
    Exit;

  { 0 と 1 からなる断続の包絡線を作り、各端を余弦で滑らかにします。これにより
    クリック音が生じず、信号がモデルの通過帯域に収まります。

    Build a 0/1 keying envelope, then soften every edge with a raised cosine so
    the transmission has no clicks and stays inside the model's passband. }
  SetLength(Envelope, Total);
  Position := LeadIn;
  for I := 0 to High(Segments) do
  begin
    Count := Round(Segments[I].Duration * SampleRate);
    if Segments[I].Tone then
      for Index := Position to Min(Position + Count, Total) - 1 do
        Envelope[Index] := 1;
    Inc(Position, Count);
  end;

  { 電鍵を押している各区間の始端と終端を余弦で整形します。利得は 2 値の包絡線
    から読み取り、別の配列へ書き出すため、整形中も端の位置を判定できます。

    Shape every keyed run with a raised cosine rise and fall. The gain is read
    from the binary envelope and written to a second array, so the edges stay
    detectable while the ramps are applied. }
  RampSamples := Max(1, Round(Options.RampMs / 1000 * SampleRate));
  SetLength(Shaped, Total);
  Index := 0;
  while Index < Total do
  begin
    if Envelope[Index] = 0 then
    begin
      Inc(Index);
      Continue;
    end;
    RunEnd := Index;
    while (RunEnd < Total) and (Envelope[RunEnd] <> 0) do
      Inc(RunEnd);
    RunLength := RunEnd - Index;
    for I := 0 to RunLength - 1 do
      Shaped[Index + I] := Min(RampGain(I, RampSamples),
        RampGain(RunLength - 1 - I, RampSamples));
    Index := RunEnd;
  end;

  SetLength(Result, Total);
  Phase := 0;
  PhaseStep := 2 * Pi * Options.ToneHz / SampleRate;
  Gain := ClampDouble(Options.Amplitude, 0, 1);
  for Index := 0 to Total - 1 do
  begin
    Value := Gain * Shaped[Index] * Sin(Phase);
    if Options.NoiseAmplitude > 0 then
      { 一様乱数 2 つの和です。軽量で扱いやすい正規雑音の代用になります。
      Sum of two uniforms: a cheap, well behaved stand-in for Gaussian noise. }
      Value := Value + Options.NoiseAmplitude * (Random + Random - 1);
    Result[Index] := ClampDouble(Value, -1, 1);
    Phase := Phase + PhaseStep;
    if Phase > 2 * Pi then
      Phase := Phase - 2 * Pi;
  end;
end;

function TextToPCM(const Text: string; const Timing: TCWTiming;
  const Options: TCWToneOptions): TSingleArray;
begin
  Result := SegmentsToPCM(TextToSegments(Text, Timing), Options);
end;

end.
