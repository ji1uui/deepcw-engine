unit FistCases;

{ 試験用の「不完全な送信」を作ります。**製品のコードではありません。**

  送信訓練の測定（`DeepCW.Fist`）は、うまくない符号を測るためのものです。
  うまい符号だけで確かめれば、**測れないことに気づけません**（付録 A.2）。
  ここでは、ばらつき・長短比・各間隔の比・速度の変化を指定して合成します。

  `cw_tune` と `dsp_check` の両方から使うため、単位を 1 つにしてあります。
  同じものを 2 つに写せば、片方だけ直したことに気づけません（教訓 10.11）。

  Builds imperfect sending, for the tests. **This is not product code.**

  The measurement in `DeepCW.Fist` exists to measure sending that is not good;
  checked only against good sending, **what it cannot measure would go unseen**
  (appendix A.2). Spread, the dah-to-dit ratio, the spacing ratios and a drift
  in speed are each given here and synthesised.

  It is one unit because both `cw_tune` and `dsp_check` use it: the same thing
  written twice can be fixed in one place and not the other (lesson 10.11). }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Math, DeepCW.Types, DeepCW.Morse;

type
  { 送信の癖。**すべて「送った値」であり、測定が復元すべきものです。**
    A hand's habits -- every one of them a figure the measurement should
    recover. }
  TSending = record
    Name: string;
    Wpm: Double;
    Ratio: Double;       { 長点 / 短点 }
    IntraRatio: Double;  { 符号内の間隔 / 短点 }
    CharRatio: Double;   { 文字間 / 短点 }
    WordRatio: Double;   { 語間 / 短点 }
    Jitter: Double;      { 要素ごとのばらつき（変動係数） }
    Drift: Double;       { 終わりまでに速度が何倍になるか − 1 }
    ToneHz: Double;
    Noise: Double;
  end;
  TSendings = array of TSending;

{ 付録 A が測った 6 つの技量です。順番は上手い順です。
  The six hands appendix A measured, best first. }
function AppendixCases: TSendings;

{ 指定した癖で課題文を送ります。`Seed` を変えると、ばらつきの出方だけが
  変わります。
  Sends the text with the given habits; a different `Seed` changes only how the
  spread falls out. }
function SendText(const Text: string; const Hand: TSending; SampleRate: Integer;
  Seed: Integer): TSingleArray;

implementation

function AppendixCases: TSendings;

  function Hand(const Name: string; Ratio, IntraRatio, CharRatio, WordRatio,
    Jitter, Drift: Double): TSending;
  begin
    Result.Name := Name;
    Result.Wpm := 20;
    Result.Ratio := Ratio;
    Result.IntraRatio := IntraRatio;
    Result.CharRatio := CharRatio;
    Result.WordRatio := WordRatio;
    Result.Jitter := Jitter;
    Result.Drift := Drift;
    Result.ToneHz := 700;
    Result.Noise := 0;
  end;

begin
  SetLength(Result, 6);
  Result[0] := Hand('熟練（ばらつき 3%）', 3.0, 1, 3, 7, 0.03, 0);
  Result[1] := Hand('ファンズワース（文字間 6）', 3.0, 1, 6, 12, 0.03, 0);
  Result[2] := Hand('バグキー風（長短比 2.6）', 2.6, 1, 3, 7, 0.06, 0);
  Result[3] := Hand('速度ドリフト 25%', 3.0, 1, 3, 7, 0.03, 0.25);
  Result[4] := Hand('中級（ばらつき 12%）', 3.0, 1, 3, 7, 0.12, 0);
  Result[5] := Hand('初級（ばらつき 25%・比 2.4・文字間 2.2）',
    2.4, 1, 2.2, 6, 0.25, 0);
end;

{ 正規分布に近い乱数。一様乱数 12 個の和から 6 を引きます。
  A near-normal deviate: twelve uniforms less six. }
function Normal: Double;
var
  I: Integer;
begin
  Result := 0;
  for I := 1 to 12 do
    Result := Result + Random;
  Result := Result - 6;
end;

function SendText(const Text: string; const Hand: TSending; SampleRate: Integer;
  Seed: Integer): TSingleArray;
type
  TPart = record
    Tone: Boolean;
    Seconds: Double;
  end;
