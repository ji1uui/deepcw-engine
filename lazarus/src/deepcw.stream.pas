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
  SysUtils, Classes, Math, DeepCW.Types, DeepCW.Decoder, DeepCW.Tuner;

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

  { 溜めておく音声の上限。解析にかける長さの倍を持ちます。

    **これを超えた分は捨てます。**入ってくる速さが解析の速さを上回ることは
    起こりうる（遅い機械、実時間より速く音を返す装置、信号の無い周波数で
    文字が 1 つも出ない状態）。上限が無ければ、その間ずっとバッファが伸び続け、
    いずれメモリを使い尽くす。**追いつけないときに正しい振る舞いは、古い音を
    捨てて、捨てたことを伝えることである**（要件 NFR-4）。

    The most audio held. Twice what is ever analysed at once.

    **Anything beyond this is discarded.** Audio can arrive faster than it can
    be analysed — a slow machine, a device that returns audio faster than real
    time, or an empty frequency where not a single character is produced. With
    no limit the buffer simply grows until memory runs out. **The right
    behaviour when falling behind is to drop the oldest audio and say so**
    (requirement NFR-4). }
  STREAM_MAX_BUFFER_SECONDS = STREAM_MAX_SECONDS * 2;
  { これだけ溜まるまでは解析しません。/ No analysis until this much is buffered. }
  STREAM_MIN_PENDING_SECONDS = 2.0;
  { 解析の先頭でこの時間内に現れた文字は捨てます。

    確定点は語間の中央に取るため、次の解析は必ず無音から始まります。その境目を
    モデルが短点と読むことがあり、細かく投入するほど、訂正される前に確定して
    しまいます。窓分割の復号が端の誤りを捨てているのと同じ理屈です
    （DEEPCW_EDGE_GUARD_SECONDS）。40 WPM でも語間の半分は 105 ms あるため、
    この長さで本物の文字を巻き込むことはありません。

    Characters emitted within this much of the analysis start are discarded.
    A split falls in the middle of a word gap, so every later analysis begins
    in silence; the model sometimes reads that boundary as a dit, and with fine
    chunks it can be confirmed before more context corrects it. This mirrors
    the edge guard the windowed decode already applies. Even at 40 WPM half a
    word gap is 105 ms, so this never swallows a real character. }
  STREAM_LEAD_GUARD_SECONDS = 0.08;

  { これを下回る振幅しか無い区間は、解析にかけません。

    無音に近い入力でもモデルは何かしらの文字を出します（実測では ',' が続けて
    出ました）。信号が来ていないときに文字が湧くと、受信できているのかどうかが
    利用者に分からなくなります。約 -46 dBFS で、静かなライン入力の暗騒音よりは
    上、耳に聞こえる信号よりは下に取っています。画面の「無音です」の表示も同じ
    値を使います（要件 FR-A.3）。

    A stretch quieter than this is not analysed at all.

    The model emits something even for near-silence; in measurement it produced
    a run of commas. Characters appearing when no signal is present leaves the
    operator unable to tell whether anything is being copied. About -46 dBFS,
    above the noise of a quiet line input and below anything audible. The
    "silent" display on screen uses the same value (requirement FR-A.3). }
  STREAM_SQUELCH_LEVEL = 0.005;

