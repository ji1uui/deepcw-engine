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
  { 語の後ろへ足す余裕。文字の時刻はその文字が鳴り終わるころを指すので、
    後ろは少しで足ります。
    The margin added after a word. A character's time marks about where it stops
    sounding, so little is needed at that end. }
  REVIEW_PAD_SECONDS = 0.25;

  { 語の前へ遡る長さ。**文字の時刻は、その文字が鳴り「終わる」ころを指します。**
    CTC は音の証拠が出そろってから札を立てるためで、実測では `K`（9 単位）の
    時刻が音の 76% のところ、`N`（5 単位）が 70% のところでした。

    後ろと同じ 0.25 秒しか遡らないと、**語の頭が切れます。**耳には頭の欠けた
    符号が鳴り、読み直し（要件 FR-C.3）は別の文字を読みます。実測では 97 語中
    70 語で頭が欠け、`JA1ABC` が `MA1ABC`、`K` が `U` になりました（付録 AC）。

    いちばん長い文字（`0` は 19 単位で、12 wpm なら 1.9 秒）を覆える長さにします。

    How far back a word starts. **A character's time marks about where it stops
    sounding**: CTC raises its label once the acoustic evidence is in, and
    measured, `K` (nine units) is timed 76% of the way through its sound and `N`
    (five units) 70%.

    Stepping back only the 0.25 seconds used at the other end **cuts the head off
    the word**: the ear hears a code with its beginning missing and a re-reading
    (requirement FR-C.3) reads a different character. Measured, 70 words in 97
    lost their head, `JA1ABC` coming back as `MA1ABC` and `K` as `U`
    (appendix AC).

    The length covers the longest character -- `0` is nineteen units, 1.9
    seconds at 12 wpm. }
  REVIEW_LOOKBACK_SECONDS = 1.2;

  { 前の文字へ食い込まないための床。**前の文字の時刻もその文字の終わりごろ**
    なので、そこから始めると前の文字の尻尾が入り、`E` や `T` として読まれます
    （実測。付録 AC.3）。

    2 つの時刻の間隔に対する割合で置きます。**固定の秒数にすると、速度が変われば
    合わなくなります。**尻尾も間隔も、速度に比例して伸び縮みするためです。

    The floor that keeps the previous character out. **Its time is near its own
    end too**, so starting there lets its tail in, to be read as an `E` or a `T`
    (measured; appendix AC.3).

    It is a fraction of the interval between the two times: **a fixed number of
    seconds would stop fitting when the speed changed**, since both the tail and
    the interval scale with it. }
  REVIEW_GUARD_FRACTION = 0.25;

{ 1 語の音を切り出す範囲を決めます（要件 FR-E.10・FR-C.3）。

  渡すのは 3 つの時刻です。語の**最初の文字の時刻**、**最後の文字の終わりの
  時刻**、そして**その語より前にある最後の文字の時刻**（無ければ負の値）。

  文字の並びではなく時刻だけを受け取るのは、この規則が時刻の話だからです。
  聴き直しと読み直しが同じ範囲を使うためにここに置いてあります。**別々に決めれば、
  聴いた音と読み直した音が食い違います**（教訓 10.11）。

  Decides the span of audio that holds one word (requirements FR-E.10, FR-C.3).

  Three times go in: the word's **first character's time**, its **last
  character's end**, and **the time of the last character before the word**, or a
  negative value where there is none.

  It takes times rather than characters because the rule is about times, and it
  lives here so that replay and re-reading use the same span: **decided
  separately, the audio heard and the audio re-read could differ**
  (lesson 10.11). }
procedure WordAudioSpan(FirstSeconds, LastEndSeconds, PreviousSeconds: Double;
  out FromSeconds, ToSeconds: Double);

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
    { 求めた保持時間のうち、記憶が足りずに確保できなかった秒数。0 なら要求どおり。
      Seconds of the requested retention that memory would not allow; zero means
      the request was met in full. }
    FShortfall: Double;
    FLock: TRTLCriticalSection;
    procedure Resize(ARate: Integer);
    function LatestUnlocked: Double;
  public
    constructor Create(ASeconds: Double; ARate: Integer);
    destructor Destroy; override;

    { 受け取った音声を、それが始まる時刻とともに足します。

      時刻は呼び出し側（復号器）が持っているものをそのまま渡してください。
      保管庫が独自に数えると、復号器が数え直した場面――受信のやり直し、ファイルの
      復号、録音周波数の変更――でどちらかがずれ、聴き直しが別の場所を鳴らします。
      **渡された時刻が保持しているものの続きでなければ、中身を手放して数え直します。**
      これにより、2 つの時計は仕組みとして食い違えません（要件 FR-E.10）。

      Adds received audio together with the time at which it begins.

      The time must be the caller's — the decoder's — rather than one counted
      here. A clock of its own would disagree wherever the decoder restarts its
      own: a fresh reception, a file decode, a change of capture rate; and a
      replay would then play the wrong place. **When the time handed in does not
      continue what is held, the contents are released and counting restarts
      from it.** The two clocks therefore cannot disagree by construction
      (requirement FR-E.10). }
    procedure Append(const Samples: TSingleArray; ASampleRate: Integer;
      StartSeconds: Double);

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
    { 記憶が足りずに確保できなかった秒数。診断に出します。
      Seconds the memory would not allow, for the diagnostics. }
    function ShortfallSeconds: Double;
    procedure SetRetention(ASeconds: Double);
  end;

