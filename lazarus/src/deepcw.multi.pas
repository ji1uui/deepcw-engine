unit DeepCW.Multi;

{ 帯域内の複数の局を、1 本のバッファから同時に読みます（要件 FR-I.1・FR-I.7）。

  **単局の復号と、ここでの復号は、確定のしかたが違います。**単局
  （DeepCW.Stream）は語間まで戻って「ここから前はもう変えない」と決め、その分だけ
  バッファを進めます。局が複数あると、語間の位置が局ごとに違うため、**どれか 1 局の
  確定点で共有のバッファを進めることはできません。**語間の来ない局が 1 つあれば、
  バッファは永遠に進まなくなります。

  そこで、決まった長さの窓を、重なりを持たせて進めます。窓ごとに全局を読み直し、
  局ごとの受信文へは**文字の時刻を見て継ぎ足します。**既に持っている分より後に
  始まった文字だけを受け取るので、重なった区間で同じ文字が二重に入りません。
  窓の末尾は、次の符号が続くかどうかがまだ分からないので受け取りません。重なりを
  末尾の保留より長く取ってあるため、保留した分は次の窓で完全な形になります。

  1 回の窓で行う変換は 1 度だけです。局ごとに周波数変換もリサンプルもしません
  （要件 FR-I.1、付録 G.1）。

  Reads several stations in the band from one buffer (requirements FR-I.1 and
  FR-I.7).

  **Confirmation works differently here than in single-station decoding.** The
  single-station path (DeepCW.Stream) goes back to a word gap, fixes everything
  before it, and advances the buffer by that much. With several stations the word
  gaps fall at different times, so **the shared buffer cannot be advanced by any
  one station's split**: a single station that never leaves a gap would stop the
  buffer for ever.

  Instead a window of fixed length is advanced with an overlap. Every station is
  re-read in each window, and each station's transcript is **extended by looking
  at the character times.** Only characters starting after what is already held
  are taken, so nothing is duplicated across the overlap. The end of the window
  is not taken, because whether more code follows is not yet known; the overlap
  is longer than that held-back tail, so what was held back arrives complete in
  the next window.

  Each window is transformed once. Nothing is translated or resampled per station
  (requirement FR-I.1, appendix G.1). }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Math, DeepCW.Types, DeepCW.Decoder, DeepCW.Dsp,
  DeepCW.Wave, DeepCW.Stream, DeepCW.Stations;

