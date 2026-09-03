unit DeepCW.Review;

{ 直近の受信音を保持し、受信文の位置から音へ戻れるようにするための保管庫です。

  読み取りが怪しいとき、運用者がまずやりたいのは「今の 1 語をもう一度聴く」
  ことです。そのためには、受信文に付いている時刻と、保管してある音声の時刻が
  同じ原点で数えられていなければなりません。ここでは
  TStreamingDecoder.ElapsedSeconds と同じ原点、すなわち受信を始めてから
  受け取った音声の通算秒数を使います。追いつけずに捨てた音声も、復号側が時刻を
  進めているぶんだけここでも進めます。そうしないと、聴き直しの位置が受信文から
  少しずつ後ろへずれていきます（要件 FR-E.10）。

  保持する長さには上限があります。上限を超えた分は古いほうから消え、
  EarliestSeconds がそれに合わせて進みます。消えた区間を求められたときは、
  黙って別の場所を返すのではなく、残っている範囲へ切り詰めたうえで、何も
  残っていなければ空を返します（第 10 章 10.1・10.9）。

  A store of recent received audio, so that a point in the transcript can be
  taken back to the sound it came from.

  When a reading looks doubtful, the first thing an operator wants is to hear
  that one word again. For that, the times carried by the transcript and the
  times of the stored audio must be counted from the same origin. The origin
  used here is the one TStreamingDecoder.ElapsedSeconds uses: total seconds of
  audio received since reception began. Audio dropped through falling behind
  still advances this clock, exactly as it advances the decoder's, because
  otherwise a replay would drift steadily later than the transcript
  (requirement FR-E.10).

  Retention is bounded. Once the bound is reached the oldest audio goes and
  EarliestSeconds moves with it. A request for a stretch that has already gone
  is not quietly served from somewhere else: it is clipped to what remains, and
  an empty result is returned when nothing of it is left (chapter 10, rules
  10.1 and 10.9). }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, DeepCW.Types;

const
  { 既定の保持時間。10 分あれば、ひとつの交信をまるごと遡れます。
    The default retention. Ten minutes covers a whole contact. }
  REVIEW_DEFAULT_SECONDS = 600.0;
  { 保持時間として受け付ける範囲。上限は記憶容量から決めています。48 kHz の
    録音を 30 分保つと約 345 MB で、これがひとつの目安です。
    The accepted range of retention. The upper end comes from memory: half an
    hour of 48 kHz audio is about 345 MB, which is the practical limit. }
  REVIEW_MIN_SECONDS = 60.0;
  REVIEW_MAX_SECONDS = 1800.0;
  { 聴き直すときに、語の前後へ足す余裕。頭から鳴り出すと符号の立ち上がりを
    聴き逃すので、少しだけ前から鳴らします。
    The margin added before and after a word when replaying. Starting exactly on
    the first element loses its attack, so playback starts slightly early. }
  REVIEW_PAD_SECONDS = 0.25;

type
  { 直近の受信音を、受信文と同じ時刻で引ける環状バッファ。

    受信スレッド（Append）と GUI スレッド（Extract など）から同時に呼ばれる
    ため、すべての公開手続きは内部で排他を取ります。

    A ring buffer of recent audio, addressable by the same clock as the
    transcript. Append is called from the capture path and the readers from the
    interface, so every public routine takes the lock itself. }
  TAudioHistory = class
  private
    FData: TSingleArray;
    { 保持している標本の数と、環の先頭（最も古い標本）の位置。
      The number of samples held and the position of the ring's head, which is
      the oldest sample. }
    FCount: Integer;
    FHead: Integer;
    FRate: Integer;
    { 残っているうち最も古い標本の、受信開始からの時刻（秒）。
      The time, in seconds since reception began, of the oldest sample kept. }
    FBaseSeconds: Double;
    FSeconds: Double;
    FLock: TRTLCriticalSection;
    procedure Resize(ARate: Integer);
    function LatestUnlocked: Double;
  public
    constructor Create(ASeconds: Double; ARate: Integer);
    destructor Destroy; override;

    { 受け取った音声を足します。録音周波数が変わったときは、それまでの音声を
      手放して新しい周波数で保持し直します。時刻は続きから数えます。

      Adds received audio. A change of capture rate releases what was held and
      starts again at the new rate; the clock continues from where it was. }
    procedure Append(const Samples: TSingleArray; ASampleRate: Integer);

    procedure Clear;

    { 保持しているいちばん古い時刻と、いちばん新しい時刻（秒）。
      The oldest and newest times held, in seconds. }
    function EarliestSeconds: Double;
    function LatestSeconds: Double;
    function RetainedSeconds: Double;
    function SampleRate: Integer;

    { 指定した区間の音声を取り出します。残っている範囲へ切り詰めたうえで返し、
      実際に返した区間を ActualFrom・ActualTo で知らせます。何も残っていなければ
      長さ 0 を返します。

      Returns the audio for a stretch of time, clipped to what remains, and
      reports the stretch actually returned in ActualFrom and ActualTo. A length
      of zero means none of it is left. }
    function Extract(FromSeconds, ToSeconds: Double;
      out ActualFrom, ActualTo: Double; out ARate: Integer): TSingleArray;

    { 保持時間（秒）。変えると、はみ出した分は古いほうから消えます。
      The retention in seconds; shortening it discards the oldest audio. }
    property RetentionSeconds: Double read FSeconds;
    procedure SetRetention(ASeconds: Double);
  end;

implementation

constructor TAudioHistory.Create(ASeconds: Double; ARate: Integer);
begin
  inherited Create;
  InitCriticalSection(FLock);
  FSeconds := EnsureRange(ASeconds, REVIEW_MIN_SECONDS, REVIEW_MAX_SECONDS);
  FRate := Max(1, ARate);
  Resize(FRate);