var
  Normalized, Code: string;
  Parts: array of TPart;
  Count, I, E, Index_, Total, Ramp, Length_: Integer;
  Dit, Value, At_, Elapsed, Speed, Gain, Phase: Double;
  Started: Boolean;
  PendingWord: Boolean;

  procedure Add(Tone: Boolean; Units__: Double);
  begin
    if Count = Length(Parts) then
      SetLength(Parts, Max(64, Count * 2));
    Parts[Count].Tone := Tone;
    Parts[Count].Seconds := Units__;
    Inc(Count);
  end;

begin
  Result := nil;
  Normalized := NormalizeText(Text);
  if (Normalized = '') or (SampleRate <= 0) or (Hand.Wpm <= 0) then
    Exit;
  RandSeed := Seed;
  Dit := 1.2 / Hand.Wpm;

  Parts := nil;
  Count := 0;
  Started := False;
  PendingWord := False;
  for I := 1 to Length(Normalized) do
  begin
    if Normalized[I] = ' ' then
    begin
      if Started then
        PendingWord := True;
      Continue;
    end;
    Code := MorseForChar(Normalized[I]);
    if Code = '' then
      Continue;
    if Started then
    begin
      if PendingWord then
        Add(False, Hand.WordRatio)
      else
        Add(False, Hand.CharRatio);
      PendingWord := False;
    end;
    for E := 1 to Length(Code) do
    begin
      if E > 1 then
        Add(False, Hand.IntraRatio);
      if Code[E] = '.' then
        Add(True, 1)
      else
        Add(True, Hand.Ratio);
    end;
    Started := True;
  end;
  SetLength(Parts, Count);
  if Count = 0 then
    Exit;

  { 長さを決めます。ばらつきは要素ごと、速度の変化は時刻に対して効きます。
    **速度の変化は、ばらつきとは別のもの**なので、別々に掛けます。
    The lengths: the spread falls per element, the drift with time. **Drift is
    not spread**, so the two are applied separately. }
  Elapsed := 0;
  for I := 0 to High(Parts) do
  begin
    Value := Parts[I].Seconds * Dit;
    if Hand.Jitter > 0 then
      Value := Value * Max(0.2, 1 + Hand.Jitter * Normal);
    Parts[I].Seconds := Value;
    Elapsed := Elapsed + Value;
  end;
  if (Hand.Drift <> 0) and (Elapsed > 0) then
  begin
    At_ := 0;
    for I := 0 to High(Parts) do
    begin
      { 速度が上がれば、長さは縮みます。/ Faster means shorter. }
      Speed := 1 + Hand.Drift * (At_ / Elapsed);
      At_ := At_ + Parts[I].Seconds;
      Parts[I].Seconds := Parts[I].Seconds / Speed;
    end;
  end;

  { 先頭と末尾に無音を置きます。/ Silence at each end. }
  Total := Round(0.3 * SampleRate);
  for I := 0 to High(Parts) do
    Total := Total + Max(1, Round(Parts[I].Seconds * SampleRate));
  Total := Total + Round(0.3 * SampleRate);
  SetLength(Result, Total);
  for I := 0 to High(Result) do
    Result[I] := 0;

  Ramp := Max(1, Round(0.005 * SampleRate));
  Index_ := Round(0.3 * SampleRate);
  Phase := 0;
  for I := 0 to High(Parts) do
  begin
    Length_ := Max(1, Round(Parts[I].Seconds * SampleRate));
    if Parts[I].Tone then
      for E := 0 to Length_ - 1 do
      begin
        { 端を余弦で整形します。**しきい値の −6 dB は整形の中央にあたるので、
          始まりと終わりのずれは打ち消し合います。**
          A raised-cosine edge: the -6 dB threshold falls at its middle, so the
          error at the start and at the end cancel. }
        Gain := 1;
        if E < Ramp then
          Gain := 0.5 * (1 - Cos(Pi * E / Ramp))
        else if E >= Length_ - Ramp then
          Gain := 0.5 * (1 - Cos(Pi * (Length_ - 1 - E) / Ramp));
        Phase := 2 * Pi * Hand.ToneHz * ((Index_ + E) / SampleRate);
        if Index_ + E <= High(Result) then
          Result[Index_ + E] := 0.5 * Gain * Sin(Phase);
      end;
    Inc(Index_, Length_);
  end;

  if Hand.Noise > 0 then
    for I := 0 to High(Result) do
      Result[I] := Result[I] + Hand.Noise * (Random + Random - 1);
end;

end.