const
  { 1 回に読む長さと、次の窓までの進み。差が重なりになります。

    窓を短くすると文字が早く出ますが、1 秒あたりの読み直しが増えます。24 秒
    （単局と同じ）では、呼ばれてから知らせるまでが最悪 24 秒になり、待機モード
    （要件 FR-I.4）としては遅すぎます。

    The span read at once and the step to the next window; the difference is the
    overlap.

    A shorter window brings characters out sooner but re-reads more per second of
    audio. At 24 seconds — what single-station uses — being called could take 24
    seconds to report, which is too slow for the waiting mode (requirement
    FR-I.4). }
  MULTI_WINDOW_SECONDS = 10.0;
  MULTI_ADVANCE_SECONDS = 7.5;

  { これより短い残りは解析しません。短すぎる音声はモデルの窓にも足りず、出て
    くる文字も当てになりません。
    A remainder shorter than this is not analysed: too little audio does not even
    fill the model's window, and what comes out cannot be relied on. }
  MULTI_MIN_WINDOW_SECONDS = 2.0;

  { 窓の末尾で受け取らない長さ。次の符号が続くかどうかがまだ分からない範囲です。
    重なり（2.5 秒）より短くなければなりません。短くないと、保留した区間が
    次の窓にも入らず、**文字が消えます。**

    The tail of a window that is not taken, being the span where it is not yet
    known whether more code follows. It must be shorter than the overlap of 2.5
    seconds; if it were not, what was held back would fall outside the next
    window too and **characters would vanish.** }
  MULTI_TAIL_GUARD_SECONDS = STREAM_TAIL_GUARD_SECONDS;

  { 溜めておく音声の上限。窓の倍を持ちます。超えた分は古いほうから捨て、
    捨てたことを申告します（第 10 章 10.1）。
    The most audio held, twice a window. Beyond it the oldest goes and the loss
    is declared (chapter 10, rule 10.1). }
  MULTI_MAX_BUFFER_SECONDS = MULTI_WINDOW_SECONDS * 2;

  { 1 回の窓で解析に使ってよい時間の割合。進みの時間に対する割合です。1.0 に
    すると、少しでも見積もりを外した瞬間に遅れが溜まりはじめます。
    The share of a window's step that analysis may use. At 1.0 the slightest
    error in the estimate starts accumulating delay. }
  MULTI_TIME_BUDGET = 0.7;

  { 解析する局数の上限。機器がいくら速くても、これ以上は増やしません。画面に
    並べて意味のある数にも限りがあります（要件 FR-J）。
    The ceiling on how many stations are analysed, however fast the machine.
    There is also a limit to how many are meaningful on screen
    (requirement FR-J). }
  MULTI_MAX_STATIONS = 24;

  { いま解析している局を、解析し続けるために与える下駄（dB）。

    強い順にそのまま選ぶと、同じくらいの強さの局が並んだときに、窓ごとに顔ぶれが
    入れ替わります。**そうなると、どの局の受信文にも穴が空きます。**しかも穴は
    時刻の飛びとしてしか現れないので、読んでいるほうは気づきません。切り捨てられた
    局が「切り捨て」と表示されるほうが、全局が虫食いになるよりよほど親切です。

    下駄を履かせると、明らかに強い局が現れたときだけ入れ替わります。

    The margin in decibels given to a station already being analysed, to keep it
    being analysed.

    Taking the strongest outright makes the chosen set change from window to
    window whenever several stations are of similar strength. **Every transcript
    then acquires holes** — holes that show up only as a jump in the timestamps,
    so a reader does not notice them. A station shown as cut is far kinder than
    every station being moth-eaten.

    With the margin, the set changes only when a station appears that is clearly
    stronger. }
  MULTI_KEEP_MARGIN_DB = 3.0;

  { 同じ文字が、これより近い間隔で 2 つ続いたら、同じ 1 文字の二度読みと見なします。

    CTC が出す文字には**幅がありません。**実測すると、文字も空白も 0〜15 ms
    （1 フレーム）です。したがって「既に取った分より後に始まったか」で二重を
    避けようとしても、重なった区間で同じ文字がわずかにずれて出れば通ってしまい
    ます。実際、境界 8.750 秒に対して 8.748 と 8.752 に出た同じ X が二度取られ、
    `JH2XYZ` が `JH2XXYZ` になりました（付録 P.1）。

    ずれの実測は 4 ms、フレームは 15 ms。一方、本当に同じ文字が 2 つ続く最短は、
    50 WPM でも短点 4 つぶん＝約 96 ms あります。50 ms はその中間に取ってあります。

    Two identical characters closer together than this are taken to be one
    character read twice.

    The characters CTC produces **have no width**: measured, both letters and
    spaces span 0 to 15 ms, one frame. Avoiding duplicates by asking whether a
    character starts after what was already taken therefore lets one through
    whenever the same character comes out slightly shifted in the overlap. It
    did: the same X at 8.748 and 8.752 against a boundary of 8.750 was taken
    twice, turning `JH2XYZ` into `JH2XXYZ` (appendix P.1).

    The measured shift is 4 ms and a frame is 15 ms, while two genuinely repeated
    characters are at least four dit lengths apart — about 96 ms even at 50 WPM.
    Fifty milliseconds sits between the two. }
  MULTI_SAME_CHAR_SECONDS = 0.05;

  { 聞こえなくなった局の記録を残す時間。バンドマップは「いつ出ていたか」を
    見せるので、消えた瞬間に記録まで消しては用をなしません（要件 FR-J）。
    How long a station's record outlives its signal. The band map shows when a
    station was on the air, so erasing the record the moment it stops would
    defeat it (requirement FR-J). }
  MULTI_KEEP_SECONDS = 600.0;

  { 1 局あたりに保つ文字数の上限。超えたら古いほうから捨てます。

    上限が無ければ、出しっぱなしの局の受信文は際限なく伸びます。単局なら 1 本
    ですが、ここでは局の数だけ並びます。**入ってくるものには上限を置き、捨てた
    ことは分かるようにする**（第 10 章 10.1）。20 WPM で 4000 文字はおよそ 40 分
    ぶんで、バンドマップから 1 局を選んで読み返すには十分な長さです。

    The most characters kept for one station; past it the oldest go.

    Without a limit, a station that never stops would grow its transcript without
    bound — and here there is one per station, not one in total. **What arrives
    is bounded, and what is dropped is visible** (chapter 10, rule 10.1). Four
    thousand characters is about forty minutes at 20 WPM, ample for picking a
    station off the band map and reading back. }
  MULTI_MAX_CHARS = 4000;

type
  { 1 局ぶんの読み取り結果。/ What was read from one station. }
  TStationLog = record
    Id: Int64;
    Hz: Double;
    LevelDb: Double;
    HalfWidthHz: Double;
    { この音程に畳み込まれた別の峰の数。0 なら 1 局です。密集した範囲を
      「密集している」と示すために要ります（要件 FR-J.6）。
      How many other peaks were folded into this pitch; zero means one station.
      Needed to show a crowded stretch as crowded (requirement FR-J.6). }
    Crowded: Integer;
    { 受信開始からの秒で、最初に現れた時刻と、最後に聞こえた時刻。
      Seconds since reception began: when it first appeared and when it was last
      heard. }
    FirstSeconds: Double;
    LastSeconds: Double;
    { ここまでの時刻の文字は受け取り済み、という境界。窓ごとに決まった時刻へ
      進むので、区間が重ならず、隙間も空きません。
      The boundary up to which characters have been taken. It advances to a fixed
      time each window, so the intervals neither overlap nor leave gaps. }
    AcceptedUntil: Double;
    { この局から読み取った文字。時刻は受信開始からの通算です。
      The characters read from this station, timed from the start of reception. }
    Chars: TDecodedChars;
    { いま聞こえているか。直前の窓でこの局の信号があったかどうかです。
      Whether it is audible now: whether its signal was there in the last
      window. }
    Heard: Boolean;
    { いま解析の対象になっているか（要件 FR-I.7）。

      **Heard と組にして初めて意味が決まります。**聞こえていて解析していないなら
      能力の都合で切り捨てた局、聞こえていないなら単に送信を止めた局です。
      どちらも Analysed だけを見ると同じに見えてしまい、送信を止めただけの局を
      「切り捨てた」と見せることになります。

      Whether it is being analysed (requirement FR-I.7).

      **It only means something paired with Heard.** Audible but not analysed is a
      station cut for want of capacity; not audible is a station that simply
      stopped transmitting. On Analysed alone the two look identical, and a
      station that merely stopped would be shown as one that was cut. }
    Analysed: Boolean;
    { 上限を超えて捨てた文字の数。0 でなければ、この局の受信文は途中から
      始まっています。
      How many characters were dropped at the limit; anything but zero means this
      station's transcript starts part way through. }
    DroppedChars: Int64;
  end;
  TStationLogs = array of TStationLog;

  { 帯域内の多局を同時に読む機械。

    Append は取り込みの側（主スレッド）から、Step は解析スレッドから呼ばれます。
    読み出し（Logs ほか）はどちらからでも呼べます。DeepCW.Stream と同じく、
    バッファの先頭を動かすのは Step だけと決めてあります。

    The machine that reads many stations at once.

    Append is called from the capture side, on the main thread, and Step from the
    analysis thread; the readers may be called from either. As in DeepCW.Stream,
    only Step moves the front of the buffer. }
  TMultiStationDecoder = class
  private
    FDecoder: TDeepCWDecoder;
    FTracker: TStationTracker;
    FLock: TRTLCriticalSection;

    FPending: TSingleArray;
    FPendingCount: Integer;
    FSourceRate: Integer;
    { バッファの先頭の標本が、受信開始から何秒目か。
      How many seconds into the reception the first buffered sample sits. }
    FBufferStart: Double;
    FDroppedSeconds: Double;

    FLogs: TStationLogs;
    { 解析の世代。Reset や録音周波数の変更でバッファを捨てるたびに進めます。
      窓を取り出したときの世代を覚えておき、結果を書き込む直前に照合します。
      食い違っていれば、その結果は既に無い音声のものなので丸ごと捨てます。
      **照合が無いと、受信をやり直した直後に前の受信の文字が現れます。**

      The analysis generation, advanced whenever the buffer is discarded by Reset
      or by a change of capture rate. The generation is remembered when the window
      is taken and checked again before the results are written; a mismatch means
      the result describes audio that no longer exists and it is dropped whole.
      **Without the check, text from the previous reception would appear just
      after a fresh one began.** }
    FEpoch: Int64;
    FRounds: Int64;
    { 1 局を 1 窓読むのにかかった時間の移動平均（秒）。解析する局数はここから
      決めます（要件 FR-I.7）。
      A moving average of the seconds one station takes for one window, from
      which the number of stations analysed is decided (requirement FR-I.7). }
    FCostSeconds: Double;
    FAnalysed: Integer;
    FDropped: Integer;
    FMaxStations: Integer;

    function WideRate: Integer;
    function LogIndexOf(Id: Int64): Integer;
    { 直前の回で解析していた局を前に寄せます。呼び出し側は FLock を保持し、
      記録の印がまだ前の回のものであるうちに呼んでください。
      Moves the stations analysed in the previous round towards the front. The
      caller must hold FLock and call it while the marks still hold the previous
      round's values. }
    procedure PreferAnalysed(var Items: TTrackedStations);
    procedure Prune(NowSeconds: Double);
    procedure CapBuffer;
    function BeginWindow(WholeTail: Boolean; out Audio: TSingleArray;
      out Rate: Integer; out StartSeconds: Double; out Epoch: Int64): Boolean;
    function HasSignal(const Audio: TSingleArray): Boolean;
    function ChooseLimit(Present: Integer): Integer;
    { 呼び出し側は FLock を保持していること。/ The caller must hold FLock. }
    procedure SyncLogs(const Present: TTrackedStations; Limit: Integer;
      StartSeconds: Double);
    procedure AdvanceWindow(Samples, Rate: Integer; WholeTail: Boolean;
      Epoch: Int64);
    function ReadStations(const Wide: TSpectrogram;
      const Present: TTrackedStations; Limit: Integer;
      StartSeconds, AcceptUntil, Span: Double; Epoch: Int64): Boolean;
    function Analyse(WholeTail: Boolean): Boolean;
    { 読み取った文字を、その局の受信文へ継ぎ足します。既に持っている分より後に
      始まった文字だけを受け取ります。
      Extends a station's transcript with what was read, taking only the
      characters that start after what is already held. }
    procedure Extend(Index: Integer; const Chars: TDecodedChars;
      StartSeconds, AcceptUntil: Double);
  public
    constructor Create(ADecoder: TDeepCWDecoder);
    destructor Destroy; override;

    procedure Append(const Samples: TSingleArray; SampleRate: Integer);
    { 1 窓ぶん解析します。何か読めたら True を返します。
      Analyses one window, returning True when anything was read. }
    function Step: Boolean;

    { 受信を止めるときに、窓 1 枚に満たない残りを読みます。

      Step は窓が満ちるまで解析しません。**そのままでは、受信を止めた時点で
      最後の最大 10 秒が一度も読まれずに終わります。**交信の終わりはたいてい
      そこにあります。ここでは末尾の保留も置きません。次の符号が続かないことが
      分かっているためです。

      Reads the remainder, less than a whole window, when reception stops.

      Step waits for a full window. **Left at that, the last ten seconds would
      never be read at all** — and the end of a contact is usually there. No tail
      is held back here, because it is known that no more code follows. }
    procedure Finish;
    procedure Reset;

    { 解析にかけられるだけ溜まっているか。
      Whether enough is buffered to analyse. }
    function Ready: Boolean;
    { 受信開始から受け取った音声の長さ（秒）。文字に付く時刻と同じ原点です。
      Seconds of audio received since reception began, from the same origin as
      the times carried by the characters. }
    function ElapsedSeconds: Double;
    function PendingSeconds: Double;
    function DroppedSeconds: Double;

    { 局ごとの読み取り結果。音程の昇順で返します。本文まで含みます。
      The per-station results with their text, in ascending pitch order. }
    function Logs: TStationLogs;
    { 本文を除いた一覧。バンドマップは「誰が・どこで・いつ」を出すだけなので、
      毎秒数回これを呼んでも本文を複製しません。局が 24、文字が 4000 あると、
      本文まで複製する呼び出しは 1 回あたり 10 万件の参照数え上げになります。

      The same list without the text. The band map shows who, where and when, so
      calling this several times a second copies no transcripts. With 24 stations
      of 4000 characters, a call that copied the text would mean a hundred
      thousand reference counts each time. }
    function Summaries: TStationLogs;
    { 1 局ぶんの本文。番号で指します。音程で指すと、局が動いたときに別の局の
      本文を返します。
      One station's text, addressed by number. Addressed by pitch, a station that
      had drifted would return another's. }
    function TextOf(Id: Int64): TDecodedChars;
    { 直前の窓で解析した局数と、能力を超えて切り捨てた局数（要件 FR-I.7）。
      How many stations the last window analysed, and how many were cut for want
      of capacity (requirement FR-I.7). }
    function AnalysedCount: Integer;
    function DroppedCount: Integer;
    { 1 局 1 窓あたりの実測時間（秒）。診断に出します。
      The measured seconds per station per window, for the diagnostics. }
    function CostSeconds: Double;
    function Rounds: Int64;

    { 同時に解析する局数の上限。実測した費用から決まる数と、この値の、小さい
      ほうが使われます。機器が速くても運用者が絞りたい場合と、試験のために
      絞る場合の両方に要ります（要件 FR-I.7）。

      The ceiling on how many stations are analysed at once; the smaller of this
      and the number the measured cost allows is used. It is needed both for an
      operator who wants fewer than a fast machine could manage and for holding
      the limit to a known value in a test (requirement FR-I.7). }
    property MaxStations: Integer read FMaxStations write FMaxStations;
  end;

implementation

constructor TMultiStationDecoder.Create(ADecoder: TDeepCWDecoder);
begin
  inherited Create;
  if ADecoder = nil then
    raise EDeepCW.Create('A multi-station decoder needs a decoder.');
  FDecoder := ADecoder;
  FTracker := TStationTracker.Create;
  FSourceRate := ADecoder.Metadata.SampleRate;
  FMaxStations := MULTI_MAX_STATIONS;
  InitCriticalSection(FLock);
end;

destructor TMultiStationDecoder.Destroy;
begin
  FTracker.Free;
  DoneCriticalSection(FLock);
  inherited Destroy;
end;

{ 広帯域の変換にかける周波数。モデルの 2 倍で、ビン幅もフレーム間隔も窓長も
  モデルと一致します（付録 G.1）。
  The rate the wide transform runs at: twice the model's, which matches its bin
  spacing, frame spacing and window length (appendix G.1). }
function TMultiStationDecoder.WideRate: Integer;
begin
  Result := FDecoder.Metadata.SampleRate * 2;
end;

procedure TMultiStationDecoder.Reset;
begin
  EnterCriticalSection(FLock);
  try
    FPending := nil;
    FPendingCount := 0;
    FBufferStart := 0;
    FDroppedSeconds := 0;
    FLogs := nil;
    FRounds := 0;
    Inc(FEpoch);
    FAnalysed := 0;
    FDropped := 0;
    FCostSeconds := 0;
    FTracker.Clear;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

procedure TMultiStationDecoder.Append(const Samples: TSingleArray;
  SampleRate: Integer);
var
  I, Needed: Integer;
begin
  if (Length(Samples) = 0) or (SampleRate <= 0) then
    Exit;
  EnterCriticalSection(FLock);
  try
    if (FSourceRate <> SampleRate) and (FPendingCount > 0) then
    begin
      { 録音周波数が変われば、溜めていた音声は意味を失います。捨てた分だけ
        時刻を進め、取りこぼしとして数えます。進めなければ、以後の文字の時刻が
        その秒数だけ手前へずれます。
        A change of capture rate makes the buffer meaningless. The clock advances
        by what was discarded and counts it as a loss; without that, every later
        character would be timed early by that much. }
      FBufferStart := FBufferStart + FPendingCount / Max(1, FSourceRate);
      FDroppedSeconds := FDroppedSeconds + FPendingCount / Max(1, FSourceRate);
      FPendingCount := 0;
      { 解析中のものがあれば、その結果は既に無い音声のものになります。
        Any analysis in flight now describes audio that no longer exists. }
      Inc(FEpoch);
    end;
    FSourceRate := SampleRate;

    Needed := FPendingCount + Length(Samples);
    if Needed > Length(FPending) then
      SetLength(FPending, Max(Needed, Max(4096, Length(FPending) * 2)));
    for I := 0 to High(Samples) do
      FPending[FPendingCount + I] := Samples[I];
    Inc(FPendingCount, Length(Samples));
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TMultiStationDecoder.ElapsedSeconds: Double;
begin
  EnterCriticalSection(FLock);
  try
    Result := FBufferStart + FPendingCount / Max(1, FSourceRate);
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TMultiStationDecoder.PendingSeconds: Double;
begin
  EnterCriticalSection(FLock);
  try
    Result := FPendingCount / Max(1, FSourceRate);
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TMultiStationDecoder.DroppedSeconds: Double;
begin
  EnterCriticalSection(FLock);
  try
    Result := FDroppedSeconds;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TMultiStationDecoder.Ready: Boolean;
begin
  Result := PendingSeconds >= MULTI_WINDOW_SECONDS;
end;

procedure TMultiStationDecoder.CapBuffer;
var
  Limit, Excess, I: Integer;
begin
  EnterCriticalSection(FLock);
  try
    Limit := Round(MULTI_MAX_BUFFER_SECONDS * FSourceRate);
    if FPendingCount <= Limit then
      Exit;
    Excess := FPendingCount - Limit;
    for I := 0 to Limit - 1 do
      FPending[I] := FPending[I + Excess];
    FPendingCount := Limit;
    FBufferStart := FBufferStart + Excess / FSourceRate;
    FDroppedSeconds := FDroppedSeconds + Excess / FSourceRate;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TMultiStationDecoder.LogIndexOf(Id: Int64): Integer;
var
  I: Integer;
begin
  for I := 0 to High(FLogs) do
    if FLogs[I].Id = Id then
      Exit(I);
  Result := -1;
end;

{ 古くなった記録を落とします。落とさなければ、長く受信するほど際限なく増えます。
  Drops records that have aged out; without this they grow without bound the
  longer reception runs. }
procedure TMultiStationDecoder.PreferAnalysed(var Items: TTrackedStations);
var
  Scores: array of Double;
  I, Index, Position: Integer;
  MovingScore: Double;
  Moving: TTrackedStation;
begin
  SetLength(Scores, Length(Items));
  for I := 0 to High(Items) do
  begin
    Scores[I] := Items[I].Station.LevelDb;
    Index := LogIndexOf(Items[I].Id);
    if (Index >= 0) and FLogs[Index].Analysed then
      Scores[I] := Scores[I] + MULTI_KEEP_MARGIN_DB;
  end;
  { 下駄を含めた強さの降順。数が少ないので単純な挿入で足ります。
    Descending by strength including the margin; the numbers are small enough for
    a plain insertion. }
  for I := 1 to High(Items) do
  begin
    Moving := Items[I];
    MovingScore := Scores[I];
    Position := I;
    while (Position > 0) and (Scores[Position - 1] < MovingScore) do
    begin
      Items[Position] := Items[Position - 1];
      Scores[Position] := Scores[Position - 1];
      Dec(Position);
    end;
    Items[Position] := Moving;
    Scores[Position] := MovingScore;
  end;
end;

procedure TMultiStationDecoder.Prune(NowSeconds: Double);
var
  I, Total: Integer;
begin
  Total := 0;
  for I := 0 to High(FLogs) do
    if NowSeconds - FLogs[I].LastSeconds <= MULTI_KEEP_SECONDS then
    begin
      FLogs[Total] := FLogs[I];
      Inc(Total);
    end;
  SetLength(FLogs, Total);
end;

procedure TMultiStationDecoder.Extend(Index: Integer; const Chars: TDecodedChars;
  StartSeconds, AcceptUntil: Double);
var
  I, Total, Held: Integer;
  Taken, At_, Begins, Ends: Double;
  LastText: string;
  Fresh: TDecodedChars;
begin
  { 受け取りの境界は、**窓ごとに決まる時刻**です。最後に取った文字の終わりでは
    ありません。文字に幅が無いため、後者では同じ文字の二度読みを止められません。
    The boundary is **a time fixed by the window**, not the end of the last
    character taken: characters have no width, so the latter cannot stop the same
    character being read twice. }
  Taken := FLogs[Index].AcceptedUntil;
  LastText := '';
  At_ := -1;
  if Length(FLogs[Index].Chars) > 0 then
  begin
    LastText := FLogs[Index].Chars[High(FLogs[Index].Chars)].Text;
    At_ := FLogs[Index].Chars[High(FLogs[Index].Chars)].Seconds;
  end;

  Total := 0;
  SetLength(Fresh, Length(Chars));
  for I := 0 to High(Chars) do
  begin
    Begins := StartSeconds + Chars[I].Seconds;
    Ends := StartSeconds + Chars[I].EndSeconds;
    { 窓の末尾は受け取りません。次の符号が続くかどうかがまだ分からないためです。
      重なりのほうが長いので、ここで見送った文字は次の窓で拾われます。
      The end of the window is not taken: whether more code follows is not yet
      known. The overlap is longer, so a character passed over here is picked up
      in the next window. }
    if Begins > AcceptUntil then
      Break;
    { 既に取った区間のものは受け取りません。
      Nothing from the stretch already taken. }
    if Begins <= Taken then
      Continue;
    { 境界のすぐ両側に、同じ文字が二度出ることがあります。文字に幅が無いので、
      時刻の比較だけでは止まりません。直前に取った文字と同じ字で、ごく近い
      時刻にあれば、同じ 1 文字を二度読んだものと見なします。
      The same character can come out on either side of the boundary, and with no
      width to compare, times alone do not stop it. A character matching the one
      just taken, at very nearly the same time, is taken to be that same
      character read twice. }
    if (Begins - At_ < MULTI_SAME_CHAR_SECONDS) and (Chars[I].Text = LastText) then
      Continue;
    Fresh[Total] := Chars[I];
    Fresh[Total].Seconds := Begins;
    Fresh[Total].EndSeconds := Ends;
    LastText := Chars[I].Text;
    At_ := Begins;
    Inc(Total);
  end;

  { 境界は、文字が取れたかどうかに関わらず進めます。無音の窓で据え置くと、
    次の窓が同じ区間をもう一度受け取れてしまいます。
    The boundary advances whether or not anything was taken; left behind on a
    silent window, the next window could take the same stretch again. }
  FLogs[Index].AcceptedUntil := AcceptUntil;
  if Total = 0 then
    Exit;

  SetLength(Fresh, Total);
  Held := Length(FLogs[Index].Chars);
  SetLength(FLogs[Index].Chars, Held + Total);
  for I := 0 to High(Fresh) do
    FLogs[Index].Chars[Held + I] := Fresh[I];

  { 上限を超えたら古いほうから落とし、落とした数を数えます。数えておかないと、
    受信文が途中から始まっていることを画面で言えません（第 10 章 10.9）。
    Past the limit the oldest go, and how many is counted: without the count the
    display could not say that a transcript starts part way through (chapter 10,
    rule 10.9). }
  Held := Length(FLogs[Index].Chars);
  if Held > MULTI_MAX_CHARS then
  begin
    Total := Held - MULTI_MAX_CHARS;
    for I := 0 to MULTI_MAX_CHARS - 1 do
      FLogs[Index].Chars[I] := FLogs[Index].Chars[I + Total];
    SetLength(FLogs[Index].Chars, MULTI_MAX_CHARS);
    Inc(FLogs[Index].DroppedChars, Total);
  end;
end;

{ 音程の昇順に並べ替えます。運用者が見るのは周波数の並びです。
  Sorts into ascending pitch: an order of frequency is what the operator reads. }
procedure SortByPitch(var Items: TStationLogs);
var
  I, Position: Integer;
  Moving: TStationLog;
begin
  for I := 1 to High(Items) do
  begin
    Moving := Items[I];
    Position := I;
    while (Position > 0) and (Items[Position - 1].Hz > Moving.Hz) do
    begin
      Items[Position] := Items[Position - 1];
      Dec(Position);
    end;
    Items[Position] := Moving;
  end;
end;

function TMultiStationDecoder.Summaries: TStationLogs;
var
  I: Integer;
begin
  EnterCriticalSection(FLock);
  try
    SetLength(Result, Length(FLogs));
    for I := 0 to High(FLogs) do
    begin
      Result[I] := FLogs[I];
      Result[I].Chars := nil;
    end;
  finally
    LeaveCriticalSection(FLock);
  end;
  SortByPitch(Result);
end;

function TMultiStationDecoder.TextOf(Id: Int64): TDecodedChars;
var
  Index: Integer;
begin
  Result := nil;
  EnterCriticalSection(FLock);
  try
    Index := LogIndexOf(Id);
    if Index >= 0 then
      Result := Copy(FLogs[Index].Chars, 0, Length(FLogs[Index].Chars));
  finally
    LeaveCriticalSection(FLock);
  end;
end;

{ 窓 1 枚ぶん、あるいは残り全部を解析する共通の処理です。Step と Finish の
  違いは、窓が満ちるのを待つかどうかと、末尾を保留するかどうかだけなので、
  中身を 2 つ持つと必ず片方だけ直す日が来ます。

  The work of analysing one window, or all that is left. Step and Finish differ
  only in whether they wait for a full window and whether they hold back the
  tail, so two copies of the body would one day be fixed in only one of them. }
{ 窓の音声を取り出します。取り出せたら True。同時に、そのときの録音周波数・
  先頭の時刻・世代も返します。3 つを別々に読むと、その隙間に変わり得ます。

  Takes the window's audio, returning True when there was enough, along with the
  capture rate, the time of its first sample and the generation. Reading them
  separately would leave a gap in which they could change. }
function TMultiStationDecoder.BeginWindow(WholeTail: Boolean;
  out Audio: TSingleArray; out Rate: Integer; out StartSeconds: Double;
  out Epoch: Int64): Boolean;
var
  Wanted: Integer;
begin
  EnterCriticalSection(FLock);
  try
    Rate := Max(1, FSourceRate);
    StartSeconds := FBufferStart;
    Epoch := FEpoch;
    if WholeTail then
      Wanted := FPendingCount
    else
      Wanted := Round(MULTI_WINDOW_SECONDS * Rate);
    Result := (Wanted <= FPendingCount) and
              (Wanted >= Round(MULTI_MIN_WINDOW_SECONDS * Rate));
    if Result then
      Audio := Copy(FPending, 0, Wanted)
    else
      Audio := nil;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

{ 解析にかけるだけの音量があるか。無ければ、文字も湧かず、時間も使いません。
  Whether there is enough level to analyse; without it no characters appear out
  of nowhere and no time is spent. }
function TMultiStationDecoder.HasSignal(const Audio: TSingleArray): Boolean;
var
  I: Integer;
  Peak: Double;
begin
  Peak := 0;
  for I := 0 to High(Audio) do
    Peak := Max(Peak, Abs(Audio[I]));
  Result := Peak >= STREAM_SQUELCH_LEVEL;
end;

{ 何局まで解析できるかを、実測した費用から決めます。見積もりではなく、直前までに
  実際にかかった時間を使います（要件 FR-I.7）。
  How many stations can be analysed, decided from the measured cost — what it
  actually took up to now, not an estimate (requirement FR-I.7). }
function TMultiStationDecoder.ChooseLimit(Present: Integer): Integer;
begin
  if FCostSeconds > 0 then
    Result := Trunc(MULTI_ADVANCE_SECONDS * MULTI_TIME_BUDGET / FCostSeconds)
  else
    Result := FMaxStations;
  Result := EnsureRange(Result, 1, Max(1, FMaxStations));
  if Result > Present then
    Result := Present;
end;

{ 記録の側を、いま聞こえている局に合わせます。切り捨てた局も記録には残し、
  「いま解析していない」と印を付けます。**黙って消えると、運用者には局が消えたのか
  切り捨てられたのか分かりません**（要件 FR-I.7）。

  Brings the records in line with the stations now audible. A station cut from the
  analysis stays in the records, marked as not being analysed: **vanishing
  silently would leave the operator unable to tell a station that stopped from one
  that was cut** (requirement FR-I.7). }
procedure TMultiStationDecoder.SyncLogs(const Present: TTrackedStations;
  Limit: Integer; StartSeconds: Double);
var
  I, Index: Integer;
begin
  for I := 0 to High(FLogs) do
  begin
    FLogs[I].Heard := False;
    FLogs[I].Analysed := False;
  end;
  for I := 0 to High(Present) do
  begin
    Index := LogIndexOf(Present[I].Id);
    if Index < 0 then
    begin
      Index := Length(FLogs);
      SetLength(FLogs, Index + 1);
      FLogs[Index].Id := Present[I].Id;
      FLogs[Index].FirstSeconds := Present[I].FirstSeconds;
      FLogs[Index].Chars := nil;
      FLogs[Index].DroppedChars := 0;
      { 初めて見る局は、この窓の頭から受け取ります。
        A station seen for the first time is taken from the head of this
        window. }
      FLogs[Index].AcceptedUntil := StartSeconds - 1;
    end;
    FLogs[Index].Hz := Present[I].Station.Hz;
    FLogs[Index].LevelDb := Present[I].Station.LevelDb;
    FLogs[Index].HalfWidthHz := Present[I].Station.HalfWidthHz;
    FLogs[Index].Crowded := Present[I].Station.Crowded;
    FLogs[Index].LastSeconds := Present[I].LastSeconds;
    FLogs[Index].Heard := True;
    FLogs[Index].Analysed := I < Limit;
  end;
  FAnalysed := Limit;
  FDropped := Length(Present) - Limit;
end;

{ 窓を進めます。標本の整数で進めるので、時刻が実際の音からずれません。
  The window steps on by a whole number of samples, so the clock cannot drift from
  the audio. }
procedure TMultiStationDecoder.AdvanceWindow(Samples, Rate: Integer;
  WholeTail: Boolean; Epoch: Int64);
var
  Advance, I: Integer;
begin
  if WholeTail then
    Advance := Samples
  else
    Advance := Round(MULTI_ADVANCE_SECONDS * Rate);
  EnterCriticalSection(FLock);
  try
    { 世代が変わっていれば、バッファは既に別のものです。進めてはいけません。
      A changed generation means the buffer is already a different one and must
      not be stepped on. }
    if FEpoch <> Epoch then
      Exit;
    if Advance > FPendingCount then
      Advance := FPendingCount;
    for I := 0 to FPendingCount - Advance - 1 do
      FPending[I] := FPending[I + Advance];
    Dec(FPendingCount, Advance);
    FBufferStart := FBufferStart + Advance / Rate;
    Inc(FRounds);
    Prune(FBufferStart);
  finally
    LeaveCriticalSection(FLock);
  end;
end;

{ 選ばれた局を順に読み、それぞれの受信文へ継ぎ足します。
  Reads the chosen stations in turn and extends each transcript. }
function TMultiStationDecoder.ReadStations(const Wide: TSpectrogram;
  const Present: TTrackedStations; Limit: Integer;
  StartSeconds, AcceptUntil, Span: Double; Epoch: Int64): Boolean;
var
  Slice: TSpectrogram;
  Chars: TDecodedChars;
  I, Index, Bins: Integer;
  Elapsed: Double;
  Begun: TDateTime;
begin
  Result := False;
  Bins := (Wide.Bins - 1) * 2;
  for I := 0 to Limit - 1 do
  begin
    Begun := Now;
    Slice := SliceSpectrogram(Wide,
      WideBinFor(Present[I].Station.Hz, WideRate, Bins), FDecoder.Metadata);
    MaskSpectrogram(Slice, Present[I].Station.HalfWidthHz, FDecoder.Metadata);
    Chars := FDecoder.DecodeSpectrogramTimed(Slice, Span);
    Elapsed := (Now - Begun) * SecsPerDay;

    EnterCriticalSection(FLock);
    try
      if FEpoch <> Epoch then
        Exit;
      Index := LogIndexOf(Present[I].Id);
      if Index >= 0 then
        Extend(Index, Chars, StartSeconds, AcceptUntil);
      { 費用は指数移動平均で追います。1 回の外れ値で局数が跳ねないためです。
        The cost is followed as an exponential moving average, so that one outlier
        does not make the number of stations jump. }
      if FCostSeconds <= 0 then
        FCostSeconds := Elapsed
      else
        FCostSeconds := FCostSeconds * 0.8 + Elapsed * 0.2;
    finally
      LeaveCriticalSection(FLock);
    end;
    Result := True;
  end;
end;

{ 窓 1 枚ぶん、あるいは残り全部を解析します。Step と Finish の違いは、窓が満ちるのを
  待つかどうかと、末尾を保留するかどうかだけなので、中身は 1 つにしてあります。

  Analyses one window, or all that is left. Step and Finish differ only in whether
  they wait for a full window and whether they hold back the tail, so there is one
  body rather than two. }
function TMultiStationDecoder.Analyse(WholeTail: Boolean): Boolean;
var
  Audio, Prepared: TSingleArray;
  Wide: TSpectrogram;
  Found: TStations;
  Present: TTrackedStations;
  Rate, Limit: Integer;
  StartSeconds, AcceptUntil, Span: Double;
  Epoch: Int64;
begin
  Result := False;
  CapBuffer;
  if not BeginWindow(WholeTail, Audio, Rate, StartSeconds, Epoch) then
    Exit;

  Span := Length(Audio) / Rate;
  if WholeTail then
    { 残りを読むときは末尾を保留しません。続きが来ないと分かっています。
      Reading the remainder holds nothing back: no more is coming. }
    AcceptUntil := StartSeconds + Span
  else
    AcceptUntil := StartSeconds + Span - MULTI_TAIL_GUARD_SECONDS;

  if HasSignal(Audio) then
  begin
    { 変換は 1 回だけ。ここから先は、局ごとにビンを切り出すだけです
      （要件 FR-I.1）。
      The transform runs once; from here on it is only a matter of cutting bins
      out per station (requirement FR-I.1). }
    Prepared := ResampleBandLimited(Audio, Rate, WideRate);
    Wide := ComputeWideSpectrogram(Prepared, WideRate, FDecoder.Metadata);
    Found := DetectStations(Wide, WideRate);

    EnterCriticalSection(FLock);
    try
      { 取り出してから変換と検出を終えるまでに、バッファが捨てられていないか
        確かめます。捨てられていれば、この結果は既に無い音声のものです。
        Check that the buffer was not discarded between taking the window and
        finishing the transform; if it was, this describes audio that no longer
        exists. }
      if FEpoch <> Epoch then
        Exit;
      FTracker.Update(Found, StartSeconds + Span);
      Present := FTracker.Loudest;
      { いま解析している局に下駄を履かせて並べ直します。**記録の印を消す前に**
        行わなければなりません。印はこの直後に上書きされます。
        Re-order with the margin for stations already being analysed. It has to
        happen **before the marks are cleared**, since they are overwritten
        immediately below. }
      PreferAnalysed(Present);
      Limit := ChooseLimit(Length(Present));
      SyncLogs(Present, Limit, StartSeconds);
    finally
      LeaveCriticalSection(FLock);
    end;

    Result := ReadStations(Wide, Present, Limit, StartSeconds, AcceptUntil,
      Span, Epoch);
  end;

  AdvanceWindow(Length(Audio), Rate, WholeTail, Epoch);
end;

function TMultiStationDecoder.Step: Boolean;
begin
  Result := Analyse(False);
end;

procedure TMultiStationDecoder.Finish;
begin
  Analyse(True);
end;

function TMultiStationDecoder.Logs: TStationLogs;
var
  I: Integer;
begin
  EnterCriticalSection(FLock);
  try
    SetLength(Result, Length(FLogs));
    for I := 0 to High(FLogs) do
    begin
      Result[I] := FLogs[I];
      Result[I].Chars := Copy(FLogs[I].Chars, 0, Length(FLogs[I].Chars));
    end;
  finally
    LeaveCriticalSection(FLock);
  end;
  SortByPitch(Result);
end;

function TMultiStationDecoder.AnalysedCount: Integer;
begin
  EnterCriticalSection(FLock);
  try
    Result := FAnalysed;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TMultiStationDecoder.DroppedCount: Integer;
begin
  EnterCriticalSection(FLock);
  try
    Result := FDropped;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TMultiStationDecoder.CostSeconds: Double;
begin
  EnterCriticalSection(FLock);
  try
    Result := FCostSeconds;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TMultiStationDecoder.Rounds: Int64;
begin
  EnterCriticalSection(FLock);
  try
    Result := FRounds;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

end.