end;

destructor TAudioHistory.Destroy;
begin
  DoneCriticalSection(FLock);
  inherited Destroy;
end;

{ 環の大きさを決め直します。中身は捨てます。保持時間や録音周波数が変わったとき
  だけ呼ばれ、そのどちらも、それまでの音声をそのまま使い続けられない変化です。
  Sets the ring's size, discarding its contents. It is called only when the
  retention or the capture rate changes, and neither change leaves the audio
  already held usable as it stands. }
procedure TAudioHistory.Resize(ARate: Integer);
begin
  FRate := Max(1, ARate);
  FData := nil;
  SetLength(FData, Max(1, Round(FSeconds * FRate)));
  FCount := 0;
  FHead := 0;
end;

function TAudioHistory.LatestUnlocked: Double;
begin
  Result := FBaseSeconds + FCount / FRate;
end;

procedure TAudioHistory.Append(const Samples: TSingleArray; ASampleRate: Integer);
var
  Capacity, Total, Take, Start, Room, I, Tail: Integer;
  Latest: Double;
begin
  if (Length(Samples) = 0) or (ASampleRate <= 0) then
    Exit;
  EnterCriticalSection(FLock);
  try
    if ASampleRate <> FRate then
    begin
      { 周波数が変われば、標本の並びの意味が変わります。時刻だけを引き継いで
        中身は手放します。
        A different rate gives the samples a different meaning; the clock is
        carried over and the contents are released. }
      Latest := LatestUnlocked;
      Resize(ASampleRate);
      FBaseSeconds := Latest;
    end;

    Capacity := Length(FData);
    Total := Length(Samples);
    { 一度に容量を超える量が来たら、その末尾だけを残します。前半は保持時間の
      外へ出るものなので、書いてすぐ上書きするより、初めから書きません。
      When more than the capacity arrives at once, only its tail is kept: the
      rest falls outside the retention, so it is never written rather than
      written and immediately overwritten. }
    Take := Min(Total, Capacity);
    Start := Total - Take;

    { 収まらない分だけ、古いほうを先に手放します。
      Release exactly as much of the old audio as will not fit. }
    Room := Capacity - FCount;
    if Take > Room then
    begin
      Tail := Take - Room;
      FHead := (FHead + Tail) mod Capacity;
      Dec(FCount, Tail);
      FBaseSeconds := FBaseSeconds + Tail / FRate;
    end;
    { 書かなかった前半のぶんも、時間としては過ぎています。
      The part that was not written has still gone by. }
    if Start > 0 then
      FBaseSeconds := FBaseSeconds + Start / FRate;

    for I := 0 to Take - 1 do
      FData[(FHead + FCount + I) mod Capacity] := Samples[Start + I];
    Inc(FCount, Take);
  finally
    LeaveCriticalSection(FLock);
  end;
end;

procedure TAudioHistory.Clear;
begin
  EnterCriticalSection(FLock);
  try
    FCount := 0;
    FHead := 0;
    FBaseSeconds := 0;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

procedure TAudioHistory.SetRetention(ASeconds: Double);
var
  Latest: Double;
begin
  EnterCriticalSection(FLock);
  try
    ASeconds := EnsureRange(ASeconds, REVIEW_MIN_SECONDS, REVIEW_MAX_SECONDS);
    if SameValue(ASeconds, FSeconds) then
      Exit;
    Latest := LatestUnlocked;
    FSeconds := ASeconds;
    Resize(FRate);
    { 中身は手放しますが、時刻は今のままです。これから受け取る音声が正しい時刻を
      持つようにします。
      The contents go but the clock does not move, so audio received from now on
      still carries the right times. }
    FBaseSeconds := Latest;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TAudioHistory.EarliestSeconds: Double;
begin
  EnterCriticalSection(FLock);
  try
    Result := FBaseSeconds;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TAudioHistory.LatestSeconds: Double;
begin
  EnterCriticalSection(FLock);
  try
    Result := LatestUnlocked;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TAudioHistory.RetainedSeconds: Double;
begin
  EnterCriticalSection(FLock);
  try
    Result := FCount / FRate;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TAudioHistory.SampleRate: Integer;
begin
  EnterCriticalSection(FLock);
  try
    Result := FRate;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TAudioHistory.Extract(FromSeconds, ToSeconds: Double;
  out ActualFrom, ActualTo: Double; out ARate: Integer): TSingleArray;
var
  FirstIndex, LastIndex, Count, I, Capacity: Integer;
begin
  Result := nil;
  EnterCriticalSection(FLock);
  try
    ARate := FRate;
    ActualFrom := 0;
    ActualTo := 0;
    if (FCount = 0) or (ToSeconds <= FromSeconds) then
      Exit;

    { 残っている範囲へ切り詰めます。
      Clip to what is still held. }
    FromSeconds := Max(FromSeconds, FBaseSeconds);
    ToSeconds := Min(ToSeconds, LatestUnlocked);
    if ToSeconds <= FromSeconds then
      Exit;

    Capacity := Length(FData);
    FirstIndex := Floor((FromSeconds - FBaseSeconds) * FRate);
    LastIndex := Ceil((ToSeconds - FBaseSeconds) * FRate);
    FirstIndex := EnsureRange(FirstIndex, 0, FCount);
    LastIndex := EnsureRange(LastIndex, FirstIndex, FCount);
    Count := LastIndex - FirstIndex;
    if Count <= 0 then
      Exit;

    SetLength(Result, Count);
    for I := 0 to Count - 1 do
      Result[I] := FData[(FHead + FirstIndex + I) mod Capacity];
    ActualFrom := FBaseSeconds + FirstIndex / FRate;
    ActualTo := FBaseSeconds + LastIndex / FRate;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

end.