type
  TStreamingDecoder = class
  private
    FDecoder: TDeepCWDecoder;
    FLock: TRTLCriticalSection;
    { 未確定の音声。先頭は直前の確定点です。**録音されたままの周波数で**保持し、
      帯域制限と周波数変換は解析の直前にまとめて行います。細切れに掛けると
      継ぎ目ごとに過渡が出るためです。

      Audio not yet committed, starting at the last split point. It is kept at
      the **capture rate**; band limiting and rate conversion happen in one go
      just before analysis, because filtering chunk by chunk leaves a transient
      at every seam. }
    FPending: TSingleArray;
    FPendingCount: Integer;
    FSourceRate: Integer;
    FAntiAlias: Boolean;
    { 同調している音程（録音された音声の中での Hz）。0 なら同調していません。
      同調していないあいだは周波数変換も帯域制限も掛けず、これまでと同じ経路を
      通ります（要件 FR-D.1）。

      The pitch being tuned, in hertz within the captured audio; 0 means no
      tuning. While it is 0 neither the translation nor the band-pass runs and
      the path is exactly what it was before (requirement FR-D.1). }
    FTuneHz: Double;
    FBandwidth: TTunerBandwidth;
    FConfirmed: TDecodedChars;
    FProvisional: TDecodedChars;
    FConfirmedSeconds: Double;
    { 取りこぼしは「秒」で数えます。録音周波数が途中で変わっても数え直しに
      ならないためです。
      Loss is counted in seconds, so that a change of capture rate part way
      through does not reinterpret what was already counted. }
    FDroppedSeconds: Double;
    { 解析の世代。Reset や録音周波数の変更でバッファを捨てるたびに進めます。
      解析スレッドは取り出したときの世代を覚えておき、確定させる直前に照合
      します。食い違っていれば、その解析結果は既に無い音声のものなので、
      丸ごと捨てます（付録 K）。
      The analysis generation, advanced whenever the buffer is discarded by
      Reset or by a change of capture rate. The analysis thread remembers the
      generation it read and checks it again just before committing; if they
      differ the result describes audio that no longer exists and is dropped
      whole (appendix K). }
    FEpoch: Int64;
    FTailGuard: Double;
    FMinConfirmed: Double;
    FSquelch: Double;
    procedure SetTuneHz(Value: Double);
    procedure SetBandwidth(Value: TTunerBandwidth);
    { 解析にかける音声・その録音周波数・世代を、ひと繋がりの排他区間で取り出
      します。3 つを別々に読むと、その隙間に録音周波数が変わり得ます。
      Read the audio to analyse, its capture rate and the generation inside a
      single locked section; reading them separately leaves a gap in which the
      capture rate could change. }
    procedure BeginAnalysis(out Audio: TSingleArray; out Rate: Integer;
      out Epoch: Int64);
    function StillCurrent(Epoch: Int64): Boolean;
    { 解析にかける形へ整えます。同調・帯域制限・標本化周波数の変換を、途切れの
      ない 1 本の音声に対してまとめて行います。
      Prepares audio for analysis: tuning, band limiting and rate conversion,
      all applied to one unbroken buffer. }
    function PrepareForModel(const Source: TSingleArray): TSingleArray;
    procedure AppendConfirmed(const Chars: TDecodedChars);
    function StripSeamSpace(const Chars: TDecodedChars): TDecodedChars;
    function DropLeadArtifacts(const Chars: TDecodedChars): TDecodedChars;
    procedure SetProvisional(const Chars: TDecodedChars);
    procedure DropLeading(Samples: Integer);
    { 溜め込みの上限を掛けます。Step の先頭から、すなわち解析スレッドから
      呼びます。入力が解析に追いつかないとき、古いほうから捨てて上限に収めます。
      Applies the buffer cap. Called at the start of Step, i.e. from the
      analysis thread. When input outruns analysis, the oldest is discarded to
      stay within the limit. }
    procedure CapBuffer;
    { 解析にかけるだけの音量があるか。無ければ、溜めた分を捨てて時刻を進めます。
      Whether there is enough level to analyse; if not, the buffer is dropped
      and the time base advanced past it. }
    function SquelchClosed(const Audio: TSingleArray; Rate: Integer): Boolean;
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

    { 追いつけずに捨てた音声の長さ（秒）。0 でなければ、解析が入力に
      追いついていません。診断に出します。
      Seconds of audio dropped through falling behind; anything but zero means
      analysis is not keeping up. Shown in the diagnostics. }
    function DroppedSeconds: Double;

    { 受信を始めてから今までに受け取った音声の長さ（秒）。文字に付く時刻と
      同じ原点で数えます。捨てた音声もここには含まれます。捨てた分だけ時刻を
      進めているためで、そうしないと聴き直しの位置が受信文とずれます
      （要件 FR-E.10）。

      Seconds of audio received since reception began, counted from the same
      origin as the times carried by the characters. Audio that was discarded
      still counts, because the time base was advanced past it; otherwise the
      point a replay starts from would not match the transcript
      (requirement FR-E.10). }
    function ElapsedSeconds: Double;

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

    { 録音された周波数がモデルより十分高いとき、折り返しを防ぐ帯域制限を
      掛けるか。既定で有効です。
      Whether to band limit before resampling when the capture rate runs well
      above the model's. On by default. }
    property AntiAlias: Boolean read FAntiAlias write FAntiAlias;

    { 同調する音程。0 なら同調しません。設定すると、その音程をモデルが最も
      よく読む音程へ寄せてから解析します。
      The pitch to tune, or 0 for none. When set, that pitch is translated to
      the one the model reads best before analysis. }
    property TuneHz: Double read FTuneHz write SetTuneHz;
    { 同調しているときに掛ける帯域幅。既定は自動です。
      Bandwidth applied while tuned; automatic by default. }
    property Bandwidth: TTunerBandwidth read FBandwidth write SetBandwidth;

    { これを下回る振幅の区間は解析しません。0 にすると常に解析します。
      Stretches quieter than this are not analysed; 0 analyses everything. }
    property SquelchLevel: Double read FSquelch write FSquelch;

    { 末尾を確定させずに残す時間。長いほど確定は遅れますが確かになります。
      Seconds left uncommitted at the tail; longer is slower but safer. }
    property TailGuardSeconds: Double read FTailGuard write FTailGuard;
    { 先頭からこの時間より短い範囲は確定させません。
      Nothing shorter than this from the start is committed. }
    property MinConfirmedSeconds: Double read FMinConfirmed write FMinConfirmed;

    property Decoder: TDeepCWDecoder read FDecoder;
  end;

implementation

constructor TStreamingDecoder.Create(ADecoder: TDeepCWDecoder);
begin
  inherited Create;
  if ADecoder = nil then
    raise EDeepCW.Create('The streaming decoder needs a decoder.');
  FDecoder := ADecoder;
  FAntiAlias := True;
  FTuneHz := 0;
  FBandwidth := tbAuto;
  FTailGuard := STREAM_TAIL_GUARD_SECONDS;
  FMinConfirmed := STREAM_MIN_CONFIRMED_SECONDS;
  FSquelch := STREAM_SQUELCH_LEVEL;
  FSourceRate := ADecoder.Metadata.SampleRate;
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
    FDroppedSeconds := 0;
    Inc(FEpoch);
  finally
    LeaveCriticalSection(FLock);
  end;
end;

procedure TStreamingDecoder.Append(const Samples: TSingleArray; SampleRate: Integer);
var
  I, Needed: Integer;
begin
  if (Length(Samples) = 0) or (SampleRate <= 0) then
    Exit;
  EnterCriticalSection(FLock);
  try
    { 途中で録音周波数が変わったら、溜めていた音声は意味を失います。
      A change of capture rate invalidates what is buffered. }
    if (FSourceRate <> SampleRate) and (FPendingCount > 0) then
    begin
      { 捨てた分だけ時刻を進め、取りこぼしとして数えます。ここを飛ばすと、
        以後の文字の時刻が捨てた秒数だけ前へずれ、受信文から音声へ戻れなく
        なります（要件 FR-E.10）。長さは**変更前の**周波数で秒に直します。
        Advance the time base by what was discarded and count it as a loss.
        Skipping this would shift every later character earlier by the discarded
        duration, and the transcript could no longer point back at the audio
        (requirement FR-E.10). The duration is computed at the **previous**
        rate. }
      FConfirmedSeconds := FConfirmedSeconds + FPendingCount / Max(1, FSourceRate);
      FDroppedSeconds := FDroppedSeconds + FPendingCount / Max(1, FSourceRate);
      FPendingCount := 0;
      FProvisional := nil;
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

    { **ここでは捨てません。**溜め込みの上限は Step（別スレッド）の先頭で掛けます。
      Append は主スレッドから、Step は解析スレッドから呼ばれます。両方が
      バッファの先頭を動かすと、解析中に先頭がずれて時刻と取りこぼしの帳簿が
      狂います。先頭を動かすのは解析スレッドだけ、と決めることで競合を断ちます
      （付録 K）。

      **Nothing is discarded here.** The buffer cap is applied at the start of
      Step, which runs on the analysis thread; Append runs on the main thread.
      If both moved the front, a front shift during analysis would desync the
      timing and the dropped-audio accounting. Making the analysis thread the
      only mutator of the front removes the race (appendix K). }
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TStreamingDecoder.ElapsedSeconds: Double;
begin
  EnterCriticalSection(FLock);
  try
    Result := FConfirmedSeconds + FPendingCount / Max(1, FSourceRate);
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TStreamingDecoder.DroppedSeconds: Double;
begin
  EnterCriticalSection(FLock);
  try
    Result := FDroppedSeconds;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TStreamingDecoder.PrepareForModel(const Source: TSingleArray): TSingleArray;
var
  Tune: Double;
  Width: TTunerBandwidth;
  Limit: Boolean;
  Rate: Integer;
begin
  { 同調の設定は画面側の操作で変わります。解析の途中で変わっても 1 回の解析が
    ちぐはぐにならないよう、始めに写し取ります。

    The tuning settings change from the UI. Copy them once at the start so a
    change part way through cannot leave a single analysis inconsistent. }
  EnterCriticalSection(FLock);
  try
    Tune := FTuneHz;
    Width := FBandwidth;
    Limit := FAntiAlias;
    Rate := FSourceRate;
  finally
    LeaveCriticalSection(FLock);
  end;
  { 整形そのものは DeepCW.Tuner が持ちます。ファイルからの復号と同じ 1 か所を
    通すためです。
    The preparation itself lives in DeepCW.Tuner, so that file decoding goes
    through exactly the same place. }
  Result := DeepCW.Tuner.PrepareForModel(Source, Rate,
    FDecoder.Metadata.SampleRate, Tune, Width, Limit);
end;

procedure TStreamingDecoder.SetTuneHz(Value: Double);
begin
  EnterCriticalSection(FLock);
  try
    if Value > 0 then
      FTuneHz := QuantizeTone(Value)
    else
      FTuneHz := 0;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

procedure TStreamingDecoder.SetBandwidth(Value: TTunerBandwidth);
begin
  EnterCriticalSection(FLock);
  try
    FBandwidth := Value;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

procedure TStreamingDecoder.BeginAnalysis(out Audio: TSingleArray;
  out Rate: Integer; out Epoch: Int64);
var
  Wanted: Integer;
begin
  EnterCriticalSection(FLock);
  try
    Rate := Max(1, FSourceRate);
    Epoch := FEpoch;
    Wanted := Min(FPendingCount, Round(STREAM_MAX_SECONDS * Rate));
    Audio := Copy(FPending, 0, Wanted);
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TStreamingDecoder.StillCurrent(Epoch: Int64): Boolean;
begin
  EnterCriticalSection(FLock);
  try
    Result := FEpoch = Epoch;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

procedure TStreamingDecoder.CapBuffer;
var
  Limit, Excess, I: Integer;
begin
  EnterCriticalSection(FLock);
  try
    Limit := Round(STREAM_MAX_BUFFER_SECONDS * FSourceRate);
    if FPendingCount > Limit then
    begin
      Excess := FPendingCount - Limit;
      for I := 0 to Limit - 1 do
        FPending[I] := FPending[I + Excess];
      FPendingCount := Limit;
      { 捨てた分だけ時刻を進め、取りこぼしとして数えます。先頭を動かすのは
        この解析スレッドだけなので、以後の DropLeading と食い違いません。
        Advance the time base by what went and count it as a genuine loss.
        Only this analysis thread moves the front, so it cannot desync with
        the DropLeading that follows in the same Step. }
      FConfirmedSeconds := FConfirmedSeconds + Excess / FSourceRate;
      FDroppedSeconds := FDroppedSeconds + Excess / FSourceRate;
      FProvisional := nil;
    end;
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
    { ここでは捨てた量を数えません。DropLeading は確定した音声・無音・受信終了の
      後始末として日常的に呼ばれます。これを「取りこぼし」に数えると、正常な
      受信でも確定した長さぶんだけ「追いつけずに捨てた」と申告してしまいます。
      取りこぼしとして数えるのは、入力が解析に追いつかずに Append の上限で
      あふれた分だけです（要件 NFR-4.6）。

      Dropped audio is not counted here. DropLeading is called routinely to
      tidy up after confirmed audio, silence and end of reception; counting it
      would make a normal reception report the whole confirmed length as
      "dropped through falling behind". Only the overflow at Append's cap,
      where input outran analysis, is a genuine loss (requirement NFR-4.6). }
  finally
    LeaveCriticalSection(FLock);
  end;
end;

{ 末尾のガードぶんだけ残して捨てます。全部捨てると、無音の直後に始まった符号の
  頭が切れてしまいます。

  All but the tail guard is dropped; dropping everything would clip the start
  of code that begins right after the silence. }
function TStreamingDecoder.SquelchClosed(const Audio: TSingleArray;
  Rate: Integer): Boolean;
var
  I, Keep, Drop: Integer;
  Peak: Double;
begin
  Result := False;
  if FSquelch <= 0 then
    Exit;
  Peak := 0;
  for I := 0 to High(Audio) do
    Peak := Max(Peak, Abs(Audio[I]));
  if Peak >= FSquelch then
    Exit;

  Result := True;
  Keep := Round(FTailGuard * Rate);
  Drop := Length(Audio) - Keep;
  if Drop <= 0 then
    Exit;
  EnterCriticalSection(FLock);
  try
    FProvisional := nil;
    { 捨てた分だけ時刻を進めます。進めないと、以後の文字の時刻が無音の長さ
      だけ手前にずれます。
      Advance the time base by what was dropped; without this every later
      character would be timed early by the length of the silence. }
    FConfirmedSeconds := FConfirmedSeconds + Drop / Rate;
  finally
    LeaveCriticalSection(FLock);
  end;
  DropLeading(Drop);
end;

function TStreamingDecoder.Ready: Boolean;
begin
  Result := PendingSeconds >= STREAM_MIN_PENDING_SECONDS;
end;

function TStreamingDecoder.PendingSeconds: Double;
begin
  EnterCriticalSection(FLock);
  try
    Result := FPendingCount / FSourceRate;
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

{ 解析の先頭に現れた偽の文字を落とします。空白はここでは触れず、継ぎ目の処理に
  任せます。最初の解析には確定点がないので、そのまま通します。

  Drops spurious characters at the head of an analysis. Spaces are left to the
  seam handling, and the very first analysis has no split before it, so it
  passes through untouched. }
function TStreamingDecoder.DropLeadArtifacts(const Chars: TDecodedChars): TDecodedChars;
var
  I, Count: Integer;
begin
  if FConfirmedSeconds <= 0 then
    Exit(Chars);
  SetLength(Result, Length(Chars));
  Count := 0;
  for I := 0 to High(Chars) do
    if (Chars[I].Text = ' ') or (Chars[I].EndSeconds >= STREAM_LEAD_GUARD_SECONDS) then
    begin
      Result[Count] := Chars[I];
      Inc(Count);
    end;
  SetLength(Result, Count);
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
    Latest := AnalysisSeconds - FTailGuard;

  for I := High(Chars) downto 0 do
  begin
    if Chars[I].Text <> ' ' then
      Continue;
    Middle := (Chars[I].Seconds + Chars[I].EndSeconds) / 2;
    if (Middle >= FMinConfirmed) and (Middle <= Latest) then
    begin
      Result := I;
      SplitSeconds := Middle;
      Exit;
    end;
  end;
end;

function TStreamingDecoder.Step: Boolean;
var
  Audio, Prepared: TSingleArray;
  Chars, Committed: TDecodedChars;
  Rate, SplitIndex, I, Count: Integer;
  AnalysisSeconds, SplitSeconds: Double;
  Forced: Boolean;
  Epoch: Int64;
begin
  Result := False;
  { まず溜め込みの上限を掛けます。入力が解析に追いつかないときは、ここで古い
    ほうから捨てて上限に収めます。先頭を動かすのは Step だけなので、以後の
    処理と帳簿が食い違いません（付録 K）。
    Apply the buffer cap first: when input outruns analysis, the oldest audio
    is discarded here. Only Step moves the front, so nothing downstream
    desyncs (appendix K). }
  CapBuffer;

  { 時間の計算はすべて録音された周波数で行い、モデルへ渡す直前にだけ変換します。
    All timing is computed at the capture rate; conversion happens only just
    before the audio reaches the model. }
  BeginAnalysis(Audio, Rate, Epoch);
  if Length(Audio) = 0 then
    Exit;

  AnalysisSeconds := Length(Audio) / Rate;
  if AnalysisSeconds < STREAM_MIN_PENDING_SECONDS then
    Exit;

  { 信号が来ていない間は解析しません。文字が湧かず、CPU も使いません。
    Nothing is analysed while no signal is present: no characters appear out
    of nowhere, and no processor time is spent. }
  if SquelchClosed(Audio, Rate) then
    Exit;

  Prepared := PrepareForModel(Audio);
  if Length(Prepared) = 0 then
    Exit;
  Chars := DropLeadArtifacts(
    FDecoder.DecodeLongSamplesTimed(Prepared, FDecoder.Metadata.SampleRate));

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
      SplitSeconds := AnalysisSeconds - FTailGuard;
      SplitIndex := High(Chars);
      while (SplitIndex >= 0) and (Chars[SplitIndex].EndSeconds > SplitSeconds) do
        Dec(SplitIndex);
      if SplitIndex < 0 then
      begin
        { 上限まで溜まったのに文字が 1 つも出なかった場合。信号の無い周波数を
          聞いていればこうなる。**ここで何も捨てずに戻ると、バッファは永久に
          伸び続ける。**確定するものは無いので、末尾のガードだけ残して捨て、
          その分だけ時刻を進める。

          The buffer filled and not one character came out, which is what
          listening to an empty frequency looks like. **Returning here without
          discarding anything lets the buffer grow forever.** There is nothing
          to confirm, so everything but the tail guard goes, and the time base
          advances by what went. }
        EnterCriticalSection(FLock);
        try
          if FEpoch <> Epoch then
            Exit;
          SetProvisional(Chars);
          FConfirmedSeconds := FConfirmedSeconds + SplitSeconds;
        finally
          LeaveCriticalSection(FLock);
        end;
        DropLeading(Round(SplitSeconds * Rate));
        Exit;
      end;
    end
    else
    begin
      EnterCriticalSection(FLock);
      try
        if FEpoch = Epoch then
          SetProvisional(Chars);
      finally
        LeaveCriticalSection(FLock);
      end;
      Exit;
    end;
  end;

  { 取り出してから解析を終えるまでに、バッファが捨てられていないか確かめます。
    捨てられていれば、この結果は既に無い音声のものです。
    Check that the buffer was not discarded between reading it and finishing the
    analysis; if it was, this result describes audio that no longer exists. }
  if not StillCurrent(Epoch) then
    Exit;

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
    if FEpoch <> Epoch then
      Exit;
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
  Audio, Prepared: TSingleArray;
  Chars: TDecodedChars;
  Rate, I: Integer;
  Epoch: Int64;
begin
  BeginAnalysis(Audio, Rate, Epoch);
  if Length(Audio) = 0 then
    Exit;
  if SquelchClosed(Audio, Rate) then
    Exit;
  Prepared := PrepareForModel(Audio);
  if Length(Prepared) = 0 then
    Exit;
  Chars := DropLeadArtifacts(
    FDecoder.DecodeLongSamplesTimed(Prepared, FDecoder.Metadata.SampleRate));
  for I := 0 to High(Chars) do
  begin
    Chars[I].Seconds := Chars[I].Seconds + FConfirmedSeconds;
    Chars[I].EndSeconds := Chars[I].EndSeconds + FConfirmedSeconds;
  end;
  EnterCriticalSection(FLock);
  try
    if FEpoch <> Epoch then
      Exit;
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
