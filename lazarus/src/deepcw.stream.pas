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
  SysUtils, Classes, Math, DeepCW.Types, DeepCW.Decoder, DeepCW.Tuner,
  DeepCW.Stations, DeepCW.Metadata;

const
  { 解析にかける最大の長さ。これを超えたら語間を待たずに確定させます。
    Longest span analysed; past this a split is forced without waiting. }
  STREAM_MAX_SECONDS = 24.0;
  { 末尾のこの時間は確定させません。/ The tail left uncommitted. }
  STREAM_TAIL_GUARD_SECONDS = 1.25;
  { これより短い先頭部分は確定させません。/ Nothing shorter than this commits. }
  STREAM_MIN_CONFIRMED_SECONDS = 2.0;
  { 解析にどれだけの機械の力を使ってよいか。1 コアに対する割合です
    （要件 FR-G.4・NFR-1.4・NFR-1.5）。

    **同じ音を何度も解析することが、費用の正体です。**確定していない部分は
    次の解析でもまた頭から読み直すため、解析を細かく回すほど、同じ音の上を
    何度も往復します。速い機械では気になりませんが、遅い機械ではここで
    1 コアを使い切ります。

    **間隔を緩めれば、確定は遅くなりますが、機械は追いつきます。**捨ててから
    「捨てました」と言うより、遅れて読めるほうがよい（要件 NFR-4 の fail-soft
    より前に打てる手があります）。

    How much of the machine the analysis may use, as a fraction of one core
    (requirements FR-G.4, NFR-1.4, NFR-1.5).

    **The cost is in analysing the same audio again and again**: whatever is not
    yet confirmed is read from the top once more at the next analysis, so the
    finer the analyses, the more times the same seconds are traversed. On a fast
    machine this goes unnoticed; on a slow one it is where a whole core goes.

    **Easing the interval delays the confirmation but lets the machine keep
    up** -- better than dropping audio and saying so afterwards; there is a move
    to play before the fail-soft of requirement NFR-4. }
  STREAM_CPU_BUDGET = 0.7;

  { 緩めても、これ以上は待ちません。**これを超えて待つくらいなら、その機械では
    実時間に追いつかないと言うべきです。**
    The interval is never eased past this. **Waiting longer than this would be
    worth less than saying plainly that the machine cannot keep up.** }
  STREAM_MAX_INTERVAL_SECONDS = 6.0;

  { 解析 1 回の費用をならす重み。**1 回の遅れで間隔を跳ね上げないためです。**
    新しい値をこの割合で混ぜます。
    How much of a new measurement enters the running cost: **one slow analysis
    must not send the interval leaping.** }
  STREAM_COST_SMOOTHING = 0.3;

  { 画面が音声を渡してくる刻み。

    **これは復号器の都合ではなく、受信経路の動作点です。**暫定文字の遅延
    （要件 NFR-1.1）はこの刻みでほぼ決まり、実測では 0.2 秒で 0.47〜0.88 秒、
    0.5 秒で 1.09〜1.44 秒、1.0 秒で 1.71〜1.95 秒（目標 1.5 秒を超える）でした。

    **測る道具と画面が別の刻みを使うと、目標を満たしているかどうかを
    実際の動作点で測っていないことになります。**そこで値をここ 1 つに置き、
    画面（取り込みの間隔）も `cw_stream` の既定もこれを使います。

    The interval at which the display hands audio over.

    **This is an operating point of the receive path, not a property of the
    decoder.** The provisional-character latency (requirement NFR-1.1) follows
    almost entirely from it: measured at 0.47-0.88 s with 0.2 s chunks,
    1.09-1.44 s with 0.5 s, and 1.71-1.95 s with 1.0 s -- past the 1.5 s target.

    **A harness feeding at a different interval from the display is not
    measuring at the operating point that has to meet the target.** So the value
    lives here once, and both the display's capture interval and `cw_stream`'s
    default are taken from it. }
  STREAM_FEED_SECONDS = 0.2;

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
  { 交信モード（1 局を聴く）で、隣の強い局のキークリックだけのコマを、復号器へ
    渡す絵から除きます（付録 CI）。多局受信の `SuppressNeighbourClicks`
    （付録 CB）と同じ判じ方で、列は `TClickColumnCache` で求めます。流し込み
    受信・ファイルの復号・読み直しが同じものを使います（整形の場所は 1 か所）。
    **1 つのスレッドから使います。**

    In contact mode (listening to one station), removes the frames holding only
    a strong neighbour's key clicks from the picture handed to the model
    (appendix CI), judged as multi-station reception's
    `SuppressNeighbourClicks` does (appendix CB), with the columns from
    `TClickColumnCache`. Streaming, file decoding and re-reading all use it
    (one place for the preparation). **Used from one thread.** }
  TTunedClickReplacer = class
  private
    FMeta: TDeepCWMetadata;
    FColumns: TClickColumnCache;
    FTune: Double;
    FAudio: TSingleArray;
    FStart: Double;
    FHalf: Double;
    FReplaced: Int64;
    procedure Apply(var Spectrogram: TSpectrogram; StartSeconds: Double);
  public
    constructor Create(Meta: TDeepCWMetadata);
    destructor Destroy; override;
    { 控えた列を捨てます（受信のやり直しなど）。/ Drops the columns kept
      (reception restarted, say). }
    procedure Clear;
    { 1 回の復号の用意をして、`DecodeLongSamplesTimed` へ渡す口を返します。
      置き換えるものが無ければ nil。`Unfiltered` は `PrepareForModelWidth` の
      帯域制限前の音、`AudioStart` はその先頭の、受信を始めてからの秒数（控えた
      列を使い回すため。1 回きりなら 0）、`Neighbours` は `AutoHalfWidth` が
      見つけた隣の局（元の音での Hz）。
      Readies one decode and returns the hook for `DecodeLongSamplesTimed`, or
      nil when there is nothing to replace. `Unfiltered` is the audio before
      the band limit from `PrepareForModelWidth`, `AudioStart` where it begins
      in seconds since reception started (for reusing the columns kept; 0 for
      a one-off), and `Neighbours` the neighbours `AutoHalfWidth` found (Hz in
      the original audio). }
    function Prepare(const Unfiltered: TSingleArray; AudioStart: Double;
      TuneHz, HalfWidthHz: Double;
      const Neighbours: array of Double): TSpectrogramFilter;
    { 置き換えたコマの延べ数。/ Frames replaced so far. }
    property Replaced: Int64 read FReplaced;
    property Columns: TClickColumnCache read FColumns;
  end;

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
    { 自動の帯域の控え（付録 CC）。決めたときの音の時計（負ならまだ）と同調先、
      その幅（片側 Hz）。
      The automatic width kept (appendix CC): the audio clock when it was worked
      out (negative for never), the pitch it was for, and the width (one side,
      Hz). }
    FAutoAt: Double;
    FAutoTune: Double;
    FAutoHalf: Double;
    { 自動の幅を決めたときに見つけた隣の局（Hz）。クリックの置き換えに使い
      回します（付録 CI）。
      The neighbours found when the automatic width was worked out (Hz),
      reused for click replacement (appendix CI). }
    FAutoNeighbours: TDoubleArray;
    { 溜めている音の先頭が、受信を始めてから何標本目か（録音周波数が変われば
      数え直し）。クリックの列を、受信の始めからの時刻で控えるためです
      （付録 CI）。
      Which sample since reception started the front of the buffer is
      (counted afresh on a change of capture rate), so that click columns can
      be kept by their time since reception began (appendix CI). }
    FFrontSample: Int64;
    { ここから下は解析（`Step`・`Finish`）だけが触ります。`Finish` は解析が
      止まっているときに呼ばれるので、同時には触られません（排他なし）。
      From here on only analysis (`Step`, `Finish`) touches these; `Finish` is
      called while no analysis runs, so never at the same time (no lock). }
    FClicks: TTunedClickReplacer;
    FClickEpoch: Int64;
    { 整形の控え（計画 6.1 の P4、付録 CJ）と、その世代。
      The preparation kept (plan 6.1 P4, appendix CJ) and its generation. }
    FShaper: TStreamShaper;
    FShapeEpoch: Int64;
    FReplaceClicks: Boolean;
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
    { 解析 1 回の費用（秒、ならしたもの）と、その 1 回が扱った音の長さ。
      **実時間比は、この 2 つの比です**（要件 FR-G.4）。
      The cost of one analysis in seconds, smoothed, and the length of audio it
      covered: **the real-time ratio is the one over the other** (FR-G.4). }
    FStepCost: Double;
    FStepAudio: Double;
    { 前回の解析を始めた時点の、受け取った音の長さ。**壁の時計ではなく音の
      時計で数えます。**試験は実時間より速く音を流し込むので、壁の時計で
      間隔を測ると、測っている動作点が実機と別物になります。
      The audio clock at the last analysis -- **the audio's clock, not the
      wall's**: a harness feeds faster than real time, and gating on the wall
      would put the test at an operating point the real thing never sees. }
    FPacedFrom: Double;
    FCpuBudget: Double;
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
      out Epoch: Int64; out Front: Int64);
    function StillCurrent(Epoch: Int64): Boolean;
    { 解析にかける形へ整えます。同調・帯域制限・標本化周波数の変換を、途切れの
      ない 1 本の音声に対してまとめて行います。
      Prepares audio for analysis: tuning, band limiting and rate conversion,
      all applied to one unbroken buffer. }
    function PrepareForModel(const Source: TSingleArray; Front, Epoch: Int64;
      out Neighbours: TDoubleArray; out Half, Tuned: Double;
      out Unfiltered: TSingleArray; out Lead: Double): TSingleArray;
    { 復号した文字の時刻を、整形した音の先頭から溜めた音の先頭へ直します
      （`Lead` は 1 標本未満。付録 CJ）。
      Moves decoded character times from the start of the prepared audio to
      the start of the buffer (`Lead`, under one sample; appendix CJ). }
    function ShiftChars(const Chars: TDecodedChars; Lead: Double): TDecodedChars;
    { 隣の局があれば、クリックの置き換えの用意をして、復号器へ渡す口を
      返します（無ければ nil。付録 CI）。
      With neighbours present, readies click replacement and returns the hook
      to hand the decoder (nil with none; appendix CI). }
    function ClickFilter(const Unfiltered: TSingleArray; Rate: Integer;
      Epoch, Front: Int64; Lead: Double; const Neighbours: TDoubleArray;
      Half, Tuned: Double): TSpectrogramFilter;
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
    { 解析 1 回の費用を控え、次に解析してよい時点を決め直します（要件 FR-G.4）。
      Notes what one analysis cost and settles when the next may run (FR-G.4). }
    procedure NotePace(AudioSeconds, CostSeconds: Double);
    { 呼び出し側は FLock を保持していること。/ The caller must hold FLock. }
    function SnapToSample(Seconds: Double; Rate: Integer;
      out Samples: Integer): Double;
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
    { いま実際に掛けている幅（片側 Hz、同調していなければ 0）。自動なら、
      近くの局に合わせて決めた幅です（付録 CC）。画面が「自動」の幅を黙って
      ±250 Hz と出さないためにあります。
      The width actually applied now (one side, Hz; 0 when not tuned). For the
      automatic setting it is the width worked out from the stations nearby
      (appendix CC), so the screen does not quietly claim +/-250 Hz. }
    function AppliedHalfWidthHz: Double;
    { 隣の局のクリックとして置き換えたコマの延べ数（付録 CI。試験と診断用）。
      解析のスレッドが数えるので、解析が止まっているときに読みます。
      How many frames were replaced as a neighbour's clicks so far
      (appendix CI; for tests and diagnostics). Counted by the analysis thread,
      so read it while analysis is idle. }
    function ClickFramesReplaced: Int64;
    { 自動の幅を決めたときに見つけた隣の局（Hz。付録 CI）。読み直しが受信と
      同じ置き換えを掛けるために使います。
      The neighbours found when the automatic width was worked out (Hz;
      appendix CI), so that re-reading applies the same replacement as
      reception. }
    function AutoNeighbours: TDoubleArray;
    { 隣の局のクリックを置き換えるか（既定は置き換える）。置き換えない場合と
      比べる試験と測りのためにあります。解析していないときに変えます。
      Whether neighbours' clicks are replaced (by default they are). It is
      there for tests and measurements comparing with no replacement; change
      it while analysis is idle. }
    property ReplaceClicks: Boolean read FReplaceClicks write FReplaceClicks;

    { これを下回る振幅の区間は解析しません。0 にすると常に解析します。
      Stretches quieter than this are not analysed; 0 analyses everything. }
    property SquelchLevel: Double read FSquelch write FSquelch;

    { 末尾を確定させずに残す時間。長いほど確定は遅れますが確かになります。
      Seconds left uncommitted at the tail; longer is slower but safer. }
    property TailGuardSeconds: Double read FTailGuard write FTailGuard;
    { 先頭からこの時間より短い範囲は確定させません。
      Nothing shorter than this from the start is committed. }
    property MinConfirmedSeconds: Double read FMinConfirmed write FMinConfirmed;

    { 解析にどれだけの機械の力を使ってよいか（要件 FR-G.4）。1 コアに対する
      割合です。0 にすると間隔を緩めません。
      How much of the machine the analysis may use (FR-G.4), as a fraction of
      one core; zero never eases the interval. }
    property CpuBudget: Double read FCpuBudget write FCpuBudget;

    { 解析 1 回の費用（秒、ならしたもの）。まだ測っていなければ 0 です。
      The cost of one analysis in seconds, smoothed; zero before the first. }
    function StepCostSeconds: Double;

    { 実時間比。音 1 秒あたり何倍の速さで解析できているか。**1 を下回ると、
      その機械では実時間に追いつきません。**測っていなければ 0 です。
      The real-time ratio: how many times faster than real time the analysis
      runs. **Below one the machine cannot keep up.** Zero before the first
      measurement. }
    function RealTimeRatio: Double;

    { いま守っている解析の間隔（音の秒数）。0 なら緩めていません。
      The interval now kept between analyses, in seconds of audio; zero means
      nothing is being eased. }
    function PaceSeconds: Double;

    property Decoder: TDeepCWDecoder read FDecoder;
  end;

