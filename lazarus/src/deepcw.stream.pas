unit DeepCW.Stream;

{ 流れてくる音声を、確定したテキストと暫定のテキストに分けて復号します。

  受信中の文字が書き換わり続けると読めません。そこで、語の切れ目まで戻って
  「ここから前はもう変えない」と決め、それより後だけを毎回引き直します
  （要件 FR-B.2）。確定点は語間の中央に取り、末尾の一定時間は確定させません。
  末尾は次の符号が続くかどうかがまだ分からないためです（要件 FR-B.3）。

  GUI から独立しているので、サウンドカードなしに検証できます（要件 NFR-7.1）。

  Decodes a stream of audio into confirmed and provisional text.

  Text that keeps rewriting itself cannot be read, so this commits everything
  before a word gap and only re-decodes what follows (requirement FR-B.2). The
  split is taken at the middle of a word space, and a guard at the tail is left
  uncommitted because it is not yet known whether more code follows
  (requirement FR-B.3).

  It has no GUI dependency, so it can be verified without a sound card
  (requirement NFR-7.1). }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Math, DeepCW.Types, DeepCW.Decoder, DeepCW.Wave;

const
  { 解析にかける最大の長さ。これを超えたら語間を待たずに確定させます。
    Longest span analysed; past this a split is forced without waiting. }
  STREAM_MAX_SECONDS = 24.0;
  { 末尾のこの時間は確定させません。/ The tail left uncommitted. }
  STREAM_TAIL_GUARD_SECONDS = 1.25;
  { これより短い先頭部分は確定させません。/ Nothing shorter than this commits. }
  STREAM_MIN_CONFIRMED_SECONDS = 2.0;
  { 解析を回す最小の間隔。/ Shortest interval between analyses. }
  STREAM_MIN_INTERVAL_SECONDS = 1.0;
  { これだけ溜まるまでは解析しません。/ No analysis until this much is buffered. }
  STREAM_MIN_PENDING_SECONDS = 2.0;

type
  TStreamingDecoder = class
  private
    FDecoder: TDeepCWDecoder;
    FLock: TRTLCriticalSection;
    { 未確定の音声。先頭は直前の確定点です。
      Audio not yet committed; it starts at the last split point. }
    FPending: TSingleArray;
    FPendingCount: Integer;
    FConfirmed: TDecodedChars;
    FProvisional: TDecodedChars;
    FConfirmedSeconds: Double;
    FDroppedSamples: Int64;
    function TakeSnapshot: TSingleArray;
    procedure AppendConfirmed(const Chars: TDecodedChars);
    function StripSeamSpace(const Chars: TDecodedChars): TDecodedChars;
    procedure SetProvisional(const Chars: TDecodedChars);
    procedure DropLeading(Samples: Integer);
    function FindSplit(const Chars: TDecodedChars; AnalysisSeconds: Double;
      Forced: Boolean; out SplitSeconds: Double): Integer;
  public
    constructor Create(ADecoder: TDeepCWDecoder);
    destructor Destroy; override;

    { 受信した音声を足します。モデルの周波数へ変換して溜めます。呼び出し側の
      スレッドから安全に呼べます。

      Adds received audio, resampled to the model rate. Safe to call from a
      different thread to Step. }
    procedure Append(const Samples: TSingleArray; SampleRate: Integer);

    { 溜まった音声を 1 回解析します。確定が進んだら True を返します。
      時間がかかるため、GUI とは別のスレッドから呼んでください。

      Analyses the buffer once, returning True when more text was confirmed.
      It is slow; call it off the GUI thread. }
    function Step: Boolean;

    { 受信を止めるときに、残っている暫定部分を確定へ移します。
      Commits whatever is still provisional, for when reception stops. }
    procedure Finish;

    procedure Reset;

    { 解析に足りるだけ溜まっているか。/ Whether enough audio is buffered. }
    function Ready: Boolean;
    function PendingSeconds: Double;

    { 確定したテキスト。二度と書き換わりません。
      Confirmed text; never rewritten. }
    function ConfirmedChars: TDecodedChars;
    { 暫定のテキスト。次の解析で書き換わります。
      Provisional text; the next analysis may rewrite it. }
    function ProvisionalChars: TDecodedChars;
    { 確定と暫定をつないだ全体と、確定部分の文字数。
      The whole transcript and how much of it is confirmed. }
    function AllChars(out ConfirmedCount: Integer): TDecodedChars;

    property Decoder: TDeepCWDecoder read FDecoder;
  end;

implementation

constructor TStreamingDecoder.Create(ADecoder: TDeepCWDecoder);
begin
  inherited Create;
  if ADecoder = nil then
    raise EDeepCW.Create('The streaming decoder needs a decoder.');
  FDecoder := ADecoder;
  InitCriticalSection(FLock);
end;

destructor TStreamingDecoder.Destroy;
begin
  DoneCriticalSection(FLock);
  inherited Destroy;
end;

procedure TStreamingDecoder.Reset;
begin
  EnterCriticalSection(FLock);
  try
    FPending := nil;
    FPendingCount := 0;
    FConfirmed := nil;
    FProvisional := nil;
    FConfirmedSeconds := 0;
    FDroppedSamples := 0;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

