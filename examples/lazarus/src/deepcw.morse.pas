unit DeepCW.Morse;

{ The transmit path: text to Morse timing to a sidetone waveform.

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
  { One keyed or silent interval of the transmission. }
  TCWSegment = record
    Tone: Boolean;
    Duration: Double;   { seconds }
    TextIndex: Integer; { 1-based index into the source text, 0 for word gaps }
  end;
  TCWSegments = array of TCWSegment;

  TCWTiming = record
    CharWpm: Double;  { speed the individual characters are sent at }
    TextWpm: Double;  { overall speed; equal to CharWpm disables Farnsworth }
  end;

  TCWToneOptions = record
    SampleRate: Integer;
    ToneHz: Double;
    Amplitude: Double;  { peak amplitude of the sidetone, 0..1 }
    RampMs: Double;     { raised-cosine rise and fall, suppresses key clicks }
    NoiseAmplitude: Double; { white noise added to the whole signal, 0..1 }
    LeadInSeconds: Double;
    LeadOutSeconds: Double;
  end;

function DefaultTiming: TCWTiming;
function DefaultToneOptions: TCWToneOptions;

{ True when the character has a Morse representation in this unit. }
function IsSendable(Ch: Char): Boolean;

{ True when the DeepCW model can emit the character, i.e. it is in the model
  alphabet. Sendable-but-undecodable characters are still transmitted. }
function IsDecodable(Ch: Char): Boolean;

{ '.-' style code for one character, or '' when it has no representation. }
function MorseForChar(Ch: Char): string;

{ Human-readable code for a whole message, '/' between words. }
function TextToMorseCode(const Text: string): string;

{ Normalises to the upper-case subset this unit can key, dropping unsupported
  characters and collapsing runs of whitespace. }
function NormalizeText(const Text: string): string;

{ Expands text into keyed and silent intervals. }
function TextToSegments(const Text: string; const Timing: TCWTiming): TCWSegments;

function SegmentsDuration(const Segments: TCWSegments): Double;

{ Renders segments as a mono waveform. The oscillator runs continuously and is
  gated by the envelope, so successive elements stay phase coherent. }
function SegmentsToPCM(const Segments: TCWSegments; const Options: TCWToneOptions): TSingleArray;

{ Convenience wrapper: text straight to audio. }
function TextToPCM(const Text: string; const Timing: TCWTiming;
  const Options: TCWToneOptions): TSingleArray;

{ Seconds per dit at the given speed. }
function DitSeconds(Wpm: Double): Double;

implementation

const
  { Index 0 is 'A'. Only characters the model alphabet contains are listed
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

function IsDecodable(Ch: Char): Boolean;
begin
  { The exported alphabet is A-Z, 0-9, comma, full stop, slash, question mark
    and space, so every character this unit can key is also decodable. }
  Result := IsSendable(Ch);
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
  { PARIS is 50 dit units long, so 1.2 / wpm seconds per dit. }
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
  { ARRL Farnsworth: spread the extra delay over three units between characters
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

{ Raised-cosine gain Offset samples into a ramp of RampSamples samples. }
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

  { Build a 0/1 keying envelope, then soften every edge with a raised cosine so
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

  { Shape every keyed run with a raised cosine rise and fall. The gain is read
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
      { Sum of two uniforms: a cheap, well behaved stand-in for Gaussian noise. }
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