{ 次の解析まで待つ音の長さ（秒）。**費用を予算で割るだけです。**
  1 回 3 秒かかる解析を 1 コアの 7 割で回すなら、4.3 秒ぶんの音が来るまで
  待てばよい、という計算です。

  費用が測れていない（0）なら 0——**最初の 1 回は待ちません。**待ってから
  測るのでは、何を待てばよいのか分かりません。

  How long to wait, in seconds of audio, before the next analysis: **the cost
  divided by the budget.** An analysis costing three seconds, at seven tenths of
  a core, wants 4.3 seconds of audio between runs.

  With no measurement yet the answer is zero: **the first analysis never
  waits**, there being nothing yet to wait on. }
function PaceInterval(CostSeconds, Budget: Double): Double;

implementation

{ TTunedClickReplacer }

constructor TTunedClickReplacer.Create(Meta: TDeepCWMetadata);
begin
  inherited Create;
  FMeta := Meta;
  FColumns := TClickColumnCache.Create;
end;

destructor TTunedClickReplacer.Destroy;
begin
  FColumns.Free;
  inherited Destroy;
end;

procedure TTunedClickReplacer.Clear;
begin
  FColumns.Clear;
  FAudio := nil;
end;

function TTunedClickReplacer.Prepare(const Unfiltered: TSingleArray;
  AudioStart: Double; TuneHz, HalfWidthHz: Double;
  const Neighbours: array of Double): TSpectrogramFilter;