procedure TStreamingDecoder.Append(const Samples: TSingleArray; SampleRate: Integer);
var
  Converted: TSingleArray;
  I, Needed: Integer;
begin
  if Length(Samples) = 0 then
    Exit;
  Converted := ResampleLinear(Samples, SampleRate, FDecoder.Metadata.SampleRate);
  EnterCriticalSection(FLock);
  try
    Needed := FPendingCount + Length(Converted);
    if Needed > Length(FPending) then
      SetLength(FPending, Max(Needed, Max(4096, Length(FPending) * 2)));
    for I := 0 to High(Converted) do
      FPending[FPendingCount + I] := Converted[I];
    Inc(FPendingCount, Length(Converted));
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TStreamingDecoder.TakeSnapshot: TSingleArray;
var
  Rate, Wanted: Integer;
begin
  Rate := FDecoder.Metadata.SampleRate;
  EnterCriticalSection(FLock);
  try
    { 解析にかけるのは先頭から最大 STREAM_MAX_SECONDS 分だけです。
      Only the first STREAM_MAX_SECONDS of the buffer is analysed. }
    Wanted := Min(FPendingCount, Round(STREAM_MAX_SECONDS * Rate));
    Result := Copy(FPending, 0, Wanted);
  finally
    LeaveCriticalSection(FLock);
  end;
end;

procedure TStreamingDecoder.DropLeading(Samples: Integer);
var
  I: Integer;
begin
  if Samples <= 0 then
    Exit;
  EnterCriticalSection(FLock);
  try
    if Samples >= FPendingCount then
      FPendingCount := 0
    else
    begin
      for I := 0 to FPendingCount - Samples - 1 do
        FPending[I] := FPending[I + Samples];
      Dec(FPendingCount, Samples);
    end;
    Inc(FDroppedSamples, Samples);
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TStreamingDecoder.Ready: Boolean;
begin
  Result := PendingSeconds >= STREAM_MIN_PENDING_SECONDS;
end;

function TStreamingDecoder.PendingSeconds: Double;
begin
  EnterCriticalSection(FLock);
  try
    Result := FPendingCount / FDecoder.Metadata.SampleRate;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

{ 語間の中央で切るため、同じ空白が確定側の末尾と次の解析の先頭に二度現れます。
  片方だけ残します。

  The split falls in the middle of a word gap, so the same space is decoded
  once at the end of the committed part and again at the head of the next
  analysis. Keep only one. }
function TStreamingDecoder.StripSeamSpace(const Chars: TDecodedChars): TDecodedChars;
begin
  Result := Chars;
  if (Length(Result) = 0) or (Result[0].Text <> ' ') then
    Exit;
  if (Length(FConfirmed) > 0) and (FConfirmed[High(FConfirmed)].Text = ' ') then
    Result := Copy(Result, 1, Length(Result) - 1);
end;

{ 暫定部分にも録音全体の時刻を持たせます。解析は確定点から始まるため、その分を
  足さないと、ウォーターフォールとの突き合わせも遅延の測定もできません。

  Provisional characters carry whole-recording times too. The analysis starts
  at the last split point, so without this offset neither waterfall alignment
  nor a latency measurement would line up. }
procedure TStreamingDecoder.SetProvisional(const Chars: TDecodedChars);
var
  Shifted: TDecodedChars;
  I: Integer;
begin
  Shifted := StripSeamSpace(Chars);
  for I := 0 to High(Shifted) do
  begin
    Shifted[I].Seconds := Shifted[I].Seconds + FConfirmedSeconds;
    Shifted[I].EndSeconds := Shifted[I].EndSeconds + FConfirmedSeconds;
  end;
  FProvisional := Shifted;
end;

procedure TStreamingDecoder.AppendConfirmed(const Chars: TDecodedChars);
var
  Trimmed: TDecodedChars;
  I, Base: Integer;
begin
  Trimmed := StripSeamSpace(Chars);
  if Length(Trimmed) = 0 then
    Exit;
  Base := Length(FConfirmed);
  SetLength(FConfirmed, Base + Length(Trimmed));
  for I := 0 to High(Trimmed) do
    FConfirmed[Base + I] := Trimmed[I];
end;

function TStreamingDecoder.FindSplit(const Chars: TDecodedChars;
  AnalysisSeconds: Double; Forced: Boolean; out SplitSeconds: Double): Integer;
var
  I: Integer;
  Latest, Middle: Double;
begin
  Result := -1;
  SplitSeconds := 0;
  { 末尾のガードより手前にある、最後の語間を探します。
    Find the last word space that sits before the tail guard. }
  if Forced then
    Latest := AnalysisSeconds
  else
    Latest := AnalysisSeconds - STREAM_TAIL_GUARD_SECONDS;

  for I := High(Chars) downto 0 do
  begin
    if Chars[I].Text <> ' ' then
      Continue;
    Middle := (Chars[I].Seconds + Chars[I].EndSeconds) / 2;
    if (Middle >= STREAM_MIN_CONFIRMED_SECONDS) and (Middle <= Latest) then
    begin
      Result := I;
      SplitSeconds := Middle;
      Exit;
    end;
  end;