implementation

procedure WordAudioSpan(FirstSeconds, LastEndSeconds, PreviousSeconds: Double;
  out FromSeconds, ToSeconds: Double);
var
  Guard: Double;
begin
  FromSeconds := FirstSeconds - REVIEW_LOOKBACK_SECONDS;
  if PreviousSeconds >= 0 then
  begin
    Guard := PreviousSeconds +
      REVIEW_GUARD_FRACTION * (FirstSeconds - PreviousSeconds);
    if FromSeconds < Guard then
      FromSeconds := Guard;
  end;
  ToSeconds := LastEndSeconds + REVIEW_PAD_SECONDS;
end;

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
var
  Wanted: Int64;
begin
  FRate := Max(1, ARate);
  FData := nil;
  FCount := 0;
  FHead := 0;
  FShortfall := 0;
  Wanted := Max(1, Round(FSeconds * FRate));
  { 30 分を 48 kHz で保つと 345 MB を一度に確保することになります。取れない
    ことは実際に起こり得ます（32 ビット版、混み合った機械）。取れないまま
    例外を上げると、受信の脈動のたびに同じ失敗を繰り返します。取れるところまで
    半分ずつ下げ、**足りなかったことを覚えておいて画面に出します**（第 10 章
    10.9）。

    Half an hour at 48 kHz means a single 345 MB allocation, and failing to get
    it is a real possibility on a 32-bit build or a busy machine. Letting the
    exception out would repeat the same failure on every pulse of the receive
    loop, so the request is halved until it succeeds and **the shortfall is
    remembered and shown** (chapter 10, rule 10.9). }
  while Wanted >= FRate do
  begin
    try
      SetLength(FData, Wanted);
      Break;
    except
      on EOutOfMemory do
      begin
        FData := nil;
        Wanted := Wanted div 2;
      end;
    end;
  end;
  if Length(FData) = 0 then
    SetLength(FData, FRate);
  if Length(FData) < Round(FSeconds * FRate) then
    FShortfall := FSeconds - Length(FData) / FRate;
end;

function TAudioHistory.LatestUnlocked: Double;
begin
  Result := FBaseSeconds + FCount / FRate;
end;

procedure TAudioHistory.Append(const Samples: TSingleArray; ASampleRate: Integer;
  StartSeconds: Double);
var
  Capacity, Total, Take, Start, Room, I, Tail: Integer;
begin
  if (Length(Samples) = 0) or (ASampleRate <= 0) then
    Exit;
  EnterCriticalSection(FLock);
  try
    if ASampleRate <> FRate then
      { 周波数が変われば、標本の並びの意味が変わります。中身は手放します。
        A different rate gives the samples a different meaning, so the contents
        are released. }
      Resize(ASampleRate);

    { 渡された時刻が、保持しているものの続きになっているか。半標本より離れて
      いれば、呼び出し側が数え直した（受信のやり直し・ファイルの復号）と見て、
      こちらも数え直します。**黙って繋げると、以後ずっと別の場所が鳴ります。**
      Whether the time handed in continues what is held. More than half a sample
      apart means the caller restarted its own count — a fresh reception, a file
      decode — so counting restarts here too. **Joining them silently would play
      the wrong place from then on.** }
    if (FCount = 0) or
       (Abs(StartSeconds - LatestUnlocked) > 0.5 / FRate) then
    begin
      FCount := 0;
      FHead := 0;
      FBaseSeconds := StartSeconds;
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

function TAudioHistory.ShortfallSeconds: Double;
begin
  EnterCriticalSection(FLock);
  try
    Result := FShortfall;
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