var
  Shifted: TDoubleArray;
  I: Integer;
begin
  Result := nil;
  FAudio := nil;
  { 同調点が変われば、控えた列は別の音のものです。/ A new tuned pitch makes
    the columns kept another sound's. }
  if TuneHz <> FTune then
  begin
    FColumns.Clear;
    FTune := TuneHz;
  end;
  if (TuneHz <= 0) or (Length(Neighbours) = 0) or (Length(Unfiltered) = 0) then
    Exit;
  { 列は、同調点を 800 Hz へ動かしたモデルの周波数の音で求めます。隣の局も
    同じだけ動かします。
    The columns come from the model-rate audio with the tuned pitch moved to
    800 Hz; the neighbours are moved by as much. }
  Shifted := nil;
  SetLength(Shifted, Length(Neighbours));
  for I := 0 to High(Neighbours) do
    Shifted[I] := Neighbours[I] - TuneHz + TUNER_TARGET_TONE_HZ;
  FColumns.Configure(FMeta.SampleRate, TUNER_TARGET_TONE_HZ, Shifted);
  { 200 Hz より近い隣の局しかいなければ、置き換えるものはありません。
    With only neighbours nearer than 200 Hz there is nothing to replace. }
  if not FColumns.HasNeighbours then
    Exit;
  FAudio := Unfiltered;
  FStart := AudioStart;
  FHalf := HalfWidthHz;
  Result := @Apply;
end;

procedure TTunedClickReplacer.Apply(var Spectrogram: TSpectrogram;
  StartSeconds: Double);
var
  Found: TClickColumns;
begin
  Found := FColumns.Columns(FAudio, FStart, StartSeconds, Spectrogram.Frames);
  Inc(FReplaced, SuppressClicksFromColumns(Spectrogram, Found, FHalf,
    FMeta.SampleRate / FMeta.FFTLength));
end;

{ TStreamingDecoder }

constructor TStreamingDecoder.Create(ADecoder: TDeepCWDecoder);
begin
  inherited Create;
  if ADecoder = nil then
    raise EDeepCW.Create('The streaming decoder needs a decoder.');
  FDecoder := ADecoder;
  FAntiAlias := True;
  FTuneHz := 0;
  FBandwidth := tbAuto;
  FAutoAt := -1;
  FAutoTune := 0;
  FAutoHalf := BandwidthHalfWidth(tbAuto);
  FTailGuard := STREAM_TAIL_GUARD_SECONDS;
  FMinConfirmed := STREAM_MIN_CONFIRMED_SECONDS;
  FSquelch := STREAM_SQUELCH_LEVEL;
  FCpuBudget := STREAM_CPU_BUDGET;
  FSourceRate := ADecoder.Metadata.SampleRate;
  FClicks := TTunedClickReplacer.Create(ADecoder.Metadata);
  FClickEpoch := -1;
  FShaper := TStreamShaper.Create;
  FShapeEpoch := -1;
  FReplaceClicks := True;
  InitCriticalSection(FLock);
end;

destructor TStreamingDecoder.Destroy;
begin
  FClicks.Free;
  FShaper.Free;
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
    FAutoAt := -1;
    FAutoNeighbours := nil;
    FFrontSample := 0;
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
      FFrontSample := 0;
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

function TStreamingDecoder.PrepareForModel(const Source: TSingleArray;
  Front, Epoch: Int64; out Neighbours: TDoubleArray; out Half, Tuned: Double;
  out Unfiltered: TSingleArray; out Lead: Double): TSingleArray;
var
  Tune, Clock, AutoAt, AutoTune: Double;
  Width: TTunerBandwidth;
  Limit: Boolean;
  Rate, Span: Integer;
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
    Clock := FConfirmedSeconds + FPendingCount / Max(1, FSourceRate);
    AutoAt := FAutoAt;
    AutoTune := FAutoTune;
    Half := FAutoHalf;
    Neighbours := FAutoNeighbours;
  finally
    LeaveCriticalSection(FLock);
  end;
  { 自動の帯域は、同調先の近くの局に合わせます（付録 CC）。決め直すのは、
    同調先が変わったとき・まだ決めていないとき・新しい音が
    `TUNER_AUTO_REFRESH_SECONDS` たまったときだけで、見るのは直近
    `TUNER_AUTO_SPAN_SECONDS` です。排他の外で求めます（重い処理のため）。
    The automatic width follows the stations near the tuned pitch
    (appendix CC). It is worked out again only when the pitch changed, when
    there is none yet, or when `TUNER_AUTO_REFRESH_SECONDS` of new audio have
    arrived, over the last `TUNER_AUTO_SPAN_SECONDS`; outside the lock, being
    heavy. }
  if (Tune > 0) and (Width = tbAuto) then
  begin
    if (AutoAt < 0) or (AutoTune <> Tune) or (Clock < AutoAt) or
       (Clock - AutoAt >= TUNER_AUTO_REFRESH_SECONDS) then
    begin
      Span := Min(Length(Source), Round(TUNER_AUTO_SPAN_SECONDS * Max(1, Rate)));
      Half := AutoHalfWidth(Copy(Source, Length(Source) - Span, Span), Rate,
        Tune, FDecoder.Metadata, Neighbours);
      EnterCriticalSection(FLock);
      try
        { 求めているあいだに同調先が変われば、この幅は前の同調先のものです。
          控えずに捨てます（画面が新しい同調先の幅として出さないように）。
          Should the pitch have changed meanwhile, this width is the old
          pitch's and is not kept (so the screen does not show it as the new
          pitch's). }
        if FTuneHz = Tune then
        begin
          FAutoAt := Clock;
          FAutoTune := Tune;
          FAutoHalf := Half;
          FAutoNeighbours := Neighbours;
        end;
      finally
        LeaveCriticalSection(FLock);
      end;
    end;
  end
  else
  begin
    Half := BandwidthHalfWidth(Width);
    { 手で選んだ幅では局を探さないので、クリックも置き換えません（付録 CI）。
      A width chosen by hand detects no stations, so clicks are not replaced
      either (appendix CI). }
    Neighbours := nil;
  end;
  if Tune <= 0 then
    Neighbours := nil;
  Tuned := Tune;
  { 整形そのものは DeepCW.Tuner が持ちます。ファイルからの復号と同じ計算を、
    新しく届いた音の分だけ行います（`TStreamShaper`。1 回だけなら
    `PrepareForModelWidth` とビット単位で同じ。付録 CJ）。世代が変われば
    （受信のやり直し・録音周波数の変更）控えは別の音のものです。
    The preparation itself lives in DeepCW.Tuner: the same computation as file
    decoding, done for newly arrived audio only (`TStreamShaper`; bit for bit
    `PrepareForModelWidth` when called once; appendix CJ). A new generation
    (reception restarted, capture rate changed) makes what is kept another
    sound's. }
  if Epoch <> FShapeEpoch then
  begin
    FShaper.Reset;
    FShapeEpoch := Epoch;
  end;
  Result := FShaper.Shape(Source, Rate, FDecoder.Metadata.SampleRate, Front,
    Tune, Half, Limit, Unfiltered, Lead);
end;

function TStreamingDecoder.ShiftChars(const Chars: TDecodedChars;
  Lead: Double): TDecodedChars;
var
  I: Integer;
begin
  Result := Chars;
  if Lead = 0 then
    Exit;
  Result := Copy(Chars);
  for I := 0 to High(Result) do
  begin
    Result[I].Seconds := Result[I].Seconds + Lead;
    Result[I].EndSeconds := Result[I].EndSeconds + Lead;
  end;
end;

function TStreamingDecoder.ClickFilter(const Unfiltered: TSingleArray;
  Rate: Integer; Epoch, Front: Int64; Lead: Double;
  const Neighbours: TDoubleArray; Half, Tuned: Double): TSpectrogramFilter;
begin
  Result := nil;
  { 世代が変われば（受信のやり直し・録音周波数の変更）、控えた列の時刻は別の
    音のものです。
    A new generation (reception restarted, capture rate changed) makes the
    times of the columns kept refer to other audio. }
  if Epoch <> FClickEpoch then
  begin
    FClicks.Clear;
    FClickEpoch := Epoch;
  end;
  if not FReplaceClicks then
    Exit;
  Result := FClicks.Prepare(Unfiltered, Front / Max(1, Rate) + Lead, Tuned,
    Half, Neighbours);
end;

function TStreamingDecoder.ClickFramesReplaced: Int64;
begin
  Result := FClicks.Replaced;
end;

function TStreamingDecoder.AutoNeighbours: TDoubleArray;
begin
  EnterCriticalSection(FLock);
  try
    if (FTuneHz > 0) and (FBandwidth = tbAuto) then
      Result := Copy(FAutoNeighbours)
    else
      Result := nil;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TStreamingDecoder.AppliedHalfWidthHz: Double;
begin
  EnterCriticalSection(FLock);
  try
    if FTuneHz <= 0 then
      Result := 0
    else if FBandwidth <> tbAuto then
      Result := BandwidthHalfWidth(FBandwidth)
    else
      Result := FAutoHalf;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

procedure TStreamingDecoder.SetTuneHz(Value: Double);
var
  Before: Double;
begin
  EnterCriticalSection(FLock);
  try
    Before := FTuneHz;
    if Value > 0 then
      FTuneHz := QuantizeTone(Value)
    else
      FTuneHz := 0;
    { 同調先が変われば、自動の幅の控えは前の同調先のものです。捨てて既定へ
      戻し、次の解析で決め直します（付録 CC）。
      A new pitch makes the kept automatic width the old pitch's: it is dropped
      back to the default and worked out again at the next analysis
      (appendix CC). }
    if FTuneHz <> Before then
    begin
      FAutoAt := -1;
      FAutoHalf := BandwidthHalfWidth(tbAuto);
      FAutoNeighbours := nil;
    end;
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
  out Rate: Integer; out Epoch: Int64; out Front: Int64);
var
  Wanted: Integer;
begin
  EnterCriticalSection(FLock);
  try
    Rate := Max(1, FSourceRate);
    Epoch := FEpoch;
    Front := FFrontSample;
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
      Inc(FFrontSample, Excess);
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

{ 区切りの位置を標本の境目へ丸めます。

  時刻を秒で進めながら、捨てるのは丸めた標本数、という組み合わせは、1 回あたり
  最大で半標本ぶん食い違います。1 回では見えませんが、確定のたびに積もるため、
  長く受信するほど文字の時刻が実際の音からずれていきます。聴き直し（FR-E.10）は
  この時刻をそのまま音の位置として使うので、ここで両者を一致させます。

  Rounds a split point to a sample boundary.

  Advancing the clock in seconds while discarding a rounded number of samples
  disagrees by up to half a sample each time. One is invisible, but it happens
  at every commit, so the character times drift from the actual audio the longer
  reception runs. Replay (FR-E.10) uses those times as positions in the audio,
  so the two are made to agree here. }
function TStreamingDecoder.SnapToSample(Seconds: Double; Rate: Integer;
  out Samples: Integer): Double;
begin
  Samples := Max(0, Round(Seconds * Rate));
  if Samples > FPendingCount then
    Samples := FPendingCount;
  Result := Samples / Rate;
end;

procedure TStreamingDecoder.DropLeading(Samples: Integer);
var
  I: Integer;
begin
  if Samples <= 0 then
    Exit;
  EnterCriticalSection(FLock);
  try
    Inc(FFrontSample, Min(Samples, FPendingCount));
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

function PaceInterval(CostSeconds, Budget: Double): Double;
begin
  if (CostSeconds <= 0) or (Budget <= 0) then
    Exit(0);
  Result := Min(STREAM_MAX_INTERVAL_SECONDS, CostSeconds / Budget);
end;

function TStreamingDecoder.StepCostSeconds: Double;
begin
  EnterCriticalSection(FLock);
  try
    Result := FStepCost;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TStreamingDecoder.RealTimeRatio: Double;
begin
  EnterCriticalSection(FLock);
  try
    if FStepCost > 0 then
      Result := FStepAudio / FStepCost
    else
      Result := 0;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TStreamingDecoder.PaceSeconds: Double;
begin
  Result := PaceInterval(StepCostSeconds, FCpuBudget);
end;

{ 解析にかけてよいか。溜まった量と、**前回からどれだけ音が来たか**の 2 つで
  決めます（要件 FR-G.4）。

  速い機械では、費用 0.3 秒 ÷ 予算 0.7 で 0.43 秒——溜まる量の条件
  （2 秒）のほうが先に効くので、**動作点は変わりません。**遅い機械でだけ
  間隔が伸び、CPU は予算に収まります。

  Whether an analysis may run: from what has accumulated and **how much audio
  has arrived since the last one** (requirement FR-G.4).

  On a fast machine a cost of 0.3 seconds over a budget of 0.7 asks for 0.43
  seconds, which the two-second minimum already covers -- **the operating point
  does not move.** The interval grows only on a machine that needs it, and the
  processor stays inside its budget. }
procedure TStreamingDecoder.NotePace(AudioSeconds, CostSeconds: Double);
begin
  if CostSeconds < 0 then
    CostSeconds := 0;
  EnterCriticalSection(FLock);
  try
    { **1 回の遅れで間隔を跳ね上げません。**他の仕事に取られた 1 回で
      「この機械は遅い」と決めつけると、そのあとずっと確定が遅れます。
      **One slow run does not send the interval leaping**: deciding the machine
      is slow from a single analysis that lost its turn would delay every
      confirmation after it. }
    if FStepCost <= 0 then
      FStepCost := CostSeconds
    else
      FStepCost := (1 - STREAM_COST_SMOOTHING) * FStepCost +
        STREAM_COST_SMOOTHING * CostSeconds;
    FStepAudio := AudioSeconds;
    FPacedFrom := FConfirmedSeconds + FPendingCount / Max(1, FSourceRate);
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TStreamingDecoder.Ready: Boolean;
var
  Interval: Double;
begin
  Result := PendingSeconds >= STREAM_MIN_PENDING_SECONDS;
  if not Result then
    Exit;
  Interval := PaceSeconds;
  if Interval <= 0 then
    Exit;
  Result := ElapsedSeconds - FPacedFrom >= Interval;
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
  Audio, Prepared, Unfiltered: TSingleArray;
  Chars, Committed: TDecodedChars;
  Rate, SplitIndex, I, Count: Integer;
  AnalysisSeconds, SplitSeconds, Half, Tuned, Lead: Double;
  Forced: Boolean;
  Epoch, Front: Int64;
  Neighbours: TDoubleArray;
  Filter: TSpectrogramFilter;
  DropSamples: Integer;
  Started: TDateTime;
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
  BeginAnalysis(Audio, Rate, Epoch, Front);
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

  Prepared := PrepareForModel(Audio, Front, Epoch, Neighbours, Half, Tuned,
    Unfiltered, Lead);
  if Length(Prepared) = 0 then
    Exit;
  { **解析の費用は、ここで測ります**（要件 FR-G.4）。測った値は、次にいつ
    解析してよいかを決めるのに使います。
    **The cost of an analysis is measured here** (requirement FR-G.4); what it
    measures decides when the next one may run. }
  Started := Now;
  Filter := ClickFilter(Unfiltered, Rate, Epoch, Front, Lead, Neighbours,
    Half, Tuned);
  Chars := DropLeadArtifacts(ShiftChars(
    FDecoder.DecodeLongSamplesTimed(Prepared, FDecoder.Metadata.SampleRate,
      Filter), Lead));
  NotePace(AnalysisSeconds, (Now - Started) * SecsPerDay);

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
          SplitSeconds := SnapToSample(SplitSeconds, Rate, DropSamples);
          FConfirmedSeconds := FConfirmedSeconds + SplitSeconds;
        finally
          LeaveCriticalSection(FLock);
        end;
        DropLeading(DropSamples);
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
    SplitSeconds := SnapToSample(SplitSeconds, Rate, DropSamples);
    FConfirmedSeconds := FConfirmedSeconds + SplitSeconds;
  finally
    LeaveCriticalSection(FLock);
  end;

  DropLeading(DropSamples);
  Result := Count > 0;
end;

procedure TStreamingDecoder.Finish;
var
  Audio, Prepared, Unfiltered: TSingleArray;
  Chars: TDecodedChars;
  Rate, I: Integer;
  Epoch, Front: Int64;
  Neighbours: TDoubleArray;
  Half, Tuned, Lead: Double;
begin
  BeginAnalysis(Audio, Rate, Epoch, Front);
  if Length(Audio) = 0 then
    Exit;
  if SquelchClosed(Audio, Rate) then
    Exit;
  Prepared := PrepareForModel(Audio, Front, Epoch, Neighbours, Half, Tuned,
    Unfiltered, Lead);
  if Length(Prepared) = 0 then
    Exit;
  Chars := DropLeadArtifacts(ShiftChars(
    FDecoder.DecodeLongSamplesTimed(Prepared, FDecoder.Metadata.SampleRate,
      ClickFilter(Unfiltered, Rate, Epoch, Front, Lead, Neighbours, Half,
        Tuned)), Lead));
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
    { 溜まっていた音声を**すべて**手放し、その全部ぶん時刻を進めます。

      解析にかけるのは先頭の最大 STREAM_MAX_SECONDS 分だけなので、それより多く
      溜まっているところで受信を止めると、解析した長さだけ時刻を進めながら
      溜まっていた全部を捨てることになります。時刻は差の分だけ**戻り**、捨てた
      音声はどこにも申告されません。解析しなかった分は本当に失われるので、
      取りこぼしとして数えます（第 10 章 10.1・10.9）。

      **All** of the buffer is released and the clock advanced by all of it.

      Only the first STREAM_MAX_SECONDS is analysed, so stopping reception with
      more than that buffered would advance the clock by the analysed length
      while discarding the whole buffer: the clock would move **backwards** by
      the difference and the discarded audio would go unreported. What was never
      analysed is genuinely lost, so it is counted as a loss (chapter 10, rules
      10.1 and 10.9). }
    if FPendingCount > Length(Audio) then
      FDroppedSeconds := FDroppedSeconds +
        (FPendingCount - Length(Audio)) / Rate;
    FConfirmedSeconds := FConfirmedSeconds + FPendingCount / Rate;
    Inc(FFrontSample, FPendingCount);
    FPendingCount := 0;
  finally
    LeaveCriticalSection(FLock);
  end;
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