end;

function TStreamingDecoder.Step: Boolean;
var
  Audio: TSingleArray;
  Chars, Committed: TDecodedChars;
  Rate, SplitIndex, I, Count: Integer;
  AnalysisSeconds, SplitSeconds: Double;
  Forced: Boolean;
begin
  Result := False;
  Rate := FDecoder.Metadata.SampleRate;
  Audio := TakeSnapshot;
  if Length(Audio) = 0 then
    Exit;

  AnalysisSeconds := Length(Audio) / Rate;
  if AnalysisSeconds < STREAM_MIN_PENDING_SECONDS then
    Exit;

  Chars := FDecoder.DecodeLongSamplesTimed(Audio, Rate);

  { 上限まで溜まったら、末尾のガードを外してでも前へ進めます。
    Once the buffer is full, commit even without the tail guard. }
  Forced := AnalysisSeconds >= STREAM_MAX_SECONDS - 0.01;
  SplitIndex := FindSplit(Chars, AnalysisSeconds, Forced, SplitSeconds);

  if SplitIndex < 0 then
  begin
    if Forced then
    begin
      { 語間がないほど詰まっている場合は、ガードの手前までを確定させます。
        With no word gap at all, commit up to the guard anyway. }
      SplitSeconds := AnalysisSeconds - STREAM_TAIL_GUARD_SECONDS;
      SplitIndex := High(Chars);
      while (SplitIndex >= 0) and (Chars[SplitIndex].EndSeconds > SplitSeconds) do
        Dec(SplitIndex);
      if SplitIndex < 0 then
      begin
        EnterCriticalSection(FLock);
        try
          SetProvisional(Chars);
        finally
          LeaveCriticalSection(FLock);
        end;
        Exit;
      end;
    end
    else
    begin
      EnterCriticalSection(FLock);
      try
        SetProvisional(Chars);
      finally
        LeaveCriticalSection(FLock);
      end;
      Exit;
    end;
  end;

  { 確定させる文字を取り出します。語間そのものは確定側の末尾に残します。
    Take the characters to commit, keeping the word space itself. }
  Count := 0;
  SetLength(Committed, SplitIndex + 1);
  for I := 0 to SplitIndex do
    if (Chars[I].EndSeconds <= SplitSeconds) or (I = SplitIndex) then
    begin
      Committed[Count] := Chars[I];
      Committed[Count].Seconds := Committed[Count].Seconds + FConfirmedSeconds;
      Committed[Count].EndSeconds := Committed[Count].EndSeconds + FConfirmedSeconds;
      Inc(Count);
    end;
  SetLength(Committed, Count);

  EnterCriticalSection(FLock);
  try
    AppendConfirmed(Committed);
    FProvisional := nil;
    FConfirmedSeconds := FConfirmedSeconds + SplitSeconds;
  finally
    LeaveCriticalSection(FLock);
  end;

  DropLeading(Round(SplitSeconds * Rate));
  Result := Count > 0;
end;

procedure TStreamingDecoder.Finish;
var
  Audio: TSingleArray;
  Chars: TDecodedChars;
  Rate, I: Integer;
begin
  Rate := FDecoder.Metadata.SampleRate;
  Audio := TakeSnapshot;
  if Length(Audio) = 0 then
    Exit;
  Chars := FDecoder.DecodeLongSamplesTimed(Audio, Rate);
  for I := 0 to High(Chars) do
  begin
    Chars[I].Seconds := Chars[I].Seconds + FConfirmedSeconds;
    Chars[I].EndSeconds := Chars[I].EndSeconds + FConfirmedSeconds;
  end;
  EnterCriticalSection(FLock);
  try
    AppendConfirmed(Chars);
    FProvisional := nil;
    FConfirmedSeconds := FConfirmedSeconds + Length(Audio) / Rate;
  finally
    LeaveCriticalSection(FLock);
  end;
  DropLeading(FPendingCount);
end;

function TStreamingDecoder.ConfirmedChars: TDecodedChars;
begin
  EnterCriticalSection(FLock);
  try
    Result := Copy(FConfirmed, 0, Length(FConfirmed));
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TStreamingDecoder.ProvisionalChars: TDecodedChars;
begin
  EnterCriticalSection(FLock);
  try
    Result := Copy(FProvisional, 0, Length(FProvisional));
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TStreamingDecoder.AllChars(out ConfirmedCount: Integer): TDecodedChars;
var
  I: Integer;
begin
  EnterCriticalSection(FLock);
  try
    ConfirmedCount := Length(FConfirmed);
    SetLength(Result, Length(FConfirmed) + Length(FProvisional));
    for I := 0 to High(FConfirmed) do
      Result[I] := FConfirmed[I];
    for I := 0 to High(FProvisional) do
      Result[Length(FConfirmed) + I] := FProvisional[I];
  finally
    LeaveCriticalSection(FLock);
  end;
end;

end.
