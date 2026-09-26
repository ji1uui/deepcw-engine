unit FrmMain;

{ DeepCW モールス通信ステーションの主ウィンドウです。

  画面は .lfm リソースではなくすべてコードで組み立てています。そのため Lazarus
  IDE を一度も開いていない環境でも lazbuild だけでビルドでき、配置も通常の
  ソースコードとして読めます。

  本ユニット全体で守っているスレッドの方針は次のとおりです。
    * ONNX デコーダはワーカースレッド上で動き、同時に 1 件だけ実行します。
    * PortAudio の録音と再生はそれぞれ専用のスレッドを持ちます。
    * GUI はこれらを待たず、タイマーで状態を確認します。

  Main window of the DeepCW Morse station.

  The window is built entirely in code rather than from an .lfm resource, so
  the project compiles with lazbuild on a machine that has never opened the
  Lazarus IDE and the layout can be reviewed as ordinary source.

  Threading rules used throughout:
    * the ONNX decoder lives on a worker thread, one decode at a time;
    * PortAudio capture and playback own their own threads;
    * the GUI never blocks on them, it polls from a timer. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Math, DateUtils, IniFiles, Clipbrd,
  Forms, Controls, Graphics, Dialogs, StdCtrls, ExtCtrls, ComCtrls, Spin,
  LCLType, FileCtrl,
  DeepCW.Types, DeepCW.Metadata, DeepCW.Dsp, DeepCW.Onnx, DeepCW.Wave,
  DeepCW.Exchange, DeepCW.Watch,
  DeepCW.Morse, DeepCW.Decoder, DeepCW.Audio, DeepCW.Stream, DeepCW.Tuner,
  DeepCW.Review, DeepCW.Journal, DeepCW.Multi, DeepCW.BandMap, DeepCW.Log,
  DeepCW.Callsign, DeepCW.Recorder, DeepCW.Practice, DeepCW.Fist,
  DeepCW.FistLog, DeepCW.Diagnostics, DeepCW.Reference, DeepCW.Roster, DeepCW.CopyLog,
  DeepCW.Hamlib, DeepCW.RigKeyer, DeepCW.TxMessage, DeepCW.NoiseReduction,
  DeepCW.Alphabet, DeepCW.TxGate, DeepCW.RigConfig,
  DeepCW.Platform,
  TranscriptView, WaterfallView, BandMapView, TrendView, HistogramView,
  ViewColors, LayoutCheck, TextCheck, UiText, UiLang;

type
  { 受信のしかた（要件 FR-I.6）。

    「いま何をしているか」を運用者が選びます。**機械の都合ではなく、運用者の
    状況そのものです。**CQ を待っているのか、いま交信しているのかは、運用者が
    自分で分かっています。

    要件は 3 つのモードを挙げていますが、コンテストモードは「得点になる局／
    交信済みの局を区別して並べる」（FR-I.5）が実装されるまで待機モードと
    同じ振る舞いにしかなりません。**同じ振る舞いのものを別の名前で 2 つ並べる
    のは、選ばせる意味がないうえに嘘に近いので、置いていません。**

    How reception is being used (requirement FR-I.6).

    The operator chooses what they are doing. **This is their own situation, not
    the machine's internals**: whether they are waiting for a call or in a
    contact is something they already know.

    The requirement lists three modes, but the contest mode cannot behave
    differently from the waiting mode until scoring and worked-before stations
    are distinguished (FR-I.5). **Two names for one behaviour gives the operator
    nothing to choose between and comes close to a lie, so it is not offered
    yet.** }
  TReceiveMode = (
    { 1 局に絞って精度を上げる。従来の受信です（要件 FR-I ③）。
      Narrowed to one station for accuracy; reception as it was
      (requirement FR-I, third mode). }
    rmContact,
    { 帯域内の全局を同時に読み、一覧に出す（要件 FR-I ①）。
      Reads every station in the band at once and lists them
      (requirement FR-I, first mode). }
    rmWatch,
    { 得点になる局と、既に交信した局を区別して並べる（要件 FR-I ②・FR-I.5）。

      読み方は待機モードと同じで、**見せ方が違います。**交信済みの局を隠せる
      ことと、時間あたりの交信数を出すことが、コンテスト中に見たいものです。
      得点計算には踏み込みません（未解決 #9）。規約は大会ごとに違い、**間違った
      得点を出すのは、何も出さないより悪い**ためです。

      Distinguishes the stations that score and the ones already worked
      (requirement FR-I, second mode; FR-I.5).

      It reads the same way the waiting mode does and **shows it differently**:
      being able to hide the stations already worked, and seeing the contacts
      per hour, are what a contest wants on screen. Scoring is left alone
      (unresolved #9): the rules differ from contest to contest, and **a wrong
      score is worse than none.** }
    rmContest);

  { 復号 1 件を UI スレッドの外で実行し、結果を Synchronize で返します。
    デコーダはフォームが所有したままですが、生きているスレッドは常に 1 つだけ
    であるため安全に共有できます。

    Runs one decode off the UI thread and hands the result back through
    Synchronize. The decoder object stays owned by the form; only one thread
    is ever alive at a time, which is what makes that safe. }
  { 復号へ渡す前の整形（同調・帯域・標本化）の設定です（要件 FR-D.3）。画面の
    スレッドで決めて、値のまま作業スレッドへ渡します。`AutoWidth` なら、幅は
    渡した音から決めます（付録 CC）。
    The settings of the preparation before decoding -- tuning, band limit,
    rate (requirement FR-D.3). Decided on the UI thread and handed to a worker
    by value. With `AutoWidth` the width is worked out from the audio itself
    (appendix CC). }
  TDecoderShaping = record
    Meta: TDeepCWMetadata;
    TuneHz: Double;
    HalfWidthHz: Double;
    AutoWidth: Boolean;
    AntiAlias: Boolean;
  end;

  TDecodeThread = class(TThread)
  private
    FDecoder: TDeepCWDecoder;
    FStream: TStreamingDecoder;
    FMulti: TMultiStationDecoder;
    FSamples: TSingleArray;
    FSampleRate: Integer;
    FChars: TDecodedChars;
    FError: string;
    { ファイルの復号（`CreateFile`）。読み込み・保管庫への投入・整形も、この
      スレッドで行います（計画 6.1 の P1）。
      A file decode (`CreateFile`): loading, storing and preparing happen on
      this thread too (plan 6.1, P1). }
    FFileName: string;
    FHistory: TAudioHistory;
    FShaping: TDecoderShaping;
    FAppliedHalf: Double;
    FLoadError: string;
    FOnLoaded: TNotifyEvent;
    FOnShaped: TNotifyEvent;
    FRecheck: Boolean;
    { 送信訓練の採点のための解析かどうか。**受信テキストへ流さないのは
      読み直しと同じ理由です。**
      Whether this analysis is for scoring send practice. **It does not flow
      into the transcript, for the same reason a re-reading does not.** }
    FFist: Boolean;
    FOnDone: TNotifyEvent;
    procedure ReportDone;
    procedure ReadFile;
    procedure FeedMulti;
    procedure ReportLoaded;
    procedure ReportShaped;
  protected
    procedure Execute; override;
  public
    constructor Create(ADecoder: TDeepCWDecoder; const ASamples: TSingleArray;
      ASampleRate: Integer; AOnDone: TNotifyEvent);
    { 流し込み受信では、溜まった音声を 1 回だけ解析します。
      For streaming reception, analyse the buffered audio once. }
    constructor CreateStreaming(AStream: TStreamingDecoder; AOnDone: TNotifyEvent);
    { 帯域内の多局を 1 回ぶん解析します（要件 FR-I）。
      Analyses one window of the many stations in the band (requirement FR-I). }
    constructor CreateMulti(AMulti: TMultiStationDecoder; AOnDone: TNotifyEvent);
    { 1 語ぶんの音を、その区間だけで読み直します（要件 FR-C.3）。

      解析そのものは `Create` と同じです。**別の入口にしてあるのは、返ってきた
      結果を受信テキストへ流し込ませないためです。**読み直しは確かめるための
      もので、確定した文字を書き換えるものではありません（要件 FR-B.2）。

      Re-reads one word from its own span of audio (requirement FR-C.3).

      The analysis is the same as `Create` does. **It has an entrance of its own
      so that what comes back cannot flow into the transcript**: a re-reading is
      for checking, not for rewriting characters already confirmed (requirement
      FR-B.2). }
    constructor CreateRecheck(ADecoder: TDeepCWDecoder;
      const ASamples: TSingleArray; ASampleRate: Integer;
      AOnDone: TNotifyEvent);
    { 送信訓練の音を、採点のために 1 度だけ読みます（要件 FR-H.6 の
      「写しやすさ」）。**読み取れた文字は画面の受信テキストには出しません。**
      Reads the send-practice audio once, for the copyability score (FR-H.6).
      **What it reads does not appear in the transcript.** }
    constructor CreateFist(ADecoder: TDeepCWDecoder;
      const ASamples: TSingleArray; ASampleRate: Integer;
      AOnDone: TNotifyEvent);
    { WAV ファイルを読み、復号します（`AMulti` があれば待機モードの経路で）。
      読めた時点で `AOnLoaded` を画面のスレッドで同期して呼びます。そこで
      画面側の片付け・波形・ノイズ低減（`Samples` を差し替える）・`Shaping` を
      済ませます。**読めなければ何も片付けず**、`LoadError` を持って終わります。
      整形が済むと `AOnShaped` を画面のスレッドへ預けます。
      Reads a WAV file and decodes it (through the waiting mode's path when
      `AMulti` is given). Once read, `AOnLoaded` runs synchronously on the UI
      thread, which does the screen's clearing, the waterfall, the noise
      reduction (replacing `Samples`) and sets `Shaping`. **If it cannot be
      read, nothing is cleared** and the thread ends with `LoadError`. When the
      preparation is done, `AOnShaped` is queued to the UI thread. }
    constructor CreateFile(ADecoder: TDeepCWDecoder;
      AMulti: TMultiStationDecoder; AHistory: TAudioHistory;
      const AFileName: string; AOnLoaded, AOnShaped, AOnDone: TNotifyEvent);
    property Samples: TSingleArray read FSamples write FSamples;
    property SampleRate: Integer read FSampleRate;
    property Shaping: TDecoderShaping read FShaping write FShaping;
    property AppliedHalfWidthHz: Double read FAppliedHalf;
    property LoadError: string read FLoadError;
    property Chars: TDecodedChars read FChars;
    property Recheck: Boolean read FRecheck;
    property Fist: Boolean read FFist;
    property Error: string read FError;
  end;

  TMainForm = class(TForm)
  private
    { エンジン / engine }
    FDecoder: TDeepCWDecoder;
    FDecodeThread: TDecodeThread;
    { 終了したスレッドを、そのスレッド自身の Synchronize の中で解放することは
      できません。TThread.Destroy が待つ相手は、主スレッドを待っているそのスレッド
      自身だからです。ここへ一時的に預け、タイマー側で解放します。

      A finished thread cannot be freed from inside its own Synchronize call:
      TThread.Destroy waits for the thread that is itself waiting for the main
      thread. It is parked here and released from the poll timer instead. }
    FCompletedThread: TDecodeThread;
    FClosing: Boolean;
    { ライブ受信で記録に追記している間は True、記録を置き換える単発の復号では
      False になります。

      True while live reception is appending to a running transcript, false for
      one-shot decodes that replace it. }
    FAppendMode: Boolean;
    FEngineError: string;
    { 技術的な原文の控え。診断画面にだけ出します（要件 NFR-5.7）。
      Raw technical messages, shown only on the diagnostics panel. }
    FDiagnostics: TStringList;
    { 設定に変更があったか。終了時だけに頼らず、動作中にも書き出します。
      Whether settings changed; they are written while running rather than
      relying on a clean exit. }
    FSettingsDirty: Boolean;
    FSettingsSavedAt: TDateTime;
    { 解析中に受信を止めた場合、その解析が終わってから残りを確定させます。
      止めた瞬間に確定させようとすると、走っている解析と衝突します。

      When reception is stopped while an analysis is running, the tail is
      committed once that analysis finishes; doing it at the moment of
      stopping would collide with the analysis in flight. }
    FFinishPending: Boolean;
    { 「間隔を緩めています」と最後に伝えた時刻。**毎秒言えば、案内の欄が
      それだけで埋まります。**
      When the eased interval was last mentioned: **said every second it would
      fill the guidance panel by itself.** }
    FPaceToldAt: TDateTime;

    { 音声 / audio }
    FRing: TAudioRing;
    FCapture: TAudioCapture;
    FPlayback: TAudioPlayback;
    { 直近の受信音の保管庫と、その聴き直し用の再生。送信の再生とは別に持ちます。
      片方を止めるつもりでもう片方が止まる、という取り違えを避けるためです。

      The store of recent audio and a playback for replaying it, kept apart
      from the transmit playback so that stopping one cannot be mistaken for
      stopping the other. }
    FHistory: TAudioHistory;
    FReviewPlay: TAudioPlayback;
    { 受信テキストの記録と、経過秒 0 に対応する実時刻。原点が無ければ、記録の
      時刻は書いた瞬間になり、確定の遅れのぶんだけ遅くなります（要件 FR-B.6）。
      The transcript journal and the wall clock corresponding to elapsed second
      zero. Without the origin the recorded times would be the moments of
      writing, late by the confirmation lag (requirement FR-B.6). }
    FJournal: TTranscriptJournal;
    { 受信音の録音（要件 FR-E.8）。受信が動いている間だけ存在します。
      The recording of the received audio (requirement FR-E.8); it exists only
      while reception runs. }
    FRecorder: TAudioRecorder;
    { 状態表示に出している文字。**同じ文字を毎回書き直さないためです。**
      What the status panel currently shows, so the same text is not written
      into it five times a second. }
    FRecordShown: string;
    { 既に知らせた参照番号（要件 FR-E.6）。同じものを繰り返さないために持ちます。
      The reference already announced (requirement FR-E.6), kept so the same one
      is not repeated. }
    FReferenceShown: string;
    { 交信数を数え直した時刻。数え直しは記録の全件を読むため、毎秒は行いません。
      When the contact count was last recounted: counting reads every record, so
      it is not done every second. }
    FRateAt: TDateTime;
    { 読み直しの依頼（要件 FR-C.3）。押されたときに解析が塞がっていることが
      あるので、**依頼を覚えておいて、空いたら出します。**
      A re-reading that has been asked for (requirement FR-C.3). The analysis can
      be busy at the moment of the press, so **the request is remembered and
      issued when it is free.** }
    FRecheckPending: Boolean;
    FRecheckIndex: Integer;
    FRecheckWord: string;
    FRecheckAt: TDateTime;
    { 解析に出したほうの語と、その依頼の時刻。**待っている間に別の語を押されても、
      返ってきた答えは押された当時の語のものです。**取り違えると、読み直しの
      結果が別の語の隣に並びます。
      The word actually handed to the analysis, and when it was asked for.
      **Another word pressed while this one is out does not change what comes
      back**: mixing them up would put a re-reading beside a different word. }
    FRecheckSent: string;
    FRecheckSentAt: TDateTime;
    { 交信の記録。バンドマップの「交信済み」も ADIF の書き出しも、ここ 1 つを
      見ます（要件 FR-E.3・FR-J.4）。
      The contact log. Both the worked marks on the band map and the ADIF export
      read this one thing (requirements FR-E.3 and FR-J.4). }
    FLog: TContactLog;
    { 一覧から選んだ局の呼出符号。選んだ時点で分かっているものを、交信モードへ
      移ったあとも覚えておきます。**忘れると、相手が分かっているのに記録できない
      という間の抜けた状態になります。**受信テキストから符号が読めれば、そちらを
      優先します。
      The call sign of the station chosen from the list, remembered into the
      contact mode. **Forgetting it leaves the odd state of knowing who is being
      worked and being unable to log it.** A call sign read from the transcript
      takes precedence once there is one. }
    FChosenCallsign: string;
    { 受信文から読み取ったもの。文字が入れ替わったときにだけ作り直します。
      画面の更新（0.2 秒ごと）のたびに読み直すと、読み取りの費用がそのまま
      毎秒 5 回の負担になります。
      What was read out of the transcript, rebuilt only when the characters
      change. Re-reading it on every display refresh (five times a second) would
      turn the cost of reading into a five-times-a-second burden. }
    FExchange: TExchange;
    { 一覧の中身。作るのは毎秒 1 回（RefreshBandMap）で、記録の問い合わせは
      ここを見ます。24 局 4000 文字で 1 回 10.6 ms かかる処理なので、0.2 秒ごとに
      作り直してはいけません。
      The list's contents, built once a second (RefreshBandMap); the log side
      reads them from here. Rebuilding costs 10.6 ms at 24 stations of 4000
      characters, so it must not happen five times a second. }
    FBandEntries: TBandEntries;
    { 待っている呼出符号と、すでに知らせた局（要件 FR-I.4）。
      The call signs being waited for and the stations already announced
      (requirement FR-I.4). }
    FWatched: TWatchedCalls;
    FAlerts: TWatchAlerts;
    FClockOrigin: TDateTime;
    { 記録へ渡し終えた確定文字の数。ここまでは書いたという印で、同じ文字を
      二度書かないために要ります。
      How many confirmed characters have been handed to the journal, so that the
      same character is never written twice. }
    FJournalled: Integer;
    FCaptureRate: Integer;
    { 選べる入力装置。番号は抜き差しで変わるため、覚えておくのは名前です
      （要件 FR-A.5）。
      The input devices on offer. Indices shift as hardware is plugged and
      unplugged, so what is remembered is the name (requirement FR-A.5). }
    FDevices: TAudioDevices;

    { 送信の状態 / transmit state }
    FTxPlaying: Boolean;
    FTxSegments: TCWSegments;
    FTxSamples: TSingleArray;
    FTxNormalized: string;
    FTxSampleRate: Integer;

    { 受信の状態 / receive state }
    FLiveChars: TDecodedChars;
    FStream: TStreamingDecoder;
    { 帯域内の多局を同時に読む機械。交信モードでは動かしません。両方を同時に
      走らせると、要らないほうにも同じだけの計算を払うことになります。
      The machine that reads many stations at once; it does not run in the
      contact mode. Running both would pay the full cost of the one not
      wanted. }
    FMulti: TMultiStationDecoder;
    FRingPosition: Int64;
    FMode: TReceiveMode;
    { バンドマップを最後に作り直した時刻。一覧は毎秒 1 回で足ります。
      When the band map was last rebuilt; once a second is enough for a list. }
    FBandMapAt: TDateTime;

    { 画面の骨組み / layout }
    FPages: TPageControl;
    FStatus: TStatusBar;
    FPollTimer: TTimer;

    { 送信タブ / transmit tab }
    FTxText: TMemo;
    FTxCode: TMemo;
    FTxCharWpm: TSpinEdit;
    FTxTextWpm: TSpinEdit;
    FTxToneHz: TSpinEdit;
    FTxVolume: TTrackBar;
    FTxNoise: TTrackBar;
    FTxSend: TButton;
    FTxStop: TButton;
    FTxSave: TButton;
    FTxVerify: TButton;
    FTxProgress: TProgressBar;
    FTxCurrentChar: TLabel;
    FTxCurrentCode: TLabel;
    FTxSummary: TLabel;
    { 送信音を作れなかったか。**作れなかったときの行は例外の原文なので、
      言語を変えても組み直しません。**
      Whether the transmit audio could not be made. **The line then holds the
      exception's own text, so a language change does not rebuild it.** }
    FTxRenderFailed: Boolean;
    { 滝に出している案内（`RsWfIdle` か `RsWfWaiting`）。
      The note the waterfall shows (`RsWfIdle` or `RsWfWaiting`). }
    FWfMessage: PResString;
    { 無線機で送る（要件 FR-T）。**鍵を触るのは `FKeyer` のスレッドだけ**で、
      画面は `Snapshot` を読むだけです。
      Sending through the rig (requirement FR-T). **Only `FKeyer`'s thread
      touches the key**; the screen only reads `Snapshot`. }
    FKeyer: TRigKeyer;
    FTxStage: TComboBox;
    FTxTemplate: TComboBox;
    FTxTheirCall: TEdit;
    FTxRst: TEdit;
    FRigConnect: TButton;
    FRigDisconnect: TButton;
    FRigSend: TButton;
    FRigStop: TButton;
    { 電源を入れる（要件 FR-T.6）。応答が無いときだけ押せます。
      Power on (FR-T.6); enabled only while the rig does not answer. }
    FRigPower: TButton;
    FRigStatus: TLabel;
    { 状態・電源の結果の移り変わりを 1 度だけ言うため。
      To announce each change of state and power result once. }
    FRigLastState: TKeyerState;
    FRigLastPower: TPowerResult;
    FRigLastRefusals: Integer;
    FRigAutoConnectPending: Boolean;
    { 同じ失敗を診断へ 2 度書かないため。/ Not to log the same failure twice. }
    FRigFaultLogged: Boolean;
    FRigStopNoted: Boolean;
    FSetRigModel: TSpinEdit;
    FSetRigPort: TEdit;
    FSetRigBaud: TComboBox;
    FSetMyCall: TEdit;
    FSetTemplates: TMemo;
    { 送っている間は復号を止めるか（要件 FR-T.4）。/ Whether decoding pauses
      while sending (FR-T.4). }
    FSetMuteRx: TCheckBox;
    FTxGate: TTxReceiveGate;
    { 詳しい接続設定（要件 FR-T.5）と、起動したら繋ぐ（FR-T.6）。
      Detailed connection settings (FR-T.5) and connect at start (FR-T.6). }
    FSetRigCivAddr: TEdit;
    FSetRigDataBits: TComboBox;
    FSetRigStopBits: TComboBox;
    FSetRigParity: TComboBox;
    FSetRigHandshake: TComboBox;
    FSetRigDtr: TComboBox;
    FSetRigRts: TComboBox;
    FSetRigTimeout: TSpinEdit;
    FSetRigWriteDelay: TSpinEdit;
    FSetRigPostDelay: TSpinEdit;
    FSetRigAutoConnect: TCheckBox;
    { 無線機の周波数を記録とバンドに使うか（要件 FR-T.7）。使っている間は
      バンドの選択を無線機に合わせ、運用者の選択は `FManualBand` に控えます。
      Whether the rig's frequency sets the log and the band (FR-T.7). While it
      does, the band choice follows the rig and the operator's own choice is
      kept in `FManualBand`. }
    FSetRigUseFreq: TCheckBox;
    { 記録する RST（要件 FR-E.11）。受けたものは読めた RST、送ったものは送信
      タブの RST が入り、**打てばそちらが勝ちます**（`*Typed`）。
      The reports to record (FR-E.11): received from the RST read, sent from
      the transmit tab's RST; **what is typed wins** (`*Typed`). }
    FRxRstRcvd: TEdit;
    FRxRstSent: TEdit;
    FRxRstInfo: TLabel;
    FRstRcvdTyped: Boolean;
    FRstSentTyped: Boolean;
    FRstFilling: Boolean;
    { 最後に記録した交信の時点の、受信テキストの長さ。受けた RST はこれより
      後ろからだけ採ります（付録 BW.1）。受信テキストを空にする・入れ替える
      ときに 0 へ戻します。
      The received text's length when the last contact was logged; the RST
      received is taken only from after it (appendix BW.1). Reset to 0 whenever
      the received text is emptied or replaced. }
    FRstFromChar: Integer;
    { 受けた RST の読み取り。受信テキストか境が変わるときにだけ読み直します。
      0.2 秒ごとの `UpdateLogInfo` で毎回読むと、長い受信で画面のスレッドを
      無駄に使います（付録 BW.3）。
      The RST received, read again only when the received text or the boundary
      changes; reading it on every 0.2 s `UpdateLogInfo` would spend the UI
      thread for nothing on a long reception (appendix BW.3). }
    FRstRead: TExchangeSpan;
    { 地方時を OS に合わせた時刻（`GetTickCount64`、未解決 #20・付録 BW.4）。
      When local time was last aligned with the OS (`GetTickCount64`; open
      question #20, appendix BW.4). }
    FClockSyncedAt: QWord;
    FRigBandActive: Boolean;
    FRigBandName: string;
    FManualBand: Integer;
    { 拡張の受け口（要件 FR-W・FR-N）。中身は保留。
      The extension seats (FR-W, FR-N); their contents are pending. }
    FSetAlphabet: TComboBox;
    FSetNoise: TComboBox;
    { 復号へ渡す音に掛けるノイズ低減。**画面のスレッドだけが使います。**
      The noise reduction applied to audio handed to the decoder. **Used on the
      UI thread only.** }
    FReducer: TNoiseReducer;

    { 受信タブ / receive tab }
    FRxFile: TEdit;
    FRxBrowse: TButton;
    FRxDecodeFile: TButton;
    FRxStart: TButton;
    FRxStop: TButton;
    FRxClear: TButton;
    FRxConfirmSpeed: TComboBox;
    FRxAntiAlias: TCheckBox;
    FRxTranscript: TTranscriptView;
    FRxSheet: TTabSheet;
    { ウォーターフォールの枠。受信テキストに高さを譲るために手元に控えます
      （付録 BV.4）。/ The waterfall's panel, kept to hand so that it can give
      height to the received text (appendix BV.4). }
    FRxWaterfallPanel: TPanel;
    FAdjustingLayout: Boolean;
    FRxShowDoubt: TCheckBox;
    FRxAlign: TCheckBox;
    FRxDoubtStrength: TTrackBar;
    FRxFontSize: TSpinEdit;
    FRxCopy: TButton;
    FRxCopyCall: TButton;
    FRxLevel: TProgressBar;
    FRxSignal: TLabel;
    FRxDevice: TComboBox;
    FRxDeviceRefresh: TButton;
    FRxWaterfall: TWaterfallView;
    FRxBandMap: TBandMapView;
    FRxMode: TComboBox;
    FRxWorked: TButton;
    FRxLogInfo: TLabel;
    { 待機モードでだけ現れる行。待つ符号を書くところです（要件 FR-I.4）。
      A row that appears only in the waiting mode, holding the call signs waited
      for (requirement FR-I.4). }
    FWatchTools: TPanel;
    FRxWatch: TEdit;
    FRxWatchInfo: TLabel;
    { 待っていた局を音でも知らせるか（未解決 #21、付録 BY）。既定は切。
      Whether to sound a chime for a station waited for too (open question #21,
      appendix BY); off by default. }
    FRxWatchSound: TCheckBox;
    { 最後に合図を鳴らした時刻（`GetTickCount64`、0 ならまだ）と、合図の音。
      When the chime last sounded (`GetTickCount64`, zero for never) and the
      chime itself. }
    FWatchSoundAt: QWord;
    { 自動の帯域で、ファイルに最後に掛けた幅とそのときの同調、画面に出して
      いる幅（付録 CC）。
      The automatic width last applied to a file, the tuning it was worked out
      for, and the width on screen (appendix CC). }
    FFileAutoHalf: Double;
    FFileAutoTune: Double;
    FShownHalf: Double;
    FWatchChime: TSingleArray;
    { コンテストモードでだけ現れる行（要件 FR-I.5）。
      A row that appears only in the contest mode (requirement FR-I.5). }
    FFindTools: TPanel;
    FContestTools: TPanel;
    FRxBand: TComboBox;
    FRxHideWorked: TCheckBox;
    FRxRate: TLabel;
    FRxTuneInfo: TLabel;
    FRxTuneClear: TButton;
    { 復調音のモニタ再生（要件 FR-A.6） / monitor playback of the decoded audio }
    FRxMonitor: TButton;
    FRxTrack: TCheckBox;
    FRxBusy: TLabel;
    FRxReplay: TButton;
    FRxReplayStop: TButton;
    FRxReplayInfo: TLabel;
    { 相手局の JCC/JCG（要件 FR-E.7）。手で打ちます——この機械は市区町村の
      一覧を持ちません（同梱しない方針）。
      The contacted station's JCC/JCG (requirement FR-E.7), typed by hand: this
      machine carries no list of cities and guns, and is not to. }
    FRxSubdivision: TEdit;
    FRxSubdivisionInfo: TLabel;
    FRxFind: TEdit;
    FRxFindPrev: TButton;
    FRxFindNext: TButton;
    FRxFindInfo: TLabel;

    { 設定タブ / settings tab }
    FSetModel: TEdit;
    FSetMetadata: TEdit;
    FSetRuntime: TEdit;
    FSetPortAudio: TEdit;
    FSetCaptureRate: TComboBox;
    FSetThreads: TComboBox;
    FSetBandwidth: TComboBox;
    FSetRetention: TComboBox;
    FSetLanguage: TComboBox;
    FSetLanguageInfo: TLabel;
    { 設定ファイルに覚えてあった言語の鍵と、この回に利用者が選び直したか。
      **命令行の `--lang` は 1 度きりなので、選び直さない限り覚えてあった方を
      書き戻します**（`UiLangFromCommandLine`）。
      The language key the settings file held, and whether the operator chose
      again this run. **A command-line `--lang` is for one run, so unless they
      chose again the remembered one is written back** (`UiLangFromCommandLine`). }
    FLangRemembered: string;
    { 文字の幅を測るための画布です。**窓がまだ無くても測れます。**
      A canvas to measure text on; **it works before any window exists.** }
    FMeasure: TBitmap;
    FLangChosenHere: Boolean;
    FSetJournal: TCheckBox;
    { 受信練習（要件 FR-F.3）。**出題は隠しておき、答え合わせのときだけ見せます。**
      Receive practice (requirement FR-F.3). **The exercise is kept out of sight
      until the copy is marked.** }
    FPrKind: TComboBox;
    FPrGroups: TSpinEdit;
    FPrWpm: TSpinEdit;
    FPrNoise: TTrackBar;
    { 遅延表示（要件 FR-F.4）。**鳴った文字を、決めた秒数だけ遅らせて出します。**
      Delayed reveal (requirement FR-F.4): **each character appears the set
      number of seconds after it has sounded.** }
    FPrDelay: TCheckBox;
    FPrDelaySeconds: TSpinEdit;
    FPrPlay: TButton;
    FPrAgain: TButton;
    FPrStop: TButton;
    FPrMark: TButton;
    FPrSummary: TLabel;
    FPrCopy: TMemo;
    FPrResult: TLabel;
    FPrAnswer: TMemo;
    FPrMistakes: TLabel;
    { これまでの練習から見える傾向（要件 FR-F.5）。**1 回ぶんの結果とは別の
      行に置きます。**同じ行に足すと、どちらが今回の話なのか読めません。
      The tendency across past sessions (requirement FR-F.5), on a row of its
      own: added to the same row, there would be no telling which part is about
      this session. }
    FPrHistory: TLabel;
    FPrText: string;
    FPrSamples: TSingleArray;
    { 各文字を見せてよい時刻（音の先頭から）と、鳴らし始めた時刻。
      **時刻は鳴らし始めから測ります。**鳴り終わったあとにも、遅れた分の文字が
      残っているためです。
      When each character may be shown, counted from the start of the sound, and
      when the sound was started. **The clock runs from the start**: after the
      sound ends, the delayed characters are still to come. }
    FPrRevealTimes: TDoubleArray;
    FPrRevealFrom: TDateTime;
    FPrRevealing: Boolean;
    { 送信訓練（要件 FR-H）。**電波は出しません。**無線機のモニタートーンを
      受信と同じ入力から取り込むだけです。
      Send practice (requirement FR-H). **Nothing is transmitted**: the
      transceiver's monitor tone is taken in through the same input as
      reception. }
    FFtKind: TComboBox;
    FFtGroups: TSpinEdit;
    FFtKey: TComboBox;
    FFtBasis: TComboBox;
    FFtFree: TCheckBox;
    FFtNew: TButton;
    FFtStart: TButton;
    FFtStop: TButton;
    FFtWav: TButton;
    FFtStatus: TLabel;
    FFtText: TMemo;
    FFtResult: TMemo;
    FFtAdvice: TLabel;
    FFtHistory: TMemo;
    FFtCapture: TAudioCapture;
    FFtRing: TAudioRing;
    FFtRate: Integer;
    FFtExercise: string;
    FFtBegan: TDateTime;
    { 採点しようとしている音と、その測定。**文字誤り率は別のスレッドで
      あとから届くので、その間これを持っておきます。**
      The audio being scored and its measurement. **The character error rate
      arrives later from another thread, so these wait here meanwhile.** }
    { 推移（要件 FR-H.10）。**1 回の点数はその日の調子で、上達は並べて
      はじめて分かります。**
      The trend (requirement FR-H.10): **one session's score is how that day
      went; improvement appears only once they are lined up.** }
    FFtTrend: TFistTrendView;
    FFtTrendItem: TComboBox;
    FFtTrendKey: TComboBox;
    FFtStreak: TLabel;
    { 分布（要件 FR-H.9）。**点数の元になった分布そのものを見せます。**
      The distributions (requirement FR-H.9): **the very thing the score came
      from.** }
    FFtHistogram: TFistHistogramView;
    FFtBottomKind: TComboBox;
    { 前回選んでいた鍵。一覧は記録から作り直すので、**選び直せるように名前で
      持っておきます。**
      The key chosen last time. The list is rebuilt from the records, so **the
      name is kept in order to choose it again.** }
    FFtTrendKeyWanted: string;
    FFtSamples: TSingleArray;
    FFtMeasured: TFistMeasurement;
    FFtLost: Boolean;
    FSetCopyInfo: TButton;
    FSettingsSheet: TTabSheet;
    FSetRecord: TCheckBox;
    FSetRecordInfo: TLabel;
    FSetLogImport: TButton;
    FSetLogExport: TButton;
    FSetLogInfo: TLabel;
    { 手元の呼出符号一覧（要件 FR-K.9）。利用者が選んだファイルだけを読みます。
      The locally held call sign roster (requirement FR-K.9); only a file the
      operator picked is read. }
    FRoster: TCallsignRoster;
    FSetRoster: TButton;
    FSetRosterClear: TButton;
    FSetRosterInfo: TLabel;
    FRosterFile: string;
    { 国別前置符字表（要件 FR-K.12）。**形は満たすがどの国にも割り当てられて
      いない前置符字**を弾くために使います。
      The country prefix table (requirement FR-K.12), used to reject a prefix
      that **fits the form but is allocated to no country.** }
    FPrefixes: TPrefixTable;
    FSetPrefixes: TButton;
    FSetPrefixesClear: TButton;
    FSetPrefixesInfo: TLabel;
    FPrefixFile: string;
    { 高コントラスト表示（要件 NFR-5.5）。
      High contrast (requirement NFR-5.5). }
    FSetHighContrast: TCheckBox;
    { 利用者が「受信」を望んでいるか（要件 NFR-4.4）。**装置が外れて止まったのか、
      利用者が止めたのか**を分けます。前者なら待って、つながり次第また始めます。
      Whether the operator wants to be receiving (requirement NFR-4.4). It tells
      **a stop caused by the device from a stop the operator asked for**: the
      first waits and starts again as soon as the device is there. }
    FWantCapture: Boolean;
    { 待っているか、何回試したか、最後に試した時刻、最後に知らせた時刻。

      回数は**利用者が押してからの累計**で、一瞬つながっても戻しません。
      戻すと、点滅する装置で数が振り出しに戻り続けます（実測）。

      Whether waiting, how many attempts, when the last one was, and when the
      operator was last told.

      The count runs **from the operator's press** and does not fall back when
      the device flickers: it would otherwise keep starting over (measured). }
    FWaiting: Boolean;
    FRetryCount: Integer;
    FLastRetryAt: TDateTime;
    FSaidDeviceAt: TDateTime;
    FSetApply: TButton;
    FSetInfo: TMemo;

    procedure BuildUI;
    function BuildTransmitTab: TTabSheet;
    function BuildReceiveTab: TTabSheet;
    function BuildSettingsTab: TTabSheet;
    function BuildPracticeTab: TTabSheet;

    { 受信練習（要件 FR-F.3） / receive practice }
    function PracticeKind: TExerciseKind;
    procedure PrRender;
    procedure PrOptionsChanged(Sender: TObject);
    function CopyLogFileName: string;
    procedure PrShowHistory;
    procedure PrPlayClick(Sender: TObject);
    procedure PrAgainClick(Sender: TObject);
    procedure PrStopClick(Sender: TObject);
    procedure PrMarkClick(Sender: TObject);
    procedure UpdatePracticeReveal;
    procedure SetCopyInfoClick(Sender: TObject);
    function BuildFistTab: TTabSheet;
    function FistLogFileName: string;
    function FistBasis: TFistStandard;
    function FistOwnTarget: TFistTarget;
    procedure FtNewClick(Sender: TObject);
    procedure FtStartClick(Sender: TObject);
    procedure FtStopClick(Sender: TObject);
    procedure FtWavClick(Sender: TObject);
    procedure FtOptionsChanged(Sender: TObject);
    procedure FtScore(const Samples: TSingleArray; SampleRate: Integer;
      Seconds: Double);
    procedure FtFinish(Cer: Double);
    procedure FtShowHistory;
    procedure FtTrendChanged(Sender: TObject);
    procedure FtBottomChanged(Sender: TObject);
    procedure FtShowTrend(const Items: TFistRecords);

    function ConfigFileName: string;
    procedure LoadSettings;
    { 設定ファイルに覚えてある言語の鍵。無ければ空です。**画面を組む前に**読む
      ためのものです（`LoadSettings` は画面の部品を触るので、その前には呼べません）。
      The language key remembered in the settings file, or empty. **Read before
      the screen is built** (`LoadSettings` touches controls, so it cannot run
      that early). }
    function RememberedUiLang: string;
    { 診断情報の記録の 1 行か。**起きたときの言語のまま残る記録**なので、切替の
      検査から除きます（状態欄と同じ扱い。付録 BQ）。
      Whether a line is a diagnostics record. **A record stays in the language it
      was made in**, so the switch checks leave it out (as with the status bar;
      appendix BQ). }
    function IsDiagnosticRecord(const Line: string): Boolean;
    procedure SaveSettings;
    procedure MarkSettingsDirty;
    procedure ApplySettings(Sender: TObject);
    procedure RefreshInfo;

    function EnsureDecoder(Silent: Boolean = False): Boolean;
    function SelectedThreads: Integer;
    function SelectedCaptureRate: Integer;
    function DecoderBusy: Boolean;
    procedure StartDecode(const Samples: TSingleArray; SampleRate: Integer);
    procedure ShowStreamText;
    procedure DecodeFinished(Sender: TObject);
    procedure FileLoaded(Sender: TObject);
    procedure FileShaped(Sender: TObject);
    function DecoderShaping: TDecoderShaping;
    function PrepareForDecoder(const Samples: TSingleArray; SampleRate: Integer): TSingleArray;

    procedure TxTextChanged(Sender: TObject);
    procedure TxOptionsChanged(Sender: TObject);
    procedure RenderTransmit;
    procedure UpdateTxSummary;
    procedure TxAutoClick(Sender: TObject);
    procedure TxTemplateClick(Sender: TObject);
    procedure TxFromRxClick(Sender: TObject);
    procedure ComposeInto(const Template: string);
    procedure RefreshTemplates;
    procedure SetTemplatesChanged(Sender: TObject);
    function RigSettings: TRigSettings;
    procedure RigConnectClick(Sender: TObject);
    procedure RigDisconnectClick(Sender: TObject);
    procedure RigSendClick(Sender: TObject);
    procedure RigStopClick(Sender: TObject);
    procedure UpdateRigStatus;
    procedure FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure SettingChanged(Sender: TObject);
    procedure ExtensionChanged(Sender: TObject);
    function ForDecoderAudio(const Samples: TSingleArray; SampleRate: Integer): TSingleArray;
    function ReceiveMutedForTx: Boolean;
    procedure CheckTranscriptHeight(Problems: TStringList);
    procedure RxTranscriptResized(Sender: TObject);
    function RigReading(out FreqHz: Double; out Mode: string): Boolean;
    function OperatingBand: string;
    procedure UpdateRigBand;
    procedure RigPowerClick(Sender: TObject);
    function RigConfFromScreen: TRigConf;
    procedure RigConfToScreen(const Conf: TRigConf);
    procedure TxSendClick(Sender: TObject);
    procedure TxStopClick(Sender: TObject);
    procedure TxSaveClick(Sender: TObject);
    procedure TxVerifyClick(Sender: TObject);

    { 交信の記録（要件 FR-E.3・FR-J.4） / the contact log }
    function LogFileName: string;
    { バンドマップから引く「交信済みか」。呼出符号だけを渡します。
      The worked-before lookup the band map uses, given only a call sign. }
    function WorkedBefore(const Callsign: string): Boolean;
    procedure RxWorkedClick(Sender: TObject);
    procedure RxSubdivisionChanged(Sender: TObject);
    procedure RxRstChanged(Sender: TObject);
    procedure TxRstChanged(Sender: TObject);
    procedure ReadRst;
    procedure FillRstFields;
    { 画面の言語を変えます（要件 NFR-7.6）。**押したその場で入れ直します。**
      Changes the language of the screen (NFR-7.6), **putting the words back in
      place as it is chosen.** }
    procedure SetLanguageChanged(Sender: TObject);
    { 控えてある文言を、いまの言語で入れ直します。控えに載らないもの
      （実行中に組み立てる文）は、ここで出し直します。
      Puts the noted words back in the current language. What the notes do not
      cover -- sentences built while running -- is re-rendered here. }
    procedure ApplyTexts;
    procedure SetLogImportClick(Sender: TObject);
    procedure SetLogExportClick(Sender: TObject);
    procedure UpdateLogInfo;
    { いま記録に残せる呼出符号。交信モードでは受信テキストから、待機モードでは
      選ばれている行から取ります。無ければ空です。
      The call sign that could be logged now: from the transcript in the contact
      mode and from the chosen row in the waiting mode, or empty. }
    { 帯域全体を読むモードか。待機とコンテストは読み方が同じで、見せ方だけが
      違います。**分岐を「待機か」で書くと、コンテストモードで受信そのものが
      止まります。**
      Whether the whole band is read. The waiting and contest modes read the same
      way and differ only in what they show; **branching on "is it the waiting
      mode" would stop reception itself in the contest mode.** }
    function BandMode: Boolean;
    function CallsignToLog: string;
    procedure ReadTranscript;
    procedure AnnounceReference;
    procedure UpdateTranscriptMessage;
    function InRoster(const Callsign: string): string;
    procedure SetRosterClick(Sender: TObject);
    procedure SetRosterClearClick(Sender: TObject);
    procedure LoadRoster(const FileName: string);
    procedure UpdateRosterInfo;
    procedure SetPrefixesClick(Sender: TObject);
    procedure SetPrefixesClearClick(Sender: TObject);
    procedure LoadPrefixes(const FileName: string);
    procedure UpdatePrefixesInfo;
    procedure HighContrastChanged(Sender: TObject);
    procedure ApplyHighContrast;
    procedure BeginCapture;
    procedure RetryCapture;
    procedure ShowStationLabels;
    function SelectedBand: string;
    function WithoutWorked(const Entries: TBandEntries): TBandEntries;
    procedure RxContestChanged(Sender: TObject);
    procedure UpdateRate(Force: Boolean = False);
    function WatchedCall(const Callsign: string): string;
    procedure RxWatchChanged(Sender: TObject);
    procedure RxWatchSoundChanged(Sender: TObject);
    procedure SoundWatched;
    procedure AnnounceWatched;
    procedure UpdateWatchInfo;
    procedure RxCopyCallClick(Sender: TObject);

    { 受信のしかた（要件 FR-I.6・FR-J） / how reception is used }
    procedure RxModeChanged(Sender: TObject);
    procedure RxStationChosen(Sender: TObject; Id: Int64; Hz: Double);
    procedure ApplyMode;
    procedure RefreshBandMap;
    { いま動いている機械の時計。受信開始からの通算秒です。聴き直しも記録も
      これを原点にします。
      The clock of whichever machine is running: seconds since reception began.
      Replay and the journal both take their origin from it. }
    function ActiveElapsedSeconds: Double;

    { 検索（要件 FR-B.5） / search (requirement FR-B.5) }
    procedure RxFindChanged(Sender: TObject);
    procedure RxFindNextClick(Sender: TObject);
    procedure RxFindPrevClick(Sender: TObject);
    procedure RxFindKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure UpdateFindInfo;

    { 記録（要件 FR-B.6） / the journal (requirement FR-B.6) }
    procedure RxJournalChanged(Sender: TObject);
    function JournalDirectory: string;
    procedure RxRecordChanged(Sender: TObject);
    function RecordingDirectory: string;
    procedure StartRecording;
    procedure StopRecording(const Why: string);
    procedure UpdateRecording;
    procedure UpdateRecordInfo;
    { 置き場所をラベルの残りの幅へ収めます（要件 NFR-5.1）。
      Fits a location into what is left of a label's width (NFR-5.1). }
    function FitPath(Lbl: TLabel; const Path, Around: string): string;
    procedure OperatingResized(Sender: TObject);
    procedure SetRecordStatus(const Shown: string);
    procedure JournalConfirmed;

    { 聴き直し（要件 FR-E.10） / replay (requirement FR-E.10) }
    procedure RxCharChosen(Sender: TObject; Index: Integer);
    procedure RxReplayClick(Sender: TObject);
    procedure RxReplayStopClick(Sender: TObject);
    procedure RxRetentionChanged(Sender: TObject);
    procedure ReplayFrom(Index: Integer);
    function WordSpan(Index: Integer; out First, Last: Integer;
      out FromSeconds, ToSeconds: Double): Boolean;
    procedure RequestRecheck(Index: Integer);
    procedure TryStartRecheck;
    procedure ShowRecheck(const Chars: TDecodedChars);
    function SelectedRetention: Double;
    procedure UpdateReplayInfo;

    procedure RxBrowseClick(Sender: TObject);
    procedure RxDecodeFileClick(Sender: TObject);
    procedure RxStartClick(Sender: TObject);
    procedure RxStopClick(Sender: TObject);
    procedure RxClearClick(Sender: TObject);
    procedure RxCopyClick(Sender: TObject);
    procedure RxDeviceRefreshClick(Sender: TObject);
    procedure RefreshDeviceList(const Preferred: string);
    function SelectedDeviceIndex: Integer;
    function SelectedDeviceName: string;
    procedure RxDisplayChanged(Sender: TObject);
    procedure RxConfirmSpeedChanged(Sender: TObject);
    procedure ApplyStreamSettings;
    function SelectedBandwidth: TTunerBandwidth;
    procedure RxTuneChanged(Sender: TObject);
    procedure RxBandwidthDragged(Sender: TObject);
    procedure RxTuneClearClick(Sender: TObject);
    procedure RxMonitorClick(Sender: TObject);
    procedure RxTrackChanged(Sender: TObject);
    procedure UpdateTuneInfo;

    procedure PagesChanged(Sender: TObject);
    procedure PollTimer(Sender: TObject);
    procedure UpdateTransmitProgress;
    procedure UpdateLiveReceive;
    procedure SetStatus(const Engine, Audio, Message_: string);
    procedure ReportError(const Context: string; E: Exception); overload;
    procedure ReportError(const Context, Raw: string); overload;
    procedure SyncClock;
    procedure LogDiagnostic(const Context, Raw: string);
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;

    { すべてのタブを順に前へ出し、そのつど組み方の破綻を数えます
      （要件 NFR-5.1）。**前へ出さないタブは数えられません。**隠れている
      部品の位置は、まだ決まっていないことがあるからです。

      戻り値は 1 件 1 行。空なら破綻なしです。

      Brings each tab to the front in turn and counts the layout breakages on
      it (requirement NFR-5.1). **A tab that is not brought forward cannot be
      counted**: a hidden control's position may not have been decided yet.

      One line per problem; empty means none. }
    function ReportLayout: TStringList;
    { 言語を往復させて、戻ってくるかを報告します（要件 NFR-7.6）。
      **日本語へ戻す道は、英語へ行く道と違います**（`UiLang` の頭書き）。
      取り違えると「一度英語にしたら戻れない」が起こり、**画面を開いて押して
      みるまで分かりません。**回帰試験が毎回押します。呼ぶ側が解放します。
      Takes the language out and back and reports (NFR-7.6). **The way back to
      Japanese is not the way out to English** (see the head of `UiLang`);
      mistake it and the application cannot return once it has gone, which
      shows only when someone opens the screen and tries. The regression tries
      it every time. The caller frees the list. }
    function ReportLanguage: TStringList;
    { ファイルを「デコード」と同じ道で読み、画面のスレッドが続けて塞がった
      いちばん長い時間を測ります（要件 NFR-4.2、計画 6.1 の P1）。`TuneHz` が
      正なら先に同調します。`LongestMs` が止まりの長さ、戻り値は報告の行です。
      Reads a file the way "decode" does and measures the longest stretch the UI
      thread stayed blocked (NFR-4.2, plan 6.1 P1). A positive `TuneHz` tunes
      first. `LongestMs` is the stall; the result is the report lines. }
    function ReportFileDecode(const FileName: string; TuneHz: Double;
      out LongestMs: Int64; out Decoded: string): TStringList;
  end;

var
  MainForm: TMainForm;

implementation

{ 画面に出す文言です（要件 NFR-7.6）。

  **ソースから分け、`.po` で見直せるようにします。**訳を足すのに再ビルドは
  要りません。`.po` が無ければ、ここに書いた日本語のまま動きます（fail-soft）。

  識別子の頭は、その文言が出るタブに合わせてあります——`Rx` 受信、`Tx` 送信、
  `Pr` 受信練習、`Ft` 送信訓練、`Set` 設定。**部品の名前と同じ並びにしてあるので、
  訳す人は画面と突き合わせられます。**

  **訳すときの制約は幅です。**部品の大きさは日本語に合わせて決めてあり、訳が
  広ければ入りません。日本語の全角は 14 画素、英字は 7 画素なので、目安は
  **英字の文字数を日本語の 2 倍まで**。`TextCheck` が `.po` を読んで数え、
  `LayoutCheck` が実物で入るかどうかを数えます（付録 BC）。

  The words shown on screen (requirement NFR-7.6).

  **They are kept out of the source and revised through a `.po`**, so a
  translation needs no rebuild. With no `.po` the application runs in the
  Japanese written here (fail-soft).

  The identifiers are prefixed by the tab the words appear on -- `Rx` receive,
  `Tx` transmit, `Pr` copy practice, `Ft` send practice, `Set` settings --
  matching the names of the controls themselves, **so a translator can follow
  them against the screen.**

  **The constraint when translating is width.** The controls were sized for the
  Japanese and a wider translation does not fit. A full-width Japanese character
  is 14 pixels and a Latin one is 7, so the rule of thumb is **up to twice the
  Japanese character count**. `TextCheck` counts this from the `.po` and
  `LayoutCheck` counts, on the real screen, whether it fits (appendix BC). }
resourcestring
  { 受信タブ / the receive tab }
  RsRxTab = '受信';
  RsRxFromWav = 'WAV ファイルから受信';
  RsRxDecode = 'デコード';
  RsRxBrowse = '参照...';
  RsRxFromInput = 'マイク / ライン入力から受信';
  RsRxInputLevel = '入力レベル';
  RsRxStart = '受信開始';
  RsRxStop = '受信停止';
  RsRxClear = '表示をクリア';
  RsRxDevice = '入力装置';
  RsRxRescan = '再検出';
  RsRxSettleLabel = '文字が決まるまで';
  RsRxSettleFast = '速さ優先';
  RsRxSettleNormal = '標準';
  RsRxSettleSure = '確実さ優先';
  RsRxModeLabel = '受信のしかた';
  RsRxModeContact = '交信モード';
  RsRxModeWatch = '待機モード';
  RsRxModeContest = 'コンテスト';
  RsRxDenoise = '帯域外の雑音を抑える';
  RsRxTuneHint = '読みたい信号をクリック。ホイールで微調整。';
  RsRxUntune = '同調を解除';
  RsRxMonitor = '復調音を聴く';
  RsRxFollow = '信号を自動で追う';
  RsRxText = '受信テキスト';
  RsRxShade = '確からしさを濃淡で示す';
  RsRxShadeAmount = '濃淡';
  RsRxFontSize = '文字の大きさ';
  RsRxCopy = 'コピー';
  RsRxCallAndRst = '符号と RST';
  RsRxOverlay = '文字を波形に重ねる';
  RsRxFind = '検索';
  RsRxLogContact = '交信を記録';
  RsRxReplay = 'もう一度聴く';
  RsRxReplayStop = '停止';
  RsRxReplayHint = '文字を押すと、その音を聴き直せます。';
  RsRxEmpty = '受信を開始すると、ここに読めた文字が出ます。';
  RsRxWatchLabel = '待つ符号';
  { 待っていた局を音でも知らせる（未解決 #21、付録 BY）。
    Sound a chime for a station waited for too (open question #21,
    appendix BY). }
  RsRxWatchSound = '音でも知らせる';
  RsCtxWatchSound = '待ち符号の合図';
  RsRxBandLabel = '運用バンド';
  RsRxBandAny = '指定なし';
  RsRxHideWorked = '交信済みを隠す';

  { 送信タブ / the transmit tab }
  RsTxTab = '送信';
  RsTxTextLabel = '送信する文（A-Z 0-9 . , ? / と空白）';
  RsTxMorse = 'モールス符号';
  RsTxSettings = '送信設定';
  RsTxCharWpm = '文字速度 (WPM)';
  RsTxTextWpm = '実効速度 (WPM)';
  RsTxToneHz = '音程 (Hz)';
  RsTxVolume = '音量';
  RsTxNoise = '受信練習用ノイズ';
  { **電波は出しません。**PC で音を鳴らすだけです。無線機で送るボタンが
    隣に来たので「送信」から改めました（取り違えると危ないため）。
    **No signal goes on air**: this only plays the sound on the PC. Renamed
    from "送信" (send) once a real transmit button stood beside it, since
    confusing the two is dangerous. }
  RsTxSend = '音で鳴らす';
  RsTxStop = '停止';
  RsTxSaveWav = 'WAV に保存';
  RsTxVerify = '自己デコード確認';
  RsTxSending = '送信中の文字';

  { 受信練習タブ / the copy-practice tab }
  RsPrTab = '練習';
  RsPrExercise = '出題';
  RsPrKind = '出す内容';
  RsPrGroups = '出す数';
  RsPrWpm = '速度 (WPM)';
  RsPrNoise = '雑音';
  RsPrToneNote = '音程と音量は送信タブの設定を使います。';
  RsPrDelay = '遅らせて正解を出す';
  RsPrDelaySeconds = '遅らせる秒数';
  RsPrDelayNote = '鳴った文字が、この秒数だけ遅れて「正解」に出ます。';
  RsPrPlay = '出題して鳴らす';
  RsPrAgain = 'もう一度鳴らす';
  RsPrStop = '止める';
  RsPrStartHint = '「出題して鳴らす」を押すと始まります。';
  RsPrCopyLabel = '写した文字を書いてください';
  RsPrMark = '答え合わせ';
  RsPrAnswer = '正解';

  { 送信訓練タブ / the send-practice tab }
  RsFtTab = '送信訓練';
  RsFtTextAndScore = '課題文と採点';
  RsFtKind = '課題文の内容';
  RsFtGroups = '出す数';
  RsFtKeyKind = '鍵の種類';
  RsFtBasis = '採点の基準';
  RsFtBasisNote = '基準は「正しさ」ではありません。バグキーの符号は、バグキーの基準で測ります。';
  RsFtFree = '課題文なしで送る（採点は参考値）';
  RsFtNew = '課題文を出す';
  RsFtStart = '訓練開始';
  RsFtFinish = '終了して採点';
  RsFtFromWav = 'WAV から採点';
  RsFtStartHint = '「課題文を出す」を押し、無線機のモニター音が届く状態で「訓練開始」を押してください。';
  RsFtTextLabel = '課題文（この文を自分の鍵で送ってください。書き換えられます）';
  RsFtScore = '採点';
  RsFtHistory = 'これまでの記録';
  RsFtBottomLabel = '下に出すもの';
  RsFtTrend = '推移';
  RsFtHistogram = '分布';
  RsFtTrendItemLabel = '推移に出す項目';
  RsFtOverall = '総合';
  RsFtAllItems = '5 項目すべて';
  { **この「すべて」は控えに載せません。**推移の絞り込みは記録から組み直される
    ので、組み直す側（`FtShowTrend`）が入れ直します（付録 BE.2）。
    **This `すべて` is not noted down**: the trend's filter is rebuilt from the
    records, so whatever rebuilds it puts it back (`FtShowTrend`, appendix
    BE.2). }
  RsFtAnyKey = 'すべて';

  { 設定タブ / the settings tab }
  RsSetTab = '設定';
  RsSetOperating = '運用設定';
  RsSetCaptureRate = '音の細かさ';
  RsSetRate8000 = '8000 Hz（推奨）';
  RsSetCaptureNote = '受信機の音を取り込む細かさです。うまく取り込めないときだけ変えてください。';
  RsSetRetention = '聴き直せる長さ';
  RsSetRetention5 = '5 分';
  RsSetRetention10 = '10 分（推奨）';
  RsSetRetention20 = '20 分';
  RsSetRetention30 = '30 分';
  RsSetRetentionNote = '受信テキストの文字を押して音を聴き直せる範囲です。長くするほど記憶を使います。';
  RsSetJournal = '受信テキストを時刻付きで記録する';
  RsSetJournalNote = '確定するそばからファイルへ書き足します。異常終了しても直前まで残ります。';
  RsSetRecord = '受信した音を WAV で録音する';
  RsSetLog = '交信記録';
  RsSetAdifImport = 'ADIF を取り込む';
  RsSetAdifExport = 'ADIF を書き出す';
  RsSetRoster = '呼出符号の一覧';
  RsSetChooseFile = 'ファイルを選ぶ';
  RsSetDontUse = '使わない';
  RsSetPrefixes = '国別前置符字表';
  RsSetHighContrast = '高コントラスト表示（薄い文字を濃くする）';
  RsSetHighContrastNote = '確からしさの濃淡は残りますが、幅は狭くなります';
  { **この行だけは訳しません。**読める言語を探している人が、読めない言語で
    書かれた見出しを探すことになります（付録 BD.2）。
    **This one line is not translated**: someone hunting for a language they can
    read would be hunting under a heading in one they cannot (appendix BD.2). }
  RsSetLanguage = '画面の言葉 / Language';
  RsSetAdvanced = '詳細・診断';
  RsSetApply = '設定を適用してエンジンを読み込み直す';
  RsSetThreads = '推論スレッド';
  RsSetAuto = '自動';
  RsSetBandwidth = '同調時の帯域幅';
  RsSetModel = 'モデル (model.onnx)';
  RsSetMetadata = 'メタデータ (model.onnx.json)';
  RsSetRuntime = 'ONNX Runtime ライブラリ（空欄なら自動検索）';
  RsSetPortAudio = 'PortAudio ライブラリ（空欄なら自動検索）';
  RsSetCopyDiag = '診断情報をコピー';
  RsSetDiagNote1 = '受信した文章・交信記録の中身・待っている符号は入りません。';
  RsSetDiagNote2 = 'ファイルの場所の利用者名は ~ に置き換えます。';
  RsSetDiagnostics = '診断情報';

  { ── 実行中に出る文言 ── / words that appear while running ──

    **改行は `#10` で書きます。`LineEnding` を使ってはいけません。**
    `LineEnding` は OS で中身が変わる（Linux は `#10`、Windows は `#13#10`）ので、
    訳の一覧に載る綴りが OS ごとに変わり、**Windows では訳が当たらなくなります**
    （実測。付録 BH.1）。画面に出す直前に `AsLines` が OS の改行へ直します。

    **Line breaks are written as `#10`; never `LineEnding`.** Its contents
    differ by platform (`#10` on Linux, `#13#10` on Windows), so the spelling in
    the translation list would differ by platform and **the translations would
    not match on Windows** (measured; appendix BH.1). `AsLines` turns them into
    the platform's line ending just before they are shown. }

  { 困ったときに出る案内（`UserMessageFor`）。**何が起きたかだけでなく、
    いま何ができるかを書きます。**
    What is said when something goes wrong: **not only what happened, but what
    can still be done.** }
  RsErrPortAudio = '音声ライブラリ PortAudio を利用できません。'#10 +
    '同梱されていない場合は、設定タブでライブラリの場所を指定してください。'#10 +
    'WAV ファイルの読み書きは、この状態でも利用できます。';
  RsErrInputStream = 'マイク（ライン入力）を開けませんでした。'#10 +
    '別の入力装置を選ぶか、他のアプリが装置を使用していないか確認してください。';
  RsErrOutputStream = '再生装置を開けませんでした。'#10 +
    '別の出力装置を選ぶか、他のアプリが装置を使用していないか確認してください。';
  RsErrRuntime = '推論ライブラリ ONNX Runtime を読み込めませんでした。'#10 +
    '設定タブでライブラリの場所を指定してください。'#10 +
    '送信音の生成と WAV への保存は、この状態でも利用できます。';
  RsErrModelMissing = 'モデルファイル model.onnx が見つかりません。'#10 +
    '設定タブで場所を指定してください。';
  RsErrMetadataMissing = '設定ファイル model.onnx.json が見つかりません。'#10 +
    '設定タブで場所を指定してください。';
  RsErrMismatch = 'モデルと設定ファイルの組み合わせが正しくありません。'#10 +
    '同じ配布物に入っている model.onnx と model.onnx.json を指定してください。';
  RsErrWav = 'この音声ファイルを読み取れませんでした。'#10 +
    'PCM 形式のモノラルまたはステレオの WAV ファイルをお使いください。';
  RsErrTooShort = '音声が短すぎます。もう少し長い録音でお試しください。';
  RsErrOther = '問題が起きたため、処理を中止しました。'#10 +
    '詳しい内容は設定タブの診断情報に記録しています。';

  { 診断情報の欄（`RefreshInfo`）。**利用者が不具合報告に貼る中身**なので、
    読める言語で出します。
    The diagnostics panel: **what the operator pastes into a bug report**, so it
    is shown in a language they can read. }
  RsInfoEngineLoaded = 'エンジン: 読み込み済み';
  RsInfoEngineNotLoaded = 'エンジン: 未読み込み';
  RsInfoSampleRate = 'サンプリング周波数: %d Hz';
  RsInfoFftHop = 'FFT 長 / ホップ長: %0:d / %1:d';
  RsInfoBand = '周波数帯: %0:.0f - %1:.0f Hz (%2:d ビン)';
  RsInfoInOut = '入力 / 出力: %0:s / %1:s';
  RsInfoAlphabet = '文字集合 (%0:d): %1:s';
  RsInfoSeconds = '音声長の制約: %0:.0f - %1:.0f 秒（長い録音は自動的に分割）';
  RsInfoNoPortAudio = 'PortAudio: 利用不可（送信の再生とマイク受信は使えません）';
  RsInfoPending = '未解析の音声: %.1f 秒';
  RsInfoPace = '解析 1 回: %0:.2f 秒 / 実時間比 %1:.0f 倍 / 推論間隔 %2:.2f 秒';
  RsInfoDropped = '追いつけずに捨てた音声: %.1f 秒';
  RsInfoJournalOff = '受信テキストの記録: 取っていません';
  RsInfoJournalNotYet = '受信テキストの記録: %0:s（まだ書いていません）';
  RsInfoJournal = '受信テキストの記録: %0:s（%1:d 行 / %2:d バイト）';
  RsInfoNoLicences = '同梱の許諾条項: 見つかりません' +
    '（配布物ではなく、ビルドした木から動かしています）';
  RsInfoLicences = '同梱の許諾条項: %0:d 件（%1:s）';
  RsInfoLog = '交信記録: %0:d 件（%1:s）';
  RsInfoReplay = '聴き直せる音声: %0:.0f 秒 / 保持の上限 %1:.0f 分（約 %2:.0f MB）';
  RsInfoNoDevices = '入力装置: 見つかりません';
  RsInfoDevice = '入力装置 %0:d: %1:s [%2:s] %3:d ch / %4:.0f Hz%5:s';
  RsInfoDefaultMark = '  ← 既定';
  RsInfoConfigFile = '設定ファイル: %0:s';
  RsInfoDiagnostics = '診断情報（技術的な原文）';
  RsInfoEngineVersion = 'エンジン: ONNX Runtime %0:s';

  { 困ったときの見出し（`ReportError`）。**場面の名前**を `%s` に入れます。
    見出しと本文を 1 本の文字列につなげてしまうと、語順の違う言語で直せません
    （付録 BH.5）。
    The heading when something goes wrong: `%s` is the name of the occasion.
    Joining the heading and the name into one literal would leave a language
    with another word order no way to fix it (appendix BH.5). }
  RsErrFailedTitle = '%sできませんでした';
  RsErrStatusLine = '%0:s: %1:s';

  { 場面の名前。診断情報にも残るので、**画面と同じ言葉**にします。
    The names of the occasions. They are kept in the diagnostics too, so they
    are **the same words as on screen.** }
  RsCtxPractice = '練習';
  RsCtxPracticeLog = '受信練習の記録';
  RsCtxFistStart = '送信訓練の開始';
  RsCtxFistLog = '送信訓練の記録';
  RsCtxFistScore = '送信訓練の採点';
  RsCtxWavRead = 'WAV の読み込み';
  RsCtxRecheck = '語の読み直し';
  RsCtxDecode = 'デコード';
  RsCtxReceiveStop = '受信の終了';

  { 受信練習タブ（要件 FR-F.3・FR-F.5）。
    The copy practice tab (requirements FR-F.3, FR-F.5). }
  RsPrHistory = 'これまで %0:d 回 ／ 直近 10 回の平均 %1:.0f%%';
  RsPrConfusions = '%0:s ／ 続けて間違えている符号: %1:s';
  RsPrSummary = '%0:d 文字 / %1:.1f 秒';
  RsPrPlaying = '出題を鳴らしています。';
  RsPrNeedExercise = '先に「出題して鳴らす」を押してください。';
  RsPrResult = '正答率 %0:.0f%%（%1:d 文字中 %2:d 文字）／ 違い %3:d ・ 落とし %4:d ・ 足し %5:d';
  RsPrNoMistakes = '間違いはありません。';
  RsPrMistakes = '間違えやすかった符号: %s';
  RsPrNoSound = '音を鳴らせませんでした。正解は「答え合わせ」で出せます。';

  { 送信訓練タブ（要件 FR-H）。
    The sending drill tab (requirements FR-H). }
  RsFtFreeText = '課題文なしで送ります。採点は参考値です。';
  RsFtNewDone = '課題文を出しました。準備ができたら「訓練開始」を押してください。';
  RsFtBusyReceiving = '受信中は訓練を始められません。先に「受信停止」を押してください。';
  RsFtNeedText = '先に「課題文を出す」を押すか、送る文を書いてください。';
  RsFtRunning = '訓練中 %d Hz';
  RsFtSendNow = '送ってください。終わったら「終了して採点」を押してください。';
  RsFtBusyDrill = '訓練中です。先に「終了して採点」を押してください。';
  RsFtWavHint = '受信タブの「WAV ファイルから受信」に、採点したい録音を選んでください。';
  RsFtNoAudio = '音が取り込めませんでした。入力装置と音量を確かめてください。';
  RsFtNoMonitor = 'モニター音が見つかりませんでした。'#10 +
    '無線機のモニター音量と、受信タブで選んだ入力装置を確かめてください。';
  RsFtNoScore = '採点できませんでした。'#10'%s';
  RsFtNoScoreStatus = '採点できませんでした。';
  RsFtScoring = '採点しています…';
  RsFtOverallLine = '総合 %0:.0f 点（%1:s の基準）';
  RsFtParts = '  速度の安定 %0:3.0f ／ 短長の明瞭 %1:3.0f ／ 区切りの明瞭 %2:3.0f ／ 間隔の正確 %3:3.0f';
  RsFtReadable = '  写しやすさ %0:3.0f（文字誤り率 %1:.1f%%）';
  RsFtNoReadable = '  写しやすさ —（課題文と読み合わせていません）';
  RsFtWpm = '実効 %0:.1f WPM ／ 短点 %1:.1f ms（ばらつき %2:.1f%%）／ 長短比 %3:.2f';
  RsFtGaps = '間隔の比: 符号内 %0:.2f ／ 文字間 %1:.2f ／ 語間 %2:.2f';
  RsFtSeparation = '分離度: 短点と長点 %0:.1f ／ 符号内と文字間 %1:.1f ／ 速度の変化 %2:.0f%%';
  RsFtNoteFreeText = '※ 課題文なしで測りました。間隔の種別はしきい値で分けています（参考値）。';
  RsFtNoteTrimmed = '※ 10 分を超えた分は保持から落ちました。最後の 10 分だけを採点しています。';
  RsFtAdvice = '直すとよい点: %s';
  RsFtScored = '採点しました。総合 %.0f 点。';
  RsFtNoRecords = 'まだ記録はありません。記録は %s に CSV で残ります。';
  RsFtRecords = '%0:d 件 ／ 自己ベスト 総合 %1:.0f 点 ／ %2:s';
  RsFtStreak = '%d 日続いています';
  RsDecodeDone = 'デコード完了: %d 文字';

  { 受信タブ（要件 FR-I・FR-J・FR-E.3・FR-E.7）。
    The Receive tab (requirements FR-I, FR-J, FR-E.3, FR-E.7). }
  RsRxWaitingLabel = '待機中';
  RsRxWaitStopped = '入力装置を待つのをやめました。';
  RsReceiveStarted = '受信を開始しました。';
  RsReceiveStopped = '受信を停止しました。';
  RsDecodingBusy = 'デコード中...';
  RsCountAndName = '%0:d 件 / %1:s';
  RsFtRunningStatus = '訓練中 %s。終わったら「終了して採点」を押してください。';
  RsRxReceivingHint = '受信中です。最初の文字が出るまで数秒かかります。';
  RsRxAnalyzingHint = '読み込んだ音を解析しています。';
  RsFileUnreadable = '読めませんでした。ファイルを確かめてください';
  RsPrefixesUnused = '使っていません（形だけで判定します）';
  RsPrefixesSkipped = '（前置符字として読めなかった行 %d）';
  RsRosterUnused = '使っていません';
  RsRosterSkipped = '（符号として読めなかった行 %d）';
  RsRosterTruncated = '（大きすぎるため途中まで）';
  RsLogOnceNote = '（1 回だけ）';
  RsLogNeedCall = '相手の符号が読めたら記録できます';
  RsLogWorkedOn = '%0:s%1:s（%2:s に交信済み）';
  RsSubdivisionHint = '相手局の市郡区番号（任意）';
  RsSubdivisionBadShape = 'この形では記録に書けません（4・5・6 桁）';
  RsCtxContactLog = '交信記録';
  RsLoggedBadSubdivision = '%0:s との交信を記録しました。JCC/JCG「%1:s」は形が違うので書いていません。';
  RsLoggedWithBand = '%0:s との交信を %1:s で記録しました（%2:s UTC）。';
  RsLoggedNoBand = '%0:s との交信を記録しました（%1:s UTC）。';
  RsImportTitle = '交信記録（ADIF）を取り込む';
  RsExportTitle = '交信記録（ADIF）を書き出す';
  RsAdifFilter = 'ADIF (*.adi;*.adif)|*.adi;*.adif|すべて (*.*)|*.*';
  RsAdifExportFilter = 'ADIF (*.adi)|*.adi|すべて (*.*)|*.*';
  RsImported = '%0:d 件を取り込みました（既にある %1:d 件は飛ばしました）。';
  RsExported = '%0:d 件を %1:s へ書き出しました。';
  RsModeContestSet = 'コンテストモードにしました。交信済みの局を隠せます。得点計算は行いません。';
  RsModeWatchSet = '待機モードにしました。帯域内の局を一覧に出します。受信文は改めて取り直します。';
  RsModeContactSet = '交信モードにしました。選んだ 1 局を読みます。受信文は改めて取り直します。';
  RsEvidenceEntry = '（%s にあり＝実在は確かです）';
  RsTunedToStation = '%0:.0f Hz の局に同調し、交信モードへ移りました。%1:s%2:s';
  RsWatchHint = '符号を書くと、その局が聞こえたときに知らせます';
  RsWatchingSome = '%0:d 局を待っています（%1:d 件は呼出符号の形になっていません）';
  RsWatchingAll = '%d 局を待っています';
  RsTuneAuto = '自動';
  { 自動の帯域を、近くの局に合わせて絞ったとき（付録 CC）。
    The automatic width narrowed to fit the stations nearby (appendix CC). }
  RsTuneAutoNeighbour = '自動・隣の局に合わせて';
  RsTuneManual = '手動';
  RsTunedBand = '同調: %0:.0f Hz ／ 帯域 ±%1:.0f Hz（%2:s）';
  RsTunedNoLimit = '同調: %.0f Hz ／ 帯域制限なし';
  RsTunedNone = '同調: なし（受信機の音程のまま）';
  RsMonitorNoAudio = '鳴らせる音がまだありません。受信を始めてからお試しください。';
  RsMonitorNoPrepared = '復調音を作れませんでした。';
  RsCtxMonitorAudio = '復調音';
  RsMonitorPlayingTuned = 'デコーダが聴いている音を %0:.1f 秒鳴らしています（%1:.0f Hz を %2:.0f Hz へ寄せ、帯域 ±%3:.0f Hz）。';
  RsMonitorPlayingUntuned = 'デコーダが聴いている音を %.1f 秒鳴らしています（同調していないので、受信機の音程のままです）。';
  RsCtxCapture = '取り込み';
  RsReceivingHz = '受信中 %d Hz';
  RsDeviceReturned = '入力装置が戻りました。受信を再開しました。';
  RsAudioPresent = '音が届いています';
  RsAudioSilent = '無音です';
  RsCtxReceive = '受信';
  RsTunedSnap = '%0:.0f Hz に寄せました。受信機の音程を %1:.0f〜%2:.0f Hz にしてください。';
  RsTunedSignal = '%.0f Hz の信号に同調しました。';
  RsTuneCleared = '同調を解除しました。受信機の音程のまま読みます。';
  RsDeviceDefault = '既定の装置（おまかせ）';
  RsDeviceNoList = '既定の装置（一覧を取得できません）';
  RsDeviceNoneFound = '録音に使える装置が見つかりませんでした。接続と OS 側の設定を確認してください。';
  RsDeviceFound = '入力装置を %d 台見つけました。';
  RsPaceEased = 'この機械では解析が追いつきにくいため、確定の間隔を %0:.0f 秒に緩めています（実時間比 %1:.1f 倍）。読み落としはしません。';
  RsReplayHintHeld = '文字を押すと、その音を聴き直せます（直近 %0:d 分 %1:d 秒を保管中）。';

  { 録音（要件 FR-E.8）。**何秒録れて、どこに残ったかを必ず言う。**
    Recording (requirement FR-E.8): always says how long and where. }
  RsCtxRecording = '録音';
  RsRecordingStarted = '録音を始めました: %s';
  RsRecordingNotKept = '%s録音は残していません（音が届きませんでした）。';
  RsRecordingLost = '（%.1f 秒を取りこぼしました）';
  RsRecordingEnded = '%0:s録音を終えました: %1:s（%2:s）%3:s';
  RsRecordingStatus = '録音 %0:s（%1:.1f MB）';
  RsRecordInfo = '受信と同時に %0:s へ書きます。上限は %1:.0f 時間で、そこで止めて知らせます。';

  { 受信テキストの記録（要件 FR-B.6）。
    Journalling the received text (requirement FR-B.6). }
  RsCtxJournal = '記録';
  RsJournalOn = '受信テキストを %s に記録します。';
  RsJournalOff = '受信テキストの記録を止めました。';

  { 聴き直し（要件 FR-E.10）。
    Replay (requirement FR-E.10). }
  RsRetentionSet = '聴き直せる長さを %d 分にしました。それまでに保管していた音は消えました。';
  RsCtxReplay = '聴き直し';
  RsReplayGone = 'この部分の音はもう残っていません。';
  RsReplayOutOfRange = 'この部分の音は保管の範囲（直近 %d 分）から出ています。設定タブの「聴き直せる長さ」を延ばすと、より前まで遡れます。';
  RsReplayNotHeld = 'この部分の音は保管していません。受信テキストを消したか、録音の設定を変えたあとの文字です。';
  RsReplayPlaying = '%0:s：受信開始から %1:d 分 %2:d 秒の音（%3:.1f 秒）';

  { 語の読み直し（要件 FR-C.3）。
    Re-reading a word (requirement FR-C.3). }
  RsRecheckBusy = '読み直し中...';
  RsRecheckSlow = '%0:d ms (target 1000 ms): %1:d 文字';
  RsRecheckNothing = '読み直すと、この区間からは何も読めませんでした（画面は %s）。';
  RsRecheckSame = '読み直しても %s でした。';
  RsRecheckDiffer = '読み直すと %0:s（画面は %1:s）。';

  { 参照実装からの読み上げ（要件 FR-E.1）。
    What was read from the reference (requirement FR-E.1). }
  RsReferenceRead = '%s を読みました。';

  { 窓の題と、送信タブの実行時の文言（要件 FR-T.1・NFR-7.6）。
    The window title and the transmit tab's runtime words (NFR-7.6). }
  RsAppTitle = 'DeepCW モールス通信 - 送受信';
  RsTxSummary = '%0:d 文字 / %1:.1f 秒';
  RsTxNothing = '送信できる文字がありません。';
  RsTxSendingNow = '送信中';
  RsTxStopped = '送信を停止しました。';
  RsTxDone = '送信完了';
  RsTxSaveTitle = 'モールス音声を保存';
  RsWavFilter = 'WAV ファイル|*.wav';
  RsSaved = '保存しました: %s';
  RsCtxTransmit = '送信';
  RsCtxWavSave = 'WAV の保存';
  RsCtxPlayback = '再生';
  RsCtxEngineLoad = 'エンジンの読み込み';
  RsCtxSaveSettings = '設定の保存';

  { 受信タブの残り（要件 NFR-7.6）。
    The rest of the receive tab (NFR-7.6). }
  RsRxOpenTitle = 'モールス音声を開く';
  RsWavOpenFilter = 'WAV ファイル|*.wav|すべてのファイル|*.*';
  RsFtBusyCapture = '送信訓練の最中です。先に「終了して採点」を押してください。';
  RsWfIdle = '受信を開始すると、ここに信号が流れます。読みたい信号をクリックしてください。';
  RsWfWaiting = '信号を待っています。読みたい信号が見えたらクリックしてください。';
  RsCtxReceiveStart = '受信の開始';
  RsWaitingDevice = '装置を待っています';
  RsRxCopied = '受信テキスト %d 文字をコピーしました。';
  RsCallCopied = '%s をコピーしました。';
  RsCallCopiedNoRst = '%s をコピーしました（RST は聞こえていません）。';
  RsRate = '直近 1 時間: %0:d 局 ／ 記録全体: %1:d 局';
  { 待っていた局の知らせ。**区切りも言語で違います**（日本語は「、」）。
    The watched-station notice. **The separator differs by language too.** }
  RsWatchedAt = '%0:s（%1:.0f Hz）';
  RsWatchedSeparator = '、';
  RsWatchedOnAir = '待っていた %s が出ています。';
  RsFindNone = '見つかりません';
  RsFindPosition = '%0:d / %1:d 件';
  RsBandwidthSet = '帯域幅を %s にしました。';

  { 設定タブの残り（要件 NFR-7.6）。
    The rest of the settings tab (NFR-7.6). }
  RsDiagCopied = '診断情報を %d 行コピーしました。不具合報告にそのまま貼れます。';
  RsCtxPrefixes = '国別前置符字表';
  RsPrefixesOpenTitle = '国別前置符字表を開く';
  RsTextFilter = 'テキスト (*.txt;*.csv)|*.txt;*.csv|すべて (*.*)|*.*';
  RsCtxRoster = '呼出符号の一覧';
  RsRosterOpenTitle = '呼出符号の一覧を開く';
  RsInRoster = '手元の一覧';

  { 無線機で送る（要件 FR-T）。**送る文そのもの（CQ・DE…）は訳しません**
    （CW の運用の言葉）。訳すのは画面の札と知らせだけです。
    Sending through the rig (requirement FR-T). **The text sent (CQ, DE...) is
    not translated** -- it is CW operating language; only the labels and
    messages are. }
  RsTxComposeLabel = '送信文を作る';
  RsTxAutoCq = '自動: CQ';
  RsTxAutoAnswer = '自動: 呼び返し';
  RsTxAutoReport = '自動: レポート';
  RsTxAutoFinal = '自動: 終わりの挨拶';
  RsTxMake = '作る';
  RsTxTheirCall = '相手';
  RsTxRst = 'RST';
  RsTxFromRx = '受信から';
  RsTxTemplateLabel = '定型';
  RsTxUseTemplate = '使う';
  RsTxNoTemplates = '定型は設定タブで書けます';
  RsTxComposed = '送信文を作りました。確かめてから「無線機で送る」を押してください。';
  RsTxNoRxCall = '受信タブで、まだ相手の符号が読めていません。';
  RsSetMuteRx = '送っている間は復号しない';
  RsRxMutedForTx = '送信中（復号を止めています）';
  RsTxRxIsMine = '受信から採れた符号 %s は自局です。相手の符号を入れてください。';
  RsRigGroup = '無線機';
  RsRigConnect = '繋ぐ';
  RsRigDisconnect = '切る';
  RsRigSend = '無線機で送る';
  RsRigStop = '止める（Esc）';
  RsRigOff = '繋いでいません';
  RsRigConnecting = '繋いでいます…';
  RsRigReady = '待機（%d WPM）';
  RsRigReadyNoSpeed = '待機（速度は無線機の設定）';
  RsRigSending = '送信中 %0:d / %1:d 文字';
  { 札は短く、詳しい案内は状態欄へ（札の後ろには幅が無い）。
    The label stays short and the full advice goes to the status bar (there is
    no room after the label). }
  RsRigCannotStop = '（途中で止められない機種）';
  RsRigCannotStopNote = 'この機種は送出の途中で止められません。止めると、無線機に渡した語の終わりで止まります。';
  RsRigFailed = '失敗（状態欄を見てください）';
  RsRigFailNoLibrary = '失敗: Hamlib が見つかりません。Hamlib を入れるか、アプリと同じ場所に置いてください。';
  RsRigFailModel = '失敗: Hamlib はこの機種番号を知りません。設定タブの機種番号を確かめてください。';
  RsRigFailConfig = '失敗: 接続設定「%s」をこの機種・接続では使えません。設定タブで直すか、機種の既定に戻してください。';
  RsRigFailPort = '失敗: 口を開けません。口の名前、ほかのアプリが使っていないか、ケーブルを確かめてください。';
  RsRigFailNoAnswer = '失敗: 無線機が応答しません。電源・通信速度・CI-V アドレスを確かめてください。遠隔で電源を入れられる機種なら「電源を入れる」を押してください。';
  RsRigFailLink = '失敗: 無線機との繋がりが切れました。ケーブルと電源を確かめてから繋ぎ直してください。';
  RsRigPower = '電源を入れる';
  RsRigNoAnswer = '応答なし（電源を確かめてください）';
  RsRigPoweringOn = '電源を入れています…';
  RsRigNoProbe = '（応答を確かめられない機種）';
  RsRigLostAnswer = '無線機が応答しなくなりました。送信はできません。電源を確かめてください（応答が戻れば自動で待機に戻ります）。';
  RsRigSilentAfterOpen = '口は開けましたが、無線機が応答しません。電源を確かめてください（応答すれば自動で待機になります）。';
  RsRigBack = '無線機の応答が戻りました。';
  RsRigConnected = '無線機に繋がりました（応答を確かめました）。';
  RsRxRstRcvd = '受けた RST';
  RsRxRstSent = '送った RST';
  RsRxRstNote = '受けた RST は読めたもの、送った RST は送信タブのものが入ります（直せます）。';
  RsRxRstBad = 'RST は 3 桁で書いてください（例: 599・5NN）。このままでは記録に書きません。';
  RsLoggedBadRst = '%0:s との交信を記録しました。RST「%1:s」は形が違うので書いていません。';
  RsRigModeNotCw = '無線機のモードが CW ではありません（%s）。無線機を CW にしてから送ってください。';
  RsRigBandText = '%s MHz（無線機から）';
  RsSetRigUseFreq = '無線機の周波数を交信記録とバンドに使う（切ればバンドは手で選ぶ）';
  RsRigPowerAsked = '無線機に電源を入れるよう頼みました。';
  RsRigPowerNotSupported = 'この機種・接続では、遠隔で電源を入れられません。無線機の電源を手で入れてください。';
  RsRigPowerFailed = '電源を入れられませんでした。無線機が応答しないか、この機種・接続では遠隔で電源を入れられません。';
  RsRigPowerNoWake = '電源を入れる命令は受けましたが、30 秒待っても無線機が応答しません。';
  RsRigPowerAwake = '無線機が起きました。';
  RsRigPowerNotNow = '電源を入れられるのは、無線機が応答しないときだけです。';
  RsRigConfCivAddr = 'CI-V アドレスは 16 進の 01〜DF で書いてください（例: 94）。';
  RsRigConfChoice = '接続設定「%s」の値が使えません。';
  RsRigConfRange = '接続設定「%s」が範囲の外です（応答待ちは 100〜10000 ms、間隔は 1000 ms まで。0 は機種の既定）。';
  RsRigConfRtsHardware = 'フロー制御がハードウェアのときは、RTS を手で決められません。RTS を機種の既定に戻してください。';
  RsRigAutoConnecting = '起動時の設定で、無線機へ繋いでいます。';
  RsSetRigAutoConnect = '起動したら無線機へ繋ぐ（繋ぐだけで、送信も電源投入もしません）';
  RsSetRigAdvGroup = '無線機の詳しい接続設定（普通は既定のまま）';
  RsSetRigCivAddr = 'CI-V アドレス';
  RsSetRigDataBits = 'データビット';
  RsSetRigStopBits = 'ストップビット';
  RsSetRigParity = 'パリティ';
  RsSetRigParityNone = 'なし';
  RsSetRigParityEven = '偶数';
  RsSetRigParityOdd = '奇数';
  RsSetRigHandshake = 'フロー制御';
  RsSetRigHandshakeNone = 'なし';
  RsSetRigHandshakeHardware = 'ハードウェア';
  RsSetRigTimeout = '応答待ち (ms)';
  RsSetRigWriteDelay = '文字の間隔 (ms)';
  RsSetRigPostDelay = '命令の間隔 (ms)';
  RsSetRigAdvHint = '「機種の既定」と 0 ms は Hamlib へ渡しません。繋ぎ直すと効きます。';
  RsSetRigLineWarn = 'DTR・RTS で送信や鍵を操作する配線では、口を開いた瞬間に電波が出ないよう OFF にしてください。';
  RsRigFailSend = '失敗: 送出の途中で無線機との繋がりが切れました。送信は止めました。繋ぎ直してください。';
  RsRigFailStop = '失敗: 止める命令が通りませんでした。無線機の電源か繋がりを確かめてください。';
  RsRigNoModel = '設定タブで無線機の機種番号を入れてください。';
  RsRigNotReady = '無線機が待機中ではありません。繋いでから送ってください。';
  RsRigStarted = '無線機で送り始めました。止めるときは Esc。';
  RsRigStopped = '送信を止めました。';
  RsCtxRig = '無線機';
  { 地方時を OS に合わせたときの診断（未解決 #20、付録 BW.4）。
    The diagnostic when local time is aligned with the OS (open question #20,
    appendix BW.4). }
  RsCtxClock = '時刻';
  RsClockAligned = '地方時を OS に合わせました（%0:s → %1:s）';
  RsTxProblemEmpty = '送信文が空です。';
  RsTxProblemUnsendable = '送れない文字があります: 「%s」';
  RsTxProblemTooLong = '長すぎます（%0:s 文字）。%1:d 文字・%2:d 秒までにしてください。';
  RsTxProblemUnexpanded = '展開されていない差し込みがあります: %s';
  RsTxProblemMissing = '%s の値がありません。自局の符号は設定タブ、相手の符号は送信タブに入れてください。';
  RsTxProblemUnknown = '知らない差し込みです: %s（使えるのは MYCALL・CALL・RST）';
  RsSetRigGroup = '無線機（送信）';
  RsSetRigModel = '機種番号';
  RsSetRigPort = '口';
  RsSetRigBaud = '通信速度';
  RsSetRigBaudDefault = '機種の既定';
  RsSetRigHint = '番号は Hamlib の rigctl -l で確かめられます（例: IC-7300 は 3073、FT-991 は 1035）。口は COM3・/dev/ttyUSB0 など。';
  RsSetMyCall = '自局の符号';
  RsSetTemplates = '定型（1 行に 1 つ。MYCALL・CALL・RST を波括弧で囲むと差し込み）';
  RsSetExtGroup = '拡張（準備中）';
  RsSetAlphabet = '文字の種類';
  RsSetAlphabetIntl = '欧文';
  RsSetAlphabetWabun = '和文（準備中）';
  RsSetNoise = 'ノイズ低減';
  RsSetNoiseOff = '使わない';
  RsSetNoiseAi = 'AI（準備中）';
  RsSetExtHint = '和文と AI のノイズ低減は準備中で、まだ選べません。';
  RsSetExtRawHint = 'ノイズ低減は復号へ渡す音だけに掛け、聴き直しと録音は生の音のままです。';
  RsSetExtPending = 'この項目は準備中で、まだ選べません。元の選択に戻しました。';



{ 改行の直し（`AsLines`）は `DeepCW.Platform` に在ります。**OS で振る舞いが
  変わるものは 1 か所へ。**
  The line-ending fix (`AsLines`) lives in `DeepCW.Platform`: **what behaves
  differently by platform goes in one place.** }

const
  { 受信テキストに必ず残す高さと、ウォーターフォールの枠の既定・最小の高さ
    （96 dpi での画素。付録 BV.4）。/ The height always left to the received
    text, and the waterfall panel's default and least heights (pixels at
    96 dpi; appendix BV.4). }
  RX_TRANSCRIPT_MIN_96 = 80;
  RX_WATERFALL_DEFAULT_96 = 230;
  RX_WATERFALL_MIN_96 = 120;

{ ノイズ低減の選択肢の鍵。**画面の項目と同じ順**です（要件 FR-N）。
  The noise-reduction keys, **in the order of the items on screen** (FR-N). }
const
  NOISE_ITEMS: array[0..1] of string = (NOISE_KEY_OFF, NOISE_KEY_AI);

{ 鍵の項目の番号。知らない鍵は -1。/ The item index of a key; -1 if unknown. }
function NoiseItemIndex(const Key: string): Integer;
var
  I: Integer;
begin
  for I := Low(NOISE_ITEMS) to High(NOISE_ITEMS) do
    if NOISE_ITEMS[I] = Key then
      Exit(I);
  Result := -1;
end;

{ 実装の後方で定義します。/ Defined further down. }
function UserMessageFor(const Raw: string): string; forward;
function BandNameAt(Index: Integer): string; forward;
function StatusLine(const Raw: string): string; forward;

{ TDecodeThread }

constructor TDecodeThread.Create(ADecoder: TDeepCWDecoder; const ASamples: TSingleArray;
  ASampleRate: Integer; AOnDone: TNotifyEvent);
begin
  FDecoder := ADecoder;
  FSamples := Copy(ASamples, 0, Length(ASamples));
  FSampleRate := ASampleRate;
  FOnDone := AOnDone;
  FreeOnTerminate := False;
  inherited Create(False);
end;

constructor TDecodeThread.CreateRecheck(ADecoder: TDeepCWDecoder;
  const ASamples: TSingleArray; ASampleRate: Integer; AOnDone: TNotifyEvent);
begin
  FRecheck := True;
  Create(ADecoder, ASamples, ASampleRate, AOnDone);
end;

constructor TDecodeThread.CreateFist(ADecoder: TDeepCWDecoder;
  const ASamples: TSingleArray; ASampleRate: Integer; AOnDone: TNotifyEvent);
begin
  FFist := True;
  Create(ADecoder, ASamples, ASampleRate, AOnDone);
end;

constructor TDecodeThread.CreateStreaming(AStream: TStreamingDecoder;
  AOnDone: TNotifyEvent);
begin
  FStream := AStream;
  FDecoder := AStream.Decoder;
  FOnDone := AOnDone;
  FreeOnTerminate := False;
  inherited Create(False);
end;

constructor TDecodeThread.CreateMulti(AMulti: TMultiStationDecoder;
  AOnDone: TNotifyEvent);
begin
  FMulti := AMulti;
  FOnDone := AOnDone;
  FreeOnTerminate := False;
  inherited Create(False);
end;

constructor TDecodeThread.CreateFile(ADecoder: TDeepCWDecoder;
  AMulti: TMultiStationDecoder; AHistory: TAudioHistory;
  const AFileName: string; AOnLoaded, AOnShaped, AOnDone: TNotifyEvent);
begin
  FDecoder := ADecoder;
  FMulti := AMulti;
  FHistory := AHistory;
  FFileName := AFileName;
  FOnLoaded := AOnLoaded;
  FOnShaped := AOnShaped;
  FOnDone := AOnDone;
  FreeOnTerminate := False;
  inherited Create(False);
end;

{ 復号へ渡す前の整形です。**ファイル・読み直し・「モデルが聴いている音」の
  すべてがここを通ります**（整形の場所は 1 か所。教訓 10.11）。どのスレッド
  からでも呼べます（フォームに触れません）。
  The preparation before decoding. **Files, re-readings and "what the model
  hears" all come through here** (one place for it; lesson 10.11). Callable
  from any thread: it does not touch the form. }
function ShapeForDecoder(const Shaping: TDecoderShaping;
  const Samples: TSingleArray; SampleRate: Integer;
  out HalfWidthHz: Double): TSingleArray;
const
  { 自動の帯域を決めるために見る長さの上限（秒）。付録 CC。
    The most audio looked at to work out the automatic width (seconds);
    appendix CC. }
  AUTO_LOOK_SECONDS = 60;
begin
  HalfWidthHz := Shaping.HalfWidthHz;
  if Shaping.AutoWidth then
    HalfWidthHz := AutoHalfWidth(Copy(Samples, 0, AUTO_LOOK_SECONDS * SampleRate),
      SampleRate, Shaping.TuneHz, Shaping.Meta);
  Result := DeepCW.Tuner.PrepareForModelWidth(Samples, SampleRate,
    Shaping.Meta.SampleRate, Shaping.TuneHz, HalfWidthHz, Shaping.AntiAlias);
end;

{ 録音全体を、待機モードの経路で読み切ります。取り込みと同じように少しずつ
  流し込むのは、一度に入れると溜め込みの上限で大半が捨てられるためです。
  Reads a whole recording through the waiting mode's path. It is fed in
  pieces, as capture would, because all at once most of it would fall off the
  buffer's limit. }
procedure TDecodeThread.FeedMulti;
const
  { 流し込む刻み。取り込みの脈動と同じ程度にします。
    The size of each piece, about what a pulse of capture delivers. }
  FILE_CHUNK_SECONDS = 1.0;
var
  Position, Taken: Integer;
begin
  Position := 0;
  while (Position < Length(FSamples)) and not Terminated do
  begin
    Taken := Min(Round(FILE_CHUNK_SECONDS * FSampleRate),
      Length(FSamples) - Position);
    FMulti.Append(Copy(FSamples, Position, Taken), FSampleRate);
    Inc(Position, Taken);
    while FMulti.Ready and not Terminated do
      FMulti.Step;
  end;
  FMulti.Finish;
end;

procedure TDecodeThread.ReadFile;
var
  Raw: TSingleArray;
begin
  { 読めないファイルは、ここで終えます。**画面はまだ何も片付けていない**ので、
    前の受信テキストはそのまま残ります。
    An unreadable file ends here. **The screen has not cleared anything yet**,
    so the previous transcript stays as it was. }
  try
    LoadWavMono(FFileName, Raw, FSampleRate);
  except
    on E: Exception do
    begin
      FLoadError := E.Message;
      Exit;
    end;
  end;
  FSamples := Raw;
  Synchronize(@ReportLoaded);
  { 画面が閉じられようとしていれば、重い仕事は始めません。
    If the window is closing, the heavy work is not started. }
  if Terminated then
    Exit;
  { 保管庫には生の音を入れます（聴き直しは生の音。要件 FR-N の取り決め 1）。
    片付けは `ReportLoaded` の中で済んでいるので、順序は崩れません。
    The store gets the raw audio (replay is raw; rule 1 of FR-N). Its clearing
    happened inside `ReportLoaded`, so the order holds. }
  FHistory.Append(Raw, FSampleRate, 0);
  Raw := nil;
  if FMulti <> nil then
  begin
    Queue(@ReportShaped);
    FeedMulti;
    Exit;
  end;
  FSamples := ShapeForDecoder(FShaping, FSamples, FSampleRate, FAppliedHalf);
  FSampleRate := FShaping.Meta.SampleRate;
  Queue(@ReportShaped);
  if Terminated then
    Exit;
  FChars := FDecoder.DecodeLongSamplesTimed(FSamples, FSampleRate);
end;

procedure TDecodeThread.ReportLoaded;
begin
  if Assigned(FOnLoaded) then
    FOnLoaded(Self);
end;

procedure TDecodeThread.ReportShaped;
begin
  if Assigned(FOnShaped) then
    FOnShaped(Self);
end;

procedure TDecodeThread.Execute;
begin
  try
    if FFileName <> '' then
      ReadFile
    else if FMulti <> nil then
      FMulti.Step
    else if FStream <> nil then
      FStream.Step
    else
      FChars := FDecoder.DecodeLongSamplesTimed(FSamples, FSampleRate);
  except
    on E: Exception do
      FError := E.Message;
  end;
  Synchronize(@ReportDone);
end;

procedure TDecodeThread.ReportDone;
begin
  if Assigned(FOnDone) then
    FOnDone(Self);
end;

{ TMainForm }

constructor TMainForm.Create(AOwner: TComponent);
begin
  { CreateNew は Create が行う .lfm の探索を省きます。
    CreateNew skips the .lfm lookup that Create would perform. }
  inherited CreateNew(AOwner);
  RegisterCaption(Self, @RsAppTitle);
  { 窓の既定の幅。**中身から決めます。**受信タブの表示の行と、送信訓練の案内文が
    いちばん幅を要る（付録 AW.2 の実測で 1033 画素）。狭くすると、それらは
    静かに切れます——警告も出ず、切れていることが画面から分かりません。
    The window's default width, **decided by what it has to hold**: the display
    row of the receive tab and the guidance line of the transmit drill need the
    most (1033 pixels, measured in appendix AW.2). Narrower than that and they
    are cut off in silence -- no warning, and no way to tell from the screen. }
  Width := 1080;
  Height := 700;
  { グループ枠の中の操作列は固定位置で配置しているため、読みやすさを保つには
    おおよそこの幅が必要です。

    The control rows inside the group boxes are laid out at fixed offsets and
    need roughly this much width to stay readable. }
  Constraints.MinWidth := 1040;
  { 受信テキスト（80）とウォーターフォールの最小（120）が両方入る高さ
    （付録 BV.4。以前の 560 では受信テキストが見えなくなっていた）。
    Tall enough for both the received text (80) and the waterfall's least
    height (120) (appendix BV.4; at the former 560 the received text
    disappeared). }
  Constraints.MinHeight := 660;
  Position := poScreenCenter;

  FDiagnostics := TStringList.Create;
  { 地方時は、日付で名付ける記録（`FJournal`）を開く**前に** OS へ合わせます。
    後にすると、起動した日の記録が UTC の日付で作られえます（付録 BW.4）。
    Local time is aligned with the OS **before** the date-named journal
    (`FJournal`) is opened; afterwards, the day's journal could be created
    under the UTC date (appendix BW.4). }
  SyncClock;
  FCaptureRate := 8000;
  FTxSampleRate := 8000;
  FRing := TAudioRing.Create(FCaptureRate * 30);
  FPlayback := TAudioPlayback.Create;
  FReviewPlay := TAudioPlayback.Create;
  FAlerts := TWatchAlerts.Create;
  FHistory := TAudioHistory.Create(REVIEW_DEFAULT_SECONDS, FCaptureRate);
  FJournal := TTranscriptJournal.Create(JournalDirectory);
  FLog := TContactLog.Create(LogFileName);
  FMode := rmContact;

  { **言語は、画面を組む前に決めて入れます**（要件 NFR-7.6、付録 BQ）。
    画面を組み、設定を読むあいだに、選択肢の手続き（`FtOptionsChanged` など）が
    文言を書き込みます。言語をそのあとで入れると、**書き込まれた文言は起動した
    ときの日本語のまま残ります**——「課題文なしで送る」を覚えていると、英語でも
    課題文の欄が日本語でした（実画面で見つけた）。先に入れれば、読み込みの途中で
    書かれる文言はすべて、最初から選んだ言語で出ます。
    **The language is decided and put in before the screen is built**
    (requirement NFR-7.6, appendix BQ). While the screen is built and the
    settings read, option handlers (`FtOptionsChanged` and others) write words
    into it. Put in afterwards, **whatever they wrote stays in the Japanese it
    started in** -- with "send freely" remembered, the exercise box was Japanese
    even in English (found on the real screen). Put in first, everything written
    during loading comes out in the chosen language from the start. }
  UseUiLang(StartingUiLang(RememberedUiLang));

  BuildUI;
  { 無線機の鍵のスレッド。**繋ぐのも送るのも、利用者が押したときだけ**です。
    The rig key's thread. **It connects and sends only when the operator
    presses.** }
  FKeyer := TRigKeyer.Create;
  { 設定を読む前は素通しです（要件 FR-N）。/ Pass-through until settings load. }
  FReducer := TBypassReducer.Create;
  FTxGate := TTxReceiveGate.Create;
  KeyPreview := True;
  OnKeyDown := @FormKeyDown;
  LoadSettings;
  { 起動したら繋ぐ（要件 FR-T.6）。**窓が出てから**、最初の刻みで繋ぎます。
    繋ぐだけで、送信も電源投入もしません。
    Connect at start-up (FR-T.6), **once the window is up**, on the first tick.
    It only connects; it neither sends nor powers on. }
  FRigAutoConnectPending := FSetRigAutoConnect.Checked and (FSetRigModel.Value > 0);
  { 覚えていた言語を入れ直します（要件 NFR-7.6）。**覚えていても、渡さなければ
    効きません**——高コントラストと同じ話です。`LoadSettings` は選択肢を合わせる
    だけなので、文言そのものはここで切り替えます。
    The remembered language is put back in (requirement NFR-7.6). **Remembered
    but not handed over, it does nothing** -- the same story as high contrast.
    `LoadSettings` only sets the choice; the words themselves change here. }
  if FSetLanguage <> nil then
  begin
    { 設定ファイルが無い（初回）ときも通ります。**命令行と OS の地域設定から
      決まるので、選択肢と画面が食い違いません。**
      Taken on a first run too, with no settings file: **the command line and
      the locale decide, so the list and the screen agree.** }
    if FSetLanguage.ItemIndex = UI_LANG_DEFAULT then
      FSetLanguage.ItemIndex := StartingUiLang('');
    UseUiLang(FSetLanguage.ItemIndex);
    { **部品側だけでなく、こちらの `ApplyTexts` を呼びます。**実行中に組み直される
      もの（推移の絞り込みなど）は控えに載らないので、組み直す側を通さないと
      組み立てたときの言語のまま残ります（付録 BE.6）。
      **The form's `ApplyTexts`, not just the unit's**: what is rebuilt while
      running -- the trend's filter, for one -- is not in the notes, so without
      going through whatever rebuilds it, it stays in the language it was built
      in (appendix BE.6). }
    ApplyTexts;
  end;
  { ステータスバーと設定タブに有用な情報を出すため、モデルは起動時に読み込み
    ます。ただしランタイムが無くても起動は妨げません。

    Load the model up front so the status bar and the settings tab say
    something useful, but never block startup on a missing runtime. }
  { 読み込んだ表示設定を実際に反映します。設定は代入だけでは効きません。
    Apply the loaded display settings; assigning the controls is not enough. }
  { 高コントラスト表示も同じです（要件 NFR-5.5）。**覚えていても、渡さなければ
    効きません。**起動のたびに切れているのでは、覚えた意味がありません。
    High contrast is no different (requirement NFR-5.5): **remembered but not
    handed over, it does nothing**, and coming up off on every launch would make
    remembering it pointless. }
  ApplyHighContrast;
  UpdateRecordInfo;
  RxDisplayChanged(nil);
  FRxMode.OnChange := @RxModeChanged;
  { 読み込んだ待ち符号を実際に反映します。設定は代入だけでは効きません。通知は
    反映のあとで繋ぎます。読み込みの代入で走らせると、起動しただけで設定が
    変わったことになります（モードの選択で同じ罠を踏んでいます）。
    Apply the watch list that was loaded; assigning the control is not enough. The
    notification is attached afterwards: run during the load it would mark the
    settings dirty on startup alone -- the same trap the mode selector fell into. }
  RxWatchChanged(nil);
  FRxWatch.OnChange := @RxWatchChanged;
  { 読み込んだ保持時間を保管庫へ反映します。設定を読むだけでは効きません。
    Apply the retention that was loaded; reading the setting is not enough. }
  FHistory.SetRetention(SelectedRetention);
  { 交信記録を読み込みます。読めなくても受信は続きます。
    The contact log is loaded; reception continues even if it cannot be read. }
  FLog.Load;
  if FLog.LastError <> '' then
    LogDiagnostic(RsCtxContactLog, FLog.LastError);
  UpdateLogInfo;
  UpdateReplayInfo;
  { 読み込んだ設定を記録へも反映します。控えるだけでは効きません。
    Apply the loaded setting to the journal too; holding it in a control is not
    enough. }
  FJournal.Enabled := FSetJournal.Checked;
  { 読み込んだモードを画面へ反映します。控えるだけでは効きません。
    Apply the mode that was loaded; holding it in a control is not enough. }
  case FRxMode.ItemIndex of
    1: FMode := rmWatch;
    2: FMode := rmContest;
  else
    FMode := rmContact;
  end;
  ApplyMode;
  UpdateFindInfo;
  { 設定に装置名が無かった場合でも一覧は用意します。
    The list is built even when the settings held no device name. }
  if FRxDevice.Items.Count = 0 then
    RefreshDeviceList('');
  { 同調の表示も同じで、読み込んだ値を画面へ映さないと、実際の状態と食い違い
    ます。
    The same holds for the tuning display: without this the panel would
    disagree with the actual state. }
  UpdateTuneInfo;
  RxTrackChanged(nil);
  EnsureDecoder(True);
  RefreshInfo;
  RenderTransmit;
end;

destructor TMainForm.Destroy;
begin
  FClosing := True;
  { **送信を真っ先に止めます**（fail-safe）。`TRigKeyer.Destroy` は止め、
    無線機の口を閉じてから戻ります。
    **Sending is stopped first** (fail-safe): `TRigKeyer.Destroy` stops and
    closes the rig before it returns. }
  FreeAndNil(FKeyer);
  if FPollTimer <> nil then
    FPollTimer.Enabled := False;
  if FCapture <> nil then
    FCapture.Stop;
  { 送信訓練の取り込みも止めます。**止めずに閉じると、装置を握ったまま
    プロセスが消えます。**
    The send-practice capture is stopped too: **left running, the process would
    disappear still holding the device.** }
  if FFtCapture <> nil then
  begin
    FFtCapture.Stop;
    FreeAndNil(FFtCapture);
  end;
  { 録音は閉じる前に終えます。**見出しは書き足すたびに直しているので、ここで
    落ちても読めますが、終えれば最後の一息まで入ります。**
    The recording is finished before closing: **the headers are kept correct as
    it goes, so dying here still leaves it readable, but finishing puts the last
    breath of it in.** }
  if FRecorder <> nil then
  begin
    FRecorder.Stop;
    FreeAndNil(FRecorder);
  end;
  if FPlayback <> nil then
    FPlayback.Stop;
  if FReviewPlay <> nil then
    FReviewPlay.Stop;
  if FDecodeThread <> nil then
  begin
    { 主スレッドでの WaitFor は Synchronize を処理し続けるため、ワーカーは
      最後まで進み、自身を FCompletedThread へ預けられます。

      WaitFor on the main thread keeps pumping Synchronize, so the worker can
      finish and hand itself over to FCompletedThread. }
    FDecodeThread.WaitFor;
    FreeAndNil(FDecodeThread);
  end;
  FreeAndNil(FCompletedThread);
  SaveSettings;
  FStream.Free;
  FReducer.Free;
  FTxGate.Free;
  FDiagnostics.Free;
  FCapture.Free;
  FFtRing.Free;
  FPlayback.Free;
  FReviewPlay.Free;
  FMeasure.Free;
  FAlerts.Free;
  { 書き残しを出してから解放します。閉じるときの 1 語は、記録として要ります。
    The remainder is written before releasing: the last word of a session
    belongs in the record. }
  if FJournal <> nil then
    FJournal.Flush;
  FJournal.Free;
  FLog.Free;
  FRoster.Free;
  FPrefixes.Free;
  FHistory.Free;
  FRing.Free;
  FDecoder.Free;
  inherited Destroy;
end;

{ ---- layout ---- }

procedure TMainForm.BuildUI;
begin
  FStatus := TStatusBar.Create(Self);
  FStatus.Parent := Self;
  FStatus.SimplePanel := False;
  FStatus.Panels.Add.Width := 160;
  FStatus.Panels.Add.Width := 140;
  { 録音は運用の間ずっと続く状態なので、案内の欄ではなく自分の欄を持ちます
    （要件 FR-E.8）。**案内に出すと、次の案内が出た時点で「録音中かどうか」が
    画面から消えます。**
    A recording is a state that lasts the whole session, so it has a panel of its
    own rather than the guidance panel (requirement FR-E.8): **put in the
    guidance, whether it is recording would vanish from the screen the moment the
    next message arrived.** }
  FStatus.Panels.Add.Width := 190;
  { 最後には対処つきの案内が入るため、残りの幅をすべて与えます。切り詰められ
    ると「次に何をすればよいか」が読めなくなります（要件 FR-A.4）。

    The last panel carries guidance with a remedy in it, so it takes all the
    remaining width; truncating it would cut off what to do next
    (requirement FR-A.4). }
  FStatus.Panels.Add.Width := 4000;

  FPages := TPageControl.Create(Self);
  FPages.Parent := Self;
  FPages.Align := alClient;
  FPages.AddTabSheet.Free;      { 仮のシートを取り除きます / drop the placeholder sheet }
  BuildTransmitTab;
  FRxSheet := BuildReceiveTab;
  BuildPracticeTab;
  BuildFistTab;
  FSettingsSheet := BuildSettingsTab;
  { 起動直後の画面は受信です。ここから受信開始まで操作 1 回で届きます
    （要件 FR-A.2）。
    The window opens on the receive tab, one action away from starting
    reception (requirement FR-A.2). }
  FPages.PageIndex := 1;
  FPages.OnChange := @PagesChanged;

  FPollTimer := TTimer.Create(Self);
  { 取り込みの間隔は、受信経路の動作点そのものです（要件 NFR-1.1）。
    測る道具と同じ値を使うため、`DeepCW.Stream` の定数から決めます。
    The capture interval is the receive path's operating point (requirement
    NFR-1.1). It is taken from the constant in `DeepCW.Stream` so that the
    harness measures at the same point. }
  FPollTimer.Interval := Round(STREAM_FEED_SECONDS * 1000);
  FPollTimer.OnTimer := @PollTimer;
  FPollTimer.Enabled := True;
end;

{ 配置についての補足です。幅いっぱいに広がる部品には右アンカーではなく Align
  を使っています。アンカーの余白はタブシートが設計時の大きさのまま確定するため、
  ウィンドウを広げると右アンカーの部品が画面外へ出てしまいます。alTop と
  alClient は実際の親の大きさから計算されるので、この問題が起きません。

  Layout note: full-width controls use Align rather than right anchors. Anchor
  offsets are captured while a tab sheet is still at its design size, which
  sends right-anchored controls off screen once the window is resized; alTop
  and alClient are computed from the live parent size instead. }

{ 作るときに、文言のありかを控えます（要件 NFR-7.6）。**控えておかないと、
  稼働中に言語を変えたときこの部品だけ前の言語のまま残ります。**控えるのは
  文字列ではなくありかなので、入れ直すのは `UiText.ApplyTexts` の仕事です。

  文字列をそのまま渡す形も残してあります。**訳さないもの**——実行中に組み立てる
  文、記録から取った値、利用者が打った文字——はそちらを通ります。

  The words' address is noted as the control is built (requirement NFR-7.6).
  **Without the note this one control would stay in the old language** when the
  language changes while running. What is noted is the address, not the string,
  so putting it back is `UiText.ApplyTexts`'s work.

  The plain-string form is kept for **what is not translated**: sentences built
  while running, values taken from records, and text the operator typed. }
function AddLabel(Parent: TWinControl; const Text: string; Left, Top: Integer): TLabel;
begin
  Result := TLabel.Create(Parent);
  Result.Parent := Parent;
  Result.Caption := Text;
  Result.Left := Left;
  Result.Top := Top;
end;

function AddLabel(Parent: TWinControl; Text: PResString; Left, Top: Integer): TLabel; overload;
begin
  Result := AddLabel(Parent, '', Left, Top);
  RegisterCaption(Result, Text);
end;

function AddSpin(Parent: TWinControl; Left, Top, Min, Max, Value: Integer;
  OnChange: TNotifyEvent): TSpinEdit;
begin
  Result := TSpinEdit.Create(Parent);
  Result.Parent := Parent;
  Result.Left := Left;
  Result.Top := Top;
  Result.Width := 80;
  Result.MinValue := Min;
  Result.MaxValue := Max;
  Result.Value := Value;
  Result.OnChange := OnChange;
end;

function AddButton(Parent: TWinControl; const Caption: string; Left, Top, Width: Integer;
  OnClick: TNotifyEvent): TButton;
begin
  Result := TButton.Create(Parent);
  Result.Parent := Parent;
  Result.Caption := Caption;
  Result.Left := Left;
  Result.Top := Top;
  Result.Width := Width;
  Result.Height := 30;
  Result.OnClick := OnClick;
end;

function AddButton(Parent: TWinControl; Caption: PResString; Left, Top, Width: Integer;
  OnClick: TNotifyEvent): TButton; overload;
begin
  Result := AddButton(Parent, '', Left, Top, Width, OnClick);
  RegisterCaption(Result, Caption);
end;

var
  { alTop の並び順は生成順ではなく Top 座標で決まるため、整列の前に順に大きな
    Top を与えます。

    alTop controls are ordered by their Top coordinate, not by creation order,
    so each one is given a larger Top before it is aligned. }
  GLayoutTop: Integer = 0;

{ 秒数を時計の形にします。**「4837 秒」では、長いのか短いのかが分かりません。**
  Turns seconds into a clock: **"4837 seconds" does not say whether that is long
  or short.** }
function SecondsAsClock(Seconds: Double): string;
var
  Whole: Integer;
begin
  Whole := Trunc(Seconds);
  if Whole < 0 then
    Whole := 0;
  if Whole >= 3600 then
    Result := Format('%d:%.2d:%.2d',
      [Whole div 3600, (Whole div 60) mod 60, Whole mod 60])
  else
    Result := Format('%d:%.2d', [Whole div 60, Whole mod 60]);
end;

procedure StackBelow(Control: TControl);
begin
  Inc(GLayoutTop, 100);
  Control.Top := GLayoutTop;
end;

function AddTopLabel(Parent: TWinControl; const Text: string): TLabel;
begin
  Result := TLabel.Create(Parent);
  Result.Parent := Parent;
  Result.Caption := Text;
  StackBelow(Result);
  Result.Align := alTop;
  Result.BorderSpacing.Left := 6;
  Result.BorderSpacing.Top := 8;
end;

function AddTopLabel(Parent: TWinControl; Text: PResString): TLabel; overload;
begin
  Result := AddTopLabel(Parent, '');
  RegisterCaption(Result, Text);
end;

function AddTopPanel(Parent: TWinControl; Height: Integer): TPanel;
begin
  Result := TPanel.Create(Parent);
  Result.Parent := Parent;
  Result.Height := Height;
  StackBelow(Result);
  Result.Align := alTop;
  Result.BevelOuter := bvNone;
end;

procedure Stretch(Control: TControl; AAlign: TAlign; Margin: Integer = 6);
begin
  if AAlign = alTop then
    StackBelow(Control);
  Control.Align := AAlign;
  Control.BorderSpacing.Around := Margin;
end;

function TMainForm.BuildTransmitTab: TTabSheet;
var
  Sheet: TTabSheet;
  Options: TGroupBox;
  Buttons, Current, Compose, Rig: TPanel;
begin
  Sheet := FPages.AddTabSheet;
  RegisterCaption(Sheet, @RsTxTab);
  Result := Sheet;
  { 送信文の作り方は 3 つ（要件 FR-T.1）: 自動・定型・下の欄への手入力。
    **どれも下の欄へ最終の文として入り、送るのはその欄の文そのもの**です。
    The text comes from one of three places (FR-T.1): automatic, a template,
    or typed into the box below. **All of them end up in that box as the final
    text, and what is sent is exactly the box.** }
  Compose := AddTopPanel(Sheet, 36);
  AddLabel(Compose, @RsTxComposeLabel, 12, 8);
  FTxStage := TComboBox.Create(Compose);
  FTxStage.Parent := Compose;
  FTxStage.SetBounds(120, 4, 170, 28);
  FTxStage.Style := csDropDownList;
  RegisterItem(FTxStage, Ord(tsCq), @RsTxAutoCq);
  RegisterItem(FTxStage, Ord(tsAnswer), @RsTxAutoAnswer);
  RegisterItem(FTxStage, Ord(tsReport), @RsTxAutoReport);
  RegisterItem(FTxStage, Ord(tsFinal), @RsTxAutoFinal);
  FTxStage.ItemIndex := 0;
  AddLabel(Compose, @RsTxTheirCall, 300, 8);
  FTxTheirCall := TEdit.Create(Compose);
  FTxTheirCall.Parent := Compose;
  FTxTheirCall.SetBounds(340, 4, 100, 28);
  FTxTheirCall.CharCase := ecUppercase;
  AddLabel(Compose, @RsTxRst, 450, 8);
  FTxRst := TEdit.Create(Compose);
  FTxRst.Parent := Compose;
  FTxRst.SetBounds(486, 4, 50, 28);
  FTxRst.Text := '599';
  FTxRst.OnChange := @TxRstChanged;
  AddButton(Compose, @RsTxFromRx, 544, 4, 90, @TxFromRxClick);
  AddButton(Compose, @RsTxMake, 642, 4, 70, @TxAutoClick);
  AddLabel(Compose, @RsTxTemplateLabel, 726, 8);
  FTxTemplate := TComboBox.Create(Compose);
  FTxTemplate.Parent := Compose;
  FTxTemplate.SetBounds(796, 4, 176, 28);
  FTxTemplate.Style := csDropDownList;
  AddButton(Compose, @RsTxUseTemplate, 980, 4, 70, @TxTemplateClick);


  AddTopLabel(Sheet, @RsTxTextLabel);
  FTxText := TMemo.Create(Sheet);
  FTxText.Parent := Sheet;
  FTxText.Height := 90;
  FTxText.ScrollBars := ssAutoVertical;
  FTxText.Text := 'CQ CQ DE JA1ABC K';
  FTxText.OnChange := @TxTextChanged;
  Stretch(FTxText, alTop);

  AddTopLabel(Sheet, @RsTxMorse);
  FTxCode := TMemo.Create(Sheet);
  FTxCode.Parent := Sheet;
  FTxCode.Height := 70;
  FTxCode.ReadOnly := True;
  FTxCode.ScrollBars := ssAutoVertical;
  FTxCode.Font.Name := 'Monospace';
  Stretch(FTxCode, alTop);

  Options := TGroupBox.Create(Sheet);
  Options.Parent := Sheet;
  Options.Height := 110;
  RegisterCaption(Options, @RsTxSettings);
  Stretch(Options, alTop);

  AddLabel(Options, @RsTxCharWpm, 14, 6);
  FTxCharWpm := AddSpin(Options, 14, 26, 5, 60, 20, @TxOptionsChanged);
  AddLabel(Options, @RsTxTextWpm, 134, 6);
  FTxTextWpm := AddSpin(Options, 134, 26, 5, 60, 20, @TxOptionsChanged);
  AddLabel(Options, @RsTxToneHz, 254, 6);
  FTxToneHz := AddSpin(Options, 254, 26, 300, 1500, 700, @TxOptionsChanged);

  AddLabel(Options, @RsTxVolume, 360, 6);
  FTxVolume := TTrackBar.Create(Options);
  FTxVolume.Parent := Options;
  FTxVolume.SetBounds(360, 24, 160, 36);
  FTxVolume.Min := 0;
  FTxVolume.Max := 100;
  FTxVolume.Position := 60;
  FTxVolume.OnChange := @TxOptionsChanged;

  AddLabel(Options, @RsTxNoise, 540, 6);
  FTxNoise := TTrackBar.Create(Options);
  FTxNoise.Parent := Options;
  FTxNoise.SetBounds(540, 24, 160, 36);
  FTxNoise.Min := 0;
  FTxNoise.Max := 40;
  FTxNoise.Position := 0;
  FTxNoise.OnChange := @TxOptionsChanged;

  FTxSummary := AddLabel(Options, '', 726, 30);

  Buttons := AddTopPanel(Sheet, 40);
  FTxSend := AddButton(Buttons, @RsTxSend, 12, 4, 110, @TxSendClick);
  FTxStop := AddButton(Buttons, @RsTxStop, 130, 4, 110, @TxStopClick);
  FTxSave := AddButton(Buttons, @RsTxSaveWav, 248, 4, 130, @TxSaveClick);
  FTxVerify := AddButton(Buttons, @RsTxVerify, 386, 4, 160, @TxVerifyClick);

  { 無線機で送る（要件 FR-T.2・T.3）。**止めるボタンは決して無効にしません。**
    Sending through the rig (FR-T.2, T.3). **The stop button is never
    disabled.** }
  Rig := AddTopPanel(Sheet, 40);
  AddLabel(Rig, @RsRigGroup, 12, 12);
  FRigConnect := AddButton(Rig, @RsRigConnect, 70, 4, 80, @RigConnectClick);
  FRigDisconnect := AddButton(Rig, @RsRigDisconnect, 156, 4, 96, @RigDisconnectClick);
  FRigSend := AddButton(Rig, @RsRigSend, 262, 4, 140, @RigSendClick);
  FRigStop := AddButton(Rig, @RsRigStop, 410, 4, 130, @RigStopClick);
  FRigPower := AddButton(Rig, @RsRigPower, 548, 4, 120, @RigPowerClick);
  FRigPower.Enabled := False;
  FRigStatus := AddLabel(Rig, '', 680, 12);

  FTxProgress := TProgressBar.Create(Sheet);
  FTxProgress.Parent := Sheet;
  FTxProgress.Height := 18;
  Stretch(FTxProgress, alTop);

  AddTopLabel(Sheet, @RsTxSending);
  Current := AddTopPanel(Sheet, 90);
  FTxCurrentChar := AddLabel(Current, '-', 12, 0);
  FTxCurrentChar.Font.Size := 28;
  FTxCurrentCode := AddLabel(Current, '', 12, 54);
  FTxCurrentCode.Font.Size := 16;
  FTxCurrentCode.Font.Name := 'Monospace';
end;

function TMainForm.BuildReceiveTab: TTabSheet;
var
  Sheet: TTabSheet;
  FileBox, LiveBox: TGroupBox;
  LiveControls, LevelPanel, WaterfallPanel, TuneTools, TextPanel: TPanel;
  TextTools, FindTools: TPanel;
begin
  Sheet := FPages.AddTabSheet;
  RegisterCaption(Sheet, @RsRxTab);
  Result := Sheet;

  FileBox := TGroupBox.Create(Sheet);
  FileBox.Parent := Sheet;
  FileBox.Height := 76;
  RegisterCaption(FileBox, @RsRxFromWav);
  Stretch(FileBox, alTop);

  { alRight は生成順に右から詰めるため、デコードボタンを先に作って最も右へ
    配置します。

    alRight fills from the right in creation order, so the decode button is
    created first and ends up furthest right. }
  FRxDecodeFile := AddButton(FileBox, @RsRxDecode, 0, 0, 120, @RxDecodeFileClick);
  Stretch(FRxDecodeFile, alRight);
  FRxBrowse := AddButton(FileBox, @RsRxBrowse, 0, 0, 90, @RxBrowseClick);
  Stretch(FRxBrowse, alRight);
  FRxFile := TEdit.Create(FileBox);
  FRxFile.Parent := FileBox;
  FRxFile.Text := '';
  Stretch(FRxFile, alClient);

  LiveBox := TGroupBox.Create(Sheet);
  LiveBox.Parent := Sheet;
  LiveBox.Height := 120;
  RegisterCaption(LiveBox, @RsRxFromInput);
  Stretch(LiveBox, alTop);

  LevelPanel := TPanel.Create(LiveBox);
  LevelPanel.Parent := LiveBox;
  LevelPanel.Align := alRight;
  LevelPanel.Width := 190;
  LevelPanel.BevelOuter := bvNone;
  AddLabel(LevelPanel, @RsRxInputLevel, 6, 4);
  FRxLevel := TProgressBar.Create(LevelPanel);
  FRxLevel.Parent := LevelPanel;
  FRxLevel.SetBounds(6, 24, 178, 20);
  FRxLevel.Max := 100;
  { 音が届いているかどうかを文字でも出します。レベルの棒だけでは、静かな信号と
    まったく鳴っていない状態を見分けられません（要件 FR-A.3）。

    Whether audio is arriving is stated in words as well. A bar alone does not
    separate a quiet signal from nothing at all (requirement FR-A.3). }
  FRxSignal := AddLabel(LevelPanel, '', 6, 48);

  LiveControls := TPanel.Create(LiveBox);
  LiveControls.Parent := LiveBox;
  LiveControls.Align := alClient;
  LiveControls.BevelOuter := bvNone;

  FRxStart := AddButton(LiveControls, @RsRxStart, 8, 22, 110, @RxStartClick);
  FRxStop := AddButton(LiveControls, @RsRxStop, 126, 22, 110, @RxStopClick);
  FRxClear := AddButton(LiveControls, @RsRxClear, 244, 22, 130, @RxClearClick);

  AddLabel(LiveControls, @RsRxDevice, 8, 56);
  FRxDevice := TComboBox.Create(LiveControls);
  FRxDevice.Parent := LiveControls;
  FRxDevice.SetBounds(78, 52, 380, 28);
  FRxDevice.Style := csDropDownList;
  FRxDevice.OnChange := @RxConfirmSpeedChanged;
  FRxDeviceRefresh := AddButton(LiveControls, @RsRxRescan, 466, 52, 80,
    @RxDeviceRefreshClick);

  AddLabel(LiveControls, @RsRxSettleLabel, 390, 4);
  FRxConfirmSpeed := TComboBox.Create(LiveControls);
  FRxConfirmSpeed.Parent := LiveControls;
  FRxConfirmSpeed.SetBounds(390, 22, 150, 28);
  FRxConfirmSpeed.Style := csDropDownList;
  RegisterItem(FRxConfirmSpeed, 0, @RsRxSettleFast);
  RegisterItem(FRxConfirmSpeed, 1, @RsRxSettleNormal);
  RegisterItem(FRxConfirmSpeed, 2, @RsRxSettleSure);
  FRxConfirmSpeed.ItemIndex := 1;
  FRxConfirmSpeed.OnChange := @RxConfirmSpeedChanged;

  { 受信のしかたを選びます。**いま何モードかが常に見えていること**が要件です
    （FR-I.6）ので、選択そのものを操作列に置き、説明を隣に添えます。
    How reception is used. The requirement is that the mode **is always visible**
    (FR-I.6), so the choice itself sits in the control row with a word of
    explanation beside it. }
  AddLabel(LiveControls, @RsRxModeLabel, 556, 56);
  FRxMode := TComboBox.Create(LiveControls);
  FRxMode.Parent := LiveControls;
  FRxMode.SetBounds(646, 52, 150, 28);
  FRxMode.Style := csDropDownList;
  { 表記は短くします。長い説明を選択肢に入れると、狭い窓で切れて**どちらを
    選んでいるのかが読めなくなります。**モードが常に見えていることが要件です
    （FR-I.6）。説明は状態表示に出します。
    The captions are short. A long explanation inside the choice is cut off in a
    narrow window and **then which mode is set cannot be read** — and the
    requirement is that it always can (FR-I.6). The explanation goes to the status
    line instead. }
  RegisterItem(FRxMode, 0, @RsRxModeContact);
  RegisterItem(FRxMode, 1, @RsRxModeWatch);
  RegisterItem(FRxMode, 2, @RsRxModeContest);
  FRxMode.ItemIndex := 0;
  { 通知は設定を読み終えてから繋ぎます。読み込みの代入で通知が走ると、起動した
    だけで「モードにしました」という身に覚えのない案内が出ます。
    The notification is attached after the settings are read: assigning during the
    load would announce a mode change the operator never made. }

  FRxAntiAlias := TCheckBox.Create(LiveControls);
  FRxAntiAlias.Parent := LiveControls;
  FRxAntiAlias.SetBounds(556, 26, 190, 24);
  RegisterCaption(FRxAntiAlias, @RsRxDenoise);
  FRxAntiAlias.Checked := True;
  FRxAntiAlias.OnChange := @RxConfirmSpeedChanged;

  { この塊は、**画面の並びと作った順が一致していない。**置き場所の都合（幅の
    広い入力装置の欄を先に取る、通知を繋ぐ順序）で作る順が決まり、LCL は
    タブ順序を作った順で取るためである。**置き場所は動かさず、順序だけを
    目で追う順に置き直す**（要件 NFR-5.6）。

    番号で与える。`A.TabOrder := B.TabOrder` は代入のたびに番号が詰め直される
    ので、**続けて書くと意図した並びにならない**（付録 AX.3）。

    1 行目: 受信開始・受信停止・表示をクリア・文字が決まるまで・帯域外の雑音
    2 行目: 入力装置・再検出・交信モード

    In this group **the order on screen and the order of construction do not
    agree.** What to build first was decided by where things go (the wide device
    box needs its space; notifications are attached in a certain order), and the
    LCL takes the Tab order from the order of construction. **The positions stay
    put; only the order is laid back out the way the eye follows it**
    (requirement NFR-5.6).

    Given by number: `A.TabOrder := B.TabOrder` renumbers as it assigns, so
    **written one after another it does not produce the order intended**
    (appendix AX.3). }
  FRxStart.TabOrder := 0;
  FRxStop.TabOrder := 1;
  FRxClear.TabOrder := 2;
  FRxConfirmSpeed.TabOrder := 3;
  FRxAntiAlias.TabOrder := 4;
  FRxDevice.TabOrder := 5;
  FRxDeviceRefresh.TabOrder := 6;
  FRxMode.TabOrder := 7;

  FRxBusy := AddTopLabel(Sheet, '');

  WaterfallPanel := TPanel.Create(Sheet);
  WaterfallPanel.Parent := Sheet;
  WaterfallPanel.Align := alBottom;
  WaterfallPanel.Height := RX_WATERFALL_DEFAULT_96;
  FRxWaterfallPanel := WaterfallPanel;
  WaterfallPanel.BevelOuter := bvNone;

  { 同調の操作はウォーターフォールのすぐ上に置きます。読みたい信号を選ぶ
    という一連の動作が 1 か所にまとまるためです（要件 FR-D.1、FR-D.5）。

    The tuning controls sit directly above the waterfall so that choosing a
    signal to read is one gesture in one place (requirements FR-D.1, FR-D.5). }
  TuneTools := TPanel.Create(WaterfallPanel);
  TuneTools.Parent := WaterfallPanel;
  TuneTools.Height := 30;
  TuneTools.Align := alTop;
  TuneTools.BevelOuter := bvNone;
  AddLabel(TuneTools, @RsRxTuneHint, 6, 7);
  FRxTuneClear := AddButton(TuneTools, @RsRxUntune, 0, 2, 110, @RxTuneClearClick);
  Stretch(FRxTuneClear, alRight);
  { **デコーダが聴いている音**を、そのまま鳴らします（要件 FR-A.6）。生の受信音
    ではありません。同調して帯域を絞ったあとの音なので、**機械が読み違えたとき
    に、機械に何が届いていたのかが耳で分かります。**
    Plays **what the decoder is listening to** (requirement FR-A.6), not the raw
    input: the audio after tuning and band limiting, so that when the machine
    reads something wrongly, **what reached the machine can be heard.** }
  FRxMonitor := AddButton(TuneTools, @RsRxMonitor, 0, 2, 120, @RxMonitorClick);
  Stretch(FRxMonitor, alRight);
  { 動いていく信号を追いかけるかどうか。既定は有効です。周波数を決め打ちで
    見張りたい場合のために、切れるようにしてあります（要件 FR-D.7）。

    Whether to follow a signal that moves; on by default, and switchable off
    for an operator deliberately watching one frequency (FR-D.7). }
  FRxTrack := TCheckBox.Create(TuneTools);
  FRxTrack.Parent := TuneTools;
  RegisterCaption(FRxTrack, @RsRxFollow);
  FRxTrack.Checked := True;
  FRxTrack.Align := alRight;
  FRxTrack.BorderSpacing.Right := 12;
  FRxTrack.OnChange := @RxTrackChanged;
  FRxTuneInfo := TLabel.Create(TuneTools);
  FRxTuneInfo.Parent := TuneTools;
  FRxTuneInfo.Align := alRight;
  FRxTuneInfo.Layout := tlCenter;
  FRxTuneInfo.Alignment := taRightJustify;
  FRxTuneInfo.BorderSpacing.Right := 10;
  FRxTuneInfo.BorderSpacing.Left := 24;

  FRxWaterfall := TWaterfallView.Create(WaterfallPanel);
  FRxWaterfall.Parent := WaterfallPanel;
  FRxWaterfall.OnTuneChanged := @RxTuneChanged;
  FRxWaterfall.OnBandwidthChanged := @RxBandwidthDragged;
  { 何も流れていないときの案内。**どちらを出しているかを控えておき**、言語を
    変えたら同じものを入れ直します（`ApplyTexts`）。
    The note shown while nothing flows. **Which one is showing is kept**, and
    the same one is put back when the language changes (`ApplyTexts`). }
  FWfMessage := @RsWfIdle;
  FRxWaterfall.Message_ := FWfMessage^;
  Stretch(FRxWaterfall, alClient);

  TextPanel := TPanel.Create(Sheet);
  TextPanel.Parent := Sheet;
  TextPanel.Align := alClient;
  TextPanel.BevelOuter := bvNone;
  AddTopLabel(TextPanel, @RsRxText);

  TextTools := TPanel.Create(TextPanel);
  TextTools.Parent := TextPanel;
  { つまみ（`TTrackBar`）は、部品側が要る高さを持っています。実測で 39 画素
    あり、34 の行に入れると下がはみ出していました。
    The slider carries a height of its own -- 39 pixels, measured -- and stuck
    out of the bottom of a 34-pixel row. }
  TextTools.Height := 42;
  StackBelow(TextTools);
  TextTools.Align := alTop;
  TextTools.BevelOuter := bvNone;

  FRxShowDoubt := TCheckBox.Create(TextTools);
  FRxShowDoubt.Parent := TextTools;
  { 幅は 200。**訳した文言のために詰めてあります**（要件 NFR-7.6）。中の文字は
    日本語 154 画素・英語 149 画素で、印の分を足しても 200 に収まります。空けた
    40 画素は隣の「濃淡」に回っています。
    200 wide: **tightened to make room for the translations** (NFR-7.6). The
    text inside is 154 pixels in Japanese and 149 in English, which fits 200
    with the box itself; the 40 pixels freed go to the label beside it. }
  FRxShowDoubt.SetBounds(6, 7, 200, 22);
  { **「正しさ」とは言いません**（要件 FR-C.5）。この値は「モデルがどれだけ
    迷わなかったか」であって、当たっているかどうかではありません。断定する語を
    使えば、利用者は確かめる手立て（読み直し・聴き直し）を使わなくなります。
    **Never "correctness"** (requirement FR-C.5): the value is how little the
    model wavered, not whether it was right. Words that assert would stop the
    operator reaching for the ways of checking -- re-reading and replaying. }
  RegisterCaption(FRxShowDoubt, @RsRxShade);
  FRxShowDoubt.Checked := True;
  FRxShowDoubt.OnChange := @RxDisplayChanged;

  { 「濃淡」は 28 画素ですが `Shade` は 45 画素あり、254 に置くとスライダーに
    6 画素食い込みます（付録 BC.4 で検査が見つけました）。210 へ寄せます。
    `濃淡` is 28 pixels and `Shade` is 45: at 254 it ran 6 pixels into the
    slider, which the check found (appendix BC.4). It moves to 210. }
  AddLabel(TextTools, @RsRxShadeAmount, 210, 9);
  FRxDoubtStrength := TTrackBar.Create(TextTools);
  FRxDoubtStrength.Parent := TextTools;
  FRxDoubtStrength.SetBounds(288, 2, 120, 30);
  FRxDoubtStrength.Min := 0;
  FRxDoubtStrength.Max := 100;
  FRxDoubtStrength.Position := 100;
  FRxDoubtStrength.ShowSelRange := False;
  FRxDoubtStrength.OnChange := @RxDisplayChanged;

  AddLabel(TextTools, @RsRxFontSize, 424, 9);
  FRxFontSize := AddSpin(TextTools, 512, 5, 9, 32, 14, @RxDisplayChanged);
  FRxCopy := AddButton(TextTools, @RsRxCopy, 604, 2, 90, @RxCopyClick);
  { 呼出符号と信号報告だけを送る口です（要件 FR-E.2）。全文をコピーしてから
    目で探して切り出すのでは「操作 1 回」になりません。
    Sends just the call sign and the report (requirement FR-E.2). Copying the
    whole transcript and then hunting through it by eye is not "one press". }
  FRxCopyCall := AddButton(TextTools, @RsRxCallAndRst, 700, 2, 130,
    @RxCopyCallClick);
  FRxCopyCall.Enabled := False;

  { 読んだ文字をウォーターフォールに重ねるか（要件 FR-D.6）。重ねた文字は信号を
    隠すので、切れるようにしてあります。
    Whether to lay the characters over the waterfall (requirement FR-D.6). They
    cover the signals, so they can be turned off. }
  FRxAlign := TCheckBox.Create(TextTools);
  FRxAlign.Parent := TextTools;
  FRxAlign.SetBounds(840, 6, 200, 24);
  RegisterCaption(FRxAlign, @RsRxOverlay);
  FRxAlign.Checked := True;
  FRxAlign.OnChange := @RxDisplayChanged;

  { 検索と聴き直しは、表示の設定とは別の行に置きます。同じ行に並べると、窓を
    狭くしたときに右端の操作が画面の外へ出て、押せなくなります（最小幅 900）。
    Search and replay go on their own row: on the same row as the display
    settings, narrowing the window pushes the right-hand controls off the screen
    where they cannot be pressed (the minimum width is 900). }
  FindTools := TPanel.Create(TextPanel);
  FindTools.Parent := TextPanel;
  { 2 段です。上の段に操作、下の段に聴き直しの状態を置きます。**1 段に収める
    と、状態の文が行の外へ出て、一度も見えませんでした**（付録 AW.3）。
    Two rows: the controls above, the replay's state below. **On one row the
    state ran off the end and was never once visible** (appendix AW.3). }
  FindTools.Height := 94;
  StackBelow(FindTools);
  FindTools.Align := alTop;
  FindTools.BevelOuter := bvNone;
  { モードによって出し入れするので、この行だけは手元に控えます。
    This row is shown and hidden by mode, so a reference to it is kept. }
  FFindTools := FindTools;

  { 検索（要件 FR-B.5）。溜まった受信テキストから、呼出符号や符丁を探すための
    ものです。入力しながら探し、Enter で次へ進みます。
    Search (requirement FR-B.5), for finding a call sign or an abbreviation in
    what has accumulated. It searches as you type; Enter moves to the next hit. }
  AddLabel(FindTools, @RsRxFind, 6, 9);
  FRxFind := TEdit.Create(FindTools);
  FRxFind.Parent := FindTools;
  FRxFind.SetBounds(42, 4, 150, 26);
  FRxFind.OnChange := @RxFindChanged;
  FRxFind.OnKeyDown := @RxFindKeyDown;
  FRxFindPrev := AddButton(FindTools, '<', 198, 2, 34, @RxFindPrevClick);
  FRxFindNext := AddButton(FindTools, '>', 234, 2, 34, @RxFindNextClick);
  FRxFindInfo := TLabel.Create(FindTools);
  FRxFindInfo.Parent := FindTools;
  FRxFindInfo.SetBounds(276, 9, 110, 20);

  { 聴き直しの操作。文字を押せば鳴るので、この 2 つは「もう一度」と「止める」
    だけです（要件 FR-E.10）。
    The replay controls. A press on a character already plays it, so these two
    are only "again" and "stop" (requirement FR-E.10). }
  { 交信を記録する操作は、受信テキストのすぐ下に置きます。読めた符号をその場で
    残す、という一連の動作が 1 か所にまとまります（要件 FR-E.3）。
    Recording a contact sits directly under the transcript, so that reading a call
    sign and keeping it is one gesture in one place (requirement FR-E.3). }
  FRxWorked := AddButton(FindTools, @RsRxLogContact, 396, 2, 100, @RxWorkedClick);
  FRxWorked.Enabled := False;
  FRxLogInfo := TLabel.Create(FindTools);
  FRxLogInfo.Parent := FindTools;
  FRxLogInfo.SetBounds(504, 9, 250, 20);

  FRxReplay := AddButton(FindTools, @RsRxReplay, 760, 2, 110, @RxReplayClick);
  FRxReplay.Enabled := False;
  FRxReplayStop := AddButton(FindTools, @RsRxReplayStop, 874, 2, 60, @RxReplayStopClick);
  FRxReplayStop.Enabled := False;
  FRxReplayInfo := TLabel.Create(FindTools);
  FRxReplayInfo.Parent := FindTools;
  { JCC/JCG（要件 FR-E.7）。**交信を記録する釦と同じ塊に置きます。**打ってから
    記録する、という順序が場所で分かるようにするためです。

    伸びる札（聴き直しの状態）は**この右**に置きます。逆に置くと、札が伸びた
    ぶんだけ入力欄に重なります。伸びるものは行の終わりに置く。

    JCC/JCG (requirement FR-E.7), in the same group as the button that records
    the contact, so that the order -- type it, then record -- is legible from
    where things sit.

    The label that grows (the replay state) goes **to the right of this**: the
    other way round, it would grow over the input. What grows belongs at the
    end of the row. }
  AddLabel(FindTools, 'JCC/JCG', 6, 40);
  FRxSubdivision := TEdit.Create(FindTools);
  FRxSubdivision.Parent := FindTools;
  FRxSubdivision.SetBounds(72, 36, 110, 26);
  FRxSubdivision.OnChange := @RxSubdivisionChanged;
  { 打ちながら読みが出ます。**記録を押してから「書けませんでした」と言われる
    のでは遅い。**
    The reading appears as it is typed: **being told "could not be written"
    after pressing record comes too late.** }
  FRxSubdivisionInfo := AddLabel(FindTools, '', 190, 40);
  RxSubdivisionChanged(nil);

  { 送った・受けた RST（要件 FR-E.11）。記録の行に置きます（見て、直して、
    記録する）。/ The reports sent and received (FR-E.11), on the logging row:
    look, correct, record. }
  AddLabel(FindTools, @RsRxRstRcvd, 6, 72);
  FRxRstRcvd := TEdit.Create(FindTools);
  FRxRstRcvd.Parent := FindTools;
  FRxRstRcvd.SetBounds(110, 68, 60, 26);
  FRxRstRcvd.MaxLength := 3;
  FRxRstRcvd.CharCase := ecUppercase;
  FRxRstRcvd.OnChange := @RxRstChanged;
  AddLabel(FindTools, @RsRxRstSent, 190, 72);
  FRxRstSent := TEdit.Create(FindTools);
  FRxRstSent.Parent := FindTools;
  FRxRstSent.SetBounds(294, 68, 60, 26);
  FRxRstSent.MaxLength := 3;
  FRxRstSent.CharCase := ecUppercase;
  FRxRstSent.OnChange := @RxRstChanged;
  FRxRstInfo := AddLabel(FindTools, '', 370, 72);

  { 読みの札（`FRxSubdivisionInfo`）が伸びる先を空けておきます。**実機で
    重なりました。**組み方の検査は、部品が生まれたときの文字しか見ていない
    ——起動時の「相手局の市郡区番号（任意）」は短く、打ってから出る
    「この形では記録に書けません（4・5・6 桁）」は長い（付録 AZ.3）。

    Room is left for the reading label (`FRxSubdivisionInfo`) to grow into.
    **They overlapped on the real screen.** The layout check only ever sees the
    text a control was born with: the short one at startup, not the longer one
    that appears once something is typed (appendix AZ.3). }
  FRxReplayInfo.SetBounds(560, 40, 300, 20);
  { 幅は文字に任せます（`AutoSize`）。**右端に留める指定をしていたのが誤りで
    した。**左右どちらも留めると幅は引き伸ばされ、置き場所を左へ移したあとも
    最初の置き場所から測った右端を守り続けて、親の外まで伸びていました。
    文字に任せれば、文が伸びた分だけ伸びます（付録 AW.3）。

    The width is left to the text (`AutoSize`). **Anchoring it to the right was
    the mistake**: anchored on both sides it is stretched, and it went on
    honouring a right edge measured from its first position even after being
    moved left, reaching past its parent. Left to the text it grows by exactly
    as much as the sentence does (appendix AW.3). }
  RegisterCaption(FRxReplayInfo, @RsRxReplayHint);

  FRxTranscript := TTranscriptView.Create(TextPanel);
  FRxTranscript.OnResize := @RxTranscriptResized;
  FRxTranscript.Parent := TextPanel;
  FRxTranscript.OnCharChosen := @RxCharChosen;
  FRxTranscript.Font.Size := 14;
  { まだ何も始めていない状態の言葉を、作った時点で入れます（要件 FR-B.1）。
    **起動直後の欄が白いままだと、起動できていないようにも読めます。**
    The words for the not-started state go in as the control is made
    (requirement FR-B.1): **a blank area just after launch reads as a program
    that did not start.** }
  FRxTranscript.Message_ := RsRxEmpty;
  Stretch(FRxTranscript, alClient);

  { バンドマップは受信テキストと同じ場所に置き、モードで入れ替えます。並べて
    出すと、どちらも狭くなって両方読めなくなります。
    The band map occupies the same place as the transcript and the mode swaps
    them. Side by side, both would be too narrow to read. }
  { 待つ符号を書く行。**待機モードのときだけ出します。**交信モードでは効かない
    ものを置いておくと、書いても何も起きない理由が分かりません
    （progressive disclosure）。
    The row for the call signs waited for. **It appears only in the waiting
    mode**: left on screen where it has no effect, there would be no way to tell
    why typing into it does nothing. }
  FWatchTools := TPanel.Create(TextPanel);
  FWatchTools.Parent := TextPanel;
  FWatchTools.Height := 34;
  StackBelow(FWatchTools);
  FWatchTools.Align := alTop;
  FWatchTools.BevelOuter := bvNone;
  AddLabel(FWatchTools, @RsRxWatchLabel, 6, 9);
  FRxWatch := TEdit.Create(FWatchTools);
  FRxWatch.Parent := FWatchTools;
  FRxWatch.SetBounds(80, 4, 260, 26);
  FRxWatch.TextHint := 'JA1ABC JH2XYZ';
  { 席を外しているときに気づけるよう、音でも知らせられます。**既定は切**です。
    入れていない人に、いきなり音が鳴ることはありません（付録 BY）。
    A chime can announce it too, for when the operator is away from the desk.
    **Off by default**: nobody who has not asked for it hears a sudden sound
    (appendix BY). }
  FRxWatchSound := TCheckBox.Create(FWatchTools);
  FRxWatchSound.Parent := FWatchTools;
  FRxWatchSound.SetBounds(352, 6, 160, 24);
  RegisterCaption(FRxWatchSound, @RsRxWatchSound);
  FRxWatchSound.Checked := False;
  FRxWatchSound.OnChange := @RxWatchSoundChanged;
  FRxWatchInfo := TLabel.Create(FWatchTools);
  FRxWatchInfo.Parent := FWatchTools;
  FRxWatchInfo.SetBounds(524, 9, 420, 20);

  { コンテスト中に見たいものを 1 行に置きます。**運用バンド・交信済みを隠す・
    時間あたりの交信数**の 3 つです。

    バンドを運用者が選ぶのは、**この機械が電波の周波数を知らない**ためです
    （受信機との連携は別仕様）。世界のコンテストソフトは無線機から周波数を
    受け取りますが、それが無い環境では手で選ばせるのが通例です。

    What a contest wants on one row: the band being worked, hiding what is
    already worked, and the contacts per hour.

    The operator chooses the band because **this machine does not know the
    radio's frequency** (the receiver link is a separate specification). Contest
    software elsewhere takes it from the radio; without that, choosing by hand is
    the usual arrangement. }
  FContestTools := TPanel.Create(TextPanel);
  FContestTools.Parent := TextPanel;
  FContestTools.Height := 34;
  StackBelow(FContestTools);
  FContestTools.Align := alTop;
  FContestTools.BevelOuter := bvNone;
  AddLabel(FContestTools, @RsRxBandLabel, 6, 9);
  FRxBand := TComboBox.Create(FContestTools);
  FRxBand.Parent := FContestTools;
  FRxBand.SetBounds(96, 4, 130, 26);
  FRxBand.Style := csDropDownList;
  { 表記は運用者の言葉（MHz）で、記録には ADIF の名前で残します。
    Shown in the operator's terms (MHz) and recorded under the ADIF name. }
  RegisterItem(FRxBand, 0, @RsRxBandAny);
  FRxBand.Items.Add('1.9 MHz');
  FRxBand.Items.Add('3.5 MHz');
  FRxBand.Items.Add('7 MHz');
  FRxBand.Items.Add('14 MHz');
  FRxBand.Items.Add('21 MHz');
  FRxBand.Items.Add('28 MHz');
  FRxBand.Items.Add('50 MHz');
  FRxBand.Items.Add('144 MHz');
  FRxBand.Items.Add('430 MHz');
  { WARC バンドは後から足したので末尾です。**保存するのは項目の番号**なので、
    途中へ挟むと古い設定ファイルの番号がずれます（要件 FR-T.7）。
    The WARC bands were added later and so sit at the end: **the settings file
    stores the item's index**, and inserting them in between would shift the
    indices of older files (FR-T.7). }
  FRxBand.Items.Add('10 MHz');
  FRxBand.Items.Add('18 MHz');
  FRxBand.Items.Add('24 MHz');
  FRxBand.ItemIndex := 0;
  FRxBand.OnChange := @RxContestChanged;

  FRxHideWorked := TCheckBox.Create(FContestTools);
  FRxHideWorked.Parent := FContestTools;
  FRxHideWorked.SetBounds(240, 6, 190, 24);
  RegisterCaption(FRxHideWorked, @RsRxHideWorked);
  FRxHideWorked.Checked := True;
  FRxHideWorked.OnChange := @RxContestChanged;

  FRxRate := TLabel.Create(FContestTools);
  FRxRate.Parent := FContestTools;
  FRxRate.SetBounds(444, 9, 500, 20);

  FRxBandMap := TBandMapView.Create(TextPanel);
  FRxBandMap.Parent := TextPanel;
  FRxBandMap.OnStationChosen := @RxStationChosen;
  FRxBandMap.Visible := False;
  Stretch(FRxBandMap, alClient);

  { タブ順序を**見た目の順序**に合わせます（要件 NFR-5.6）。

    LCL はタブ順序を**作った順**で決めます。ウォーターフォールの枠は画面では
    いちばん下ですが、`alBottom` で場所を先に取る必要があるため、受信テキストの
    枠より**先に**作ってあります。そのままだと、Tab を押していくと

      … → 同調の操作 → ウォーターフォール → **上へ戻って** 受信テキストの行 → …

    と飛びます。実際に Tab を 18 回押して画面を撮り、焦点が y≈834 から y≈425 へ
    戻ることを測って見つけました。

    **並べ替えるのは順序だけで、場所は動かしません。**`TabOrder` を入れ替えると、
    LCL がほかの兄弟の番号を詰め直します。

    The tab order is made to match **the order on screen** (requirement NFR-5.6).

    LCL decides tab order by **the order things are created**. The waterfall's
    panel is at the very bottom of the screen, but being `alBottom` it has to
    claim its space first, so it is created **before** the transcript's panel.
    Left alone, tabbing runs

      ... -> tuning controls -> waterfall -> **back up** to the transcript row ...

    which was found by pressing Tab eighteen times and photographing the screen:
    the focus goes from y 834 back to y 425.

    **Only the order is changed, never the placement**: assigning `TabOrder` has
    LCL renumber the siblings around it. }
  WaterfallPanel.TabOrder := TextPanel.TabOrder;
end;

{ 受信練習のタブ（要件 FR-F.3）。

  **出題は画面に出しません。**見えていれば練習になりません。答え合わせを押した
  ときにだけ、正解と間違いの傾向を出します。

  音程と音量は送信タブの設定を使います。**同じものを 2 か所に置くと、片方だけを
  直したときに気づけません**（教訓 10.3）。ここに置くのは、要件が挙げる 3 つ
  ――出題の種類（文字集合）・速度・雑音――だけです。

  The receive practice tab (requirement FR-F.3).

  **The exercise is not shown**: visible, it would not be practice. The answer
  and the tendency of the mistakes appear only when the copy is marked.

  The pitch and the volume come from the transmit settings: **the same thing in
  two places is a thing that can be changed in one and not the other**
  (lesson 10.3). What lives here is the three the requirement names -- the kind
  of material, which is also the character set, the speed, and the noise. }
function TMainForm.BuildPracticeTab: TTabSheet;
var
  Sheet: TTabSheet;
  Options: TGroupBox;
  Buttons: TPanel;
  Kind: TExerciseKind;
begin
  Sheet := FPages.AddTabSheet;
  RegisterCaption(Sheet, @RsPrTab);
  Result := Sheet;

  Options := TGroupBox.Create(Sheet);
  Options.Parent := Sheet;
  Options.Height := 124;
  RegisterCaption(Options, @RsPrExercise);
  Stretch(Options, alTop);

  AddLabel(Options, @RsPrKind, 14, 8);
  FPrKind := TComboBox.Create(Options);
  FPrKind.Parent := Options;
  FPrKind.SetBounds(14, 28, 200, 28);
  FPrKind.Style := csDropDownList;
  for Kind := Low(TExerciseKind) to High(TExerciseKind) do
    RegisterItem(FPrKind, Ord(Kind), EXERCISE_NAMES[Kind]);
  FPrKind.ItemIndex := 0;
  FPrKind.OnChange := @PrOptionsChanged;

  AddLabel(Options, @RsPrGroups, 230, 8);
  FPrGroups := AddSpin(Options, 230, 30, 1, 50, 10, @PrOptionsChanged);
  AddLabel(Options, @RsPrWpm, 330, 8);
  FPrWpm := AddSpin(Options, 330, 30, 5, 40, 20, @PrOptionsChanged);

  AddLabel(Options, @RsPrNoise, 440, 8);
  FPrNoise := TTrackBar.Create(Options);
  FPrNoise.Parent := Options;
  FPrNoise.SetBounds(440, 26, 160, 36);
  FPrNoise.Min := 0;
  FPrNoise.Max := 40;
  FPrNoise.Position := 10;
  FPrNoise.OnChange := @PrOptionsChanged;

  AddLabel(Options, @RsPrToneNote, 620, 34);

  { 遅延表示（要件 FR-F.4）。**既定は入れておきます。**「先に自分で写し、後から
    正解を出す」がこのタブの狙いで、押さないと何も出ないより、遅れて出るほうが
    練習の形に近いためです。切れば、これまでどおり答え合わせまで何も出ません。
    Delayed reveal (requirement FR-F.4), **on by default**: copying first and
    seeing the answer afterwards is what this tab is for, and an answer that
    arrives late is closer to that than one that arrives only when asked.
    Switched off, nothing appears until the copy is marked, as before. }
  FPrDelay := TCheckBox.Create(Options);
  FPrDelay.Parent := Options;
  FPrDelay.SetBounds(14, 74, 210, 24);
  RegisterCaption(FPrDelay, @RsPrDelay);
  FPrDelay.Checked := True;
  FPrDelay.OnChange := @PrOptionsChanged;

  AddLabel(Options, @RsPrDelaySeconds, 230, 78);
  FPrDelaySeconds := AddSpin(Options, 330, 74, 0, REVEAL_DELAY_MAX_SECONDS,
    REVEAL_DELAY_DEFAULT_SECONDS, @PrOptionsChanged);
  AddLabel(Options, @RsPrDelayNote, 440, 78);

  Buttons := AddTopPanel(Sheet, 40);
  FPrPlay := AddButton(Buttons, @RsPrPlay, 12, 4, 150, @PrPlayClick);
  FPrAgain := AddButton(Buttons, @RsPrAgain, 170, 4, 150, @PrAgainClick);
  FPrAgain.Enabled := False;
  FPrStop := AddButton(Buttons, @RsPrStop, 328, 4, 100, @PrStopClick);
  FPrStop.Enabled := False;
  FPrSummary := AddLabel(Buttons, @RsPrStartHint, 440, 12);

  AddTopLabel(Sheet, @RsPrCopyLabel);
  FPrCopy := TMemo.Create(Sheet);
  FPrCopy.Parent := Sheet;
  FPrCopy.Height := 90;
  FPrCopy.ScrollBars := ssAutoVertical;
  FPrCopy.Font.Size := 14;
  Stretch(FPrCopy, alTop);

  Buttons := AddTopPanel(Sheet, 40);
  FPrMark := AddButton(Buttons, @RsPrMark, 12, 4, 130, @PrMarkClick);
  FPrMark.Enabled := False;
  FPrResult := AddLabel(Buttons, '', 156, 12);

  AddTopLabel(Sheet, @RsPrAnswer);
  FPrAnswer := TMemo.Create(Sheet);
  FPrAnswer.Parent := Sheet;
  FPrAnswer.Height := 70;
  FPrAnswer.ReadOnly := True;
  FPrAnswer.ScrollBars := ssAutoVertical;
  FPrAnswer.Font.Size := 14;
  Stretch(FPrAnswer, alTop);

  FPrMistakes := AddTopLabel(Sheet, '');
  FPrHistory := AddTopLabel(Sheet, '');
  PrShowHistory;
end;

{ 練習の記録の置き場所。送信訓練の記録と同じところに置きます。
  Where the practice records live: beside the send-practice records. }
function TMainForm.CopyLogFileName: string;
begin
  Result := IncludeTrailingPathDelimiter(
    ExtractFilePath(ConfigFileName)) + 'copy.csv';
end;

{ これまでの練習から見えることを 1 行にします（要件 FR-F.5）。

  **回数が少ないうちは傾向を出しません。**1 度読み違えただけの符号を
  「いつも間違える符号」として見せると、運用者は直すところを取り違えます。

  Puts what past sessions show into one line (requirement FR-F.5).

  **No tendency is offered while there are few sessions.** A character misread
  once, shown as one always misread, sends the operator to practise the wrong
  thing. }
procedure TMainForm.PrShowHistory;
var
  Items: TCopyRecords;
  Found: TConfusions;
  Line: string;
begin
  if FPrHistory = nil then
    Exit;
  Items := LoadCopyRecords(CopyLogFileName);
  if Length(Items) = 0 then
  begin
    FPrHistory.Caption := '';
    Exit;
  end;
  Line := Format(RsPrHistory, [Length(Items), AveragePercent(Items, 10)]);
  if Length(Items) >= COPYLOG_MIN_SESSIONS then
  begin
    Found := TallyConfusions(Items, 3);
    if Length(Found) > 0 then
      Line := Format(RsPrConfusions, [Line, ConfusionCaption(Found)]);
  end;
  FPrHistory.Caption := Line;
end;

function TMainForm.PracticeKind: TExerciseKind;
begin
  if (FPrKind = nil) or (FPrKind.ItemIndex < 0) or
     (FPrKind.ItemIndex > Ord(High(TExerciseKind))) then
    Exit(ekLetters);
  Result := TExerciseKind(FPrKind.ItemIndex);
end;

{ いまの出題を、いまの設定で音にします。**出題そのものは作り直しません。**
  速度や雑音を変えて同じ問題をもう一度聴けることが練習では要ります。
  Turns the current exercise into sound with the current settings. **The
  exercise itself is not rebuilt**: hearing the same one again at another speed
  or with more noise is part of practising. }
procedure TMainForm.PrRender;
var
  Timing: TCWTiming;
  Options: TCWToneOptions;
begin
  FPrSamples := nil;
  FPrRevealTimes := nil;
  if FPrText = '' then
    Exit;
  Timing.CharWpm := FPrWpm.Value;
  Timing.TextWpm := FPrWpm.Value;
  Options := DefaultToneOptions;
  Options.SampleRate := FTxSampleRate;
  Options.ToneHz := FTxToneHz.Value;
  Options.Amplitude := FTxVolume.Position / 100;
  Options.NoiseAmplitude := FPrNoise.Position / 100;
  try
    FPrSamples := TextToPCM(FPrText, Timing, Options);
    { 見せてよい時刻は、鳴らす音と**同じ設定から**作ります。別々に作れば、
      速度を変えたときに片方だけが変わります（教訓 10.3）。
      The reveal times are built from **the same settings as the sound**; built
      separately, a change of speed would move one and not the other
      (lesson 10.3). }
    FPrRevealTimes := RevealTimes(FPrText, Timing, Options.LeadInSeconds,
      FPrDelaySeconds.Value);
    FPrSummary.Caption := Format(RsPrSummary,
      [Length(FPrText), Length(FPrSamples) / FTxSampleRate]);
  except
    on E: Exception do
    begin
      FPrSamples := nil;
      FPrRevealTimes := nil;
      FPrSummary.Caption := E.Message;
    end;
  end;
end;

procedure TMainForm.PrOptionsChanged(Sender: TObject);
begin
  MarkSettingsDirty;
  { 速度と雑音は、いまの出題にそのまま効きます。出す内容を変えたときは、
    次の出題から効きます。**いま聴いている問題が、押していないのに別のものへ
    変わってはいけません。**
    Speed and noise take effect on the exercise in hand; a change of material
    takes effect at the next one. **What is being listened to must not turn into
    something else without being asked.** }
  if (Sender = FPrWpm) or (Sender = FPrNoise) or
     (Sender = FPrDelaySeconds) then
    PrRender;
  { 遅延表示を切ったら、出ているものを引っ込めます。**答え合わせより前に
    見えたままにはしません。**
    Switching the delayed reveal off takes back what it has shown: **nothing
    stays visible ahead of the marking.** }
  if (Sender = FPrDelay) and (FPrDelay <> nil) and not FPrDelay.Checked then
  begin
    FPrRevealing := False;
    if (FPrAnswer <> nil) and (FPrResult <> nil) and (FPrResult.Caption = '') then
      FPrAnswer.Clear;
  end;
end;

procedure TMainForm.PrPlayClick(Sender: TObject);
begin
  { 出題は毎回変えます。種は時刻から採ります。**同じ問題が続けて出ると、
    覚えているかどうかを測ることになります。**
    A new exercise each time, seeded from the clock: **the same one twice over
    would measure remembering rather than copying.** }
  FPrText := MakeExercise(PracticeKind, FPrGroups.Value,
    Round(Frac(Now) * MSecsPerDay) + Random(1000));
  FPrCopy.Clear;
  FPrAnswer.Clear;
  FPrResult.Caption := '';
  FPrMistakes.Caption := '';
  FPrRevealing := False;
  PrRender;
  FPrAgain.Enabled := Length(FPrSamples) > 0;
  FPrMark.Enabled := FPrText <> '';
  PrAgainClick(nil);
  if FPrCopy.CanFocus then
    FPrCopy.SetFocus;
end;

procedure TMainForm.PrAgainClick(Sender: TObject);
begin
  if Length(FPrSamples) = 0 then
    Exit;
  try
    if not LoadPortAudio(FSetPortAudio.Text) then
      raise EDeepCW.Create(PortAudioLoadError);
    { ほかの音を止めてから鳴らします。2 つ重なると、どちらを写しているのか
      分からなくなります。
      Anything else playing is stopped first: two sounds at once leave no telling
      which is being copied. }
    FReviewPlay.Stop;
    FPlayback.Stop;
    FTxPlaying := False;
    FPlayback.Play(FPrSamples, FTxSampleRate);
    FPrStop.Enabled := True;
    { 遅らせて出すなら、ここから数えます。鳴らし直すたびに数え直します。
      **前に鳴らしたぶんの続きから出しては、聴いていない文字が出ます。**
      The reveal is counted from here and counted again on every replay:
      continuing from where the previous playing left off would show characters
      that were never heard. }
    FPrRevealing := FPrDelay.Checked and (Length(FPrRevealTimes) > 0);
    FPrRevealFrom := Now;
    if FPrRevealing then
      FPrAnswer.Clear;
    SetStatus('', '', RsPrPlaying);
  except
    on E: Exception do
      ReportError(RsCtxPractice, E);
  end;
end;

procedure TMainForm.PrStopClick(Sender: TObject);
begin
  FPlayback.Stop;
  FPrStop.Enabled := False;
  { 止めたら、出すのも止めます。**聴いていない文字の正解は出しません。**
    Stopped means stopped: **the answer to what was not heard does not
    appear.** }
  FPrRevealing := False;
end;

{ 写したものを突き合わせ、正解と間違いの傾向を出します（要件 FR-F.3・FR-F.5）。

  **正解はここで初めて見せます。**出題のときに見せていれば、練習になりません。

  Marks the copy and shows the answer with the tendency of the mistakes
  (requirements FR-F.3, FR-F.5).

  **The answer is shown here and not before**: shown when it was sent, there
  would have been nothing to practise. }
procedure TMainForm.PrMarkClick(Sender: TObject);
var
  Score: TCopyScore;
  Mistakes: string;
  Item: TCopyRecord;
begin
  if FPrText = '' then
  begin
    SetStatus('', '', RsPrNeedExercise);
    Exit;
  end;
  { 答え合わせが済めば、遅らせて出す意味はもうありません。全部を出します。
    Once the copy is marked there is nothing left to delay; the whole answer
    goes up. }
  FPrRevealing := False;
  Score := ScoreCopy(FPrText, FPrCopy.Text);
  FPrAnswer.Text := FPrText;
  FPrResult.Caption := Format(RsPrResult,
    [Score.Percent, Score.Total, Score.Same, Score.Wrong, Score.Missed,
     Score.Extra]);
  Mistakes := MistakeSummary(Score);
  if Mistakes = '' then
    FPrMistakes.Caption := RsPrNoMistakes
  else
    FPrMistakes.Caption := Format(RsPrMistakes, [Mistakes]);

  { 1 回ぶんを残します（要件 FR-F.5）。**残すのは出題と写しそのもの**で、
    傾向はそこから数え直します（`DeepCW.CopyLog` の頭書き）。

    残せなくても練習は続きます。**答え合わせができたのに「記録できません」で
    止まるほうが損です**（受信は fail-soft）。

    One session is kept (requirement FR-F.5). **What is kept is the text sent
    and the text copied**; the tendency is counted from those (see the head of
    `DeepCW.CopyLog`).

    Practice carries on when it cannot be kept: **stopping at "cannot record"
    after the copy has been marked costs more than it saves** (receive is
    fail-soft). }
  Item := Default(TCopyRecord);
  Item.When_ := Now;
  { 記録には鍵を書きます。表示名は訳されるためです（要件 NFR-7.6）。
    The key is what is recorded: the name shown is translated (NFR-7.6). }
  Item.Kind := EXERCISE_KEYS[PracticeKind];
  Item.Groups := FPrGroups.Value;
  Item.Wpm := FPrWpm.Value;
  Item.Noise := FPrNoise.Position / 100;
  Item.Total := Score.Total;
  Item.Same := Score.Same;
  Item.Wrong := Score.Wrong;
  Item.Missed := Score.Missed;
  Item.Extra := Score.Extra;
  Item.Percent := Score.Percent;
  Item.Truth := FPrText;
  Item.Typed := FPrCopy.Text;
  try
    AppendCopyRecord(CopyLogFileName, Item);
  except
    on E: Exception do
      LogDiagnostic(RsCtxPracticeLog, E.Message);
  end;
  PrShowHistory;
end;

{ 遅らせて正解を出します（要件 FR-F.4）。

  0.2 秒ごとに呼ばれ、鳴らし始めからの経過で「見せてよいところまで」を出します。
  **鳴り終わったあとも続けます。**最後の文字は、鳴り終わってから遅延の秒数だけ
  経ってようやく出るためです。

  Reveals the answer late (requirement FR-F.4).

  Called every 0.2 seconds, it shows as much as the time since the sound started
  allows. **It carries on after the sound has ended**: the last character is due
  only once the delay has passed since it finished sounding. }
procedure TMainForm.UpdatePracticeReveal;
var
  Elapsed: Double;
  Shown: string;
begin
  if not FPrRevealing then
    Exit;
  { 音が鳴らなかったのなら、正解を出す理由はありません。**聴いていないものの
    答えを出すのは、練習ではなく答えを見せているだけです。**再生は別のスレッド
    で失敗するため、ここで拾います。
    If the sound never played there is no reason to show the answer: **showing
    what was not heard is not practice.** The playing fails on a thread of its
    own, so it is picked up here. }
  if FPlayback.LastError <> '' then
  begin
    FPrRevealing := False;
    SetStatus('', '', RsPrNoSound);
    Exit;
  end;
  Elapsed := (Now - FPrRevealFrom) * SecsPerDay;
  Shown := RevealedText(FPrText, FPrRevealTimes, Elapsed);
  { 同じ文字列を入れ直すと、選択位置と描画が毎回動きます。変わったときだけ。
    Re-assigning the same text moves the caret and repaints for nothing; only
    on a change. }
  if FPrAnswer.Text <> Shown then
    FPrAnswer.Text := Shown;
  { 全部出たら数えるのをやめます。**止め時が無ければ、次の出題まで回り続けます。**
    Once it is all shown there is nothing left to count: without a stopping
    point this would keep running until the next exercise. }
  if (Length(FPrRevealTimes) > 0) and
     (Elapsed >= FPrRevealTimes[High(FPrRevealTimes)]) then
    FPrRevealing := False;
end;


{ 送信訓練のタブ（要件 FR-H）。

  **ここでは課題文を画面に出します。**受信練習（FR-F.3）とは逆です。あちらは
  写す練習なので答えを伏せますが、こちらは**その文を自分の鍵で送る**練習
  なので、見えていなければ始まりません。

  電波は出しません。無線機のモニタートーンを、受信と同じ入力から取り込むだけ
  です（要件 FR-H.1）。ダミーロードでも、モニターだけでも同じように動きます。

  The send-practice tab (requirement FR-H).

  **The text is shown here**, unlike the receive practice (FR-F.3): there the
  answer is kept back because copying is the exercise, here the exercise is to
  send that text with one's own key, and nothing can begin unless it is visible.

  Nothing is transmitted. The transceiver's monitor tone comes in through the
  same input as reception (FR-H.1), which works into a dummy load or with the
  monitor alone. }
{ 診断情報を控えとして写します（要件 FR-G.5）。

  **写す前に作り直します。**設定タブを開いたまま時間が経っていることがあり、
  古い数字を貼っても助けになりません。
  Copies the diagnostics (requirement FR-G.5). **They are rebuilt first**: the
  tab may have been open for a while, and stale figures are no help to anyone. }
procedure TMainForm.SetCopyInfoClick(Sender: TObject);
var
  Report: string;
begin
  RefreshInfo;
  Report := BuildDiagnosticReport(FSetInfo.Lines.Text, GetUserDir, Now);
  Clipboard.AsText := Report;
  SetStatus('', '', Format(RsDiagCopied,
    [Length(FSetInfo.Lines.Text.Split([LineEnding])) + 3]));
end;

function TMainForm.BuildFistTab: TTabSheet;
var
  Sheet: TTabSheet;
  Options: TGroupBox;
  Buttons: TPanel;
  Kind: TExerciseKind;
  Standard_: TFistStandard;
  Item: TFistItem;
  KeyKind: Integer;
  Bottom: TPanel;
begin
  Sheet := FPages.AddTabSheet;
  RegisterCaption(Sheet, @RsFtTab);
  Result := Sheet;

  Options := TGroupBox.Create(Sheet);
  Options.Parent := Sheet;
  Options.Height := 124;
  RegisterCaption(Options, @RsFtTextAndScore);
  Stretch(Options, alTop);

  AddLabel(Options, @RsFtKind, 14, 8);
  FFtKind := TComboBox.Create(Options);
  FFtKind.Parent := Options;
  FFtKind.SetBounds(14, 28, 200, 28);
  FFtKind.Style := csDropDownList;
  for Kind := Low(TExerciseKind) to High(TExerciseKind) do
    RegisterItem(FFtKind, Ord(Kind), EXERCISE_NAMES[Kind]);
  FFtKind.ItemIndex := Ord(ekQso);
  FFtKind.OnChange := @FtOptionsChanged;

  AddLabel(Options, @RsFtGroups, 230, 8);
  FFtGroups := AddSpin(Options, 230, 30, 1, 20, 3, @FtOptionsChanged);

  AddLabel(Options, @RsFtKeyKind, 330, 8);
  FFtKey := TComboBox.Create(Options);
  FFtKey.Parent := Options;
  FFtKey.SetBounds(330, 28, 150, 28);
  FFtKey.Style := csDropDownList;
  { 並びは `FIST_KEY_KEYS` と 1 対 1 です。**記録には鍵を書き、画面には名前を
    出します**（要件 NFR-7.6）。
    The order matches `FIST_KEY_KEYS` one for one: **the key is what is
    recorded, the name is what is shown** (NFR-7.6). }
  for KeyKind := Low(FIST_KEY_NAMES) to High(FIST_KEY_NAMES) do
    RegisterItem(FFtKey, KeyKind, FIST_KEY_NAMES[KeyKind]);
  FFtKey.ItemIndex := 0;
  FFtKey.OnChange := @FtOptionsChanged;

  AddLabel(Options, @RsFtBasis, 496, 8);
  FFtBasis := TComboBox.Create(Options);
  FFtBasis.Parent := Options;
  FFtBasis.SetBounds(496, 28, 180, 28);
  FFtBasis.Style := csDropDownList;
  for Standard_ := Low(TFistStandard) to High(TFistStandard) do
    RegisterItem(FFtBasis, Ord(Standard_), FIST_STANDARD_NAMES[Standard_]);
  FFtBasis.ItemIndex := 0;
  FFtBasis.OnChange := @FtOptionsChanged;
  { 採点の基準のすぐ下に置きます。右隣に置くと行に収まりませんでした。
    Directly under the basis; to its right it did not fit on the row. }
  AddLabel(Options, @RsFtBasisNote, 496, 60);

  { 課題文なしでも測れますが、間隔の種別をしきい値で分けるため**参考値**に
    なります（要件 FR-H.3）。画面でそう分かるようにします。
    Without a text it still measures, but the kinds of gap are split at a
    threshold and the result is **indicative only** (FR-H.3); the screen says
    so. }
  FFtFree := TCheckBox.Create(Options);
  FFtFree.Parent := Options;
  FFtFree.SetBounds(14, 74, 300, 24);
  RegisterCaption(FFtFree, @RsFtFree);
  FFtFree.OnChange := @FtOptionsChanged;

  FFtNew := AddButton(Options, @RsFtNew, 330, 70, 150, @FtNewClick);

  Buttons := AddTopPanel(Sheet, 40);
  FFtStart := AddButton(Buttons, @RsFtStart, 12, 4, 120, @FtStartClick);
  FFtStop := AddButton(Buttons, @RsFtFinish, 140, 4, 150, @FtStopClick);
  FFtStop.Enabled := False;
  FFtWav := AddButton(Buttons, @RsFtFromWav, 298, 4, 150, @FtWavClick);
  FFtStatus := AddLabel(Buttons, @RsFtStartHint, 460, 12);

  AddTopLabel(Sheet, @RsFtTextLabel);
  FFtText := TMemo.Create(Sheet);
  FFtText.Parent := Sheet;
  { **推移（要件 FR-H.10）に高さを残すため、上の欄は詰めます。**窓の既定の
    高さでは、足し合わせるとグラフの場所が無くなります。
    **The sections above are kept tight so that the trend has room**: at the
    window's default height they would otherwise add up to leave none. }
  FFtText.Height := 52;
  { **書き換えられるようにします。**自分で決めた文を送りたいことがあり、
    録音から採点するときは、その録音で送った文をここへ入れます。
    **It can be edited**: an operator may want to send a text of their own, and
    scoring from a recording means putting in the text that recording holds. }
  FFtText.ReadOnly := False;
  FFtText.ScrollBars := ssAutoVertical;
  FFtText.Font.Size := 14;
  Stretch(FFtText, alTop);

  AddTopLabel(Sheet, @RsFtScore);
  { 採点の欄は、余った高さを受け取ります。**下端の推移と、上の課題文は
    読める高さを先に取り、伸び縮みはここが引き受けます。**中身は巻き取れます。
    The score takes what height is left: **the trend at the foot and the text
    above it claim a readable height first**, and the give and take happens
    here, where the content scrolls. }
  FFtResult := TMemo.Create(Sheet);
  FFtResult.Parent := Sheet;
  FFtResult.ReadOnly := True;
  FFtResult.ScrollBars := ssAutoVertical;
  Stretch(FFtResult, alClient);

  FFtAdvice := AddTopLabel(Sheet, '');

  { 推移（要件 FR-H.10）。**鍵の種類ごとに分けて出せます。**鍵が違えば送り方が
    違うので、混ぜて並べた線は上達ではなく持ち替えを映します。

    場所は下端に固定します。**窓の高さに応じて分け合うと、既定の高さでは
    グラフが 90 画素ほどになり、目盛りの間隔より線の太さが勝ちます。**
    読み切れる高さを先に取り、余りを一覧へ渡します（一覧は巻き取れます）。

    The trend (requirement FR-H.10), **which can be drawn for one kind of key at
    a time**: a different key is a different way of sending, and a line through
    both would show the change of key rather than progress.

    It is pinned to the foot of the tab. **Sharing the height out instead left
    the graph about ninety pixels at the window's default size, where the lines
    are thicker than the gaps between the gridlines.** The height that can be
    read is taken first, and what is left goes to the list, which scrolls. }
  Bottom := TPanel.Create(Sheet);
  Bottom.Parent := Sheet;
  Bottom.Align := alBottom;
  Bottom.Height := 304;
  Bottom.BevelOuter := bvNone;

  { 記録の一覧も推移と同じ塊に入れます。**どちらも「これまで」を見るもの**
    なので、窓を縮めたときに片方だけが消えないようにします。
    The list of records sits in the same block as the trend: **both are for
    looking back**, so a shrinking window does not take one and leave the
    other. }
  AddTopLabel(Bottom, @RsFtHistory);
  FFtHistory := TMemo.Create(Bottom);
  FFtHistory.Parent := Bottom;
  FFtHistory.ReadOnly := True;
  FFtHistory.ScrollBars := ssAutoVertical;
  FFtHistory.Height := 72;
  Stretch(FFtHistory, alTop);

  { 上から順に積むには、この画面の決まりどおり `StackBelow` を通します。
    **通さないと、あとから作った行が先頭へ回ります**（記録の一覧より上に
    推移の操作が出てしまいました）。
    Stacked in order through `StackBelow`, as the rest of this window does:
    **without it a row made later comes out first** -- the trend's controls
    appeared above the list of records. }
  Buttons := TPanel.Create(Bottom);
  Buttons.Parent := Bottom;
  Buttons.Height := 40;
  StackBelow(Buttons);
  Buttons.Align := alTop;
  Buttons.BevelOuter := bvNone;
  { 下の欄に何を出すか（要件 FR-H.9・FR-H.10）。**推移は「回を追って」、
    分布は「いまの 1 回の中で」を見るものです。**同時に出すには場所が足りず、
    どちらも小さくするより、選べるほうがよいと判断しました。
    What the panel below shows (FR-H.9, FR-H.10): **the trend looks across
    sessions, the distributions inside one.** There is not room for both, and
    choosing beats shrinking each to half. }
  AddLabel(Buttons, @RsFtBottomLabel, 12, 12);
  FFtBottomKind := TComboBox.Create(Buttons);
  FFtBottomKind.Parent := Buttons;
  FFtBottomKind.SetBounds(104, 6, 130, 28);
  FFtBottomKind.Style := csDropDownList;
  RegisterItem(FFtBottomKind, 0, @RsFtTrend);
  RegisterItem(FFtBottomKind, 1, @RsFtHistogram);
  FFtBottomKind.ItemIndex := 0;
  FFtBottomKind.OnChange := @FtBottomChanged;

  AddLabel(Buttons, @RsFtTrendItemLabel, 252, 12);
  FFtTrendItem := TComboBox.Create(Buttons);
  FFtTrendItem.Parent := Buttons;
  FFtTrendItem.SetBounds(360, 6, 150, 28);
  FFtTrendItem.Style := csDropDownList;
  RegisterItem(FFtTrendItem, 0, @RsFtOverall);
  RegisterItem(FFtTrendItem, 1, @RsFtAllItems);
  { 行 0 は総合、行 1 は全項目なので、項目は行 2 から並びます。
    Row 0 is the overall and row 1 all items, so the items start at row 2. }
  for Item := Succ(Low(TFistItem)) to High(TFistItem) do
    RegisterItem(FFtTrendItem, Ord(Item) + 1, FIST_ITEM_NAMES[Item]);
  FFtTrendItem.ItemIndex := 0;
  FFtTrendItem.OnChange := @FtTrendChanged;

  AddLabel(Buttons, @RsFtKeyKind, 526, 12);
  FFtTrendKey := TComboBox.Create(Buttons);
  FFtTrendKey.Parent := Buttons;
  FFtTrendKey.SetBounds(596, 6, 140, 28);
  FFtTrendKey.Style := csDropDownList;
  { **控えに載せません。**この選択肢は記録から組み直されるので、組み直す側
    （`FtShowTrend`）が入れ直します（付録 BE.2）。載せると、組み直したあとの
    0 番目を上書きすることになります。
    **Not noted down**: this list is rebuilt from the records, so whatever
    rebuilds it puts the word back (`FtShowTrend`, appendix BE.2). Noted, it
    would overwrite whatever stood first after a rebuild. }
  FFtTrendKey.Items.Add(RsFtAnyKey);
  FFtTrendKey.ItemIndex := 0;
  FFtTrendKey.OnChange := @FtTrendChanged;

  FFtStreak := AddLabel(Buttons, '', 752, 12);

  FFtTrend := TFistTrendView.Create(Bottom);
  FFtTrend.Parent := Bottom;
  FFtTrend.Align := alClient;

  FFtHistogram := TFistHistogramView.Create(Bottom);
  FFtHistogram.Parent := Bottom;
  FFtHistogram.Align := alClient;
  FFtHistogram.Visible := False;

  FtShowHistory;
end;

{ 記録の置き場所。交信記録や録音と同じ場所に置きます。
  Where the records live: the same place as the contact log and the recordings. }
function TMainForm.FistLogFileName: string;
begin
  Result := IncludeTrailingPathDelimiter(
    ExtractFilePath(ConfigFileName)) + 'fist.csv';
end;

function TMainForm.FistBasis: TFistStandard;
begin
  if (FFtBasis = nil) or (FFtBasis.ItemIndex < 0) or
     (FFtBasis.ItemIndex > Ord(High(TFistStandard))) then
    Exit(fsStandard);
  Result := TFistStandard(FFtBasis.ItemIndex);
end;

{ 「自分の過去」の基準。**直近の記録の素の測定値**を使います。記録が無ければ
  標準に落ちます（要件 FR-H.7）。
  The basis for "my own past": **the raw figures of the latest record**, falling
  back to the standard when there is none (FR-H.7). }
function TMainForm.FistOwnTarget: TFistTarget;
var
  Records_: TFistRecords;
begin
  Result := FistTargetFor(fsStandard, Default(TFistTarget));
  Records_ := LoadFistRecords(FistLogFileName);
  if Length(Records_) = 0 then
    Exit;
  Result.Ratio := Records_[High(Records_)].Measurement.Ratio;
  Result.IntraRatio := Records_[High(Records_)].Measurement.IntraRatio;
  Result.CharRatio := Records_[High(Records_)].Measurement.CharRatio;
  Result.WordRatio := Records_[High(Records_)].Measurement.WordRatio;
end;

procedure TMainForm.FtOptionsChanged(Sender: TObject);
begin
  MarkSettingsDirty;
  if (FFtFree <> nil) and (FFtNew <> nil) then
  begin
    FFtNew.Enabled := not FFtFree.Checked;
    FFtKind.Enabled := not FFtFree.Checked;
    FFtGroups.Enabled := not FFtFree.Checked;
    if FFtFree.Checked then
      FFtText.Text := RsFtFreeText;
  end;
end;

procedure TMainForm.FtNewClick(Sender: TObject);
var
  Kind: TExerciseKind;
begin
  Kind := ekQso;
  if (FFtKind <> nil) and (FFtKind.ItemIndex >= 0) and
     (FFtKind.ItemIndex <= Ord(High(TExerciseKind))) then
    Kind := TExerciseKind(FFtKind.ItemIndex);
  FFtExercise := MakeExercise(Kind, FFtGroups.Value,
    Round(Frac(Now) * MSecsPerDay) + Random(1000));
  FFtText.Text := FFtExercise;
  FFtResult.Clear;
  FFtAdvice.Caption := '';
  SetStatus('', '', RsFtNewDone);
end;

{ 訓練を始めます。**受信と同じ入力を使うので、受信中には始められません。**
  1 つの装置を 2 つの経路が同時に開けるとは限らず、開けたとしても、どちらの
  音を測っているのか分からなくなります。
  Starts the training. **It cannot start while reception is running**, because
  it uses the same input: one device may not open twice, and even where it does,
  which of the two is being measured would no longer be clear. }
procedure TMainForm.FtStartClick(Sender: TObject);
begin
  if FFtCapture <> nil then
    Exit;
  if FCapture <> nil then
  begin
    SetStatus('', '', RsFtBusyReceiving);
    Exit;
  end;
  if (not FFtFree.Checked) and (Trim(FFtText.Text) = '') then
  begin
    SetStatus('', '', RsFtNeedText);
    Exit;
  end;
  try
    if not LoadPortAudio(FSetPortAudio.Text) then
      raise EDeepCW.Create(PortAudioLoadError);
    FFtRate := SelectedCaptureRate;
    { 保持は 10 分ぶんです。**超えた分は古いほうから落ちます。**落ちたことは
      採点のときに画面へ出します（黙って捨てない）。
      Ten minutes are held, **the oldest falling off beyond that** -- and that it
      fell off is said on the screen when the scoring comes (nothing is dropped
      in silence). }
    FreeAndNil(FFtRing);
    FFtRing := TAudioRing.Create(FFtRate * 600);
    FFtCapture := TAudioCapture.Create(FFtRing, FFtRate, SelectedDeviceIndex);
    FFtCapture.Start;
    FFtBegan := Now;
    FFtStart.Enabled := False;
    FFtStop.Enabled := True;
    FFtResult.Clear;
    FFtAdvice.Caption := '';
    SetStatus('', Format(RsFtRunning, [FFtRate]), RsFtSendNow);
  except
    on E: Exception do
    begin
      FreeAndNil(FFtCapture);
      FFtStart.Enabled := True;
      FFtStop.Enabled := False;
      ReportError(RsCtxFistStart, E);
    end;
  end;
end;

procedure TMainForm.FtStopClick(Sender: TObject);
var
  Samples: TSingleArray;
  Seconds: Double;
begin
  if FFtCapture = nil then
    Exit;
  FFtCapture.Stop;
  FreeAndNil(FFtCapture);
  FFtStart.Enabled := True;
  FFtStop.Enabled := False;
  Samples := FFtRing.Snapshot;
  { 保持を超えた分が落ちたかどうかを、そのまま伝えます。
    Whether anything fell off the buffer is said as it is. }
  FFtLost := (FFtRing <> nil) and (FFtRing.Written > FFtRing.Capacity);
  Seconds := (Now - FFtBegan) * SecsPerDay;
  FtScore(Samples, FFtRate, Seconds);
end;

{ 録音した WAV からも採点できます（要件 FR-E.8 の録音をそのまま使えます）。
  **この容器のように音声装置が無い環境でも、経路全体を確かめられます。**
  Scoring from a recorded WAV as well -- the recordings of requirement FR-E.8
  serve directly. **It also makes the whole path checkable where there is no
  audio device at all, as in a container.** }
procedure TMainForm.FtWavClick(Sender: TObject);
var
  Samples: TSingleArray;
  SampleRate: Integer;
begin
  if FFtCapture <> nil then
  begin
    SetStatus('', '', RsFtBusyDrill);
    Exit;
  end;
  if FRxFile.Text = '' then
  begin
    SetStatus('', '', RsFtWavHint);
    Exit;
  end;
  try
    LoadWavMono(FRxFile.Text, Samples, SampleRate);
  except
    on E: Exception do
    begin
      ReportError(RsCtxWavRead, E);
      Exit;
    end;
  end;
  FFtLost := False;
  FFtBegan := Now;
  FtScore(Samples, SampleRate, Length(Samples) / Max(1, SampleRate));
end;

{ 測って採点します。**文字誤り率だけは、あとから別のスレッドで届きます。**
  ここで同期に読むと、長い録音では画面が止まります。
  Measures and scores. **The character error rate alone arrives later from
  another thread**: read synchronously here, a long recording would stop the
  screen. }
procedure TMainForm.FtScore(const Samples: TSingleArray; SampleRate: Integer;
  Seconds: Double);
var
  ToneHz: Double;
begin
  FFtSamples := nil;
  FFtMeasured := Default(TFistMeasurement);
  if Length(Samples) = 0 then
  begin
    FFtResult.Text := RsFtNoAudio;
    Exit;
  end;
  ToneHz := DetectToneHz(Samples, SampleRate);
  if ToneHz <= 0 then
  begin
    FFtResult.Text := AsLines(RsFtNoMonitor);
    Exit;
  end;

  { 課題文は画面に出ているものが本物です。**変数に控えたほうを使うと、
    書き換えた文と採点する文が食い違います。**
    The text on the screen is the text: **scoring against a copy kept in a
    variable would score something the operator can no longer see.** }
  FFtExercise := Trim(FFtText.Text);
  if FFtFree.Checked then
    FFtMeasured := MeasureFree(Samples, SampleRate, ToneHz)
  else
    FFtMeasured := MeasureAgainstText(Samples, SampleRate, ToneHz, FFtExercise);
  FFtMeasured.Seconds := Seconds;
  if not FFtMeasured.Ok then
  begin
    FFtResult.Text := AsLines(Format(RsFtNoScore, [FFtMeasured.Note]));
    FFtAdvice.Caption := '';
    SetStatus('', '', RsFtNoScoreStatus);
    Exit;
  end;

  { 写しやすさは、課題文があるときだけ measurable です。エンジンが無い、
    または解析が塞がっているときは 4 項目で採点します。**待たせません。**
    Copyability can be measured only against a text; without the engine, or
    while an analysis is running, the score is out of the other four.
    **Nobody is kept waiting.** }
  if (not FFtFree.Checked) and (FDecoder <> nil) and (not DecoderBusy) then
  begin
    FFtSamples := Samples;
    SetStatus('', '', RsFtScoring);
    FDecodeThread := TDecodeThread.CreateFist(FDecoder, Samples, SampleRate,
      @DecodeFinished);
  end
  else
    FtFinish(-1);
end;

{ 採点を締めくくり、記録に残します（要件 FR-H.10）。
  Finishes the scoring and keeps the record (FR-H.10). }
procedure TMainForm.FtFinish(Cer: Double);
var
  Score: TFistScore;
  Item: TFistRecord;
  Lines: TStringList;
begin
  if not FFtMeasured.Ok then
    Exit;
  Score := ScoreFist(FFtMeasured, FistBasis, FistOwnTarget, Cer);

  Lines := TStringList.Create;
  try
    Lines.Add(Format(RsFtOverallLine, [Score.Overall,
      FIST_STANDARD_NAMES[FistBasis]^]));
    Lines.Add(Format(RsFtParts,
      [Score.Speed, Score.Clarity, Score.Separation, Score.Spacing]));
    if Score.HasCopyability then
      Lines.Add(Format(RsFtReadable,
        [Score.Copyability, 100 * Cer]))
    else
      Lines.Add(RsFtNoReadable);
    Lines.Add('');
    Lines.Add(Format(RsFtWpm,
      [FFtMeasured.EffectiveWpm, FFtMeasured.DitSeconds * 1000,
       100 * FFtMeasured.Stats[ekDit].Cv, FFtMeasured.Ratio]));
    Lines.Add(Format(RsFtGaps,
      [FFtMeasured.IntraRatio, FFtMeasured.CharRatio, FFtMeasured.WordRatio]));
    Lines.Add(Format(RsFtSeparation,
      [FFtMeasured.ToneSeparation, FFtMeasured.GapSeparation,
       100 * FFtMeasured.Drift]));
    if FFtMeasured.Reference then
      Lines.Add(RsFtNoteFreeText);
    if FFtLost then
      Lines.Add(RsFtNoteTrimmed);
    FFtResult.Text := Lines.Text;
  finally
    Lines.Free;
  end;
  { **点数の低さは、余地であって誤りではありません。**助言はそのように書きます。
    **A low score is room to grow, not a fault**, and the advice is written to
    say so. }
  FFtAdvice.Caption := Format(RsFtAdvice, [Score.Advice]);

  Item := Default(TFistRecord);
  Item.When_ := Now;
  Item.Seconds := FFtMeasured.Seconds;
  if (FFtKey.ItemIndex >= 0) and (FFtKey.ItemIndex <= High(FIST_KEY_KEYS)) then
    { 記録に書くのは鍵です。画面の名前は訳されます（要件 NFR-7.6）。
      The key is what goes into the record: the name shown is translated. }
    Item.Key := FIST_KEY_KEYS[FFtKey.ItemIndex];
  if FFtFree.Checked then
    Item.Text_ := ''
  else
    Item.Text_ := FFtExercise;
  Item.Characters := FFtMeasured.Characters;
  Item.Reference := FFtMeasured.Reference;
  Item.Standard := FistBasis;
  Item.Score := Score;
  Item.Measurement := FFtMeasured;
  Item.Measurement.Elements := nil;
  try
    AppendFistRecord(FistLogFileName, Item);
  except
    on E: Exception do
      LogDiagnostic(RsCtxFistLog, E.Message);
  end;
  { 分布は、いま採点した回のものを出します（要件 FR-H.9）。**記録には要素まで
    残していない**ので、出せるのはこの 1 回だけです。
    The distributions are those of the session just scored (FR-H.9): **the
    record does not keep the elements**, so this one session is what there is
    to show. }
  if FFtHistogram <> nil then
    FFtHistogram.SetMeasurement(FFtMeasured);
  FtShowHistory;
  SetStatus('', '', Format(RsFtScored, [Score.Overall]));
end;

{ これまでの記録を新しい順に出します（要件 FR-H.10 の入口）。
  折れ線での推移はまだ作っていません。**まず、残っていることと読めることです。**
  The records, newest first (the way in to FR-H.10). The trend line is not built
  yet: **first they have to be kept, and readable.** }
procedure TMainForm.FtShowHistory;
var
  Records_: TFistRecords;
  Lines: TStringList;
  I, Shown: Integer;
  Best: Double;
begin
  if FFtHistory = nil then
    Exit;
  Records_ := LoadFistRecords(FistLogFileName);
  Lines := TStringList.Create;
  try
    if Length(Records_) = 0 then
      Lines.Add(Format(RsFtNoRecords, [FistLogFileName]))
    else
    begin
      Best := 0;
      for I := 0 to High(Records_) do
        if Records_[I].Score.Overall > Best then
          Best := Records_[I].Score.Overall;
      Lines.Add(Format(RsFtRecords,
        [Length(Records_), Best, FistLogFileName]));
      Shown := 0;
      I := High(Records_);
      while (I >= 0) and (Shown < 12) do
      begin
        Lines.Add(FistRecordCaption(Records_[I]));
        Dec(I);
        Inc(Shown);
      end;
    end;
    FFtHistory.Text := Lines.Text;
  finally
    Lines.Free;
  end;
  FtShowTrend(Records_);
end;

{ 推移を描き直します（要件 FR-H.10・FR-H.11）。

  **絞り込みと項目の選択は、描く側ではなくここで決めます。**部品は受け取った
  ものをそのまま描くだけです。
  Redraws the trend (FR-H.10, FR-H.11). **What to narrow to and which item to
  show are settled here**, not in the drawing: the control draws what it is
  handed. }
procedure TMainForm.FtShowTrend(const Items: TFistRecords);
var
  Keys: TStringArray;
  Shown: TFistItems;
  Key, Kept: string;
  I, Days: Integer;
  Narrowed: TFistRecords;
begin
  if (FFtTrend = nil) or (FFtTrendKey = nil) then
    Exit;
  { 選べる鍵は記録から作ります。**決め打ちにすると、記録にある鍵を選べない
    ことが起こります。**選んでいたものは、あれば選び直します。
    The keys on offer come from the records: **written in advance, a key that is
    in the records could end up not being offered.** Whatever was chosen is
    chosen again when it is still there. }
  Kept := FFtTrendKeyWanted;
  { 覚えておくのは鍵のほうです（要件 NFR-7.6）。
    What is remembered is the key, not the name shown (NFR-7.6). }
  if FFtTrendKey.ItemIndex > 0 then
    Kept := FistKeyToKey(FFtTrendKey.Items[FFtTrendKey.ItemIndex]);
  FFtTrendKeyWanted := '';
  Keys := KeysUsed(Items);
  FFtTrendKey.Items.BeginUpdate;
  try
    FFtTrendKey.Items.Clear;
    FFtTrendKey.Items.Add(RsFtAnyKey);
    for I := 0 to High(Keys) do
      FFtTrendKey.Items.Add(FistKeyCaption(Keys[I]));
  finally
    FFtTrendKey.Items.EndUpdate;
  end;
  FFtTrendKey.ItemIndex := Max(0, FFtTrendKey.Items.IndexOf(FistKeyCaption(Kept)));

  Key := '';
  if FFtTrendKey.ItemIndex > 0 then
    Key := FistKeyToKey(FFtTrendKey.Items[FFtTrendKey.ItemIndex]);
  Narrowed := FilterByKey(Items, Key);

  Shown := [fiOverall];
  if FFtTrendItem <> nil then
    case FFtTrendItem.ItemIndex of
      0: Shown := [fiOverall];
      1: Shown := FIST_ALL_ITEMS - [fiOverall];
    else
      { 3 番目以降は、項目を 1 つずつ並べた順に対応します。
        From the third entry on, one item each, in order. }
      Shown := [TFistItem(FFtTrendItem.ItemIndex - 1)];
    end;
  FFtTrend.SetShown(Shown);
  FFtTrend.SetItems(Narrowed);

  { 続いた日数（要件 FR-H.11）。**続けていることが見えるのは、続ける理由に
    なります。**0 日なら何も言いません。数えられないものを 0 と書くのとは
    違うためです。
    The days in a row (requirement FR-H.11): **seeing that it is being kept up
    is a reason to keep it up.** Nothing is said at zero, which is not the same
    as writing nought for something not counted. }
  Days := ConsecutiveDays(Items, Now);
  if Days > 0 then
    FFtStreak.Caption := Format(RsFtStreak, [Days])
  else
    FFtStreak.Caption := '';
end;

{ 下の欄を、推移と分布で入れ替えます（要件 FR-H.9）。
  Swaps the panel below between the trend and the distributions (FR-H.9). }
procedure TMainForm.FtBottomChanged(Sender: TObject);
var
  ShowTrend: Boolean;
begin
  MarkSettingsDirty;
  if (FFtTrend = nil) or (FFtHistogram = nil) then
    Exit;
  ShowTrend := (FFtBottomKind = nil) or (FFtBottomKind.ItemIndex = 0);
  FFtTrend.Visible := ShowTrend;
  FFtHistogram.Visible := not ShowTrend;
  { 推移の操作は、推移を出しているときだけ押せます。**押しても何も起きない
    操作は、壊れているように見えます。**
    The trend's controls can be used only while the trend is shown: **a control
    that does nothing when pressed looks broken.** }
  FFtTrendItem.Enabled := ShowTrend;
  FFtTrendKey.Enabled := ShowTrend;
end;

procedure TMainForm.FtTrendChanged(Sender: TObject);
begin
  MarkSettingsDirty;
  FtShowTrend(LoadFistRecords(FistLogFileName));
end;

function TMainForm.BuildSettingsTab: TTabSheet;
var
  Sheet: TTabSheet;
  Scroller: TScrollBox;
  Operating, Advanced, RigGroup, RigAdvGroup, ExtGroup: TGroupBox;
  Row, Apply: TPanel;
  Choice: TTunerBandwidth;
  Language_: Integer;

  { 詳しい接続設定の選択肢。先頭は「機種の既定」（要件 FR-T.5）。
    A choice of the detailed settings; the first item is "the model's default"
    (FR-T.5). }
  function AddChoice(Parent: TWinControl; Left, Top, Width: Integer): TComboBox;
  begin
    Result := TComboBox.Create(Parent);
    Result.Parent := Parent;
    Result.SetBounds(Left, Top, Width, 28);
    Result.Style := csDropDownList;
    RegisterItem(Result, 0, @RsSetRigBaudDefault);
    Result.ItemIndex := 0;
    Result.OnChange := @SettingChanged;
  end;

  { 技術的な設定は「詳細・診断」側にだけ置きます（要件 FR-G.1）。
    Technical settings live only under the advanced group (FR-G.1). }
  { 見出しも控えに載せます（要件 NFR-7.6）。**載せないと、この 4 行だけが
    前の言語のまま残ります。**
    The heading is noted down too (NFR-7.6): **without it these four rows alone
    would stay in the old language.** }
  function AddPathEdit(Parent: TWinControl; Caption: PResString;
    const Value: string): TEdit;
  begin
    AddTopLabel(Parent, Caption);
    Result := TEdit.Create(Parent);
    Result.Parent := Parent;
    Result.Text := Value;
    Stretch(Result, alTop);
  end;

begin
  Sheet := FPages.AddTabSheet;
  RegisterCaption(Sheet, @RsSetTab);
  Result := Sheet;

  { 設定は**巻き取れる欄**に載せます（要件 FR-G.3・教訓 10.36）。

    運用設定の枠は、設定を足すたびに背が伸びます。版 2.42 から 2.44 のあいだに
    210 から 300 へ伸び、**その分だけ診断情報の欄が押し出されて、既定の窓では
    読めなくなっていました。**画面を撮って気づきました。

    窓を高くしても、次に設定を足せば同じことが起きます。**足し算で決まる高さに
    固定の窓で付き合わない。**巻き取れるようにして、どちらの枠も本来の高さを
    保てるようにします。

    The settings ride in **a scrolling area** (requirement FR-G.3, lesson 10.36).

    The operating group grows taller with every setting added: between versions
    2.42 and 2.44 it went from 210 to 300, and **the diagnostics panel was
    pushed out by exactly that much until it could not be read at the default
    window size.** A screenshot is what showed it.

    A taller window would only postpone it -- the next setting would do the same.
    **A height that grows by addition is not something a fixed window can keep
    up with.** Scrolling lets both groups keep the height they need. }
  Scroller := TScrollBox.Create(Sheet);
  Scroller.Parent := Sheet;
  Scroller.Align := alClient;
  Scroller.BorderStyle := bsNone;
  Scroller.HorzScrollBar.Visible := False;

  { ── 運用設定：普段さわるもの。技術用語を置かない ──
    Operating settings: what an operator actually changes. No jargon here. }
  Operating := TGroupBox.Create(Scroller);
  Operating.Parent := Scroller;
  { 高さは、中に置いた行の合計です。**足りなければ、最後に置いた行が枠の外へ
    出ます。**呼出符号の一覧（要件 FR-K.9）を足したとき、実際にそうなりました
    ——画面を撮って分かりました（教訓 10.42・10.36）。最後の行は上端 178 から
    22 画素なので、枠は 210 では足りません。
    The height is the sum of the rows put inside: **too little and the last row
    added falls outside the box.** That is what happened when the roster row
    (requirement FR-K.9) went in, and a screenshot is what showed it (lessons
    10.42, 10.36). The last row sits at 178 and is 22 tall, so 210 is not
    enough. 前置符字表（要件 FR-K.12）を足したので、さらに 32 画素。
    The prefix table row (requirement FR-K.12) adds another 32. }
  { 画面の言語の行（要件 NFR-7.6）を足したので 40 画素ぶん高くします。
    The language row (requirement NFR-7.6) adds another 40. }
  Operating.Height := 340;
  RegisterCaption(Operating, @RsSetOperating);
  Stretch(Operating, alTop);
  { 幅が決まるたびに、置き場所を収め直します（`FitPath`）。
    Each time the width settles, the locations are fitted again (`FitPath`). }
  Operating.OnResize := @OperatingResized;

  AddLabel(Operating, @RsSetCaptureRate, 14, 8);
  FSetCaptureRate := TComboBox.Create(Operating);
  FSetCaptureRate.Parent := Operating;
  FSetCaptureRate.SetBounds(14, 30, 200, 28);
  FSetCaptureRate.Style := csDropDownList;
  RegisterItem(FSetCaptureRate, 0, @RsSetRate8000);
  FSetCaptureRate.Items.Add('11025 Hz');
  FSetCaptureRate.Items.Add('16000 Hz');
  FSetCaptureRate.Items.Add('22050 Hz');
  FSetCaptureRate.Items.Add('44100 Hz');
  FSetCaptureRate.Items.Add('48000 Hz');
  FSetCaptureRate.ItemIndex := 0;
  AddLabel(Operating, @RsSetCaptureNote,
    232, 36);

  AddLabel(Operating, @RsSetRetention, 14, 62);
  FSetRetention := TComboBox.Create(Operating);
  FSetRetention.Parent := Operating;
  FSetRetention.SetBounds(120, 58, 110, 28);
  FSetRetention.Style := csDropDownList;
  RegisterItem(FSetRetention, 0, @RsSetRetention5);
  RegisterItem(FSetRetention, 1, @RsSetRetention10);
  RegisterItem(FSetRetention, 2, @RsSetRetention20);
  RegisterItem(FSetRetention, 3, @RsSetRetention30);
  FSetRetention.ItemIndex := 1;
  FSetRetention.OnChange := @RxRetentionChanged;
  AddLabel(Operating, @RsSetRetentionNote, 248, 62);

  FSetJournal := TCheckBox.Create(Operating);
  FSetJournal.Parent := Operating;
  FSetJournal.SetBounds(14, 90, 300, 22);
  RegisterCaption(FSetJournal, @RsSetJournal);
  FSetJournal.Checked := True;
  FSetJournal.OnChange := @RxJournalChanged;
  AddLabel(Operating, @RsSetJournalNote, 330, 92);

  { 受信音の録音（要件 FR-E.8）。受信テキストの記録のすぐ下に置きます。**同じ
    運用の、同じ「残す」という選択**であり、片方が設定タブで片方が受信タブに
    あると、どちらを入れたのか覚えていられません。

    既定は入れません。**書くのは利用者のディスクです。**聴き直し（要件 FR-E.10）
    は記憶の中だけで済みますが、こちらは残ります。

    Recording the received audio (requirement FR-E.8), directly under the
    transcript journal: **the same session and the same choice to keep
    something**, and split between two tabs there would be no remembering which
    was switched on.

    It is off by default. **What is written is the operator's own disk**: replay
    (requirement FR-E.10) stays in memory, while this stays. }
  FSetRecord := TCheckBox.Create(Operating);
  FSetRecord.Parent := Operating;
  FSetRecord.SetBounds(14, 118, 300, 22);
  RegisterCaption(FSetRecord, @RsSetRecord);
  FSetRecord.Checked := False;
  FSetRecord.OnChange := @RxRecordChanged;
  FSetRecordInfo := AddLabel(Operating, '', 330, 120);

  { 交信記録の出し入れ。運用者が別のソフトで積み上げた記録を取り込めば、その場で
    「交信済み」が効きます（要件 FR-E.3・FR-J.4）。
    Taking the contact log in and out. Importing a log an operator built in
    another program makes the worked marks work at once (requirements FR-E.3 and
    FR-J.4). }
  AddLabel(Operating, @RsSetLog, 14, 150);
  FSetLogImport := AddButton(Operating, @RsSetAdifImport, 120, 146, 150,
    @SetLogImportClick);
  FSetLogExport := AddButton(Operating, @RsSetAdifExport, 278, 146, 150,
    @SetLogExportClick);
  FSetLogInfo := AddLabel(Operating, '', 440, 150);

  { 手元の呼出符号一覧（要件 FR-K.9）。**同梱はしません。**配られている一覧を
    再配布してよいかが分からないためです（未解決 #15）。読むのは利用者が自分で
    置いたファイルだけで、**通信は一切しません。**

    A locally held call sign roster (requirement FR-K.9). **Nothing is
    bundled**: whether the distributed rosters may be redistributed is not known
    (open question #15). Only a file the operator put there is read, and
    **nothing is ever sent.** }
  AddLabel(Operating, @RsSetRoster, 14, 182);
  FSetRoster := AddButton(Operating, @RsSetChooseFile, 120, 178, 150,
    @SetRosterClick);
  FSetRosterClear := AddButton(Operating, @RsSetDontUse, 278, 178, 150,
    @SetRosterClearClick);
  FSetRosterInfo := AddLabel(Operating, '', 440, 182);

  { 国別前置符字表（要件 FR-K.12）。**呼出符号の一覧より小さく、更新も稀**
    なので、別のファイルとして持ちます。これも同梱しません。
    The country prefix table (requirement FR-K.12). **Smaller than the call sign
    roster and rarely updated**, so it is a file of its own; not bundled
    either. }
  AddLabel(Operating, @RsSetPrefixes, 14, 214);
  FSetPrefixes := AddButton(Operating, @RsSetChooseFile, 120, 210, 150,
    @SetPrefixesClick);
  FSetPrefixesClear := AddButton(Operating, @RsSetDontUse, 278, 210, 150,
    @SetPrefixesClearClick);
  FSetPrefixesInfo := AddLabel(Operating, '', 440, 214);

  { 高コントラスト表示（要件 NFR-5.5）。**この製品が想定する利用者は老眼を
    抱える運用者**なので、薄い文字は読めないことがあります。
    High contrast (requirement NFR-5.5): **the operators this product is for
    have presbyopia**, and faint text can simply be unreadable to them. }
  FSetHighContrast := TCheckBox.Create(Operating);
  FSetHighContrast.Parent := Operating;
  FSetHighContrast.SetBounds(14, 244, 420, 22);
  RegisterCaption(FSetHighContrast, @RsSetHighContrast);
  FSetHighContrast.Checked := False;
  FSetHighContrast.OnChange := @HighContrastChanged;
  AddLabel(Operating, @RsSetHighContrastNote,
    440, 246);

  { 画面の言語（要件 NFR-7.6）。**再起動を求めません。**押したその場で変わります。

    選択肢の名前は、それぞれの言語で書いてあります（`UiLangCaption`）。
    「English」を「英語」と出すと、英語しか読めない人には選べません。

    **この選択肢は訳しません。**訳すと、読めない言語で書かれた選択肢の中から
    読める言語を探すことになります。

    The language of the screen (requirement NFR-7.6). **No restart is asked
    for**: it changes as it is chosen.

    Each choice is named in its own language (`UiLangCaption`): shown as `英語`,
    `English` could not be found by someone who reads only English.

    **These choices are not translated**, or the operator would be hunting for a
    language they can read among names written in one they cannot. }
  AddLabel(Operating, @RsSetLanguage, 14, 278);
  FSetLanguage := TComboBox.Create(Operating);
  FSetLanguage.Parent := Operating;
  FSetLanguage.SetBounds(200, 274, 160, 28);
  FSetLanguage.Style := csDropDownList;
  for Language_ := Low(UI_LANG_KEYS) to High(UI_LANG_KEYS) do
    FSetLanguage.Items.Add(UiLangCaption(Language_));
  FSetLanguage.ItemIndex := UI_LANG_DEFAULT;
  FSetLanguage.OnChange := @SetLanguageChanged;
  FSetLanguageInfo := AddLabel(Operating, '', 380, 278);

  { ── 無線機（送信）: 要件 FR-T ──
    The rig (sending): requirement FR-T. }
  RigGroup := TGroupBox.Create(Scroller);
  RigGroup.Parent := Scroller;
  RegisterCaption(RigGroup, @RsSetRigGroup);
  RigGroup.Height := 262;
  Stretch(RigGroup, alTop);
  AddLabel(RigGroup, @RsSetRigModel, 14, 10);
  FSetRigModel := AddSpin(RigGroup, 100, 6, 0, 99999, 0, @SettingChanged);
  AddLabel(RigGroup, @RsSetRigPort, 220, 10);
  FSetRigPort := TEdit.Create(RigGroup);
  FSetRigPort.Parent := RigGroup;
  FSetRigPort.SetBounds(260, 6, 200, 28);
  FSetRigPort.OnChange := @SettingChanged;
  AddLabel(RigGroup, @RsSetRigBaud, 476, 10);
  FSetRigBaud := TComboBox.Create(RigGroup);
  FSetRigBaud.Parent := RigGroup;
  FSetRigBaud.SetBounds(560, 6, 140, 28);
  FSetRigBaud.Style := csDropDownList;
  RegisterItem(FSetRigBaud, 0, @RsSetRigBaudDefault);
  FSetRigBaud.Items.Add('4800');
  FSetRigBaud.Items.Add('9600');
  FSetRigBaud.Items.Add('19200');
  FSetRigBaud.Items.Add('38400');
  FSetRigBaud.Items.Add('57600');
  FSetRigBaud.Items.Add('115200');
  FSetRigBaud.ItemIndex := 0;
  FSetRigBaud.OnChange := @SettingChanged;
  AddLabel(RigGroup, @RsSetRigHint, 14, 40);
  AddLabel(RigGroup, @RsSetMyCall, 14, 70);
  FSetMyCall := TEdit.Create(RigGroup);
  FSetMyCall.Parent := RigGroup;
  FSetMyCall.SetBounds(120, 66, 140, 28);
  FSetMyCall.CharCase := ecUppercase;
  FSetMyCall.OnChange := @SettingChanged;
  FSetMuteRx := TCheckBox.Create(RigGroup);
  FSetMuteRx.Parent := RigGroup;
  FSetMuteRx.SetBounds(300, 68, 400, 22);
  RegisterCaption(FSetMuteRx, @RsSetMuteRx);
  FSetMuteRx.Checked := True;
  FSetMuteRx.OnChange := @SettingChanged;
  AddLabel(RigGroup, @RsSetTemplates, 14, 100);
  FSetTemplates := TMemo.Create(RigGroup);
  FSetTemplates.Parent := RigGroup;
  FSetTemplates.SetBounds(14, 120, 700, 70);
  FSetTemplates.ScrollBars := ssAutoVertical;
  FSetTemplates.OnChange := @SetTemplatesChanged;
  FSetRigAutoConnect := TCheckBox.Create(RigGroup);
  FSetRigAutoConnect.Parent := RigGroup;
  FSetRigAutoConnect.SetBounds(14, 196, 700, 22);
  RegisterCaption(FSetRigAutoConnect, @RsSetRigAutoConnect);
  FSetRigAutoConnect.OnChange := @SettingChanged;
  FSetRigUseFreq := TCheckBox.Create(RigGroup);
  FSetRigUseFreq.Parent := RigGroup;
  FSetRigUseFreq.SetBounds(14, 222, 700, 22);
  RegisterCaption(FSetRigUseFreq, @RsSetRigUseFreq);
  FSetRigUseFreq.Checked := True;
  FSetRigUseFreq.OnChange := @SettingChanged;

  { ── 無線機の詳しい接続設定: 要件 FR-T.5 ──
    **普通は既定のまま。**「機種の既定」と 0 ms は Hamlib へ渡しません。
    項目の並びは `DeepCW.RigConfig` の選択肢と同じ順です。
    Detailed rig connection settings (FR-T.5). **Normally left at the
    defaults**; "the model's default" and 0 ms are not passed to Hamlib. The
    items follow the order of the choices in `DeepCW.RigConfig`. }
  RigAdvGroup := TGroupBox.Create(Scroller);
  RigAdvGroup.Parent := Scroller;
  RegisterCaption(RigAdvGroup, @RsSetRigAdvGroup);
  RigAdvGroup.Height := 214;
  Stretch(RigAdvGroup, alTop);
  AddLabel(RigAdvGroup, @RsSetRigCivAddr, 14, 10);
  FSetRigCivAddr := TEdit.Create(RigAdvGroup);
  FSetRigCivAddr.Parent := RigAdvGroup;
  FSetRigCivAddr.SetBounds(140, 6, 60, 28);
  FSetRigCivAddr.CharCase := ecUppercase;
  FSetRigCivAddr.MaxLength := 2;
  FSetRigCivAddr.OnChange := @SettingChanged;
  AddLabel(RigAdvGroup, @RsSetRigDataBits, 230, 10);
  FSetRigDataBits := AddChoice(RigAdvGroup, 340, 6, 120);
  FSetRigDataBits.Items.Add('7');
  FSetRigDataBits.Items.Add('8');
  AddLabel(RigAdvGroup, @RsSetRigStopBits, 490, 10);
  FSetRigStopBits := AddChoice(RigAdvGroup, 610, 6, 120);
  FSetRigStopBits.Items.Add('1');
  FSetRigStopBits.Items.Add('2');
  AddLabel(RigAdvGroup, @RsSetRigParity, 14, 44);
  FSetRigParity := AddChoice(RigAdvGroup, 140, 40, 130);
  RegisterItem(FSetRigParity, 1, @RsSetRigParityNone);
  RegisterItem(FSetRigParity, 2, @RsSetRigParityEven);
  RegisterItem(FSetRigParity, 3, @RsSetRigParityOdd);
  AddLabel(RigAdvGroup, @RsSetRigHandshake, 300, 44);
  FSetRigHandshake := AddChoice(RigAdvGroup, 410, 40, 160);
  RegisterItem(FSetRigHandshake, 1, @RsSetRigHandshakeNone);
  FSetRigHandshake.Items.Add('XON/XOFF');
  RegisterItem(FSetRigHandshake, 3, @RsSetRigHandshakeHardware);
  AddLabel(RigAdvGroup, 'DTR', 14, 78);
  FSetRigDtr := AddChoice(RigAdvGroup, 140, 74, 130);
  FSetRigDtr.Items.Add('ON');
  FSetRigDtr.Items.Add('OFF');
  AddLabel(RigAdvGroup, 'RTS', 300, 78);
  FSetRigRts := AddChoice(RigAdvGroup, 410, 74, 160);
  FSetRigRts.Items.Add('ON');
  FSetRigRts.Items.Add('OFF');
  AddLabel(RigAdvGroup, @RsSetRigTimeout, 14, 112);
  FSetRigTimeout := AddSpin(RigAdvGroup, 140, 108, 0, RIG_TIMEOUT_MAX, 0, @SettingChanged);
  FSetRigTimeout.Width := 90;
  AddLabel(RigAdvGroup, @RsSetRigWriteDelay, 250, 112);
  FSetRigWriteDelay := AddSpin(RigAdvGroup, 380, 108, 0, RIG_DELAY_MAX, 0, @SettingChanged);
  AddLabel(RigAdvGroup, @RsSetRigPostDelay, 480, 112);
  FSetRigPostDelay := AddSpin(RigAdvGroup, 610, 108, 0, RIG_DELAY_MAX, 0, @SettingChanged);
  AddLabel(RigAdvGroup, @RsSetRigAdvHint, 14, 146);
  AddLabel(RigAdvGroup, @RsSetRigLineWarn, 14, 170);

  { ── 拡張（準備中）: 要件 FR-W・FR-N ──
    **受け口だけ**です。準備中の項目も見せますが、選べません
    （`ExtensionChanged`）。項目の並びは `ALPHABET_ITEMS`・`NOISE_ITEMS` と
    同じ順です。
    Extensions (pending): FR-W, FR-N. **Only the seats**: pending items are
    shown but cannot be chosen (`ExtensionChanged`). The items follow the order
    of `ALPHABET_ITEMS` and `NOISE_ITEMS`. }
  ExtGroup := TGroupBox.Create(Scroller);
  ExtGroup.Parent := Scroller;
  RegisterCaption(ExtGroup, @RsSetExtGroup);
  ExtGroup.Height := 110;
  Stretch(ExtGroup, alTop);
  AddLabel(ExtGroup, @RsSetAlphabet, 14, 10);
  FSetAlphabet := TComboBox.Create(ExtGroup);
  FSetAlphabet.Parent := ExtGroup;
  FSetAlphabet.SetBounds(140, 6, 180, 28);
  FSetAlphabet.Style := csDropDownList;
  RegisterItem(FSetAlphabet, 0, @RsSetAlphabetIntl);
  RegisterItem(FSetAlphabet, 1, @RsSetAlphabetWabun);
  FSetAlphabet.ItemIndex := 0;
  FSetAlphabet.OnChange := @ExtensionChanged;
  AddLabel(ExtGroup, @RsSetNoise, 360, 10);
  FSetNoise := TComboBox.Create(ExtGroup);
  FSetNoise.Parent := ExtGroup;
  FSetNoise.SetBounds(490, 6, 180, 28);
  FSetNoise.Style := csDropDownList;
  RegisterItem(FSetNoise, 0, @RsSetNoiseOff);
  RegisterItem(FSetNoise, 1, @RsSetNoiseAi);
  FSetNoise.ItemIndex := 0;
  FSetNoise.OnChange := @ExtensionChanged;
  AddLabel(ExtGroup, @RsSetExtHint, 14, 44);
  AddLabel(ExtGroup, @RsSetExtRawHint, 14, 70);

  { ── 詳細・診断：困ったときだけ見るもの ──
    Advanced and diagnostics: only looked at when something is wrong. }
  Advanced := TGroupBox.Create(Scroller);
  Advanced.Parent := Scroller;
  RegisterCaption(Advanced, @RsSetAdvanced);
  { 巻き取れる欄の中では、`alClient` は「残り全部」ではなく「見えている分だけ」に
    なります。**それでは診断情報が見えなくなった元の状態に戻ります。**必要な
    高さを持たせて積みます。
    Inside a scrolling area `alClient` means what is visible rather than what is
    left, **which is the state that hid the diagnostics in the first place**: the
    group is given the height it needs and stacked. }
  Advanced.AutoSize := True;
  Stretch(Advanced, alTop);

  Row := AddTopPanel(Advanced, 40);
  FSetApply := AddButton(Row, @RsSetApply, 8, 4, 300, @ApplySettings);
  AddLabel(Row, @RsSetThreads, 328, 12);
  FSetThreads := TComboBox.Create(Row);
  FSetThreads.Parent := Row;
  FSetThreads.SetBounds(416, 8, 110, 28);
  FSetThreads.Style := csDropDownList;
  RegisterItem(FSetThreads, 0, @RsSetAuto);
  FSetThreads.Items.Add('1');
  FSetThreads.Items.Add('2');
  FSetThreads.Items.Add('4');
  FSetThreads.ItemIndex := 0;

  { 帯域幅は自動のままで実用に足ります。手で選びたい人のためだけに残します
    （要件 FR-D.3）。
    Automatic is good enough in practice; the manual choice exists only for
    those who want it (requirement FR-D.3). }
  AddLabel(Row, @RsSetBandwidth, 536, 12);
  FSetBandwidth := TComboBox.Create(Row);
  FSetBandwidth.Parent := Row;
  FSetBandwidth.SetBounds(648, 8, 160, 28);
  FSetBandwidth.Style := csDropDownList;
  for Choice := Low(TTunerBandwidth) to High(TTunerBandwidth) do
    RegisterItem(FSetBandwidth, Ord(Choice), BandwidthCaptionRef(Choice));
  FSetBandwidth.ItemIndex := 0;
  FSetBandwidth.OnChange := @RxConfirmSpeedChanged;

  FSetModel := AddPathEdit(Advanced, @RsSetModel, LocateDataFile('model.onnx'));
  FSetMetadata := AddPathEdit(Advanced, @RsSetMetadata,
    LocateDataFile('model.onnx.json'));
  FSetRuntime := AddPathEdit(Advanced, @RsSetRuntime, '');
  FSetPortAudio := AddPathEdit(Advanced, @RsSetPortAudio, '');

  { 不具合報告に添えられるように、まとめて写せるようにします（要件 FR-G.5）。
    **画面を撮って送るより、貼れるほうが正確です。**
    So that it can be attached to a bug report (requirement FR-G.5): **pasting
    is more accurate than sending a picture of the screen.** }
  { 2 行ぶんの注記が入るので 44。**40 では 1〜2 画素重なりました**（付録 BE.4）。
    文字の高さは 96 dpi で 17〜18 画素あり、192 dpi では倍になります。
    44 to fit two lines of note: **at 40 they overlapped by a pixel or two**
    (appendix BE.4). The text is 17 to 18 pixels tall at 96 dpi and twice that
    at 192. }
  Row := AddTopPanel(Advanced, 44);
  FSetCopyInfo := AddButton(Row, @RsSetCopyDiag, 12, 4, 180,
    @SetCopyInfoClick);
  { 2 文に分けて置きます。**1 つに繋いで渡すと、控えに載せられません**——控えるのは
    文言のありかなので、繋いだ結果には「ありか」がありません（付録 BE.2）。
    Two labels rather than one joined string: **a joined string cannot be noted
    down**, because what is noted is where the words live and a joined result
    lives nowhere (appendix BE.2). }
  AddLabel(Row, @RsSetDiagNote1, 200, 3);
  AddLabel(Row, @RsSetDiagNote2, 200, 23);

  AddTopLabel(Advanced, @RsSetDiagnostics);
  FSetInfo := TMemo.Create(Advanced);
  FSetInfo.Parent := Advanced;
  FSetInfo.ReadOnly := True;
  FSetInfo.ScrollBars := ssAutoBoth;
  FSetInfo.WordWrap := False;
  FSetInfo.Font.Name := 'Monospace';
  { 巻き取れる欄の中なので、**読める高さを自分で持ちます。**`alClient` は
    「見えている分だけ」になり、上に積んだものが増えるほど痩せます
    （教訓 10.36）。
    Inside a scrolling area it **carries a readable height of its own**:
    `alClient` would mean only what is visible, growing thinner as things stack
    above it (lesson 10.36). }
  FSetInfo.Height := 200;
  Stretch(FSetInfo, alTop);
end;

{ ---- settings ---- }

function TMainForm.ConfigFileName: string;
begin
  Result := GetAppConfigFile(False);
end;

function TMainForm.IsDiagnosticRecord(const Line: string): Boolean;
begin
  Result := (FDiagnostics <> nil) and (FDiagnostics.IndexOf(Line) >= 0);
end;

function TMainForm.RememberedUiLang: string;
var
  Ini: TIniFile;
begin
  Result := '';
  if not FileExists(ConfigFileName) then
    Exit;
  try
    Ini := TIniFile.Create(ConfigFileName);
    try
      Result := Ini.ReadString('ui', 'language', '');
    finally
      Ini.Free;
    end;
  except
    { 読めなければ既定の決め方に任せます。設定の読み込みで改めて知らせます。
      Unreadable, the usual decision applies; loading the settings reports it. }
    Result := '';
  end;
end;

procedure TMainForm.LoadSettings;
var
  Ini: TIniFile;
  Rate: string;
  Index: Integer;
  RigValues: TStringList;
  Rejected: TStringArray;
begin
  if not FileExists(ConfigFileName) then
    Exit;
  Ini := TIniFile.Create(ConfigFileName);
  try
    FSetModel.Text := Ini.ReadString('engine', 'model', FSetModel.Text);
    FSetMetadata.Text := Ini.ReadString('engine', 'metadata', FSetMetadata.Text);
    FSetRuntime.Text := Ini.ReadString('engine', 'onnxruntime', '');
    FSetPortAudio.Text := Ini.ReadString('audio', 'portaudio', '');
    FSetThreads.ItemIndex := ClampInt(Ini.ReadInteger('engine', 'threads_choice', 0), 0, 3);

    Rate := Ini.ReadString('audio', 'capture_rate', '8000');
    for Index := 0 to FSetCaptureRate.Items.Count - 1 do
      if Pos(Rate, FSetCaptureRate.Items[Index]) = 1 then
      begin
        FSetCaptureRate.ItemIndex := Index;
        Break;
      end;

    FTxCharWpm.Value := Ini.ReadInteger('transmit', 'char_wpm', 20);
    FTxTextWpm.Value := Ini.ReadInteger('transmit', 'text_wpm', 20);
    FTxToneHz.Value := Ini.ReadInteger('transmit', 'tone_hz', 700);
    FTxVolume.Position := Ini.ReadInteger('transmit', 'volume', 60);
    FTxText.Text := Ini.ReadString('transmit', 'text', FTxText.Text);
    { 無線機と自局の符号・定型（要件 FR-T）。**足した鍵なので、古い設定
      ファイルには無く、既定で読みます。**
      The rig, own call and templates (FR-T). **New keys: older settings files
      lack them and the defaults are read.** }
    FSetRigModel.Value := Ini.ReadInteger('rig', 'model', 0);
    FSetRigPort.Text := Ini.ReadString('rig', 'port', '');
    Index := FSetRigBaud.Items.IndexOf(IntToStr(Ini.ReadInteger('rig', 'baud', 0)));
    if Index < 0 then
      Index := 0;
    FSetRigBaud.ItemIndex := Index;
    FSetMyCall.Text := Ini.ReadString('transmit', 'my_call', '');
    FSetMuteRx.Checked := Ini.ReadBool('rig', 'mute_receive', True);
    { 詳しい接続設定（要件 FR-T.5）。**読めない値は既定に戻し、診断に残します**
      （黙って捨てない）。/ Detailed settings (FR-T.5). **Unreadable values fall
      back to the default and are logged** (never dropped silently). }
    RigValues := TStringList.Create;
    try
      Ini.ReadSectionValues('rig', RigValues);
      RigConfToScreen(RigConfFromValues(RigValues, Rejected));
      for Index := 0 to High(Rejected) do
        LogDiagnostic(RsCtxRig, Format(
          'Settings file: [rig] %s cannot be used; the model''s default is used instead.',
          [Rejected[Index]]));
    finally
      RigValues.Free;
    end;
    FSetRigAutoConnect.Checked := Ini.ReadBool('rig', 'connect_at_start', False);
    FSetRigUseFreq.Checked := Ini.ReadBool('rig', 'use_frequency', True);
    FSetTemplates.Lines.Clear;
    for Index := 1 to 8 do
      if Ini.ReadString('transmit', 'template' + IntToStr(Index), '') <> '' then
        FSetTemplates.Lines.Add(Ini.ReadString('transmit', 'template' + IntToStr(Index), ''));
    RefreshTemplates;
    { 拡張の受け口（要件 FR-W・FR-N）。**知らない鍵・準備中の項目は既定へ
      戻します**（fail-soft）。
      The extension seats (FR-W, FR-N). **An unknown key or a pending item
      falls back to the default** (fail-soft). }
    if AlphabetAvailable(AlphabetFromKey(Ini.ReadString('receive', 'alphabet',
      ALPHABET_KEY_INTERNATIONAL))) then
      FSetAlphabet.ItemIndex := Ord(AlphabetFromKey(Ini.ReadString('receive',
        'alphabet', ALPHABET_KEY_INTERNATIONAL)))
    else
      FSetAlphabet.ItemIndex := Ord(caInternational);
    FReducer.Free;
    FReducer := CreateNoiseReducer(Ini.ReadString('receive', 'noise_reduction',
      NOISE_KEY_OFF));
    FSetNoise.ItemIndex := Max(0, NoiseItemIndex(FReducer.Key));

    FRxConfirmSpeed.ItemIndex := ClampInt(
      Ini.ReadInteger('receive', 'confirm_speed', 1), 0, 2);
    FRxAntiAlias.Checked := Ini.ReadBool('receive', 'anti_alias', True);
    FRxShowDoubt.Checked := Ini.ReadBool('receive', 'show_doubt', True);
    FRxAlign.Checked := Ini.ReadBool('receive', 'align_characters', True);
    FRxDoubtStrength.Position := ClampInt(
      Ini.ReadInteger('receive', 'doubt_strength', 100), 0, 100);
    FRxFontSize.Value := ClampInt(Ini.ReadInteger('receive', 'font_size', 14), 9, 32);
    FSetRetention.ItemIndex := ClampInt(Ini.ReadInteger('receive', 'retention', 1), 0, 3);
    FSetJournal.Checked := Ini.ReadBool('receive', 'journal', True);
    FSetRecord.Checked := Ini.ReadBool('receive', 'record', False);
    FPrKind.ItemIndex := ClampInt(Ini.ReadInteger('practice', 'kind', 0),
      0, FPrKind.Items.Count - 1);
    FPrGroups.Value := ClampInt(Ini.ReadInteger('practice', 'groups', 10), 1, 50);
    FPrWpm.Value := ClampInt(Ini.ReadInteger('practice', 'wpm', 20), 5, 40);
    FPrNoise.Position := ClampInt(Ini.ReadInteger('practice', 'noise', 10), 0, 40);
    { 前回の一覧を読み直します。**無くなっていても黙って続けます**――一覧が
      無いのは「照合できない」であって「起動できない」ではありません
      （要件 FR-K.10）。
      The roster is read again; **gone, it passes in silence**: no roster means
      "cannot match", not "cannot start" (requirement FR-K.10). }
    LoadRoster(Ini.ReadString('roster', 'file', ''));
    LoadPrefixes(Ini.ReadString('roster', 'prefixes', ''));
    FSetHighContrast.Checked :=
      Ini.ReadBool('receive', 'high_contrast', False);
    FPrDelay.Checked := Ini.ReadBool('practice', 'delay', True);
    FPrDelaySeconds.Value := ClampInt(
      Ini.ReadInteger('practice', 'delay_seconds', REVEAL_DELAY_DEFAULT_SECONDS),
      0, REVEAL_DELAY_MAX_SECONDS);
    FFtKind.ItemIndex := ClampInt(Ini.ReadInteger('fist', 'kind', Ord(ekQso)),
      0, FFtKind.Items.Count - 1);
    FFtGroups.Value := ClampInt(Ini.ReadInteger('fist', 'groups', 3), 1, 20);
    FFtKey.ItemIndex := ClampInt(Ini.ReadInteger('fist', 'key', 0),
      0, FFtKey.Items.Count - 1);
    FFtBasis.ItemIndex := ClampInt(Ini.ReadInteger('fist', 'standard', 0),
      0, FFtBasis.Items.Count - 1);
    FFtFree.Checked := Ini.ReadBool('fist', 'free', False);
    FFtTrendItem.ItemIndex := ClampInt(Ini.ReadInteger('fist', 'trend_item', 0),
      0, FFtTrendItem.Items.Count - 1);
    { 鍵は**名前で**覚えます。番号で覚えると、記録が増えて並びが変わった日に
      別の鍵の推移が出ます（装置の記憶と同じ考え方）。
      The key is remembered **by name**: by number, the day the records gain a
      new key would show the trend of a different one -- the same reasoning as
      remembering the input device. }
    { 鍵より前の設定には日本語が入っています。読むときに揃えます。
      A settings file from before the keys holds Japanese; it is normalised here. }
    FFtTrendKeyWanted := FistKeyToKey(Ini.ReadString('fist', 'trend_key', ''));
    { 画面の言語（要件 NFR-7.6）。**読み込みの終わりで入れ直します**ので、
      ここでは選択だけを合わせます。
      The language (NFR-7.6). **The words go back in at the end of loading**, so
      only the choice is set here. }
    FLangRemembered := Ini.ReadString('ui', 'language', '');
    FSetLanguage.ItemIndex := StartingUiLang(FLangRemembered);
    FFtBottomKind.ItemIndex := ClampInt(Ini.ReadInteger('fist', 'bottom', 0),
      0, FFtBottomKind.Items.Count - 1);
    FtBottomChanged(nil);
    FtOptionsChanged(nil);
    FRxMode.ItemIndex := ClampInt(Ini.ReadInteger('receive', 'mode', 0), 0, 2);
    FRxBand.ItemIndex := ClampInt(Ini.ReadInteger('receive', 'band', 0),
      0, FRxBand.Items.Count - 1);
    FRxHideWorked.Checked := Ini.ReadBool('receive', 'hide_worked', True);
    { 待つ符号は覚えておきます。待っている相手は、アプリを閉じたくらいでは
      変わらないためです。
      The call signs waited for are remembered: closing the application is not a
      reason to stop waiting for someone. }
    FRxWatch.Text := Ini.ReadString('receive', 'watch', '');
    { 無い・読めない値は切（既定）です。/ Missing or unreadable means off. }
    FRxWatchSound.Checked := Ini.ReadBool('receive', 'watch_sound', False);
    FSetBandwidth.ItemIndex := ClampInt(Ini.ReadInteger('receive', 'bandwidth', 0),
      0, FSetBandwidth.Items.Count - 1);
    { 前回の同調先は覚えておきます。同じ設備なら音程は同じであることが多く、
      毎回選び直させる理由がありません。
      The last tuning is remembered: with the same station the pitch is
      usually the same, and there is no reason to make it be chosen again. }
    FRxWaterfall.TuneHz := Ini.ReadInteger('receive', 'tune_hz', 0);
    { 装置は名前で覚えています。前回と同じ装置が繋がっていればそれを選び、
      無ければ黙って既定へ戻します（要件 FR-A.5）。
      The device is remembered by name: the same one is selected if it is still
      connected, and otherwise it quietly falls back to the default
      (requirement FR-A.5). }
    RefreshDeviceList(Ini.ReadString('audio', 'input_device', ''));
    FRxTrack.Checked := Ini.ReadBool('receive', 'track_signal', True);
  finally
    Ini.Free;
  end;
end;

{ 設定を書き出す必要があることを覚えておきます。実際の書き出しは間引いて
  行います（PollTimer）。

  Notes that settings need writing; the write itself is rate limited. }
procedure TMainForm.MarkSettingsDirty;
begin
  FSettingsDirty := True;
end;

procedure TMainForm.SaveSettings;
var
  Ini: TIniFile;
  Index: Integer;
  RigValues: TStringList;
begin
  FSettingsDirty := False;
  FSettingsSavedAt := Now;
  try
    ForceDirectories(ExtractFilePath(ConfigFileName));
    Ini := TIniFile.Create(ConfigFileName);
    try
      Ini.WriteString('engine', 'model', FSetModel.Text);
      Ini.WriteString('engine', 'metadata', FSetMetadata.Text);
      Ini.WriteString('engine', 'onnxruntime', FSetRuntime.Text);
      Ini.WriteInteger('engine', 'threads_choice', FSetThreads.ItemIndex);
      Ini.WriteString('audio', 'portaudio', FSetPortAudio.Text);
      Ini.WriteString('audio', 'capture_rate', IntToStr(SelectedCaptureRate));
      Ini.WriteInteger('transmit', 'char_wpm', FTxCharWpm.Value);
      Ini.WriteInteger('transmit', 'text_wpm', FTxTextWpm.Value);
      Ini.WriteInteger('transmit', 'tone_hz', FTxToneHz.Value);
      Ini.WriteInteger('transmit', 'volume', FTxVolume.Position);
      Ini.WriteString('transmit', 'text', FTxText.Text);
      Ini.WriteInteger('rig', 'model', FSetRigModel.Value);
      Ini.WriteString('rig', 'port', FSetRigPort.Text);
      Ini.WriteInteger('rig', 'baud', StrToIntDef(
        FSetRigBaud.Items[Max(0, FSetRigBaud.ItemIndex)], 0));
      Ini.WriteString('transmit', 'my_call', FSetMyCall.Text);
      Ini.WriteBool('rig', 'mute_receive', FSetMuteRx.Checked);
      RigValues := TStringList.Create;
      try
        RigConfToValues(RigConfFromScreen, RigValues);
        for Index := 0 to RigValues.Count - 1 do
          Ini.WriteString('rig', RigValues.Names[Index], RigValues.ValueFromIndex[Index]);
      finally
        RigValues.Free;
      end;
      Ini.WriteBool('rig', 'connect_at_start', FSetRigAutoConnect.Checked);
      Ini.WriteBool('rig', 'use_frequency', FSetRigUseFreq.Checked);
      Ini.WriteString('receive', 'alphabet',
        AlphabetKey(TCwAlphabet(Max(0, FSetAlphabet.ItemIndex))));
      Ini.WriteString('receive', 'noise_reduction', FReducer.Key);
      for Index := 1 to 8 do
        if Index <= FSetTemplates.Lines.Count then
          Ini.WriteString('transmit', 'template' + IntToStr(Index),
            Trim(FSetTemplates.Lines[Index - 1]))
        else
          Ini.DeleteKey('transmit', 'template' + IntToStr(Index));
      Ini.WriteInteger('receive', 'confirm_speed', FRxConfirmSpeed.ItemIndex);
      Ini.WriteBool('receive', 'anti_alias', FRxAntiAlias.Checked);
      Ini.WriteBool('receive', 'show_doubt', FRxShowDoubt.Checked);
      Ini.WriteBool('receive', 'align_characters', FRxAlign.Checked);
      { 濃淡の強さと入切は覚えます（要件 FR-C.4）。
        The shading's strength and whether it is on are remembered
        (requirement FR-C.4). }
      Ini.WriteInteger('receive', 'doubt_strength', FRxDoubtStrength.Position);
      Ini.WriteInteger('receive', 'font_size', FRxFontSize.Value);
      Ini.WriteInteger('receive', 'tune_hz', Round(FRxWaterfall.TuneHz));
      Ini.WriteInteger('receive', 'bandwidth', FSetBandwidth.ItemIndex);
      Ini.WriteInteger('receive', 'retention', FSetRetention.ItemIndex);
      Ini.WriteBool('receive', 'journal', FSetJournal.Checked);
      Ini.WriteBool('receive', 'record', FSetRecord.Checked);
      Ini.WriteInteger('practice', 'kind', FPrKind.ItemIndex);
      Ini.WriteInteger('practice', 'groups', FPrGroups.Value);
      Ini.WriteInteger('practice', 'wpm', FPrWpm.Value);
      Ini.WriteInteger('practice', 'noise', FPrNoise.Position);
      { 一覧そのものではなく、**ファイルの場所だけ**を覚えます。写しを持てば、
        利用者が更新しても古いままになります（要件 FR-K.9 の「利用者が用意した
        ファイル」）。
        The file's location is remembered, **not the roster itself**: a copy
        would stay stale after the operator updated theirs (requirement FR-K.9
        says the file is the operator's). }
      Ini.WriteString('roster', 'file', FRosterFile);
      Ini.WriteString('roster', 'prefixes', FPrefixFile);
      Ini.WriteBool('receive', 'high_contrast', FSetHighContrast.Checked);
      Ini.WriteBool('practice', 'delay', FPrDelay.Checked);
      Ini.WriteInteger('practice', 'delay_seconds', FPrDelaySeconds.Value);
      Ini.WriteInteger('fist', 'kind', FFtKind.ItemIndex);
      Ini.WriteInteger('fist', 'groups', FFtGroups.Value);
      Ini.WriteInteger('fist', 'key', FFtKey.ItemIndex);
      Ini.WriteInteger('fist', 'standard', FFtBasis.ItemIndex);
      Ini.WriteBool('fist', 'free', FFtFree.Checked);
      Ini.WriteInteger('fist', 'bottom', FFtBottomKind.ItemIndex);
      Ini.WriteInteger('fist', 'trend_item', FFtTrendItem.ItemIndex);
      if FFtTrendKey.ItemIndex > 0 then
        { 設定にも鍵を書きます（要件 NFR-7.6）。
          The key goes into the settings too (NFR-7.6). }
        Ini.WriteString('fist', 'trend_key',
          FistKeyToKey(FFtTrendKey.Items[FFtTrendKey.ItemIndex]))
      else
        Ini.WriteString('fist', 'trend_key', '');
      { 画面の言語は**鍵**で覚えます（要件 NFR-7.6）。番号で覚えると、言語を
        足した日に別の言語が選ばれます。表示名で覚えれば、その言語でしか
        読み戻せません（版 2.54 と同じ話）。
        The language is remembered **by key** (NFR-7.6): by number, adding a
        language would select a different one; by the name shown, it could only
        be read back in that same language (the same story as version 2.54). }
      { **命令行で決まった言語は書き戻しません。**選び直したときだけ書きます。
        覚えてあった鍵が無ければ何も書かず、次は OS の地域設定で決まります。
        **A language decided by the command line is not written back**; only a
        choice made on the screen is. With nothing remembered, nothing is written
        and the next start follows the locale. }
      if (UiLangFromCommandLine = '') or FLangChosenHere then
      begin
        if (FSetLanguage.ItemIndex >= Low(UI_LANG_KEYS)) and
           (FSetLanguage.ItemIndex <= High(UI_LANG_KEYS)) then
          Ini.WriteString('ui', 'language', UI_LANG_KEYS[FSetLanguage.ItemIndex]);
      end
      else if FLangRemembered <> '' then
        Ini.WriteString('ui', 'language', FLangRemembered);
      Ini.WriteInteger('receive', 'mode', FRxMode.ItemIndex);
      Ini.WriteString('receive', 'watch', FRxWatch.Text);
      Ini.WriteBool('receive', 'watch_sound', FRxWatchSound.Checked);
      { 無線機に合わせている間は、運用者の選択を残します（要件 FR-T.7）。
        While following the rig, the operator's own choice is saved (FR-T.7). }
      if FRigBandActive then
        Ini.WriteInteger('receive', 'band', FManualBand)
      else
        Ini.WriteInteger('receive', 'band', FRxBand.ItemIndex);
      Ini.WriteBool('receive', 'hide_worked', FRxHideWorked.Checked);
      Ini.WriteString('audio', 'input_device', SelectedDeviceName);
      Ini.WriteBool('receive', 'track_signal', FRxTrack.Checked);
    finally
      Ini.Free;
    end;
  except
    on E: Exception do
      { 設定は利便のためのものなので終了は妨げませんが、黙って失敗すると
        原因が分からなくなるため診断情報には残します。
        Settings are a convenience and must not block exit, but a silent
        failure leaves no way to find the cause, so it is recorded. }
      LogDiagnostic(RsCtxSaveSettings, E.Message);
  end;
end;

procedure TMainForm.ApplySettings(Sender: TObject);
begin
  MarkSettingsDirty;
  RxStopClick(nil);
  { 走っている解析が FStream と FDecoder を掴んでいるため、解放の前に待ちます。
    A running analysis holds both objects, so wait for it before freeing. }
  if FDecodeThread <> nil then
  begin
    FDecodeThread.WaitFor;
    FreeAndNil(FDecodeThread);
  end;
  FreeAndNil(FCompletedThread);
  FreeAndNil(FStream);
  { 次の受信は空の受信テキストから始まり、今の文字と入れ替わります。受けた
    RST の境も 0 へ戻します（付録 BW.1）。戻さないと、新しい受信テキストが前の
    長さを超えるまで RST を読みません（実画面で確かめた）。
    The next reception starts from an empty text that replaces the current
    one, so the RST boundary goes back to 0 too (appendix BW.1); otherwise no
    RST is read until the new text grows past the old length (seen on the
    running program). }
  FRstFromChar := 0;
  FreeAndNil(FMulti);
  FreeAndNil(FDecoder);
  FEngineError := '';
  UnloadOnnxRuntime;
  EnsureDecoder;
  RefreshInfo;
end;

{ 控えてある文言を、いまの言語で入れ直します（要件 NFR-7.6）。

  **控えに載らないものが 2 通りあります。**

  1. 部品の `Caption` ではない見出し（ここでは受信テキストの初期表示）
  2. **実行中に組み立てた文**——状態、同調、記録の件数、練習の履歴

  2 のうち、**いまの状態から出し直せるものは出し直します。**出し直せないもの
  ——すでに流れた案内や、そのときの出来事として出た警告——は**そのまま残します。**
  起きたときの言葉で残っているほうが、記録としては正しいからです。

  Puts the noted words back in the current language (requirement NFR-7.6).

  **Two kinds are not covered by the notes**: headings that are not a control's
  `Caption` (here, the receive area's placeholder), and **sentences built while
  running** -- status, tuning, how many contacts, the practice history.

  Of the second kind, **whatever can be produced again from the current state
  is produced again.** What cannot -- a notice that has already scrolled past,
  a warning raised by something that happened -- **is left as it is**: as a
  record, it is more truthful in the words it was raised in. }
procedure TMainForm.ApplyTexts;
begin
  UiText.ApplyTexts;
  if FRxTranscript <> nil then
    FRxTranscript.Message_ := RsRxEmpty;
  { いまの状態から出し直せるもの。**控えに載らない「実行時に組み立てる札」は
    すべてここで出し直す。**これらは `UiText` に登録できない（内容が
    `Format` で作られる／実行中に組み直される）ため、呼び忘れれば起動した
    ときの言語のまま残る。版 2.64 では受信タブで見えた 2 つ（装置・JCC）
    だけを直したが、設定タブの一覧（呼出符号・前置符字）と録音の説明、待ち
    符号・検索・聴き直しの札も同じ穴だった（版 2.64 の実機点検で見つけた。
    付録 BM）。**1 か所に集める**ことで、次に足す札も漏らさない（教訓 10.11）。
    Everything produced again from the current state. **Every runtime-built
    label that cannot be noted is refreshed here.** These cannot be registered
    with `UiText` (their content is built by `Format` or rebuilt while running),
    so left uncalled they stay in the language they were first built in. Version
    2.64 fixed only the two visible on the Receive tab (device, JCC); the
    Settings-tab lists (roster, prefixes), the recording note, and the watch,
    find and replay labels were the same gap (found in the version 2.64
    real-screen review; appendix BM). **Gathered in one place** so the next
    label added is not missed (lesson 10.11). }
  RefreshInfo;
  UpdateTuneInfo;
  UpdateLogInfo;
  UpdatePrefixesInfo;
  UpdateRosterInfo;
  UpdateWatchInfo;
  UpdateFindInfo;
  UpdateRecordInfo;
  UpdateReplayInfo;
  PrShowHistory;
  FtShowHistory;
  { 版 2.66 で足した、送信の要約・局数・滝の案内。
    Added in version 2.66: the transmit summary, the rate, the waterfall note. }
  UpdateTxSummary;
  UpdateRate(True);
  UpdateRigStatus;
  { 「課題文なしで送る」の案内は、課題文の欄に**文言として**書かれます。
    The "send freely" notice is written **as text** into the exercise box. }
  if (FFtFree <> nil) and FFtFree.Checked and (FFtText <> nil) then
    FFtText.Text := RsFtFreeText;
  if (FRxWaterfall <> nil) and (FWfMessage <> nil) then
  begin
    FRxWaterfall.Message_ := FWfMessage^;
    FRxWaterfall.Invalidate;
  end;
  { 描くときに文言を読む部品（版 2.67）。**描き直さなければ、次に何かが動く
    まで前の言語のまま見えます。**局の一覧の根拠の名前（`TrustSource`）は、
    一覧が 1 秒ごとに作り直すときに入れ替わります。
    Parts that read their words when drawing (version 2.67). **Unless redrawn
    they show the previous language until something moves.** The evidence name
    in the station list (`TrustSource`) changes when the list is rebuilt, once
    a second. }
  if FRxBandMap <> nil then
    FRxBandMap.Invalidate;
  if FFtTrend <> nil then
    FFtTrend.Invalidate;
  if FFtHistogram <> nil then
    FFtHistogram.Invalidate;
  { **これも控えに載らない組み直しです。**`FRxSubdivisionInfo` の文言は
    `RxSubdivisionChanged` が都度組み立てるので、控えには載せられません
    （空欄なら案内、埋まっていれば読みの札）。呼ばなければ、起動したときの
    言語のまま残ります（版 2.63 の点検で見つけた。付録 BE.6 と同じ形の穴）。
    **This one is rebuilt too, and cannot be noted**: `FRxSubdivisionInfo`'s
    words are `RxSubdivisionChanged`'s to build each time (the hint when empty,
    the reading when not). Left uncalled, it would stay in whatever language it
    was built in (found in the version 2.63 review; the same shape of gap as
    appendix BE.6). }
  if FRxSubdivision <> nil then
    RxSubdivisionChanged(nil);
  { 入力装置の一覧も同じです。**先頭の「おまかせ」と「← 既定」の印は文言で、
    控えには載りません。**選んでいた装置は名前で覚えているので、渡せば同じ
    ものを選び直します（要件 FR-A.5 と同じ考え方）。
    The input device list, the same way: **the leading "auto" entry and the
    "default" mark are words that cannot be noted.** The chosen device is
    remembered by name, so passing it back selects the same one again (the
    same reasoning as requirement FR-A.5). }
  if FRxDevice <> nil then
    RefreshDeviceList(SelectedDeviceName);
end;

{ 文字列に CJK（日本語）が含まれるか。**UTF-8 の先頭バイトで見ます。**
  U+3000〜FFFF（かな・漢字・全角記号）の 3 バイト列は先頭が $E3〜$EF。英語の札は
  ここに入らない（ASCII と Latin-1 のみ）ので、これで「英語なのに日本語」を拾えます。
  Whether a string contains CJK (Japanese). **Judged by the UTF-8 lead byte**:
  the three-byte sequences for U+3000..FFFF (kana, kanji, full-width) lead with
  $E3..$EF, and an English label never reaches there (ASCII and Latin-1 only),
  so this catches "Japanese on an English screen". }
function HasCjk(const S: string): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 1 to Length(S) do
    if (Ord(S[I]) >= $E3) and (Ord(S[I]) <= $EF) then
      Exit(True);
end;

{ 窓のすべての `TLabel` の文言と、入力欄（`TEdit`・`TMemo`）の中身を集めます
  （入れ子をたどります）。**登録できない実行時の札も、ここには必ず出ます。**
  入力欄も見るのは、案内を**欄の中身として**書く所があるからです（「課題文なしで
  送る」の案内。付録 BQ）。選択肢（combo）は見ません。装置の名前は OS が付ける
  ので、日本語の装置名が偽の穴に見えます（付録 BM）。
  Collects the caption of every `TLabel` and the contents of every entry box
  (`TEdit`, `TMemo`) on the form, descending into nested controls. **Even a
  runtime label that cannot be registered shows up here.** Entry boxes are
  included because some notes are written **as a box's contents** (the "send
  freely" note; appendix BQ). Lists (combos) are not: the operating system
  names the devices, and a Japanese device name would look like a gap
  (appendix BM). }
procedure CollectFormLabels(Root: TWinControl; Into: TStrings);
var
  I: Integer;
  C: TControl;
begin
  for I := 0 to Root.ControlCount - 1 do
  begin
    C := Root.Controls[I];
    if C is TLabel then
      Into.Add(TLabel(C).Caption)
    else if C is TCustomMemo then
      { 行ごとに集めます。落ちたときに**どの行か**を名指しできます。
        Line by line, so that a failure names **which line**. }
      Into.AddStrings(TCustomMemo(C).Lines)
    else if C is TCustomEdit then
      Into.Add(TCustomEdit(C).Text);
    if C is TWinControl then
      CollectFormLabels(TWinControl(C), Into);
  end;
end;

function TMainForm.ReportLanguage: TStringList;
var
  Before, After, Back, Labels, Current: TStringList;
  Pairs: TTextWidthList;
  Started: TDateTime;
  Spent: Int64;
  I, J, Moved, Wrong, Leaks: Integer;
  HintBefore, HintAfter, HintBack: string;
  DeviceBefore, DeviceAfter, DeviceBack: string;
begin
  Result := TStringList.Create;
  Before := TStringList.Create;
  After := TStringList.Create;
  Back := TStringList.Create;
  Labels := TStringList.Create;
  Current := TStringList.Create;
  try
    { **英語で起動したなら、切り替える前に一度見ます**（付録 BQ）。切り替えれば
      `ApplyTexts` が出し直すので、**起動の順序の誤り**（言語を入れる前に書かれた
      文言）はそこで隠れてしまいます。登録済みの札（両言語で同じ「画面の言葉 /
      Language」）は除きます。
      **When started in English, look once before any switching** (appendix
      BQ). A switch runs `ApplyTexts`, which would hide **a start-up ordering
      fault** (words written before the language went in). The registered
      labels (only the bilingual "画面の言葉 / Language") are excluded. }
    if (FSetLanguage <> nil) and
       (FSetLanguage.ItemIndex = UiLangIndexOf('en')) then
    begin
      UiText.CollectTexts(Current);
      CollectFormLabels(Self, Labels);
      for I := 0 to Labels.Count - 1 do
        if HasCjk(Labels[I]) and (Current.IndexOf(Labels[I]) < 0) and
           not IsDiagnosticRecord(Labels[I]) then
          Result.Add(Format('英語で起動したのに日本語の札: 「%s」', [Labels[I]]));
      Labels.Clear;
    end;
    { **控えに載らない組み直しも、別枠で名指しします。**`FRxSubdivisionInfo`
      と `FRxDevice` は `UiText` に登録できない（付録 BE.6）ので、`Before`・
      `After`・`Back` の数には入りません。それでも `ApplyTexts` が呼び忘れれば
      画面には日本語が残り、実機の点検でしか見つかりませんでした（版 2.63）。
      ここで機械にも見つけさせます。
      **What cannot be noted is checked apart, by name.**
      `FRxSubdivisionInfo` and `FRxDevice` cannot be registered with `UiText`
      (appendix BE.6), so they never entered the counts. Left uncalled by
      `ApplyTexts`, Japanese stayed on screen and only a real-screen check
      found it (version 2.63). This makes the machine find it too. }
    if FRxSubdivision <> nil then
      FRxSubdivision.Text := '';

    UseUiLang(UI_LANG_DEFAULT);
    ApplyTexts;
    UiText.CollectTexts(Before);
    if FRxSubdivisionInfo <> nil then HintBefore := FRxSubdivisionInfo.Caption;
    if (FRxDevice <> nil) and (FRxDevice.Items.Count > 0) then
      DeviceBefore := FRxDevice.Items[0];

    { 切替にどれだけ掛かるかを測ります（要件 NFR-1）。**利用者が押す操作**なので、
      掛かるなら掛かると言えなければなりません。画面を作り直す方式との差も、
      ここに出ます。
      How long the switch takes is measured (requirement NFR-1). **It is
      something the operator presses**, so if it costs, that has to be sayable.
      The difference from rebuilding the screen shows here too. }
    Started := Now;
    UseUiLang(UiLangIndexOf('en'));
    ApplyTexts;
    Spent := MilliSecondsBetween(Now, Started);
    UiText.CollectTexts(After);
    if FRxSubdivisionInfo <> nil then HintAfter := FRxSubdivisionInfo.Caption;
    if (FRxDevice <> nil) and (FRxDevice.Items.Count > 0) then
      DeviceAfter := FRxDevice.Items[0];
    { **英語のまま日本語が残っている札を、名指しせずに拾います。**登録できない
      札を 1 つずつ名前で見るのは、足すたびに検査も足す約束で、いつか漏れます
      （版 2.64 で 2 つだけ見て 6 つ漏らした）。ここでは窓の札を全部たどり、
      英語なのに日本語が残っているものを、登録済みの札（両言語で同じ「画面の
      言葉 / Language」だけ）を除いて拾います（付録 BM）。
      **Catches Japanese-on-English labels without naming them.** Checking each
      unregisterable label by name is a promise to add a check every time one is
      added, and that promise gets missed (version 2.64 checked two and missed
      six). Here every label on the form is walked and any that still holds
      Japanese in English mode is flagged, save the registered ones (only the
      bilingual "画面の言葉 / Language") (appendix BM). }
    CollectFormLabels(Self, Labels);

    UseUiLang(UI_LANG_DEFAULT);
    ApplyTexts;
    UiText.CollectTexts(Back);
    if FRxSubdivisionInfo <> nil then HintBack := FRxSubdivisionInfo.Caption;
    if (FRxDevice <> nil) and (FRxDevice.Items.Count > 0) then
      DeviceBack := FRxDevice.Items[0];

    { **訳があるのに変わらなかったものを名指しします。**数えるだけでは、
      40 件のうち 7 件しか切り替わっていなくても通ってしまいます（実測。
      付録 BD.4）。`.po` に「違う訳」があるものは、必ず変わらねばなりません。
      **Whatever has a translation and did not change is named.** Counting
      alone would pass with only 7 of 40 switching (measured; appendix BD.4):
      anything the `.po` gives a different wording for must change. }
    Pairs := LoadPoPairs(LanguageDirectory + 'deepcw_station.en.po');

    Moved := 0;
    Wrong := 0;
    for I := 0 to Before.Count - 1 do
    begin
      if (I < After.Count) and (After[I] <> Before[I]) then
        Inc(Moved)
      else
      begin
        for J := 0 to High(Pairs) do
          if (Pairs[J].Source = Before[I]) and (Pairs[J].Target <> Before[I]) then
          begin
            Inc(Wrong);
            if Wrong <= 10 then
              Result.Add(Format('切り替わっていない: 「%0:s」は「%1:s」になるはず',
                [Before[I], Pairs[J].Target]));
            Break;
          end;
      end;
      { **戻ってきていないものを名指しします。**数だけでは、どれが戻らないのか
        分かりません。
        **Whatever did not come back is named**: a count alone does not say
        which one. }
      if (I >= Back.Count) or (Back[I] <> Before[I]) then
      begin
        Inc(Wrong);
        if Wrong <= 10 then
          Result.Add(Format('戻っていない: 「%0:s」→「%1:s」', [Before[I],
            Back[Min(I, Back.Count - 1)]]));
      end;
    end;

    { 控えに載らない 2 つも、同じ形で見ます。**変わらなければ切り替わっていない、
      戻らなければ戻る道が壊れています。**
      The two that cannot be noted are checked the same way: **unchanged means
      the switch did not reach them; not back means the way back is broken.** }
    if (HintBefore <> '') and (HintAfter = HintBefore) then
    begin
      Inc(Wrong);
      Result.Add(Format('JCC/JCG の案内が切り替わっていない: 「%s」', [HintBefore]));
    end;
    if HintBack <> HintBefore then
    begin
      Inc(Wrong);
      Result.Add(Format('JCC/JCG の案内が戻っていない: 「%0:s」→「%1:s」',
        [HintBefore, HintBack]));
    end;
    if (DeviceBefore <> '') and (DeviceAfter = DeviceBefore) then
    begin
      Inc(Wrong);
      Result.Add(Format('装置一覧の先頭が切り替わっていない: 「%s」', [DeviceBefore]));
    end;
    if DeviceBack <> DeviceBefore then
    begin
      Inc(Wrong);
      Result.Add(Format('装置一覧の先頭が戻っていない: 「%0:s」→「%1:s」',
        [DeviceBefore, DeviceBack]));
    end;

    { 英語のときに集めた札のうち、日本語が残っていて、かつ登録済みでないものを
      数え、**1 つでもあれば落とします。**版 2.65 では進み具合の目盛り（落とさない）
      でしたが、版 2.66 で `frmmain` の文言を訳し終え、試験の家を一時の場所へ
      移して結果が手元の設定に左右されなくなったので、0 を確かめて落とす検査に
      格上げしました（付録 BN）。落ちたときは札の文言を名指しします。
      登録済み（`After` にある）のは意図して両言語のままの「画面の言葉 /
      Language」だけなので除きます。
      Counts the labels gathered in English that still hold Japanese and are not
      registered, and **fails if there is even one.** In version 2.65 it was a
      progress meter that never failed; in version 2.66 `frmmain`'s words were
      all translated and the tests were given a scratch home, so the outcome no
      longer depends on the operator's settings. With 0 confirmed it is promoted
      to a gate (appendix BN), and a failure names the label. The registered
      ones (in `After`) are excluded -- the only one with Japanese is the
      deliberately bilingual "画面の言葉 / Language". }
    Leaks := 0;
    for I := 0 to Labels.Count - 1 do
      if HasCjk(Labels[I]) and (After.IndexOf(Labels[I]) < 0) and
         not IsDiagnosticRecord(Labels[I]) then
      begin
        Inc(Leaks);
        Result.Add(Format('英語なのに日本語が残っている札: 「%s」', [Labels[I]]));
      end;

    Result.Insert(0, Format('控え %0:d 件 / 英語で変わった %1:d 件 / 戻らなかった %2:d 件 / 未反映の疑い %3:d 件 / 切替 %4:d ms',
      [UiText.TextCount, Moved, Wrong, Leaks, Spent]));
    { **1 つも変わらないのは、切替が効いていないということです。**訳が
      見つからなくても静かに通ってしまうので、ここで落とします。
      **Nothing changing means the switch is not working.** A translation that
      is never found would otherwise pass in silence, so it fails here. }
    if Moved = 0 then
      Result.Add('英語に切り替えても 1 つも変わりませんでした');
  finally
    Current.Free;
    Labels.Free;
    Back.Free;
    After.Free;
    Before.Free;
  end;
end;

{ 画面の言語を変えます（要件 NFR-7.6）。

  **再起動を求めません。**受信中でも切り替えられます——入れ直すだけで、画面を
  作り直すわけではないからです（画面を作り直すと、受信中の経路を壊します）。

  Changes the language of the screen (requirement NFR-7.6).

  **No restart is asked for**, and it can be done mid-reception: the words are
  put back in place, the screen is not rebuilt (rebuilding it would tear down a
  running receive path). }
procedure TMainForm.SetLanguageChanged(Sender: TObject);
begin
  if FSetLanguage = nil then
    Exit;
  FLangChosenHere := True;
  UseUiLang(FSetLanguage.ItemIndex);
  ApplyTexts;
  MarkSettingsDirty;
end;

procedure TMainForm.RefreshInfo;
var
  Lines, Licences: TStringList;
  I, Device: Integer;
  Alphabet: string;
begin
  Lines := TStringList.Create;
  try
    if FDecoder <> nil then
    begin
      Lines.Add(RsInfoEngineLoaded);
      Lines.Add(Format('ONNX Runtime: %s (%s)', [OnnxRuntimeVersion, OnnxRuntimeLibraryPath]));
      Lines.Add(Format(RsInfoSampleRate, [FDecoder.Metadata.SampleRate]));
      Lines.Add(Format(RsInfoFftHop,
        [FDecoder.Metadata.FFTLength, FDecoder.Metadata.HopLength]));
      Lines.Add(Format(RsInfoBand,
        [FDecoder.Metadata.MinFreqHz, FDecoder.Metadata.MaxFreqHz,
         FDecoder.Metadata.FrequencyBins]));
      Lines.Add(Format(RsInfoInOut,
        [FDecoder.Metadata.InputName, FDecoder.Metadata.OutputName]));
      Alphabet := '';
      for I := 0 to FDecoder.Metadata.CharCount - 1 do
        Alphabet := Alphabet + FDecoder.Metadata.Chars[I];
      Lines.Add(Format(RsInfoAlphabet, [FDecoder.Metadata.CharCount, Alphabet]));
      Lines.Add(Format(RsInfoSeconds,
        [DEEPCW_MIN_SECONDS, DEEPCW_MAX_SECONDS]));
    end
    else
    begin
      Lines.Add(RsInfoEngineNotLoaded);
      if FEngineError <> '' then
        Lines.Add(FEngineError);
    end;

    Lines.Add('');
    if LoadPortAudio(FSetPortAudio.Text) then
      Lines.Add(Format('PortAudio: %s (%s)', [PortAudioVersion, PortAudioLibraryPath]))
    else
    begin
      Lines.Add(RsInfoNoPortAudio);
      Lines.Add(PortAudioLoadError);
    end;
    Lines.Add('');
    if FStream <> nil then
    begin
      Lines.Add(Format(RsInfoPending, [FStream.PendingSeconds]));
      { 実時間比と、いま守っている解析の間隔（要件 FR-G.4・FR-G.3）。
        **どちらも、遅い機械で何が起きているのかを説明する数字です。**
        The real-time ratio and the interval now kept (FR-G.4, FR-G.3): **the
        two numbers that explain what is happening on a slow machine.** }
      if FStream.RealTimeRatio > 0 then
        Lines.Add(Format(RsInfoPace,
          [FStream.StepCostSeconds, FStream.RealTimeRatio,
           FStream.PaceSeconds]));
      { 追いつけずに捨てた分は、黙って消えてはいけません。読めなかった理由が
        そこにあるかもしれないからです（要件 NFR-4、FR-G.3）。
        Audio dropped through falling behind must not vanish silently: it may
        be why something was not read (requirements NFR-4, FR-G.3). }
      if FStream.DroppedSeconds > 0 then
        Lines.Add(Format(RsInfoDropped, [FStream.DroppedSeconds]));
    end;
    if FJournal <> nil then
    begin
      if not FSetJournal.Checked then
        Lines.Add(RsInfoJournalOff)
      else if FJournal.FileName = '' then
        Lines.Add(Format(RsInfoJournalNotYet, [JournalDirectory]))
      else
        Lines.Add(Format(RsInfoJournal,
          [FJournal.FileName, FJournal.LinesWritten, FJournal.BytesWritten]));
      if FJournal.LastError <> '' then
        Lines.Add('  ' + FJournal.LastError);
    end;
    { 同梱している許諾条項を一覧で出します（要件 NFR-8.4）。

      **AGPL の本体と、MIT 系の同梱物が混ざっている**ので、利用者が何を受け
      取ったのかを知る手立てが要ります。開発の木から走らせているときは
      `licences/` が無いので、**在るふりをせず、無いと言います。**

      The bundled licence texts, listed (requirement NFR-8.4).

      **An AGPL application with MIT-style libraries inside it** needs to let
      the operator see what they actually received. Run from a build tree there
      is no `licences/`, and then it **says so rather than pretending.** }
    Licences := BundledLicences;
    try
      Lines.Add('');
      if Licences.Count = 0 then
        Lines.Add(RsInfoNoLicences)
      else
      begin
        Lines.Add(Format(RsInfoLicences,
          [Licences.Count, LicenceDirectory]));
        for I := 0 to Licences.Count - 1 do
          Lines.Add('  ' + Licences[I]);
      end;
    finally
      Licences.Free;
    end;

    if FLog <> nil then
    begin
      Lines.Add(Format(RsInfoLog, [FLog.Count, FLog.FileName]));
      if FLog.LastError <> '' then
        Lines.Add('  ' + FLog.LastError);
    end;
    if FHistory <> nil then
      { 保持している音の量と、それが使っている記憶を出します。長くするほど
        増えるので、選ぶ前ではなく選んだあとに実際の数字が見えることが要ります
        （要件 FR-G.3）。
        How much audio is held and what it costs in memory. It grows with the
        retention, so the real figure has to be visible after the choice rather
        than only described before it (requirement FR-G.3). }
      Lines.Add(Format(RsInfoReplay,
        [FHistory.RetainedSeconds, FHistory.RetentionSeconds / 60,
         FHistory.RetentionSeconds * FHistory.SampleRate * SizeOf(Single) / (1024 * 1024)]));
    if Length(FDevices) = 0 then
      Lines.Add(RsInfoNoDevices)
    else
      for Device := 0 to High(FDevices) do
        Lines.Add(Format(RsInfoDevice,
          [FDevices[Device].Index, FDevices[Device].Name, FDevices[Device].HostApi,
           FDevices[Device].MaxInputChannels, FDevices[Device].DefaultSampleRate,
           BoolToStr(FDevices[Device].IsDefault, RsInfoDefaultMark, '')]));

    Lines.Add('');
    Lines.Add(Format(RsInfoConfigFile, [ConfigFileName]));
    if (FDiagnostics <> nil) and (FDiagnostics.Count > 0) then
    begin
      Lines.Add('');
      Lines.Add(RsInfoDiagnostics);
      Lines.AddStrings(FDiagnostics);
    end;
    FSetInfo.Lines.Assign(Lines);
  finally
    Lines.Free;
  end;

  if FDecoder <> nil then
    SetStatus(Format(RsInfoEngineVersion, [OnnxRuntimeVersion]), '', '')
  else
    SetStatus(RsInfoEngineNotLoaded, '', '');
end;

{ ---- engine ---- }

{ 「自動」は 1 スレッドです。実測で実時間の 40〜60 倍が出ており、増やす必要が
  ありません（要件 FR-G.2）。機器に応じた調整は FR-G.4 で扱います。

  "Automatic" means one thread: measured throughput is 40-60 times real time,
  so more buys nothing (requirement FR-G.2). Adapting to slower machines is
  FR-G.4's job. }
function TMainForm.SelectedThreads: Integer;
begin
  case FSetThreads.ItemIndex of
    1: Result := 1;
    2: Result := 2;
    3: Result := 4;
  else
    Result := 1;
  end;
end;

{ 表示は「8000 Hz（推奨）」のような文言なので、先頭の数値だけを取り出します。
  The list shows text like "8000 Hz (recommended)"; take the leading number. }
function TMainForm.SelectedCaptureRate: Integer;
var
  Item: string;
  I: Integer;
begin
  Item := FSetCaptureRate.Text;
  I := 1;
  while (I <= Length(Item)) and (Item[I] in ['0'..'9']) do
    Inc(I);
  Result := StrToIntDef(Copy(Item, 1, I - 1), 8000);
end;

function TMainForm.EnsureDecoder(Silent: Boolean): Boolean;
begin
  if FDecoder <> nil then
    Exit(True);
  try
    LoadOnnxRuntime(FSetRuntime.Text);
    FDecoder := TDeepCWDecoder.Create(FSetModel.Text, FSetMetadata.Text, SelectedThreads);
    FEngineError := '';
    Result := True;
  except
    on E: Exception do
    begin
      FEngineError := E.Message;
      FDecoder := nil;
      if Silent then
      begin
        LogDiagnostic(RsCtxEngineLoad, E.Message);
        SetStatus(RsInfoEngineNotLoaded, '',
          StatusLine(E.Message));
      end
      else
        ReportError(RsCtxEngineLoad, E);
      Result := False;
    end;
  end;
end;

function TMainForm.DecoderBusy: Boolean;
begin
  Result := FDecodeThread <> nil;
end;

{ ファイル・読み直し・モニタの整形の設定を、いまの画面から決めます。どれも
  流し込み受信とまったく同じ整形を通るので、同調していれば録音済みの音声にも
  効きます。整形の結果はモデルの周波数になっています。
  The preparation settings for files, re-readings and the monitor, taken from
  the screen as it is now. All of them go through exactly the same preparation
  as streaming reception, so a tuning applies to recordings too. The result of
  the preparation is at the model's rate. }
function TMainForm.DecoderShaping: TDecoderShaping;
begin
  Result.Meta := FDecoder.Metadata;
  Result.TuneHz := FRxWaterfall.TuneHz;
  Result.AntiAlias := FRxAntiAlias.Checked;
  Result.HalfWidthHz := BandwidthHalfWidth(SelectedBandwidth);
  Result.AutoWidth := False;
  { 自動なら、流し込み受信と同じく近くの局に合わせます（付録 CC）。読み直しと
    モニタは、**受信やファイルの復号が実際に掛けた幅**を使います。短い切れ端で
    決め直すと、読んだときとは別の音を聴くことになります。どちらも無ければ、
    渡された音から決めます。
    Automatic follows the stations nearby, as streaming reception does
    (appendix CC). The re-reading and the monitor use **the width reception or
    the file decode actually applied**: worked out again from a short clip,
    they would hear a different sound from what was read. Failing both, it is
    worked out from the audio handed in. }
  if (SelectedBandwidth = tbAuto) and (Result.TuneHz > 0) then
  begin
    if (FStream <> nil) and (FCapture <> nil) then
      Result.HalfWidthHz := FStream.AppliedHalfWidthHz
    else if (FFileAutoHalf > 0) and (FFileAutoTune = Result.TuneHz) then
      Result.HalfWidthHz := FFileAutoHalf
    else
      Result.AutoWidth := True;
  end;
end;

function TMainForm.PrepareForDecoder(const Samples: TSingleArray;
  SampleRate: Integer): TSingleArray;
var
  Half: Double;
begin
  Result := ShapeForDecoder(DecoderShaping, Samples, SampleRate, Half);
end;

procedure TMainForm.StartDecode(const Samples: TSingleArray; SampleRate: Integer);
begin
  if DecoderBusy or not EnsureDecoder then
    Exit;
  FRxBusy.Caption := RsDecodingBusy;
  FDecodeThread := TDecodeThread.Create(FDecoder, Samples, SampleRate, @DecodeFinished);
  { 解析が始まってから言い直します。**始める前に呼ぶと、まだ走っていないので
    「まだ始めていない」ほうの言葉になります。**長いファイルほど、その空白は
    長く続きます（要件 FR-B.1）。
    Said after the analysis has begun: **called before, nothing is running yet
    and the words would be the not-started ones.** The longer the file, the
    longer that blank lasts (requirement FR-B.1). }
  UpdateTranscriptMessage;
end;

procedure TMainForm.DecodeFinished(Sender: TObject);
var
  Thread: TDecodeThread;
begin
  Thread := TDecodeThread(Sender);
  { 先に預けられたスレッドはすでに終了しているため、ここで解放しても安全です。
    タイマーの解放待ちは常に 1 つまでに保たれます。

    Any thread parked earlier has long since terminated, so releasing it here
    is safe and keeps at most one waiting for the timer. }
  FreeAndNil(FCompletedThread);
  FDecodeThread := nil;

  if FClosing then
  begin
    FCompletedThread := Thread;
    Exit;
  end;

  FRxBusy.Caption := '';

  { 読めなかったファイル。画面はまだ何も片付けていません（`FileLoaded`）。
    A file that could not be read; the screen has cleared nothing yet
    (`FileLoaded`). }
  if Thread.LoadError <> '' then
  begin
    ReportError(RsCtxWavRead, Thread.LoadError);
    FCompletedThread := Thread;
    Exit;
  end;

  { 読み直しの結果は、ここで折り返します（要件 FR-C.3）。**受信テキストへは
    流しません。**確かめるために読んだものが、確かめた相手を書き換えては
    いけません（要件 FR-B.2）。
    A re-reading turns back here (requirement FR-C.3): **it does not flow into
    the transcript.** What was read in order to check something must not rewrite
    the thing it checked (requirement FR-B.2). }
  { 送信訓練の採点のための解析は、ここで折り返します（要件 FR-H.6）。
    **受信テキストへは流しません。**送った符号を機械が読んだ結果は、
    「写しやすさ」の材料であって、受信の記録ではありません。
    An analysis for the send-practice score turns back here (FR-H.6) and **does
    not flow into the transcript**: what the machine made of one's own sending
    is material for the copyability score, not a record of reception. }
  if Thread.Fist then
  begin
    if Thread.Error <> '' then
    begin
      LogDiagnostic(RsCtxFistScore, Thread.Error);
      FtFinish(-1);
    end
    else
      FtFinish(CharErrorRate(NormalizeText(FFtExercise),
        Trim(DecodedText(Thread.Chars))));
    FCompletedThread := Thread;
    Exit;
  end;

  if Thread.Recheck then
  begin
    if Thread.Error <> '' then
    begin
      LogDiagnostic(RsCtxRecheck, Thread.Error);
      SetStatus('', '', StatusLine(Thread.Error));
    end
    else
      ShowRecheck(Thread.Chars);
    FCompletedThread := Thread;
    Exit;
  end;

  if Thread.Error <> '' then
  begin
    LogDiagnostic(RsCtxDecode, Thread.Error);
    SetStatus('', '', StatusLine(Thread.Error));
  end
  else if BandMode then
    { 待機モードでは、局ごとの受信文ではなく一覧を出します。
      In the waiting mode the list is shown, not a per-station transcript. }
    RefreshBandMap
  else
  begin
    if FAppendMode then
      { 流し込み受信では、確定と暫定を分けて表示します。
        Streaming reception shows confirmed and provisional text apart. }
      ShowStreamText
    else
    begin
      FLiveChars := Thread.Chars;
      FRstFromChar := 0;
      FRxTranscript.PendingFrom := MaxInt;
      FRxTranscript.SetChars(FLiveChars);
      ReadTranscript;
      SetStatus('', '', Format(RsDecodeDone, [Length(Thread.Chars)]));
    end;
  end;

  { 参照番号の知らせは**状態の欄を書いたあと**に出します。先に出すと、その直後の
    「デコード完了」に上書きされて一度も読めません。**画面に出したつもりで
    出ていない**という、いちばん質の悪い失敗です。実際そうなっていたのを、
    走らせた画面を撮って見つけました（付録 AN）。
    The reference is announced **after the status line is written**: announced
    before, it is overwritten by the "decode complete" that follows and is never
    read. That is the worst kind of failure -- **believing something is on screen
    when it is not** -- and it is what a screenshot of the running program
    actually showed (appendix AN). }
  AnnounceReference;
  { 解析が終われば、欄はもう「解析しています」ではありません。文字が 1 つも
    出なかったとき（雑音だけの音）に、その言葉が残ります。
    With the analysis done the area is no longer "analysing"; those words would
    otherwise stay behind when not one character came out, as with sound that
    held only noise. }
  UpdateTranscriptMessage;

  { 受信を止めたあとに解析が終わったなら、ここで残りを確定させます。
    If reception was stopped while this analysis ran, the tail is committed
    now. }
  if FFinishPending and (FCapture = nil) then
  begin
    FFinishPending := False;
    try
      { どちらの機械が動いていたかで、残りを読み切る相手が違います。動いて
        いないほうを触ると、何も無いところを確定させることになります。
        Which machine was running decides which one reads out the remainder;
        touching the other would commit from nothing. }
      if BandMode then
      begin
        if FMulti <> nil then
        begin
          FMulti.Finish;
          FBandMapAt := 0;
          RefreshBandMap;
        end;
        Exit;
      end;
      FStream.Finish;
      { ShowStreamText の中で、確定した末尾が記録へ回ります。そのあとで書き残しを
        出さないと、最後の語が待ったまま残ります（要件 FR-B.6）。
        ShowStreamText passes the newly confirmed tail to the journal; without
        the flush that follows, the last word would stay waiting (requirement
        FR-B.6). }
      ShowStreamText;
      if FJournal <> nil then
        FJournal.Flush;
    except
      on E: Exception do
        LogDiagnostic(RsCtxReceiveStop, E.Message);
    end;
  end;

  FCompletedThread := Thread;
end;

{ ---- transmit ---- }

procedure TMainForm.TxTextChanged(Sender: TObject);
begin
  RenderTransmit;
  if Sender <> nil then
    MarkSettingsDirty;
end;

procedure TMainForm.TxOptionsChanged(Sender: TObject);
begin
  if Sender <> nil then
    MarkSettingsDirty;
  { ファンズワース間隔は、実効速度が文字速度以下のときにのみ意味を持ちます。
  Farnsworth only makes sense when the effective speed is the slower one. }
  if FTxTextWpm.Value > FTxCharWpm.Value then
    FTxTextWpm.Value := FTxCharWpm.Value;
  { 無線機のキーヤーの速度は、文字速度に合わせます。
    The rig keyer's speed follows the character speed. }
  if FKeyer <> nil then
    FKeyer.SetWpm(FTxCharWpm.Value);
  RenderTransmit;
end;

{ 送信の要約（文字数と長さ）を出します。**言語を変えたときも通ります**ので、
  音は作り直しません——送信中に作り直すと、鳴っている音を取り替えることになります。
  Shows the transmit summary (characters and length). **Also run when the
  language changes**, so the audio is not rebuilt: rebuilding it mid-send
  would swap the sound being played. }
procedure TMainForm.UpdateTxSummary;
begin
  if (FTxSummary = nil) or FTxRenderFailed then
    Exit;
  FTxSummary.Caption := Format(RsTxSummary,
    [Length(FTxNormalized), Length(FTxSamples) / FTxSampleRate]);
end;

procedure TMainForm.SettingChanged(Sender: TObject);
begin
  MarkSettingsDirty;
end;

{ 拡張の選択（要件 FR-W・FR-N）。**準備中の項目は選べず、元へ戻して
  そう言います。**ノイズ低減は、作る側（`CreateNoiseReducer`）が使えないものを
  素通しにするので、**選べるかの判定はそこ 1 か所**です。
  An extension choice (FR-W, FR-N). **A pending item cannot be chosen: the
  choice goes back and the operator is told.** The factory
  (`CreateNoiseReducer`) turns an unavailable reducer into pass-through, so
  **whether it can be chosen is decided there alone.** }
procedure TMainForm.ExtensionChanged(Sender: TObject);
var
  Fresh: TNoiseReducer;
begin
  if Sender = FSetAlphabet then
  begin
    if not AlphabetAvailable(TCwAlphabet(Max(0, FSetAlphabet.ItemIndex))) then
    begin
      FSetAlphabet.ItemIndex := Ord(caInternational);
      SetStatus('', '', RsSetExtPending);
      Exit;
    end;
  end
  else if Sender = FSetNoise then
  begin
    Fresh := CreateNoiseReducer(NOISE_ITEMS[Max(0, FSetNoise.ItemIndex)]);
    if Fresh.Key <> NOISE_ITEMS[Max(0, FSetNoise.ItemIndex)] then
    begin
      Fresh.Free;
      FSetNoise.ItemIndex := Max(0, NoiseItemIndex(FReducer.Key));
      SetStatus('', '', RsSetExtPending);
      Exit;
    end;
    FReducer.Free;
    FReducer := Fresh;
  end;
  MarkSettingsDirty;
end;

{ 復号へ渡す音（要件 FR-N）。**受信の入口はすべてここを通します。**生の音は
  変えません（使わないときは同じ配列が返ります）。
  The audio handed to the decoder (FR-N). **Every receive entry point goes
  through here.** The raw audio is never changed (off returns the same array). }
function TMainForm.ForDecoderAudio(const Samples: TSingleArray;
  SampleRate: Integer): TSingleArray;
begin
  Result := ForDecoder(FReducer, Samples, SampleRate);
end;

{ 自局が送っている（か、送り終えた直後）で、復号を止めるか（要件 FR-T.4）。
  **鍵の様子は、使うかどうかに関わらず毎回伝えます**——設定を入れた瞬間から
  正しく止まるためです。
  Whether the station is sending (or has just finished) and decoding is to be
  paused (FR-T.4). **The keyer is reported every time, whether or not the
  setting is on**, so that turning it on takes effect at once. }
{ 無線機から読めた、新しい周波数とモード（要件 FR-T.7）。**応答している
  （待機・送信中）ときの、15 秒以内の読み取りだけ**を使います。応答が無い・
  切れた無線機の周波数は、もう合っているか分からないためです。送っている間は
  確かめないので、送る直前の読み取りを使います。
  A fresh frequency and mode read from the rig (FR-T.7). **Only a reading from
  a rig that answers (ready or sending), at most 15 s old**, is used: the
  frequency of a silent or lost rig may no longer be right. No check runs while
  sending, so the reading from just before is used then. }
function TMainForm.RigReading(out FreqHz: Double; out Mode: string): Boolean;
const
  FRESH_MS = 15000;
var
  Status: TKeyerStatus;
begin
  FreqHz := 0;
  Mode := '';
  Result := False;
  if FKeyer = nil then
    Exit;
  Status := FKeyer.Snapshot;
  if (Status.RigFreqHz <= 0) or (Status.RigReadAt = 0) then
    Exit;
  if not ((Status.State = ksSending) or
          ((Status.State = ksReady) and
           (GetTickCount64 - Status.RigReadAt <= FRESH_MS))) then
    Exit;
  FreqHz := Status.RigFreqHz;
  Mode := Status.RigMode;
  Result := True;
end;

{ 記録し、交信済みを問うバンド（要件 FR-T.7）。無線機の周波数を使っていれば
  そのバンド、でなければ運用者の選択。**記録するバンドと問うバンドは必ず
  同じ**です（`WorkedBefore` の注記）。
  The band to record and to ask "worked?" about (FR-T.7): the rig's band while
  its frequency is in use, otherwise the operator's choice. **The band recorded
  and the band asked are always the same** (see `WorkedBefore`). }
function TMainForm.OperatingBand: string;
begin
  if FRigBandActive then
    Result := FRigBandName
  else
    Result := SelectedBand;
end;

{ 無線機の周波数に合わせてバンドの選択を動かします（要件 FR-T.7）。**運用者の
  選択は控えて、読めなくなったら戻します**（無線機の値で上書きしたまま保存
  しない）。使っている間は選択を押せなくします（どちらが効いているか迷わない）。
  Moves the band choice to follow the rig's frequency (FR-T.7). **The
  operator's own choice is kept aside and restored once the rig can no longer
  be read** (never saved overwritten by the rig's value). While in use the
  choice is disabled, so there is no doubt which one applies. }
procedure TMainForm.UpdateRigBand;
var
  Hz: Double;
  Mode, Band: string;
  Index: Integer;
  Reading: Boolean;
begin
  if (FRxBand = nil) or (FSetRigUseFreq = nil) then
    Exit;
  { 読めていれば、**アマチュアバンドの外でも無線機に従います**（バンドは空、
    記録には FREQ だけ）。外にいるときに手の選択へ戻すと、古い選択のバンドで
    記録してしまいます（付録 BV.2）。
    With a reading, **the rig is followed even outside the amateur bands**
    (empty band, only FREQ in the log): falling back to the hand choice there
    would record under a stale band (appendix BV.2). }
  Band := '';
  Reading := FSetRigUseFreq.Checked and RigReading(Hz, Mode);
  if Reading then
    Band := AdifBandForMHz(Hz / 1000000);
  if Reading then
  begin
    if not FRigBandActive then
    begin
      FManualBand := FRxBand.ItemIndex;
      FRigBandActive := True;
      FRxBand.Enabled := False;
    end;
    Index := 0;
    while (Index < FRxBand.Items.Count) and
          (not SameText(BandNameAt(Index), Band)) do
      Inc(Index);
    if Index >= FRxBand.Items.Count then
      Index := 0;
    if (Band <> FRigBandName) or (FRxBand.ItemIndex <> Index) then
    begin
      FRigBandName := Band;
      FRxBand.ItemIndex := Index;
      RxContestChanged(nil);
    end;
  end
  else if FRigBandActive then
  begin
    FRigBandActive := False;
    FRigBandName := '';
    FRxBand.Enabled := True;
    FRxBand.ItemIndex := FManualBand;
    RxContestChanged(nil);
  end;
end;

function TMainForm.ReceiveMutedForTx: Boolean;
var
  Status: TKeyerStatus;
  NowMs: QWord;
begin
  Result := False;
  if (FKeyer = nil) or (FTxGate = nil) then
    Exit;
  Status := FKeyer.Snapshot;
  NowMs := GetTickCount64;
  FTxGate.Update(Status.State = ksSending, Status.KeyedUntil, NowMs);
  Result := FSetMuteRx.Checked and FTxGate.Muted(NowMs);
end;

{ 送信文を作り、下の欄へ入れます（要件 FR-T.1）。**差し込みの値が無ければ
  作らず**、何が足りないかを言います（抜けたまま送らない）。
  Composes the text into the box below (FR-T.1). **With a macro value
  missing nothing is composed**; what is missing is said instead (never send
  with a gap). }
procedure TMainForm.ComposeInto(const Template: string);
var
  Context: TTxContext;
  Composed, Detail: string;
  Problem: TTxProblem;
begin
  Context.MyCall := Trim(FSetMyCall.Text);
  Context.TheirCall := Trim(FTxTheirCall.Text);
  Context.Rst := Trim(FTxRst.Text);
  if not ExpandTemplate(Template, Context, Composed, Problem, Detail) then
  begin
    case Problem of
      tpMissingValue: SetStatus('', '', Format(RsTxProblemMissing, [Detail]));
    else
      SetStatus('', '', Format(RsTxProblemUnknown, [Detail]));
    end;
    Exit;
  end;
  FTxText.Text := Composed;
  SetStatus('', '', RsTxComposed);
end;

procedure TMainForm.TxAutoClick(Sender: TObject);
begin
  if (FTxStage.ItemIndex < Ord(Low(TTxStage))) or
     (FTxStage.ItemIndex > Ord(High(TTxStage))) then
    Exit;
  ComposeInto(AutoTemplate(TTxStage(FTxStage.ItemIndex)));
end;

procedure TMainForm.TxTemplateClick(Sender: TObject);
begin
  if (FTxTemplate.ItemIndex < 0) or
     (FTxTemplate.ItemIndex >= FSetTemplates.Lines.Count) then
  begin
    SetStatus('', '', RsTxNoTemplates);
    Exit;
  end;
  ComposeInto(Trim(FSetTemplates.Lines[FTxTemplate.ItemIndex]));
end;

{ 受信タブで読めた相手の符号を持ってきます（要件 FR-T.1）。**押したときだけ**
  です。勝手に書き換えると、確かめた文と送る文が食い違います。
  Takes the call sign read on the Receive tab (FR-T.1). **Only when pressed**:
  changing it on its own would make the checked text differ from the sent one. }
procedure TMainForm.TxFromRxClick(Sender: TObject);
var
  Call: string;
begin
  Call := CallsignToLog;
  if Call = '' then
  begin
    SetStatus('', '', RsTxNoRxCall);
    Exit;
  end;
  { **自局の符号は相手に入れません**（付録 BS.4）。自分の送信を受信が拾うと、
    「DE の直後」は自局になります。
    **The operator's own call is never taken as theirs** (appendix BS.4): when
    reception picks up one's own sending, the call after DE is one's own. }
  if SameText(Call, Trim(FSetMyCall.Text)) then
  begin
    SetStatus('', '', Format(RsTxRxIsMine, [Call]));
    Exit;
  end;
  FTxTheirCall.Text := Call;
end;

{ 定型の一覧を、設定タブの欄から作り直します。定型は利用者の文そのもの
  なので訳しません。/ Rebuilds the template list from the settings box; the
  templates are the operator's own words and are not translated. }
procedure TMainForm.RefreshTemplates;
var
  I, Was: Integer;
begin
  if (FTxTemplate = nil) or (FSetTemplates = nil) then
    Exit;
  Was := FTxTemplate.ItemIndex;
  FTxTemplate.Items.BeginUpdate;
  try
    FTxTemplate.Items.Clear;
    for I := 0 to Min(FSetTemplates.Lines.Count, 8) - 1 do
      FTxTemplate.Items.Add(Trim(FSetTemplates.Lines[I]));
  finally
    FTxTemplate.Items.EndUpdate;
  end;
  if (Was >= 0) and (Was < FTxTemplate.Items.Count) then
    FTxTemplate.ItemIndex := Was
  else if FTxTemplate.Items.Count > 0 then
    FTxTemplate.ItemIndex := 0;
end;

procedure TMainForm.SetTemplatesChanged(Sender: TObject);
begin
  RefreshTemplates;
  MarkSettingsDirty;
end;

function TMainForm.RigSettings: TRigSettings;
begin
  Result.Model := FSetRigModel.Value;
  Result.Port := Trim(FSetRigPort.Text);
  Result.Baud := StrToIntDef(FSetRigBaud.Items[Max(0, FSetRigBaud.ItemIndex)], 0);
  Result.Conf := RigConfPairs(RigConfFromScreen);
  { 電源は繋ぐときには入れません（要件 FR-T.6）。/ Connecting never powers on. }
  Result.PowerOnAtOpen := False;
end;

function IndexOfChoice(const Value: string; const Choices: array of string): Integer;
var
  I: Integer;
begin
  for I := 0 to High(Choices) do
    if Choices[I] = Value then
      Exit(I);
  Result := 0;
end;

function IndexOfIntChoice(Value: Integer; const Choices: array of Integer): Integer;
var
  I: Integer;
begin
  for I := 0 to High(Choices) do
    if Choices[I] = Value then
      Exit(I);
  Result := 0;
end;

{ 画面の詳しい接続設定（要件 FR-T.5）。/ The detailed settings on screen. }
function TMainForm.RigConfFromScreen: TRigConf;
begin
  Result := DefaultRigConf;
  Result.CivAddr := Trim(FSetRigCivAddr.Text);
  Result.DataBits := RIG_DATA_BITS_CHOICES[Max(0, FSetRigDataBits.ItemIndex)];
  Result.StopBits := RIG_STOP_BITS_CHOICES[Max(0, FSetRigStopBits.ItemIndex)];
  Result.Parity := RIG_PARITY_CHOICES[Max(0, FSetRigParity.ItemIndex)];
  Result.Handshake := RIG_HANDSHAKE_CHOICES[Max(0, FSetRigHandshake.ItemIndex)];
  Result.Dtr := RIG_LINE_CHOICES[Max(0, FSetRigDtr.ItemIndex)];
  Result.Rts := RIG_LINE_CHOICES[Max(0, FSetRigRts.ItemIndex)];
  Result.TimeoutMs := FSetRigTimeout.Value;
  Result.WriteDelayMs := FSetRigWriteDelay.Value;
  Result.PostWriteDelayMs := FSetRigPostDelay.Value;
end;

procedure TMainForm.RigConfToScreen(const Conf: TRigConf);
begin
  FSetRigCivAddr.Text := Conf.CivAddr;
  FSetRigDataBits.ItemIndex := IndexOfIntChoice(Conf.DataBits, RIG_DATA_BITS_CHOICES);
  FSetRigStopBits.ItemIndex := IndexOfIntChoice(Conf.StopBits, RIG_STOP_BITS_CHOICES);
  FSetRigParity.ItemIndex := IndexOfChoice(Conf.Parity, RIG_PARITY_CHOICES);
  FSetRigHandshake.ItemIndex := IndexOfChoice(Conf.Handshake, RIG_HANDSHAKE_CHOICES);
  FSetRigDtr.ItemIndex := IndexOfChoice(Conf.Dtr, RIG_LINE_CHOICES);
  FSetRigRts.ItemIndex := IndexOfChoice(Conf.Rts, RIG_LINE_CHOICES);
  FSetRigTimeout.Value := Conf.TimeoutMs;
  FSetRigWriteDelay.Value := Conf.WriteDelayMs;
  FSetRigPostDelay.Value := Conf.PostWriteDelayMs;
end;

{ 繋ぎます（要件 FR-T.2・T.5）。**詳しい接続設定を先に確かめ、通らなければ
  繋ぎません**（理由を名指しする）。起動したら繋ぐ設定のときも、ここを通ります。
  Connects (FR-T.2, T.5). **The detailed settings are checked first, and a
  failure means no connection** (the reason is named). Connecting at start-up
  comes through here too. }
procedure TMainForm.RigConnectClick(Sender: TObject);
var
  Problem: TRigConfProblem;
  Setting: string;
begin
  if FSetRigModel.Value <= 0 then
  begin
    SetStatus('', '', RsRigNoModel);
    Exit;
  end;
  if not CheckRigConf(RigConfFromScreen, Problem, Setting) then
  begin
    case Problem of
      rcpCivAddr: SetStatus('', '', RsRigConfCivAddr);
      rcpRange: SetStatus('', '', Format(RsRigConfRange, [Setting]));
      rcpRtsWithHardware: SetStatus('', '', RsRigConfRtsHardware);
    else
      SetStatus('', '', Format(RsRigConfChoice, [Setting]));
    end;
    Exit;
  end;
  FRigFaultLogged := False;
  FKeyer.Connect(RigSettings, FTxCharWpm.Value);
  UpdateRigStatus;
end;

{ 電源を入れます（要件 FR-T.6）。**利用者が押したときだけ**で、自動では
  決して入れません。応答が無いときだけ頼めます。
  Powers the rig on (FR-T.6). **Only when the operator presses**; never
  automatically. It can be asked only while the rig does not answer. }
procedure TMainForm.RigPowerClick(Sender: TObject);
begin
  FRigFaultLogged := False;
  if not FKeyer.PowerOn then
  begin
    SetStatus('', '', RsRigPowerNotNow);
    Exit;
  end;
  SetStatus('', '', RsRigPowerAsked);
  UpdateRigStatus;
end;

procedure TMainForm.RigDisconnectClick(Sender: TObject);
begin
  FKeyer.Stop;
  FKeyer.Disconnect;
  UpdateRigStatus;
end;

{ 無線機で送ります（要件 FR-T.2）。**送るのは欄の文そのもの**で、確かめて
  通らなければ送りません（落とさずに断る）。
  Sends through the rig (FR-T.2). **Exactly the box's text is sent**, and
  only if it passes the check (refused, never trimmed). }
procedure TMainForm.RigSendClick(Sender: TObject);
var
  Clean, Detail: string;
  Problem: TTxProblem;
begin
  if not CheckTransmitText(FTxText.Text, FTxCharWpm.Value, Clean, Problem,
    Detail) then
  begin
    case Problem of
      tpEmpty: SetStatus('', '', RsTxProblemEmpty);
      tpUnsendable: SetStatus('', '', Format(RsTxProblemUnsendable, [Detail]));
      tpTooLong: SetStatus('', '', Format(RsTxProblemTooLong,
        [Detail, TX_MAX_CHARS, TX_MAX_SECONDS]));
      tpUnexpanded: SetStatus('', '', Format(RsTxProblemUnexpanded, [Detail]));
    end;
    Exit;
  end;
  { モードの確かめは鍵のスレッドが**送る直前に読み直して**行います（付録
    BV.1）。ここで 5 秒ごとの読み取りを見て判じると、切り替えた直後に取り違え
    ます。断ったことは `UpdateRigStatus` が言います。
    The mode is checked by the keyer thread, **read again right before
    sending** (appendix BV.1); judging here from the 5-second reading would
    misread a switch just made. `UpdateRigStatus` reports a refusal. }
  if not FKeyer.Send(Clean) then
  begin
    SetStatus('', '', RsRigNotReady);
    Exit;
  end;
  SetStatus('', '', RsRigStarted);
  UpdateRigStatus;
end;

procedure TMainForm.RigStopClick(Sender: TObject);
begin
  FKeyer.Stop;
  SetStatus('', '', RsRigStopped);
  UpdateRigStatus;
end;

{ Esc は、どこにいても送信を止めます（要件 FR-T.3）。
  Esc stops sending wherever the focus is (FR-T.3). }
procedure TMainForm.FormKeyDown(Sender: TObject; var Key: Word;
  Shift: TShiftState);
begin
  if (Key = VK_ESCAPE) and (FKeyer <> nil) and
     (FKeyer.Snapshot.State in [ksSending, ksConnecting]) then
  begin
    FKeyer.Stop;
    SetStatus('', '', RsRigStopped);
    Key := 0;
  end;
end;

{ 無線機の様子を札とボタンに映します。`PollTimer` と `ApplyTexts` が呼びます。
  **止めるボタンは無効にしません。**
  Shows the rig's state on the label and buttons; called by `PollTimer` and
  `ApplyTexts`. **The stop button is never disabled.** }
procedure TMainForm.UpdateRigStatus;
var
  Status: TKeyerStatus;
  Caption_: string;
  RigHz: Double;
  RigModeName: string;
begin
  if (FKeyer = nil) or (FRigStatus = nil) then
    Exit;
  Status := FKeyer.Snapshot;
  case Status.State of
    ksOff: Caption_ := RsRigOff;
    ksConnecting: Caption_ := RsRigConnecting;
    ksNoAnswer: Caption_ := RsRigNoAnswer;
    ksPoweringOn: Caption_ := RsRigPoweringOn;
    ksReady:
      { 無線機が答えた速度を先に見せます。丸められていれば、それが本当の
        速度です（付録 BS.2）。/ The speed the rig reports comes first: if it
        was clamped, that is the real speed (appendix BS.2). }
      if Status.RigWpm > 0 then
        Caption_ := Format(RsRigReady, [Status.RigWpm])
      else if Status.SpeedSet then
        Caption_ := Format(RsRigReady, [Status.Wpm])
      else
        Caption_ := RsRigReadyNoSpeed;
    ksSending: Caption_ := Format(RsRigSending, [Status.Handed, Length(Status.Text)]);
  else
    Caption_ := RsRigFailed;
  end;
  if (Status.State = ksReady) and not Status.CanProbe then
    Caption_ := Caption_ + RsRigNoProbe;
  { 読めた周波数とモード（要件 FR-T.7）。/ The frequency and mode read (FR-T.7). }
  if RigReading(RigHz, RigModeName) then
    Caption_ := Caption_ + '  ' + AdifFreqText(RigHz) + ' MHz ' + RigModeName;
  UpdateRigBand;
  if Status.Stop = ssNo then
    Caption_ := Caption_ + RsRigCannotStop;
  if FRigStatus.Caption <> Caption_ then
    FRigStatus.Caption := Caption_;
  FRigConnect.Enabled := Status.State in [ksOff, ksFailed, ksNoAnswer];
  FRigDisconnect.Enabled := Status.State <> ksOff;
  FRigSend.Enabled := Status.State = ksReady;
  FRigStop.Enabled := True;
  FRigPower.Enabled := (Status.State = ksNoAnswer) or
    ((Status.State = ksFailed) and (Status.Fault = kfNoAnswer));
  { 応答が無くなった・戻ったは、移ったときに 1 度だけ言います（要件 FR-T.6）。
    Losing and regaining the answer is said once, when it happens (FR-T.6). }
  if Status.State <> FRigLastState then
  begin
    if Status.State = ksNoAnswer then
    begin
      if FRigLastState in [ksReady, ksSending] then
        SetStatus('', '', RsRigLostAnswer)
      else if FRigLastState = ksConnecting then
        SetStatus('', '', RsRigSilentAfterOpen);
      LogDiagnostic(RsCtxRig, 'The rig does not answer.');
    end
    else if (Status.State = ksReady) and (FRigLastState = ksNoAnswer) then
    begin
      SetStatus('', '', RsRigBack);
      LogDiagnostic(RsCtxRig, 'The rig answers again.');
    end
    else if (Status.State = ksReady) and (FRigLastState in [ksOff, ksConnecting, ksFailed]) then
      { 前の失敗の案内を残さないため。/ So that no earlier failure message lingers. }
      SetStatus('', '', RsRigConnected);
    FRigLastState := Status.State;
  end;
  { 失敗の原文は診断へ 1 度だけ。**送った文は書きません**（診断の控えは、
    受信した文章や符号を含まないと約束しているため）。
    The failure's original text goes to the diagnostics once. **The text sent
    is never written there** -- the diagnostics copy promises to hold no
    received text or call signs. }
  if (Status.State = ksFailed) and not FRigFaultLogged then
  begin
    FRigFaultLogged := True;
    LogDiagnostic(RsCtxRig, Status.Detail);
    case Status.Fault of
      kfNoLibrary: SetStatus('', '', RsRigFailNoLibrary);
      kfModel: SetStatus('', '', RsRigFailModel);
      kfConfig: SetStatus('', '', Format(RsRigFailConfig, [Status.Setting]));
      kfPort: SetStatus('', '', RsRigFailPort);
      kfNoAnswer: SetStatus('', '', RsRigFailNoAnswer);
      kfLink: SetStatus('', '', RsRigFailLink);
      kfStop: SetStatus('', '', RsRigFailStop);
    else
      SetStatus('', '', RsRigFailSend);
    end;
  end;
  { 送る直前にモードで断った（付録 BV.1）。/ Refused on the mode right before
    sending (appendix BV.1). }
  if Status.Refusals <> FRigLastRefusals then
  begin
    FRigLastRefusals := Status.Refusals;
    SetStatus('', '', Format(RsRigModeNotCw, [Status.RefusedMode]));
  end;
  { 電源を頼んだ結果（要件 FR-T.6）。変わったときに 1 度だけ言います。
    The outcome of a power-on request (FR-T.6), said once when it changes. }
  if Status.Power <> FRigLastPower then
  begin
    case Status.Power of
      prNotSupported: SetStatus('', '', RsRigPowerNotSupported);
      prFailed: SetStatus('', '', RsRigPowerFailed);
      prNoWake: SetStatus('', '', RsRigPowerNoWake);
      prAwake: SetStatus('', '', RsRigPowerAwake);
    end;
    if Status.Power in [prNotSupported, prFailed, prNoWake, prAwake] then
      LogDiagnostic(RsCtxRig, Format('Power on: %d', [Ord(Status.Power)]));
    FRigLastPower := Status.Power;
  end;
  { 止められないと分かったときも、状態欄で 1 度だけ詳しく言います。
    Once it is known the rig cannot stop, the status bar says so in full, once. }
  if (Status.Stop = ssNo) and not FRigStopNoted then
  begin
    FRigStopNoted := True;
    SetStatus('', '', RsRigCannotStopNote);
  end;
end;

procedure TMainForm.RenderTransmit;
var
  Timing: TCWTiming;
  Options: TCWToneOptions;
begin
  FTxNormalized := NormalizeText(FTxText.Text);
  FTxCode.Text := TextToMorseCode(FTxText.Text);

  Timing.CharWpm := FTxCharWpm.Value;
  Timing.TextWpm := Min(FTxTextWpm.Value, FTxCharWpm.Value);

  Options := DefaultToneOptions;
  Options.SampleRate := FTxSampleRate;
  Options.ToneHz := FTxToneHz.Value;
  Options.Amplitude := FTxVolume.Position / 100;
  Options.NoiseAmplitude := FTxNoise.Position / 100;

  try
    FTxSegments := TextToSegments(FTxText.Text, Timing);
    FTxSamples := SegmentsToPCM(FTxSegments, Options);
    FTxRenderFailed := False;
    UpdateTxSummary;
  except
    on E: Exception do
    begin
      FTxSegments := nil;
      FTxSamples := nil;
      FTxRenderFailed := True;
      FTxSummary.Caption := E.Message;
    end;
  end;

  FTxProgress.Max := Max(1, Length(FTxSamples));
  FTxProgress.Position := 0;
end;

procedure TMainForm.TxSendClick(Sender: TObject);
begin
  if Length(FTxSamples) = 0 then
  begin
    SetStatus('', '', RsTxNothing);
    Exit;
  end;
  try
    if not LoadPortAudio(FSetPortAudio.Text) then
      raise EDeepCW.Create(PortAudioLoadError);
    FPlayback.Play(FTxSamples, FTxSampleRate);
    FTxPlaying := True;
    SetStatus('', '', RsTxSendingNow);
  except
    on E: Exception do
      ReportError(RsCtxTransmit, E);
  end;
end;

procedure TMainForm.TxStopClick(Sender: TObject);
begin
  { **どの「止める」も無線機を止めます。**押した人が、どちらを止めたつもりか
    分からないためです。
    **Every stop stops the rig too**: which one the operator meant to stop
    cannot be known. }
  if FKeyer <> nil then
    FKeyer.Stop;
  FPlayback.Stop;
  FTxPlaying := False;
  FTxProgress.Position := 0;
  FTxCurrentChar.Caption := '-';
  FTxCurrentCode.Caption := '';
  SetStatus('', '', RsTxStopped);
end;

procedure TMainForm.TxSaveClick(Sender: TObject);
var
  Dialog: TSaveDialog;
begin
  if Length(FTxSamples) = 0 then
    Exit;
  Dialog := TSaveDialog.Create(Self);
  try
    Dialog.Title := RsTxSaveTitle;
    Dialog.Filter := RsWavFilter;
    Dialog.DefaultExt := 'wav';
    Dialog.FileName := 'morse.wav';
    if not Dialog.Execute then
      Exit;
    try
      SaveWavMono(Dialog.FileName, FTxSamples, FTxSampleRate);
      SetStatus('', '', Format(RsSaved, [Dialog.FileName]));
    except
      on E: Exception do
        ReportError(RsCtxWavSave, E);
    end;
  finally
    Dialog.Free;
  end;
end;

procedure TMainForm.TxVerifyClick(Sender: TObject);
var
  Samples: TSingleArray;
  Needed: Integer;
begin
  if Length(FTxSamples) = 0 then
    Exit;
  if DecoderBusy then
    Exit;

  { 送信した音声をそのままデコーダへ戻します。短いメッセージは、モデルが求める
    5 秒の下限を満たすように無音で補います。

    Feed the transmission straight back into the decoder. Short messages get
    padded with silence so they clear the model's five second minimum. }
  Samples := Copy(FTxSamples, 0, Length(FTxSamples));
  Needed := Ceil((DEEPCW_MIN_SECONDS + 0.2) * FTxSampleRate);
  if Length(Samples) < Needed then
    SetLength(Samples, Needed);

  FAppendMode := False;
  FPages.PageIndex := 1;
  StartDecode(Samples, FTxSampleRate);
end;

procedure TMainForm.UpdateTransmitProgress;
var
  PlayPosition: Integer;
  Elapsed, Accumulated: Double;
  I, TextIndex: Integer;
begin
  if not FPlayback.Running then
  begin
    { デバイスが開けない場合、スレッドは最初のバッファを書く前に終了します。
      そのため完了の判定は、進捗ではなくフラグで行います。

      A device that refuses to open ends the thread before the first buffer,
      so completion is tracked by the flag rather than by progress made. }
    if FTxPlaying then
    begin
      FTxPlaying := False;
      FTxProgress.Position := 0;
      FTxCurrentChar.Caption := '-';
      FTxCurrentCode.Caption := '';
      if FPlayback.LastError <> '' then
      begin
        LogDiagnostic(RsCtxPlayback, FPlayback.LastError);
        SetStatus('', '', StatusLine(FPlayback.LastError));
      end
      else
        SetStatus('', '', RsTxDone);
    end;
    Exit;
  end;

  PlayPosition := FPlayback.Position;
  FTxProgress.Position := Min(FTxProgress.Max, PlayPosition);

  { 再生位置を区間の列に対応付け、送出中の文字を表示します。
  Map the play head onto the segment list to show the character on the air. }
  Elapsed := PlayPosition / FTxSampleRate - DefaultToneOptions.LeadInSeconds;
  Accumulated := 0;
  TextIndex := 0;
  for I := 0 to High(FTxSegments) do
  begin
    Accumulated := Accumulated + FTxSegments[I].Duration;
    if Elapsed <= Accumulated then
    begin
      TextIndex := FTxSegments[I].TextIndex;
      Break;
    end;
  end;

  if (TextIndex >= 1) and (TextIndex <= Length(FTxNormalized)) then
  begin
    FTxCurrentChar.Caption := FTxNormalized[TextIndex];
    FTxCurrentCode.Caption := MorseForChar(FTxNormalized[TextIndex]);
  end
  else
  begin
    FTxCurrentChar.Caption := '␣';
    FTxCurrentCode.Caption := '';
  end;
end;

{ ---- receive ---- }

procedure TMainForm.RxBrowseClick(Sender: TObject);
var
  Dialog: TOpenDialog;
begin
  Dialog := TOpenDialog.Create(Self);
  try
    Dialog.Title := RsRxOpenTitle;
    Dialog.Filter := RsWavOpenFilter;
    if Dialog.Execute then
      FRxFile.Text := Dialog.FileName;
  finally
    Dialog.Free;
  end;
end;

procedure TMainForm.RxDecodeFileClick(Sender: TObject);
begin
  if DecoderBusy then
    Exit;
  { 読み込みから先は復号のスレッドで行います（要件 NFR-4.2、計画 6.1 の P1）。
    30 分の録音では、読み込みと整形だけで画面が 12 秒止まっていました（付録 CE）。
    ここでは受信を止めることと、エンジンを用意することだけをします。**受信は
    読み込みの前に止めます。**解析の最中に止めると、最後の暫定の文字が確定
    されずに記録から落ちるためです（`RxStopClick`）。
    From loading onward the work happens on the decode thread (NFR-4.2, plan
    6.1 P1): a 30-minute recording used to freeze the screen for 12 seconds on
    loading and preparing alone (appendix CE). Here reception is stopped and
    the engine made ready, nothing more. **Reception stops before the load**:
    stopped in the middle of an analysis, the last provisional characters would
    miss confirmation and drop out of the record (`RxStopClick`). }
  RxStopClick(nil);
  { 整形にモデルの標本化周波数が要るため、先にエンジンを用意します。
    The preparation needs the model's sample rate, so the engine comes first. }
  if not EnsureDecoder then
    Exit;
  { 待機モードでは、録音も帯域として読みます。混み合ったバンドを録った音から
    一覧を作れますし、**音声装置の無い機械でもこの経路を確かめられます。**
    In the waiting mode a recording is read as a band: a list can be built from a
    recording of a crowded band, and **the path can be checked on a machine with
    no sound hardware.** }
  if BandMode and (FMulti = nil) then
    FMulti := TMultiStationDecoder.Create(FDecoder);
  FRxBusy.Caption := RsDecodingBusy;
  if BandMode then
    FDecodeThread := TDecodeThread.CreateFile(FDecoder, FMulti, FHistory,
      FRxFile.Text, @FileLoaded, @FileShaped, @DecodeFinished)
  else
    FDecodeThread := TDecodeThread.CreateFile(FDecoder, nil, FHistory,
      FRxFile.Text, @FileLoaded, @FileShaped, @DecodeFinished);
end;

{ ファイルが読めたとき（復号のスレッドが待っている間に、画面のスレッドで）。
  **読めてから片付けます。**読めないファイルで、前の受信テキストを消さない
  ためです。
  The file has been read (on the UI thread, while the decode thread waits).
  **Clearing waits until the file has been read**, so an unreadable file does
  not wipe the previous transcript. }
procedure TMainForm.FileLoaded(Sender: TObject);
var
  Thread: TDecodeThread;
begin
  Thread := TDecodeThread(Sender);
  if FClosing then
  begin
    Thread.Terminate;
    Exit;
  end;
  FLiveChars := nil;
  FRstFromChar := 0;
  ReadTranscript;
  FAppendMode := False;
  { ファイルの復号は受信をやり直すのと同じ扱いにします。前の受信の続きとして
    時刻を数えたままだと、出てくる文字（0 秒から始まる）と保管庫の音が食い違い、
    聴き直しが別の場所を鳴らします（要件 FR-E.10）。

    Decoding a file is treated as starting reception afresh. Carrying the
    previous reception's clock forward would leave the characters, which start
    at zero, disagreeing with the stored audio, and a replay would play the
    wrong place (requirement FR-E.10). }
  if FStream <> nil then
    FStream.Reset;
  if FMulti <> nil then
    FMulti.Reset;
  FReducer.Reset;
  FRxBandMap.Clear;
  FReviewPlay.Stop;
  { ファイルの復号は実時刻を持ちません。記録は実時刻の記録なので、ここでは
    書き残しを出すだけで、以後は書きません（要件 FR-B.6）。
    A file decode has no wall clock, and the journal is a record of wall-clock
    times, so the waiting line is written out and nothing further is recorded
    (requirement FR-B.6). }
  if FJournal <> nil then
    FJournal.Flush;
  FJournalled := 0;
  FClockOrigin := 0;
  { ファイルの音そのものを保管します（入れるのは復号のスレッド）。これで、
    ファイルから読んだ文字も押せば聴き直せます。保持時間より長いファイルは、
    後ろのぶんだけが残ります。
    The file's own audio is stored (the decode thread puts it in), so
    characters read from a file can be replayed too. A file longer than the
    retention keeps only its tail. }
  FHistory.Clear;
  { 同じ音を波形にも流します。**保管庫と同じ時刻の基準を渡すこと**が肝心で、
    別々に数えさせると、重ねた文字が別の行を指します（要件 FR-D.6）。

    ファイルの復号でも波形を出すのは、**そうしないと、読んだ文字がどの音から
    出たのかを確かめる手立てが、音声装置のある機械でしか使えなくなる**ためです。
    画面に収まるのは末尾の 10 秒ぶんで、それより古い文字は重なりません。

    The same audio goes to the waterfall. **Handing it the store's own time
    origin** is what matters: counted separately, the characters laid over it
    would point at the wrong row (requirement FR-D.6).

    A file decode draws the waterfall too, because otherwise **the means of
    seeing which sound a character came from would exist only on a machine with
    audio hardware.** The display holds the last ten seconds; characters older
    than that are not laid over it. }
  FRxWaterfall.Clear;
  FRxWaterfall.PushSamples(Thread.Samples, Thread.SampleRate, 0);
  { ノイズ低減は画面のスレッドで掛けます（FR-N の取り決め 4。低減器は設定で
    差し替わるため、復号のスレッドには渡しません）。
    Noise reduction is applied on the UI thread (rule 4 of FR-N: the reducer
    is replaced when the setting changes, so it is not handed to the decode
    thread). }
  Thread.Samples := ForDecoderAudio(Thread.Samples, Thread.SampleRate);
  { 前のファイルで決めた幅は、このファイルには当てはまりません。
    The width worked out for the previous file does not apply to this one. }
  FFileAutoHalf := 0;
  Thread.Shaping := DecoderShaping;
  UpdateTuneInfo;
  UpdateReplayInfo;
  { 解析が始まってから言い直します。**始める前に呼ぶと、まだ走っていないので
    「まだ始めていない」ほうの言葉になります。**長いファイルほど、その空白は
    長く続きます（要件 FR-B.1）。
    Said after the analysis has begun: **called before, nothing is running yet
    and the words would be the not-started ones.** The longer the file, the
    longer that blank lasts (requirement FR-B.1). }
  UpdateTranscriptMessage;
end;

{ ファイルの整形が済んだとき。自動の幅なら、決まった幅を表示に出します
  （付録 CC）。**決めたときの同調を一緒に覚えます。**そのあと同調を変えれば、
  その幅はもう当てはまりません。
  The file's preparation is done. For an automatic width the width decided is
  shown (appendix CC), **remembered together with the tuning it was decided
  for**: once retuned, it no longer applies. }
procedure TMainForm.FileShaped(Sender: TObject);
var
  Thread: TDecodeThread;
begin
  if FClosing then
    Exit;
  Thread := TDecodeThread(Sender);
  if Thread.Shaping.AutoWidth then
  begin
    FFileAutoHalf := Thread.AppliedHalfWidthHz;
    FFileAutoTune := Thread.Shaping.TuneHz;
  end;
  UpdateTuneInfo;
  UpdateReplayInfo;
end;

{ 「受信開始」を押したとき。**利用者が望んだ**ことを立ててから始めます
  （要件 NFR-4.4）。装置が外れて止まったときに、また始めてよいかどうかは、
  これで決まります。
  The operator pressed start: **what they want** is recorded before the attempt
  (requirement NFR-4.4), and that is what decides whether a stop caused by the
  device may be followed by another attempt. }
procedure TMainForm.RxStartClick(Sender: TObject);
begin
  if FCapture <> nil then
    Exit;
  FWantCapture := True;
  FWaiting := False;
  FRetryCount := 0;
  FSaidDeviceAt := 0;
  BeginCapture;
end;

{ 実際に取り込みを始めます。**押されたときと、待ってから試し直すときの両方**が
  ここを通ります。利用者の意思（`FWantCapture`）はここでは触りません。
  Actually starts capturing. **Both the press and a retry after waiting** come
  through here; what the operator wants (`FWantCapture`) is not touched. }
procedure TMainForm.BeginCapture;
begin
  if FCapture <> nil then
    Exit;
  { 送信訓練が同じ入力を握っています。**両方が同じ装置を開こうとすると、
    開けないか、どちらが何を測っているのか分からなくなります。**
    Send practice holds the same input. **Both opening the one device would
    either fail or leave it unclear which is measuring what.** }
  if FFtCapture <> nil then
  begin
    SetStatus('', '', RsFtBusyCapture);
    Exit;
  end;
  if not EnsureDecoder then
    Exit;
  try
    if not LoadPortAudio(FSetPortAudio.Text) then
      raise EDeepCW.Create(PortAudioLoadError);

    FCaptureRate := SelectedCaptureRate;
    { 最長の窓の 2 倍を保持し、復号が遅れても次の窓が不足しないようにします。
    Hold twice the longest window so a slow decode never starves the next. }
    { 輪バッファを作り直す前に、それを読んでいるものを止めます。**録音は輪
      バッファを指しているので、先に作り直せば無いものを読みます。**
      Whatever reads the ring is stopped before it is rebuilt: **the recording
      points at the ring, and rebuilding first would leave it reading what is no
      longer there.** }
    StopRecording('');
    FreeAndNil(FRing);
    FRing := TAudioRing.Create(FCaptureRate * 2 * Round(DEEPCW_MAX_SECONDS));
    { 流し込み復号器はここで用意します。エンジンが読めていなければ作れず、
      作られていなければ、録音は溜まるのに一文字も出ません。

      The streaming decoder is created here. It cannot exist before the engine
      loads, and without it audio would pile up while not a single character
      appeared. }
    if FStream = nil then
      FStream := TStreamingDecoder.Create(FDecoder);
    if (FMode = rmWatch) and (FMulti = nil) then
      FMulti := TMultiStationDecoder.Create(FDecoder);
    ApplyStreamSettings;
    { 輪バッファを作り直したので、読み出し位置も先頭へ戻します。
      The ring was recreated, so the read position goes back to its start. }
    FRingPosition := 0;
    { ファイルで決めた幅は、これから受信する音には当てはまりません。残すと、
      受信を止めたあとの読み直しが前のファイルの幅で読みます。
      The width worked out for a file does not apply to what is received now;
      kept, a re-reading after reception stops would use the old file's width. }
    FFileAutoHalf := 0;

    FCapture := TAudioCapture.Create(FRing, FCaptureRate, SelectedDeviceIndex);
    FCapture.Start;
    { 音の細かさが変わればウォーターフォールの目盛りも変わります。溜まって
      いた絵は意味を失うので消します。
      A change of capture rate changes the waterfall's scale, so whatever is
      already drawn no longer means anything and is cleared. }
    FRxWaterfall.Clear;
    FWfMessage := @RsWfWaiting;
    FRxWaterfall.Message_ := FWfMessage^;
    { 「録音」はファイルへ残すこと（要件 FR-E.8）に使う語なので、取り込んで
      いる状態は「受信中」と言います。**1 つの語に 2 つの意味を持たせると、
      録音していないのに録音中と読めます。**
      "Recording" is the word for keeping a file (requirement FR-E.8), so
      capturing is called receiving: **one word with two meanings would read as
      recording when nothing is being recorded.** }
    SetStatus('', Format(RsReceivingHz, [FCaptureRate]), RsReceiveStarted);
    UpdateTranscriptMessage;
    if FSetRecord.Checked then
      StartRecording;
  except
    on E: Exception do
    begin
      FreeAndNil(FCapture);
      LogDiagnostic(RsCtxReceiveStart, E.Message);
      { **知らせは 30 秒に 1 度まで。**3 秒ごとに同じ文言を出し直すと、ほかの
        知らせが読めません（要件 FR-A.4）。
        **Told at most once every thirty seconds**: the same words every three
        would bury every other message (requirement FR-A.4). }
      if SecondsBetween(Now, FSaidDeviceAt) >= 30 then
      begin
        FSaidDeviceAt := Now;
        ReportError(RsCtxReceiveStart, E);
      end;
      FWaiting := True;
      FLastRetryAt := Now;
    end;
  end;
end;

{ 装置がつながるのを待ち、つながったら自分で受信を再開します（要件 NFR-4.4）。

  **待つのは、利用者が受信を望んでいるあいだだけ**です。「受信停止」を押されて
  いれば待ちません。止めた機械が勝手に動き出すのは、**故障と区別が付かない**
  からです。

  上限は置きません。装置が戻るのが 1 分後か 1 時間後かは、こちらには分かりま
  せん。**待っていることは画面に出す**ので、止めたければ止められます。

  Waits for the device and resumes receiving by itself (requirement NFR-4.4).

  **Only while the operator wants to receive**: with stop pressed, there is no
  waiting. A machine that was stopped starting up again on its own **cannot be
  told from a fault.**

  No limit: whether the device returns in a minute or an hour is not ours to
  know. **The waiting is on screen**, so it can be ended. }
procedure TMainForm.RetryCapture;
begin
  if (not FWantCapture) or (FCapture <> nil) or (not FWaiting) then
    Exit;
  { 送信訓練が同じ装置を握っているあいだは試しません。**奪い合っても、どちらも
    使えません。**
    No attempt while send practice holds the same device: **fighting over it
    leaves neither working.** }
  if FFtCapture <> nil then
    Exit;
  { 待ちは**状態の欄**に出します。入力レベルの脇の欄（`FRxSignal`）は
    「音が届いています／無音です」のための短い欄で、ここに長い文を入れると
    はみ出します。
    The wait goes in the **status panel**; the label beside the level meter
    (`FRxSignal`) is the short one for "sound is arriving" and "silent", and a
    sentence there runs off the end. }
  FRxSignal.Caption := RsWaitingDevice;
  SetStatus('', WaitingForDeviceCaption(FRetryCount), '');
  if MilliSecondsBetween(Now, FLastRetryAt) < Round(AUDIO_RETRY_SECONDS * 1000) then
    Exit;
  FLastRetryAt := Now;
  Inc(FRetryCount);
  { 開けたら黙って戻ります。**戻ったと言うのは、実際に読めたとき**です
    （`UpdateLiveReceive`）。開けただけで言うと、読めずにまた止まったときに
    「戻りました」と「開けませんでした」を繰り返します。
    A successful open returns in silence: **the return is announced when reading
    actually works** (in `UpdateLiveReceive`). Announcing it at the open would
    repeat "it is back" and "it could not be opened" in turn whenever the device
    opens but does not read. }
  BeginCapture;
end;

{ 「受信停止」を押したとき。**待っている最中でも押せます**（要件 NFR-4.4）。

  待ちに入ると取り込みそのものは無いので、`FCapture` は nil です。そこで早々に
  戻る作りだと、**押しても待ちが終わらず、止められない機械になります。**
  先に「受信を望んでいる」を下ろします。

  The operator pressed stop. **It works while waiting too** (requirement
  NFR-4.4): waiting holds no capture, so `FCapture` is nil, and returning early
  on that would leave **a machine that goes on waiting however often stop is
  pressed.** What the operator wants is cleared first. }
procedure TMainForm.RxStopClick(Sender: TObject);
begin
  FWantCapture := False;
  FRetryCount := 0;
  FSaidDeviceAt := 0;
  if FWaiting then
  begin
    FWaiting := False;
    FRxSignal.Caption := '';
    SetStatus('', RsRxWaitingLabel, RsRxWaitStopped);
  end;
  if FCapture = nil then
    Exit;
  FCapture.Stop;
  FreeAndNil(FCapture);
  { 録音は取り込みを止めてから終えます。**先に録音を終えると、そのあと届いた
    音が録音に入りません。**
    The recording ends after the capture does: **ending it first would leave the
    audio that arrived afterwards out of the file.** }
  StopRecording('');
  FRxLevel.Position := 0;
  FRxSignal.Caption := '';
  { 残った暫定部分を確定させてから止めます（要件 FR-B.2）。
    Commit whatever is still provisional before stopping. }
  if FStream <> nil then
  begin
    if DecoderBusy then
      { 解析が走っている。終わってから確定させます。ここで捨てると、最後の
        数文字が暫定のまま固まらずに残ります。
        An analysis is running; the tail is committed when it finishes.
        Abandoning it here would leave the last few characters provisional
        for ever. }
      FFinishPending := True
    else
      try
        FStream.Finish;
        ShowStreamText;
      except
        on E: Exception do
          LogDiagnostic(RsCtxReceiveStop, E.Message);
      end;
  end;
  { 書き残しの行を出します。交信の最後の語は、たいてい語間で終わらないため、
    ここで出さなければ記録から落ちます（要件 FR-B.6）。
    The waiting line is written out: the last word of a contact usually does not
    end on a word space, so without this it would be missing from the record
    (requirement FR-B.6). }
  { 待機モードでは、窓 1 枚に満たない残りをここで読み切ります。読まないと、
    最後の 10 秒がどの局からも落ちます（要件 FR-I.1）。
    In the waiting mode the remainder shorter than a window is read out here;
    without it the last ten seconds would be missing from every station
    (requirement FR-I.1). }
  if BandMode and (FMulti <> nil) and not DecoderBusy then
    try
      FMulti.Finish;
      FBandMapAt := 0;
      RefreshBandMap;
    except
      on E: Exception do
        LogDiagnostic(RsCtxReceiveStop, E.Message);
    end;
  if FJournal <> nil then
    FJournal.Flush;
  SetStatus('', RsRxWaitingLabel, RsReceiveStopped);
  UpdateTranscriptMessage;
end;

procedure TMainForm.RxClearClick(Sender: TObject);
begin
  FLiveChars := nil;
  FRstFromChar := 0;
  { 消した受信文の添字は、もう何も指しません。頼まれていた読み直しは捨てます。
    An index into a cleared transcript points at nothing; a re-reading that was
    asked for is dropped. }
  FRecheckPending := False;
  ReadTranscript;
  { 消せば欄は再び空になります。**いまどの状態なのかを言い直さないと、
    消したあとだけ何も出ない欄になります。**
    A clear empties the area again: **without saying which state it is in, the
    area would be the one blank thing left after a clear.** }
  UpdateTranscriptMessage;
  FAlerts.Reset;
  if FStream <> nil then
    FStream.Reset;
  if FMulti <> nil then
    FMulti.Reset;
  FReducer.Reset;
  FRxBandMap.Clear;
  { 受信テキストを消したら、そこを指していた音も手放します。残しておくと、
    次の受信の時刻と噛み合わない音が保管庫に居座ります（要件 FR-E.10）。
    Clearing the transcript releases the audio it pointed at; keeping it would
    leave audio in the store whose times no longer match the next reception
    (requirement FR-E.10). }
  FReviewPlay.Stop;
  if FHistory <> nil then
    FHistory.Clear;
  { 記録は残します。消すのは画面であって、書いたものではありません。書き残しの
    行だけ先に出して、次の受信と混ざらないようにします（要件 FR-B.6）。
    The record stays: what is cleared is the display, not what was written. Only
    the waiting line is written out, so it does not run into the next reception
    (requirement FR-B.6). }
  if FJournal <> nil then
    FJournal.Flush;
  FJournalled := 0;
  FClockOrigin := 0;
  FRxTranscript.Clear;
  FRxWaterfall.Clear;
  FChosenCallsign := '';
  UpdateReplayInfo;
  UpdateFindInfo;
  UpdateLogInfo;
end;

procedure TMainForm.RxCopyClick(Sender: TObject);
begin
  Clipboard.AsText := FRxTranscript.AsText;
  SetStatus('', '', Format(RsRxCopied,
    [FRxTranscript.CharCount]));
end;

{ 受信文を読み直し、見つけた呼出符号の位置を画面へ渡します（要件 FR-E.1）。

  **文字が入れ替わったときにだけ**呼びます。読み取りは 4000 文字で 0.2 ms と
  安いのですが、安いものを 0.2 秒ごとに繰り返す理由はありません。

  Re-reads the transcript and hands the call sign positions to the display
  (requirement FR-E.1).

  Called **only when the characters change.** Reading costs 0.2 ms at 4000
  characters, which is cheap -- but there is no reason to repeat something cheap
  five times a second. }
procedure TMainForm.ReadTranscript;
begin
  FExchange := ReadExchange(FLiveChars);
  ReadRst;
  FRxTranscript.SetCallsigns(FExchange.Callsigns, FExchange.Chosen);
  { 参照番号も同じ文字の並びの上に印を付けます（要件 FR-E.6）。**読み取りは
    1 度で済んでいます。**`ReadExchange` が符号と一緒に返しているためです。
    The references are marked over the same characters (requirement FR-E.6).
    **The reading was done once:** `ReadExchange` returns them with the call
    signs. }
  FRxTranscript.SetReferences(FExchange.References);
  { 同じ文字をウォーターフォールへも渡します（要件 FR-D.6）。読んだ文字が音の
    どこから出たのかが、目で辿れるようになります。
    The same characters go to the waterfall (requirement FR-D.6), so that where
    in the sound each one came from can be followed by eye. }
  FRxWaterfall.SetCharacters(FLiveChars);
end;

{ 読めた参照番号を、状態の欄へ一度だけ知らせます（要件 FR-E.6）。

  受信テキストには `JP6T0123` と出ます。**電波に乗っているのはその文字だから**
  です（付録 AN）。けれど利用者が記録に書くのは `JP-0123` で、ハイフンの位置は
  こちらが補ったものです。**補ったものを黙って見せないため**、直した形のほうを
  言葉で一度出します。

  置き場所は状態の欄です。記録の欄の隣には、既定の窓幅（940）で空きがありません
  （`FRxLogInfo` は 504 から 250、その右 760 が「もう一度聴く」）。**入らない所へ
  文字を足すと、足したものが見えないだけでなく、元からあった文言まで切れます。**

  同じものは繰り返しません。文字が伸びるたびに出し直すと、状態の欄が参照番号で
  埋まり、ほかの知らせが読めなくなります。

  Announces a reference that has been read, once, in the status area
  (requirement FR-E.6).

  The transcript shows `JP6T0123`, **that being what is actually on the air**
  (appendix AN) -- but what the operator writes down is `JP-0123`, and the hyphen
  is ours. **So that nothing we filled in passes unseen**, the corrected form is
  said once, in words.

  The status area is where it goes: there is no room beside the log controls at
  the default window width of 940 (`FRxLogInfo` is 250 wide at 504, with "play
  again" at 760). **Text added where it does not fit is not merely invisible: it
  cuts off what was already there.**

  The same one is not repeated. Announcing it again on every character would
  fill the status area with references and bury every other message. }
procedure TMainForm.AnnounceReference;
var
  Latest: string;
begin
  { 受信文が空になったら、覚えているものも捨てます。**捨てないと、消してから
    もう一度同じ局を受けたときに、何も言わなくなります。**
    An emptied transcript drops what is remembered: **without that, the same
    station received again after a clear would be announced no more.** }
  if Length(FExchange.References) = 0 then
  begin
    if Length(FLiveChars) = 0 then
      FReferenceShown := '';
    Exit;
  end;
  Latest := ReferenceCaption(
    FExchange.References[High(FExchange.References)]);
  if Latest = FReferenceShown then
    Exit;
  FReferenceShown := Latest;
  SetStatus('', '', Format(RsReferenceRead, [Latest]));
end;

{ 文字がまだ 1 つも無いあいだ、受信テキストの欄に何と出すかを決めます
  （要件 FR-B.1）。

  この機械は音をある長さまとめてから読みます。だから**受信を始めてから最初の
  文字が出るまでには数秒かかり**、そのあいだ欄は白いままです。要件 FR-B.1 は
  「エンジンの入力長制限を利用者に露出しない」と言っています。**秒数を説明する
  のではなく、待てばよいと分かる状態にする**、という意味に採りました。

  白い欄は「動いている」とも「壊れている」とも読めます。**どちらなのかを、
  待っているあいだも言葉で言います。**

  3 つの状態を分けます。受信しているか、ファイルを解析しているか、まだ何も
  始めていないか。**どれなのかを知っているのはこちらだけ**なので、部品には
  言葉だけを渡します。

  Decides what the transcript area says while there is not one character yet
  (requirement FR-B.1).

  This machine reads sound a stretch at a time, so **seconds pass between
  starting and the first character**, and the area stays blank meanwhile.
  Requirement FR-B.1 says not to expose the engine's input-length limit to the
  operator; that is read here as **making the wait legible rather than
  explaining the seconds.**

  A blank area reads as "working" and as "broken" alike. **Which one it is gets
  said in words while the wait lasts.**

  Three states are told apart: receiving, analysing a file, or not started.
  **Only this form knows which**, so the control is handed the words alone. }
procedure TMainForm.UpdateTranscriptMessage;
begin
  if FRxTranscript = nil then
    Exit;
  if FCapture <> nil then
    FRxTranscript.Message_ := RsRxReceivingHint
  else if DecoderBusy then
    FRxTranscript.Message_ := RsRxAnalyzingHint
  else
    FRxTranscript.Message_ := RsRxEmpty;
end;

{ 高コントラスト表示を効かせます（要件 NFR-5.5）。

  薄くする計算は `ViewColors.BlendColor` 1 か所に集まっているので、**入切も
  そこへ渡すだけ**で、確からしさの濃淡・一覧の休止行・待っているあいだの言葉・
  折れ線の目盛りが一度に濃くなります。

  そのうえで、文字の並ぶ欄は**地と文字を白と黒に決め打ちます。**画面の主題色は
  環境によって灰色寄りのことがあり、**高コントラストと名乗るなら、環境任せに
  しません。**

  描き直しは呼ぶ側から明示します。色は計算のときに決まるので、**描き直さないと
  次に何かが起きるまで前の色のままです。**

  Puts high contrast into effect (requirement NFR-5.5).

  The fading arithmetic lives in one place, `ViewColors.BlendColor`, so **handing
  the switch to it** is enough to darken the confidence shading, the paused rows
  of the list, the words shown while waiting and the trend's gridlines all at
  once.

  On top of that the text areas are **pinned to black on white**: a desktop's own
  window colours can be greyish, and **naming something high contrast means not
  leaving it to the desktop.**

  The repaints are asked for explicitly: colours are decided as they are drawn,
  so **without a repaint the old ones stay until something else happens.** }
procedure TMainForm.ApplyHighContrast;
var
  On_: Boolean;
begin
  if FSetHighContrast = nil then
    Exit;
  On_ := FSetHighContrast.Checked;
  SetHighContrast(On_);
  if FRxTranscript <> nil then
  begin
    if On_ then
    begin
      FRxTranscript.Color := clWhite;
      FRxTranscript.Font.Color := clBlack;
    end
    else
    begin
      FRxTranscript.Color := clWindow;
      FRxTranscript.Font.Color := clWindowText;
    end;
    FRxTranscript.Invalidate;
  end;
  if FRxBandMap <> nil then
  begin
    if On_ then
    begin
      FRxBandMap.Color := clWhite;
      FRxBandMap.Font.Color := clBlack;
    end
    else
    begin
      FRxBandMap.Color := clWindow;
      FRxBandMap.Font.Color := clWindowText;
    end;
    FRxBandMap.Invalidate;
  end;
  if FFtTrend <> nil then
    FFtTrend.Invalidate;
  if FFtHistogram <> nil then
    FFtHistogram.Invalidate;
end;

procedure TMainForm.HighContrastChanged(Sender: TObject);
begin
  ApplyHighContrast;
  MarkSettingsDirty;
end;

{ 国別前置符字表を読み込み、形の規則へ渡します（要件 FR-K.12）。

  **渡すのはここです。**読む側（`TPrefixTable`）は読むだけにしてあります。
  ファイルを読んだ副作用で形の規則が変わるのは分かりにくいためです。

  Loads the country prefix table and hands it to the form rule (requirement
  FR-K.12).

  **Handing it over happens here**: the reader only reads, since having the form
  rule change as a side effect of reading a file would be hard to follow. }
procedure TMainForm.LoadPrefixes(const FileName: string);
begin
  if FPrefixes = nil then
    FPrefixes := TPrefixTable.Create;
  FPrefixFile := FileName;
  FPrefixes.LoadFromFile(FileName);
  if FPrefixes.LastError <> '' then
    LogDiagnostic(RsCtxPrefixes, FPrefixes.LastError);
  SetAllocatedPrefixes(FPrefixes.Items);
  UpdatePrefixesInfo;
  { 形の規則が変われば、一覧に出る符号も変わります。作り直します。
    A change to the form rule changes which call signs the list shows, so it is
    rebuilt. }
  FBandMapAt := 0;
  RefreshBandMap;
  { 受信テキストの下線も同じ規則で引いています（要件 FR-E.1）。
    The transcript underlines run on the same rule (requirement FR-E.1). }
  ReadTranscript;
end;

procedure TMainForm.UpdatePrefixesInfo;
begin
  if FSetPrefixesInfo = nil then
    Exit;
  if (FPrefixes = nil) or (FPrefixFile = '') then
  begin
    FSetPrefixesInfo.Caption := RsPrefixesUnused;
    Exit;
  end;
  if FPrefixes.LastError <> '' then
  begin
    FSetPrefixesInfo.Caption := RsFileUnreadable;
    Exit;
  end;
  FSetPrefixesInfo.Caption := Format(RsCountAndName,
    [AllocatedPrefixCount, FPrefixes.Name]);
  if FPrefixes.Skipped > 0 then
    FSetPrefixesInfo.Caption := FSetPrefixesInfo.Caption +
      Format(RsPrefixesSkipped, [FPrefixes.Skipped]);
end;

procedure TMainForm.SetPrefixesClick(Sender: TObject);
var
  Dialog: TOpenDialog;
begin
  Dialog := TOpenDialog.Create(Self);
  try
    Dialog.Title := RsPrefixesOpenTitle;
    Dialog.Filter := RsTextFilter;
    if not Dialog.Execute then
      Exit;
    LoadPrefixes(Dialog.FileName);
  finally
    Dialog.Free;
  end;
end;

procedure TMainForm.SetPrefixesClearClick(Sender: TObject);
begin
  FPrefixFile := '';
  { 一度も選ばれていなければ器がありません。**先に作ってから空にします**
    ——空の器から `Items` を取ろうとして落ちる道を残さないためです。
    With nothing ever picked there is no table object. **It is made before being
    emptied**, so that no path is left that reads `Items` from nothing. }
  if FPrefixes = nil then
    FPrefixes := TPrefixTable.Create;
  FPrefixes.Clear;
  { **空になった表を渡し直して、規則を元へ戻します。**渡さないと、外したはずの
    表が効いたままになります。直前の `Clear` で空になっているので、渡すのは
    空の並びです。
    **The now-empty table is handed back so the rule returns to what it was**:
    without it, a table the operator dropped would go on tightening. The `Clear`
    just above emptied it, so what is handed over is an empty list. }
  SetAllocatedPrefixes(FPrefixes.Items);
  UpdatePrefixesInfo;
  FBandMapAt := 0;
  RefreshBandMap;
  ReadTranscript;
end;

{ 手元の一覧に在るかを引きます（要件 FR-K.9）。在れば**何で確かめたのか**を
  返し、無ければ空を返します。

  返すのはファイル名ではなく「手元の一覧」という言葉です。一覧の行は狭く、
  **そこへ file 名を出しても読み切れません。**どのファイルを読んでいるかは
  設定タブに出ます。

  Looks a call sign up in the roster (requirement FR-K.9), returning **what
  confirmed it** or an empty string.

  The words rather than the file name: a row of the list is narrow and **a file
  name would not be read there.** Which file is loaded is shown on the settings
  tab. }
function TMainForm.InRoster(const Callsign: string): string;
begin
  Result := '';
  { 一覧が無いときは、何も言いません。**「一覧に無い」と「一覧が無い」を同じ
    顔で出してはいけません**（要件 FR-K.4 と同じ考え方）。
    With no roster nothing is said: **"not in the roster" and "there is no
    roster" must not wear the same face** (the reasoning of requirement
    FR-K.4). }
  if (FRoster = nil) or (FRoster.Count = 0) then
    Exit;
  if FRoster.Contains(Callsign) then
    Result := RsInRoster;
end;

{ 一覧を読み込みます。**読めなくても受信は止めません**（要件 FR-K.10）。
  Loads the roster. **A file that cannot be read does not stop reception**
  (requirement FR-K.10). }
procedure TMainForm.LoadRoster(const FileName: string);
begin
  if FRoster = nil then
    FRoster := TCallsignRoster.Create;
  FRosterFile := FileName;
  FRoster.LoadFromFile(FileName);
  if FRoster.LastError <> '' then
    { 原文は診断へ、利用者には対処のある言葉を出します（要件 FR-A.4）。
      The original text goes to the diagnostics and the operator gets words with
      a next step in them (requirement FR-A.4). }
    LogDiagnostic(RsCtxRoster, FRoster.LastError);
  UpdateRosterInfo;
  { 読み込んだら一覧を作り直します。**作り直さないと、次に局が動くまで
    反映されません。**
    The list is rebuilt: **without that, nothing would change until the next
    time a station moves.** }
  FBandMapAt := 0;
  RefreshBandMap;
end;

procedure TMainForm.UpdateRosterInfo;
begin
  if FSetRosterInfo = nil then
    Exit;
  if (FRoster = nil) or (FRosterFile = '') then
  begin
    FSetRosterInfo.Caption := RsRosterUnused;
    Exit;
  end;
  if FRoster.LastError <> '' then
  begin
    FSetRosterInfo.Caption := RsFileUnreadable;
    Exit;
  end;
  { **読めなかった行の数も出します。**件数だけを出すと、半分しか読めていない
    ファイルが「読めた」ように見えます。
    **The lines that could not be read are said too**: a count alone would let a
    file half of which was skipped look as though it had been read. }
  FSetRosterInfo.Caption := Format(RsCountAndName, [FRoster.Count, FRoster.Name]);
  if FRoster.Skipped > 0 then
    FSetRosterInfo.Caption := FSetRosterInfo.Caption +
      Format(RsRosterSkipped, [FRoster.Skipped]);
  if FRoster.Truncated then
    FSetRosterInfo.Caption := FSetRosterInfo.Caption + RsRosterTruncated;
end;

procedure TMainForm.SetRosterClick(Sender: TObject);
var
  Dialog: TOpenDialog;
begin
  Dialog := TOpenDialog.Create(Self);
  try
    Dialog.Title := RsRosterOpenTitle;
    Dialog.Filter := RsTextFilter;
    if not Dialog.Execute then
      Exit;
    LoadRoster(Dialog.FileName);
  finally
    Dialog.Free;
  end;
end;

procedure TMainForm.SetRosterClearClick(Sender: TObject);
begin
  FRosterFile := '';
  if FRoster <> nil then
    FRoster.Clear;
  UpdateRosterInfo;
  FBandMapAt := 0;
  RefreshBandMap;
end;

{ 呼出符号と信号報告だけをクリップボードへ送ります（要件 FR-E.2）。

  RST が聞こえていなければ符号だけを送ります。**聞こえていないものを 599 と
  補って送ってはいけません。**記録に残るのは実際に受けた報告であり、機械が
  埋めた値ではありません。

  Puts just the call sign and the report on the clipboard (requirement FR-E.2).

  With no RST heard, only the call sign is sent. **A report that was not heard
  must never be filled in as 599:** what goes into the log is the report that
  was actually received, not one the machine invented. }
procedure TMainForm.RxCopyCallClick(Sender: TObject);
var
  Call, Sent: string;
begin
  Call := CallsignToLog;
  if Call = '' then
    Exit;
  Sent := Call;
  if FExchange.Rst.First >= 0 then
    Sent := Sent + ' ' + FExchange.Rst.Text;
  Clipboard.AsText := Sent;
  if FExchange.Rst.First >= 0 then
    SetStatus('', '', Format(RsCallCopied, [Sent]))
  else
    SetStatus('', '', Format(RsCallCopiedNoRst, [Sent]));
end;

{ ---- 交信の記録（要件 FR-E.3・FR-J.4） ---- }

function TMainForm.LogFileName: string;
begin
  { 設定ファイルと同じ場所に置きます。受信テキストの記録と並びます。
    Beside the settings file, alongside the transcript journal. }
  Result := IncludeTrailingPathDelimiter(
    ExtractFilePath(ConfigFileName)) + 'contacts.adi';
end;

{ 選ばれている運用バンドの ADIF 名。「指定なし」なら空を返します。
  The ADIF name of the band selected, or empty for "not set". }
{ 選択肢の番号の ADIF 名。選択肢の並びと同じ順です。
  The ADIF name of a choice's index, in the same order as the choices. }
function BandNameAt(Index: Integer): string;
const
  NAMES: array[0..12] of string = ('', '160M', '80M', '40M', '20M', '15M',
    '10M', '6M', '2M', '70CM', '30M', '17M', '12M');
begin
  if (Index < Low(NAMES)) or (Index > High(NAMES)) then
    Exit('');
  Result := NAMES[Index];
end;

function TMainForm.SelectedBand: string;
begin
  if FRxBand = nil then
    Exit('');
  Result := BandNameAt(FRxBand.ItemIndex);
end;

{ 交信済みか。**運用バンドを選んでいれば、そのバンドだけを見ます。**7 MHz で
  交信した局を 14 MHz で「交信済み」と示すと、有効な交信を見送らせます。

  モードでは分けません。記録に残るバンドは `SelectedBand` ですから、**残す
  バンドと、問うバンドが違えば、記録と画面が食い違います。**一覧で「まだ」と
  出た局を選んだ次の画面で「交信済み」と出るのは、そのずれです。

  「指定なし」のままなら、バンドを問わず「かつて交信したか」を答えます。バンドを
  選んでいない運用者にとっては、それが「知っている局か」だからです。

  Whether the station has been worked. **With an operating band chosen, only that
  band counts**: marking a station worked on 7 MHz as worked on 14 MHz would have
  the operator pass over a valid contact.

  The mode does not enter into it. The band a contact is recorded under is
  `SelectedBand`, so **asking about a different band than the one it will be
  recorded under would let the record and the screen disagree** -- which is
  exactly what "not yet" in the list followed by "worked" on the next screen
  would be.

  Left at "not set", the answer covers every band, because to an operator who has
  not chosen one that is what "do I know this station" means. }
function TMainForm.WorkedBefore(const Callsign: string): Boolean;
begin
  if FLog = nil then
    Exit(False);
  Result := FLog.WorkedCountOn(Callsign, OperatingBand) > 0;
end;

procedure TMainForm.RxContestChanged(Sender: TObject);
begin
  { バンドを変えれば交信済みの判定が変わります。一覧を作り直さないと、前の
    バンドの印が残ります。
    Changing the band changes what counts as worked; without rebuilding, the
    previous band's marks would stay on screen. }
  FBandMapAt := 0;
  RefreshBandMap;
  UpdateLogInfo;
  if Sender <> nil then
    MarkSettingsDirty;
end;

{ 直近 1 時間の交信数。コンテスト中に運用者が最も見る数字です。**得点ではなく、
  自分の記録から数えられるものだけを出します**（未解決 #9）。

  数え直しは**記録の全件を読む**ため、件数に比例して重くなります（1 万件で
  2.23 ms の実測）。一覧を作り直すたび、つまり毎秒これを行うと、**記録を積んだ
  運用者ほど重くなる**という、いちばん避けたい形になります。

  `Force` を渡さなければ数秒に 1 度しか数え直しません。1 時間あたりの局数が
  数秒古いことは、運用の判断を何も変えません。交信を記録した直後や取り込んだ
  直後は `Force` で即座に映します。**自分が今いれた 1 局が数に出ないのは、
  古い数字とは意味が違います。**

  Contacts in the last hour, the number a contest operator watches most.
  **Not a score: only what can be counted from the operator's own log**
  (unresolved #9).

  Counting **reads every record**, so it grows with the size of the log (2.23 ms
  at ten thousand, measured). Doing it on every rebuild of the list -- once a
  second -- would make the application heavier for exactly the operator who has
  logged the most, which is the last shape it should take.

  Without `Force` it recounts only every few seconds: an hourly rate that is a
  few seconds old changes no decision. After a contact is logged or a log is
  imported it is forced, because **a contact the operator has just entered not
  appearing in the count means something different from a slightly old
  number.** }
procedure TMainForm.UpdateRate(Force: Boolean);
const
  { 数え直す間隔。1 時間あたりの局数は、数秒では意味のある変わり方をしません。
    How often to recount: contacts per hour does not change meaningfully in a
    few seconds. }
  RATE_REFRESH_SECONDS = 5;
var
  Hour, Total: Integer;
begin
  if (FRxRate = nil) or (FLog = nil) then
    Exit;
  if (not Force) and (FRateAt > 0) and
     (SecondsBetween(Now, FRateAt) < RATE_REFRESH_SECONDS) then
    Exit;
  FRateAt := Now;
  Hour := FLog.CountSince(IncHour(LocalTimeToUniversal(Now), -1));
  Total := FLog.Count;
  FRxRate.Caption := Format(RsRate, [Hour, Total]);
end;

{ いま記録に残せる呼出符号を探します。

  **利用者が指し示した符号があれば、それを使います。**一覧の行を選んだとき、
  受信テキストの符号を押したときに決まります。機械の判断が気に入らないときに
  直せなければ、直せないものを見せているのと同じです。

  指し示されていなければ、待機モードは一覧の行から、交信モードは受信文から
  採ります。受信文から採る規則は DeepCW.Exchange が持つものと同じ、**DE の
  直後を優先する規則**です。一覧と記録が別の規則で選ぶと、画面に出た符号と
  記録した符号が食い違います。

  Finds the call sign that could be logged now.

  **A call sign the operator pointed at wins**, whether by choosing a row in the
  list or by pressing one in the received text. A judgement that cannot be
  corrected is no better than one that cannot be seen.

  With nothing pointed at, the waiting mode takes it from the chosen row and the
  contact mode from the transcript, by the same rule DeepCW.Exchange holds --
  **the one after DE.** Choosing by different rules in the list and in the log
  would let the call sign on screen disagree with the call sign written down. }
function TMainForm.CallsignToLog: string;
var
  I: Integer;
begin
  Result := '';
  if FChosenCallsign <> '' then
    Exit(FChosenCallsign);
  if BandMode then
  begin
    if FRxBandMap.SelectedId = 0 then
      Exit;
    for I := 0 to High(FBandEntries) do
      if (FBandEntries[I].Id = FRxBandMap.SelectedId) and
         (FBandEntries[I].Trust >= ctAgreed) then
        Exit(FBandEntries[I].Callsign);
    Exit;
  end;
  Result := FExchange.Callsign;
end;

procedure TMainForm.UpdateLogInfo;
var
  Call, Note: string;
begin
  if FRxWorked = nil then
    Exit;
  FillRstFields;
  Call := CallsignToLog;
  FRxWorked.Enabled := Call <> '';
  FRxCopyCall.Enabled := Call <> '';
  { 1 度しか聞こえていない符号は、そうと添えます。同じ顔で出すと、2 度一致した
    ものと見分けが付きません（要件 FR-J.7 と同じ考え）。手で指したものには
    付けません。利用者が見て決めたものだからです。
    A call sign heard only once says so. Presented with the same face, it would
    be indistinguishable from one confirmed twice (the reasoning of requirement
    FR-J.7). A call sign the operator pointed at carries no such note: they
    looked at it and decided. }
  Note := '';
  if (FChosenCallsign = '') and (FMode = rmContact) and
     (FExchange.Sightings = 1) then
    Note := RsLogOnceNote;
  if Call = '' then
    FRxLogInfo.Caption := RsLogNeedCall
  else if WorkedBefore(Call) then
    { 日付も同じバンドから採ります。回数だけをバンドごとに答えて日付を全体から
      採ると、そのバンドで交信していない日付を「交信済み」の証拠として示します。
      The date comes from the same band: answering the count band by band while
      taking the date from every band would offer, as the evidence of a duplicate,
      a date on which that band was not worked. }
    FRxLogInfo.Caption := Format(RsLogWorkedOn,
      [Call, Note, FLog.LastWorkedOn(Call, OperatingBand)])
  else
    FRxLogInfo.Caption := Call + Note;
  if FSetLogInfo <> nil then
    FSetLogInfo.Caption := Format(RsCountAndName, [FLog.Count,
      FitPath(FSetLogInfo, FLog.FileName,
        Format(RsCountAndName, [FLog.Count, '']))]);
end;

{ 交信を 1 件記録します（要件 FR-E.3）。時刻は協定世界時で持ちます。ADIF の
  QSO_DATE と TIME_ON はいずれも協定世界時と決まっており、地方時で書くと、
  読み込んだログソフトが別の時刻として扱います。

  Records one contact (requirement FR-E.3). The times are UTC: ADIF defines
  QSO_DATE and TIME_ON as UTC, and writing local time would have the logger that
  reads it treat them as a different moment. }
{ 打たれた JCC/JCG の読みを、その場で出します（要件 FR-E.7）。

  **記録できなかったことを、記録したあとに知らせるのでは遅い。**打っている
  あいだに「市」「郡」と出れば、桁を間違えたことはその場で分かります。

  Shows what the typed JCC/JCG reads as, as it is typed (requirement FR-E.7).

  **Telling someone after the fact that it could not be recorded comes too
  late.** With "city" or "gun" appearing as they type, a wrong digit count
  shows itself there and then. }
{ RST の欄を打ったとき（要件 FR-E.11）。**打った欄は、以後自動では書き換え
  ません**（記録すれば戻る）。形が違えばそう言います——記録を押してから
  「書けませんでした」では遅い。
  An RST box was typed in (FR-E.11). **A typed box is no longer filled
  automatically** (until the contact is recorded). A malformed value is said at
  once: "could not be written" after pressing record comes too late. }
procedure TMainForm.RxRstChanged(Sender: TObject);
begin
  if (FRxRstRcvd = nil) or (FRxRstSent = nil) or (FRxRstInfo = nil) then
    Exit;
  if not FRstFilling then
  begin
    if Sender = FRxRstRcvd then
      FRstRcvdTyped := True
    else if Sender = FRxRstSent then
      FRstSentTyped := True;
  end;
  if ((Trim(FRxRstRcvd.Text) <> '') and (RstDigits(FRxRstRcvd.Text) = '')) or
     ((Trim(FRxRstSent.Text) <> '') and (RstDigits(FRxRstSent.Text) = '')) then
    FRxRstInfo.Caption := RsRxRstBad
  else
    FRxRstInfo.Caption := RsRxRstNote;
end;

procedure TMainForm.TxRstChanged(Sender: TObject);
begin
  FillRstFields;
end;

{ 打たれていない RST の欄を埋めます。受けたものは読めた RST（読めなければ空。
  **599 で埋めない**——付録 S.4 と同じ考え）、送ったものは送信タブの RST。
  Fills the RST boxes not typed in: received from the RST read (empty if none;
  **never filled with 599**, as in appendix S.4), sent from the transmit tab's
  RST. }
procedure TMainForm.ReadRst;
begin
  { 記録した交信より後ろの RST だけ（付録 BW.1）。記録する前は受信テキスト
    全体から選んだもの（`FExchange`）と同じです。
    Only an RST after the last logged contact (appendix BW.1); before any
    contact is logged it is the one chosen from the whole text (`FExchange`). }
  if FRstFromChar <= 0 then
    FRstRead := FExchange.Rst
  else
    FRstRead := RstAfter(FLiveChars, FRstFromChar);
end;

procedure TMainForm.FillRstFields;
var
  Rcvd, Sent: string;
begin
  if (FRxRstRcvd = nil) or (FRxRstSent = nil) then
    Exit;
  Rcvd := '';
  if FRstRead.First >= 0 then
    Rcvd := RstDigits(FRstRead.Text);
  Sent := '';
  if FTxRst <> nil then
    Sent := RstDigits(FTxRst.Text);
  FRstFilling := True;
  try
    if (not FRstRcvdTyped) and (FRxRstRcvd.Text <> Rcvd) then
      FRxRstRcvd.Text := Rcvd;
    if (not FRstSentTyped) and (FRxRstSent.Text <> Sent) then
      FRxRstSent.Text := Sent;
  finally
    FRstFilling := False;
  end;
  RxRstChanged(nil);
end;

procedure TMainForm.RxSubdivisionChanged(Sender: TObject);
var
  Code: string;
  Kind: TJapanSubdivision;
begin
  if (FRxSubdivision = nil) or (FRxSubdivisionInfo = nil) then
    Exit;
  if Trim(FRxSubdivision.Text) = '' then
  begin
    FRxSubdivisionInfo.Caption := RsSubdivisionHint;
    Exit;
  end;
  Kind := ParseJapanSubdivision(FRxSubdivision.Text, Code);
  if Kind = jsUnknown then
    FRxSubdivisionInfo.Caption := RsSubdivisionBadShape
  else
    FRxSubdivisionInfo.Caption := JapanSubdivisionCaption(Kind) + ' ' + Code;
end;

procedure TMainForm.RxWorkedClick(Sender: TObject);
var
  Item: TAdifRecord;
  Call: string;
  Moment: TDateTime;
  Code: string;
  Entered: string;
  Typed: Boolean;
  RigHz: Double;
  RigModeName: string;
  RstSent, RstRcvd, BadRst: string;
begin
  RigHz := 0;
  Call := CallsignToLog;
  if Call = '' then
    Exit;
  { 地方時を協定世界時へ直してから渡します。ADIF はこの 2 つの欄を協定世界時と
    定めており、地方時のまま書くと、読み込んだログソフトが別の時刻として扱います。
    The local time is converted to UTC before it is handed over: ADIF defines
    these two fields as UTC, and left local the logger that reads them would
    treat them as a different moment. }
  Moment := LocalTimeToUniversal(Now);
  { 打たれたかどうかと、読み取れたかどうかを分けて控えます。**打っていない
    のに「書けませんでした」と言えば、打ち忘れたのかと思わせます。**
    Whether something was typed and whether it read are noted apart: **saying
    "could not be written" when nothing was typed would suggest it had been
    forgotten.** }
  { **欄を消す前に控えます。**案内文の中で欄を読み直すと、消したあとの空文字を
    読んで「JCC/JCG「」は形が違う」と出ます（実機の画面で出しました）。
    **Taken before the box is cleared**: read back inside the message, it would
    be the emptied box that was read, and the line would say the code `「」` was
    malformed -- as it did on the real screen. }
  Entered := Trim(FRxSubdivision.Text);
  Typed := Entered <> '';
  ParseJapanSubdivision(Entered, Code);
  { 無線機の周波数を使っているなら、その周波数も残します（要件 FR-T.7）。
    **バンドと周波数は同じ読み取りから**採ります（別々に採ると食い違いうる）。
    With the rig's frequency in use it is recorded too (FR-T.7). **Band and
    frequency come from the same reading** (taken apart they could disagree). }
  if not (FRigBandActive and RigReading(RigHz, RigModeName)) then
    RigHz := 0;
  { RST は交信モードの行にだけあります（要件 FR-E.11）。形の違うものは
    書かず、あとでそう言います（交信そのものは残す）。
    The reports exist only on the contact mode row (FR-E.11). A malformed one
    is not written, and that is said afterwards (the contact itself is kept). }
  RstSent := '';
  RstRcvd := '';
  BadRst := '';
  if FMode = rmContact then
  begin
    RstSent := RstDigits(FRxRstSent.Text);
    RstRcvd := RstDigits(FRxRstRcvd.Text);
    if (Trim(FRxRstRcvd.Text) <> '') and (RstRcvd = '') then
      BadRst := Trim(FRxRstRcvd.Text)
    else if (Trim(FRxRstSent.Text) <> '') and (RstSent = '') then
      BadRst := Trim(FRxRstSent.Text);
  end;
  Item := BuildContactAt(Call, Moment, 'CW', OperatingBand,
    FRxSubdivision.Text, RigHz, RstSent, RstRcvd);
  if not FLog.Add(Item) then
  begin
    LogDiagnostic(RsCtxContactLog, FLog.LastError);
    SetStatus('', '', StatusLine(FLog.LastError));
    Exit;
  end;
  { 記録したら、指し示していた符号は用済みです。持ち越すと、次の局を読み始めても
    記録の候補が前の相手のままになります。
    Once recorded, the pointed-at call sign has served its purpose; carried over,
    the candidate to log would stay the previous station even as the next one
    starts coming in. }
  FChosenCallsign := '';
  { 符丁は局ごとに違います。持ち越すと、次の局に前の局の市を付けて記録します。
    The code differs from station to station; carried over, the next contact
    would be filed under the previous station's city. }
  FRxSubdivision.Text := '';
  RxSubdivisionChanged(nil);
  { RST も局ごとです。打った印を外し、元の出どころから埋め直します。
    The reports are per station too: the typed marks are cleared and the boxes
    refilled from their sources. }
  FRstRcvdTyped := False;
  FRstSentTyped := False;
  { ここまでの RST は、今記録した交信のものです（付録 BW.1）。
    Every RST so far belongs to the contact just logged (appendix BW.1). }
  FRstFromChar := Length(FLiveChars);
  ReadRst;
  UpdateLogInfo;
  UpdateRate(True);
  FBandMapAt := 0;
  RefreshBandMap;
  RefreshInfo;
  { どのバンドで残したかも言います。**運用バンドを選ぶ操作はコンテストの行に
    しかないので、ほかのモードでは何で残したのかが画面から読めません。**
    The band it was recorded under is said too: **the control that chooses it is
    only on the contest row, so in the other modes the screen would not say what
    the contact was filed under.** }
  { 時刻の区切りは引用符で囲みます。囲まないと、その環境の時刻区切りに
    置き換わります（`DeepCW.Journal` に同じ注記）。
    The separator is quoted, or it is replaced by the environment's own (the
    same note as in `DeepCW.Journal`). }
  { 打たれていたのに書けなかったなら、そう言います。**黙って落とすと、運用者は
    記録に入っていると思い込みます。**交信そのものは残す——市郡区が書けない
    ことより、交信が残らないことのほうが損です（受信は fail-soft）。
    When something was typed but could not be written, it is said: **dropped in
    silence, the operator would believe it went in.** The contact itself is
    kept: losing the contact costs more than losing the subdivision. }
  if Typed and (Code = '') then
    SetStatus('', '', Format(RsLoggedBadSubdivision,
      [Call, Entered]))
  else if BadRst <> '' then
    SetStatus('', '', Format(RsLoggedBadRst, [Call, BadRst]))
  else if RigHz > 0 then
    SetStatus('', '', Format(RsLoggedWithBand,
      [Call, Format(RsRigBandText, [AdifFreqText(RigHz)]),
       FormatDateTime('yyyy-mm-dd hh":"nn', Moment)]))
  else if OperatingBand <> '' then
    SetStatus('', '', Format(RsLoggedWithBand,
      [Call, FRxBand.Text, FormatDateTime('yyyy-mm-dd hh":"nn', Moment)]))
  else
    SetStatus('', '', Format(RsLoggedNoBand,
      [Call, FormatDateTime('yyyy-mm-dd hh":"nn', Moment)]));
end;

procedure TMainForm.SetLogImportClick(Sender: TObject);
var
  Dialog: TOpenDialog;
  Added, Skipped: Integer;
begin
  Dialog := TOpenDialog.Create(Self);
  try
    Dialog.Title := RsImportTitle;
    Dialog.Filter := RsAdifFilter;
    if not Dialog.Execute then
      Exit;
    if not FLog.ImportAdif(Dialog.FileName, Added, Skipped) then
    begin
      LogDiagnostic(RsCtxContactLog, FLog.LastError);
      SetStatus('', '', StatusLine(FLog.LastError));
      Exit;
    end;
    UpdateLogInfo;
    UpdateRate(True);
    FBandMapAt := 0;
    RefreshBandMap;
    RefreshInfo;
    { 飛ばした件数も言います。**黙って減ると、取り込めたのかどうかが分かりません。**
      The number skipped is said too: **silence about it leaves the operator
      unable to tell whether the import worked.** }
    SetStatus('', '', Format(RsImported,
      [Added, Skipped]));
  finally
    Dialog.Free;
  end;
end;

procedure TMainForm.SetLogExportClick(Sender: TObject);
var
  Dialog: TSaveDialog;
begin
  Dialog := TSaveDialog.Create(Self);
  try
    Dialog.Title := RsExportTitle;
    Dialog.Filter := RsAdifExportFilter;
    Dialog.DefaultExt := 'adi';
    Dialog.FileName := 'contacts.adi';
    if not Dialog.Execute then
      Exit;
    if not FLog.ExportAdif(Dialog.FileName) then
    begin
      LogDiagnostic(RsCtxContactLog, FLog.LastError);
      SetStatus('', '', StatusLine(FLog.LastError));
      Exit;
    end;
    SetStatus('', '', Format(RsExported,
      [FLog.Count, Dialog.FileName]));
  finally
    Dialog.Free;
  end;
end;

{ ---- 受信のしかた（要件 FR-I.6・FR-J） ---- }

function TMainForm.BandMode: Boolean;
begin
  Result := FMode in [rmWatch, rmContest];
end;

function TMainForm.ActiveElapsedSeconds: Double;
begin
  if BandMode and (FMulti <> nil) then
    Result := FMulti.ElapsedSeconds
  else if FStream <> nil then
    Result := FStream.ElapsedSeconds
  else
    Result := 0;
end;

{ モードに合わせて画面を組み替えます。

  受信を**やり直します。**動かす機械が変わると時計の出どころも変わり、聴き直し
  （FR-E.10）が指す先が食い違うためです。運用上、モードを変えるのは局面が
  変わるときなので、そこで受信文が改まるのは自然です。バンドマップの記録は
  それぞれの機械が持っているので、切り替えで失われるのは画面の続きだけです。

  Rearranges the window for the mode.

  Reception **starts afresh.** A different machine means a different clock, and
  replay (requirement FR-E.10) would otherwise point somewhere else. Changing
  mode happens when the situation changes, so a fresh transcript there is
  natural; each machine keeps its own records, so what a switch costs is only the
  continuity on screen. }
procedure TMainForm.ApplyMode;
begin
  if BandMode then
  begin
    if (FMulti = nil) and (FDecoder <> nil) then
      FMulti := TMultiStationDecoder.Create(FDecoder);
    if FMulti <> nil then
      FMulti.Reset;
  end
  else
  begin
    if FStream <> nil then
      FStream.Reset;
  end;
  { 復号器と同じく、ノイズ低減の内側の状態も捨てます（要件 FR-N）。
    Like the decoders, noise reduction drops its inner state (FR-N). }
  FReducer.Reset;

  { どちらのモードでも、時計の出どころが変わったので保管庫と記録を改めます。
    Either way the clock has a new origin, so the store and the journal start
    again. }
  FReviewPlay.Stop;
  if FHistory <> nil then
    FHistory.Clear;
  if FJournal <> nil then
    FJournal.Flush;
  FJournalled := 0;
  FClockOrigin := 0;
  FLiveChars := nil;
  FRstFromChar := 0;
  FRecheckPending := False;
  ReadTranscript;
  FRxTranscript.Clear;
  FRxBandMap.Clear;
  { 一覧へ戻るなら、覚えていた符号は用済みです。持ち越すと、別の局を選ぶまで
    前の相手が記録の候補として残ります。
    Back to the list, the remembered call sign has served its purpose; carried
    over it would stand as the candidate to log until another is chosen. }
  if BandMode then
    FChosenCallsign := '';
  { 一覧の控えも捨てます。残しておくと、消えた一覧の中身で記録の相手が決まります。
    The cached list goes too: kept, it would decide who to log from a list that
    is no longer on screen. }
  FBandEntries := nil;

  { 一覧を離れれば見出しも用済みです。残すと、交信モードの波形に前のモードの
    局名が浮いたままになります。
    Leaving the list, its labels have served their purpose; kept, the previous
    mode's station names would float over the contact mode's waterfall. }
  FRxWaterfall.SetStations(nil);
  FRxTranscript.Visible := FMode = rmContact;
  FRxBandMap.Visible := BandMode;
  { 検索・記録・聴き直しの行は受信テキストと一緒に出し入れします。**この行の
    操作はすべて受信テキストに対するもので、一覧を出している間はどれも押せません。**
    押せない操作を並べたまま、一覧を 1 行に狭めるのは逆です。コンテストでは
    一覧が主役なので、その分をここから返します。
    The row of search, log and replay controls appears with the transcript.
    **Every control on it acts on the transcript, and none of them can be pressed
    while the list is shown.** Keeping a row of dead controls and squeezing the
    list down to a single row would be the wrong way round: in a contest the list
    is the tool, and this is where the room for it comes from. }
  FFindTools.Visible := FMode = rmContact;
  FWatchTools.Visible := BandMode;
  FContestTools.Visible := FMode = rmContest;
  { 受信をやり直せば局の番号も振り直されるので、知らせた覚えは捨てます。
    残すと、番号を使い回した別の局が黙ったままになります。
    Restarting reception renumbers the stations, so what was announced is
    forgotten: kept, a different station reusing a number would stay silent. }
  FAlerts.Reset;
  UpdateReplayInfo;
  UpdateFindInfo;
  UpdateWatchInfo;
  { 交信数はモードを移した時点で出します。**受信を始めるまで空欄のままでは、
    数えていないのか 0 局なのかが分かりません。**
    The contact count is shown the moment the mode is entered: **left blank
    until reception starts, it would not say whether nothing is counted or
    nothing has been worked.** }
  UpdateRate(True);
end;

procedure TMainForm.RxModeChanged(Sender: TObject);
begin
  case FRxMode.ItemIndex of
    1: FMode := rmWatch;
    2: FMode := rmContest;
  else
    FMode := rmContact;
  end;
  ApplyMode;
  MarkSettingsDirty;
  if FMode = rmContest then
    SetStatus('', '', RsModeContestSet)
  else if FMode = rmWatch then
    SetStatus('', '', RsModeWatchSet)
  else
    SetStatus('', '', RsModeContactSet);
end;

{ 一覧の行を選んだら、その局へ同調して交信モードへ移ります（要件 FR-J.3）。
  操作は 1 回です。
  Choosing a row tunes to that station and moves to the contact mode
  (requirement FR-J.3), in one gesture. }
procedure TMainForm.RxStationChosen(Sender: TObject; Id: Int64; Hz: Double);
var
  Picked, Evidence: string;
  I: Integer;
begin
  { 選んだ行の呼出符号を控えます。作り直さずに控えの一覧から引くのは、速いから
    だけではありません。**利用者が押した行に出ていた符号そのもの**を採るため
    です。作り直すと、押してから移るまでの間に届いた文字で別の符号に変わり得ます。
    The chosen row's call sign is taken from the list already built, and not
    only because that is faster: it is **the call sign that was on the row the
    operator pressed.** Rebuilding could yield a different one, from characters
    that arrived between the press and the move. }
  Picked := '';
  Evidence := '';
  for I := 0 to High(FBandEntries) do
    if (FBandEntries[I].Id = Id) and (FBandEntries[I].Trust >= ctAgreed) then
    begin
      Picked := FBandEntries[I].Callsign;
      { 何でその符号を信じているのかを添えます（要件 FR-K.11）。**交信した相手
        なら、実在は確かです。**根拠を言わずに確からしさだけ上げるのは、
        黙って断定するのと同じです。
        What the call sign is trusted on is said with it (requirement FR-K.11):
        **a station one has worked certainly exists.** Raising the trust without
        naming the reason would be asserting it silently. }
      if FBandEntries[I].TrustSource <> '' then
        Evidence := Format(RsEvidenceEntry,
          [FBandEntries[I].TrustSource]);
    end;
  FRxWaterfall.TuneHz := Hz;
  FRxMode.ItemIndex := 0;
  FMode := rmContact;
  ApplyMode;
  { 控えた符号を渡すのは最後です。同調も切り替えも、指し示した符号を消す側
    なので、先に渡すと消されます。
    The remembered call sign is handed over last: both the tuning and the mode
    switch clear a pointed-at call sign, so handing it over earlier would lose
    it. }
  FChosenCallsign := Picked;
  UpdateLogInfo;
  if FStream <> nil then
    FStream.TuneHz := FRxWaterfall.TuneHz;
  UpdateTuneInfo;
  SetStatus('', '', Format(RsTunedToStation,
    [FRxWaterfall.TuneHz, Picked, Evidence]));
end;

{ ---- 待っている呼出符号（要件 FR-I.4） ---- }

{ 一覧の行が待ち符号に当たるかを引きます。一覧の層に待ち符号そのものを持たせない
  のは、交信記録を持たせないのと同じ理由です。
  The lookup the list uses to tell whether a row is one being waited for. The list
  layer holds no watch list itself, for the same reason it holds no log. }
function TMainForm.WatchedCall(const Callsign: string): string;
begin
  Result := MatchedWatch(Callsign, FWatched);
end;

procedure TMainForm.RxWatchChanged(Sender: TObject);
begin
  FWatched := ParseWatchList(FRxWatch.Text);
  { 書き換えたら、知らせた覚えは捨てます。**別の符号を待ち始めたのに、前の待ちで
    知らせた局が黙ったままになるのを避けるためです。**
    Changing it forgets what was announced: otherwise a station announced under
    the previous watch would stay silent under the new one. }
  if FAlerts <> nil then
    FAlerts.Reset;
  UpdateWatchInfo;
  if Sender <> nil then
    MarkSettingsDirty;
end;

procedure TMainForm.UpdateWatchInfo;
var
  Given, Kept: Integer;
begin
  if FRxWatchInfo = nil then
    Exit;
  Given := CountWatchWords(FRxWatch.Text);
  Kept := Length(FWatched);
  if Given = 0 then
    FRxWatchInfo.Caption := RsWatchHint
  else if Kept < Given then
    { 形にならない符号を黙って捨てると、いつまでも知らせが来ない理由が分かりません。
      Dropping a malformed call sign silently leaves no way to tell why nothing is
      ever announced. }
    FRxWatchInfo.Caption := Format(RsWatchingSome,
      [Kept, Given - Kept])
  else
    FRxWatchInfo.Caption := Format(RsWatchingAll, [Kept]);
end;

{ 待っていた局が出ていれば知らせます。

  一覧を作り直した直後に呼びます。**知らせるのは局ごとに一度きり**で、消えて
  出直した局には改めて知らせます。局の番号がそのまま「同じ呼び出しか」を表すため、
  番号で覚えるだけで済みます。

  Announces the stations waited for, if any have appeared.

  Called just after the list is rebuilt. **Each station is announced once**, and
  again if it drops and returns: the station's number already carries whether it
  is the same call, so remembering numbers is all that is needed. }
procedure TMainForm.AnnounceWatched;
var
  I: Integer;
  Found: string;
begin
  if (FAlerts = nil) or (Length(FWatched) = 0) then
    Exit;
  Found := '';
  for I := 0 to High(FBandEntries) do
    if (FBandEntries[I].Watched <> '') and FAlerts.Announce(FBandEntries[I].Id) then
    begin
      if Found <> '' then
        Found := Found + RsWatchedSeparator;
      Found := Found + Format(RsWatchedAt,
        [FBandEntries[I].Callsign, FBandEntries[I].Hz]);
    end;
  if Found <> '' then
  begin
    SetStatus('', '', Format(RsWatchedOnAir, [Found]));
    SoundWatched;
  end;
end;

{ 待っていた局を音でも知らせます（未解決 #21、付録 BY）。

  **新しい音声の流れは開きません。**聴き直しの再生（`FReviewPlay`）が空いて
  いれば、それを借りて鳴らします。何かを再生中なら利用者は席にいるので鳴らさず、
  無線機で送っている間（送り終える見込みまで）も鳴らしません。鳴らせなければ
  （出力の装置が無いなど）診断に残すだけで、受信は妨げません（Receive は
  fail-soft）。

  Sounds a chime for a station waited for (open question #21, appendix BY).

  **No new audio stream is opened**: the replay player (`FReviewPlay`) is
  borrowed while idle. While anything plays the operator is present, so no
  chime; nor while the rig is sending (up to the expected end). If it cannot
  sound (no output device, say) it is only noted in the diagnostics and
  reception carries on (receive is fail-soft). }
procedure TMainForm.SoundWatched;
var
  NowMs: QWord;
  Status: TKeyerStatus;
  Sending: Boolean;
begin
  NowMs := GetTickCount64;
  { 送っているかは、鍵のスレッドの今の様子から求めます（受信の抑制と同じ
    見込み。「送っている間は復号しない」を切っていても効きます）。
    Whether the rig is sending comes from the keyer's state right now (the
    same expectation as the receive gate, in force even with "do not decode
    while sending" switched off). }
  Sending := False;
  if (FKeyer <> nil) and (FTxGate <> nil) then
  begin
    Status := FKeyer.Snapshot;
    FTxGate.Update(Status.State = ksSending, Status.KeyedUntil, NowMs);
    Sending := FTxGate.Muted(NowMs);
  end;
  if not ShouldSoundWatch(FRxWatchSound.Checked,
    FPlayback.Running or FReviewPlay.Running, Sending, NowMs,
    FWatchSoundAt) then
    Exit;
  FWatchSoundAt := NowMs;
  if Length(FWatchChime) = 0 then
    FWatchChime := WatchChime(FTxSampleRate);
  FReviewPlay.Play(FWatchChime, FTxSampleRate);
  if FReviewPlay.LastError <> '' then
    LogDiagnostic(RsCtxWatchSound, FReviewPlay.LastError);
end;

procedure TMainForm.RxWatchSoundChanged(Sender: TObject);
begin
  { 入れ直したら、すぐ次の知らせで鳴るようにします。
    Switching it on again lets the very next announcement sound. }
  FWatchSoundAt := 0;
  if Sender <> nil then
    MarkSettingsDirty;
end;

{ 一覧を作り直します。毎秒 1 回で足ります。局の並びが 0.2 秒ごとに変わる必要は
  なく、そのたびに全局の受信文を複製するのは無駄です。
  Rebuilds the list, once a second. The order of stations need not change five
  times a second, and copying every transcript that often would be waste. }
procedure TMainForm.RefreshBandMap;
begin
  if (FMulti = nil) or not BandMode then
    Exit;
  if MilliSecondsBetween(Now, FBandMapAt) < 1000 then
    Exit;
  FBandMapAt := Now;
  { 作った一覧は控えておきます。記録の側が同じものを作り直すと、10.6 ms の
    処理が毎秒 5 回になります（dsp_check の実測）。
    The list just built is kept: having the log side rebuild the same thing
    would run a 10.6 ms job five times a second (measured in dsp_check). }
  FBandEntries := BuildBandEntries(FMulti.Logs, FMulti.ElapsedSeconds,
    @WorkedBefore, @WatchedCall, @InRoster);
  { コンテストモードでは、交信済みの局を一覧から外せます。**世界のコンテスト
    ソフトが例外なく持つ機能で、混み合った帯域では、呼ぶ相手だけが残ることに
    値打ちがあります。**外した局も記録には残っており、印を外せば戻ります。
    In the contest mode the stations already worked can be dropped from the
    list. **Contest software everywhere has this**, and on a crowded band the
    value is in what remains: only the stations worth calling. What is dropped
    is still in the log and comes back when the box is cleared. }
  if (FMode = rmContest) and FRxHideWorked.Checked then
    FBandEntries := WithoutWorked(FBandEntries);
  FRxBandMap.SetEntries(FBandEntries, FMulti.ElapsedSeconds);
  ShowStationLabels;
  AnnounceWatched;
  UpdateRate;
end;

{ 交信済みの行を除いた一覧。
  The list without the rows already worked. }
function TMainForm.WithoutWorked(const Entries: TBandEntries): TBandEntries;
var
  I, Count: Integer;
begin
  SetLength(Result, Length(Entries));
  Count := 0;
  for I := 0 to High(Entries) do
    if not Entries[I].Worked then
    begin
      Result[Count] := Entries[I];
      Inc(Count);
    end;
  SetLength(Result, Count);
end;

{ 一覧と同じ内容を、ウォーターフォールの音程の上へも渡します（要件 FR-J.5）。

  **名前は一覧と同じ規則（`EntryCaption`）で決めます。**同じ局を一覧と波形で違う
  名前で出したら、どちらを信じるべきか分かりません。ここは渡すだけで、何も
  決めません。

  The same contents go to the waterfall, above each pitch (requirement FR-J.5).

  **The names come from the list's own rule (`EntryCaption`)**: the same station
  named differently in the two places would leave no telling which to believe.
  Nothing is decided here; it is only handed over. }
procedure TMainForm.ShowStationLabels;
var
  Labels: TStationLabels;
  I, Count: Integer;
begin
  SetLength(Labels, Length(FBandEntries));
  Count := 0;
  for I := 0 to High(FBandEntries) do
  begin
    Labels[Count].Text := EntryCaption(FBandEntries[I]);
    if Labels[Count].Text = '' then
      { 名前の付いていない局は見出しを持ちません。**「何か居る」とだけ書いても、
        ウォーターフォールがすでにそれを示しています。**
        A station with no name gets no label: **writing "something is here" adds
        nothing to what the waterfall already shows.** }
      Continue;
    Labels[Count].Hz := FBandEntries[I].Hz;
    Labels[Count].LevelDb := FBandEntries[I].LevelDb;
    Inc(Count);
  end;
  SetLength(Labels, Count);
  FRxWaterfall.SetStations(Labels);
end;

{ ---- 検索（要件 FR-B.5） / search (requirement FR-B.5) ---- }

procedure TMainForm.UpdateFindInfo;
begin
  if FRxFindInfo = nil then
    Exit;
  FRxFindPrev.Enabled := FRxTranscript.MatchCount > 0;
  FRxFindNext.Enabled := FRxTranscript.MatchCount > 0;
  if FRxTranscript.SearchTerm = '' then
    FRxFindInfo.Caption := ''
  else if FRxTranscript.MatchCount = 0 then
    { 「0 件」ではなく「見つかりません」と言います。数だけでは、探せていないのか
      無いのかが分かりません。
      "Not found" rather than "0": a bare count does not say whether the search
      ran or whether there is nothing there. }
    FRxFindInfo.Caption := RsFindNone
  else
    FRxFindInfo.Caption := Format(RsFindPosition,
      [FRxTranscript.CurrentMatch, FRxTranscript.MatchCount]);
end;

procedure TMainForm.RxFindChanged(Sender: TObject);
begin
  FRxTranscript.Search(Trim(FRxFind.Text));
  UpdateFindInfo;
end;

procedure TMainForm.RxFindNextClick(Sender: TObject);
begin
  FRxTranscript.NextMatch;
  UpdateFindInfo;
end;

procedure TMainForm.RxFindPrevClick(Sender: TObject);
begin
  FRxTranscript.PreviousMatch;
  UpdateFindInfo;
end;

procedure TMainForm.RxFindKeyDown(Sender: TObject; var Key: Word;
  Shift: TShiftState);
begin
  { Enter で次へ、Shift+Enter で前へ。検索欄に居たまま辿れるようにします。
    Enter goes forward and Shift+Enter back, so the operator can walk the hits
    without leaving the box. }
  if Key <> VK_RETURN then
    Exit;
  if ssShift in Shift then
    FRxTranscript.PreviousMatch
  else
    FRxTranscript.NextMatch;
  UpdateFindInfo;
  Key := 0;
end;

{ ---- 記録（要件 FR-B.6） / the journal (requirement FR-B.6) ---- }

function TMainForm.JournalDirectory: string;
begin
  { 設定ファイルと同じ場所に置きます。利用者が 1 か所だけ覚えれば済みます。
    Kept beside the settings file, so there is only one place to remember. }
  Result := IncludeTrailingPathDelimiter(
    ExtractFilePath(ConfigFileName)) + 'log';
end;

{ 録音の置き場所。設定ファイルと同じところの `audio` です。受信テキストの記録が
  `log` に入るのと並びます。
  Where recordings are kept: `audio` beside the settings file, alongside the
  `log` the transcript journal writes into. }
function TMainForm.RecordingDirectory: string;
begin
  Result := IncludeTrailingPathDelimiter(
    ExtractFilePath(ConfigFileName)) + 'audio';
end;

{ 録音を始めます。**受信が動いていなければ何もしません。**録るものが無いのに
  ファイルだけができると、0 秒の録音がディスクに溜まります。
  Starts recording. **Nothing happens unless reception is running**: a file made
  with nothing to put in it would leave recordings of zero seconds on the disk. }
procedure TMainForm.StartRecording;
var
  Path: string;
begin
  if (FRecorder <> nil) or (FCapture = nil) or (FRing = nil) then
    Exit;
  Path := RecordingFileFor(RecordingDirectory, Now);
  FRecorder := TAudioRecorder.Create(FRing, FCaptureRate);
  if not FRecorder.Start(Path) then
  begin
    LogDiagnostic(RsCtxRecording, FRecorder.LastError);
    SetStatus('', '', StatusLine(FRecorder.LastError));
    FreeAndNil(FRecorder);
    { 始められなかったのに印だけ入ったままにはしません。**入っているのに録れて
      いない**のがいちばん困ります。
      The box is not left ticked when the recording could not start: **ticked and
      not recording** is the worst of the outcomes. }
    FSetRecord.OnChange := nil;
    FSetRecord.Checked := False;
    FSetRecord.OnChange := @RxRecordChanged;
    Exit;
  end;
  SetStatus('', '', Format(RsRecordingStarted, [Path]));
end;

{ 録音を終えます。**何秒録れたか、どこに残ったかを必ず言います。**
  Stops recording, **always saying how long it kept and where it went.** }
procedure TMainForm.StopRecording(const Why: string);
var
  Status: TRecorderStatus;
  Path, Lost: string;
begin
  if FRecorder = nil then
    Exit;
  Path := FRecorder.FileName;
  { 先に止めます。止めるときに残りを書き切るので、**止める前に数えた長さは、
    実際に残った長さより短く出ます。**
    Stopped first: stopping writes out the remainder, so **a length counted
    before that would be shorter than what the file actually holds.** }
  FRecorder.Stop;
  Status := FRecorder.Snapshot;
  FreeAndNil(FRecorder);
  SetRecordStatus('');
  { 1 標本も録れていない録音は残しません。**受信が始められなかったときに、
    0 秒のファイルだけがディスクに積もります。**消したことは言います。
    A recording with not one sample in it is not kept: **a reception that failed
    to start would otherwise leave nothing but files of zero seconds piling up.**
    That it was removed is said. }
  if Status.Seconds <= 0 then
  begin
    DeleteFile(Path);
    SetStatus('', '', Format(RsRecordingNotKept, [Why]));
    Exit;
  end;
  Lost := '';
  if Status.Lost > 0 then
    { 取りこぼしは黙って飲み込みません（教訓 10.1）。**穴の空いた録音を、
      無傷の録音と同じ顔で渡さないためです。**
      Dropped audio is not swallowed in silence (lesson 10.1): **a recording with
      a hole in it must not be handed over wearing the face of a whole one.** }
    Lost := Format(RsRecordingLost, [Status.Lost / FCaptureRate]);
  SetStatus('', '', Format(RsRecordingEnded,
    [Why, Path, SecondsAsClock(Status.Seconds), Lost]));
end;

{ 録音の状態を状態表示へ映し、自ら止まっていれば後始末をします。
  Reflects the recording into the status bar and clears up if it stopped by
  itself. }
procedure TMainForm.UpdateRecording;
var
  Status: TRecorderStatus;
begin
  if FRecorder = nil then
    Exit;
  Status := FRecorder.Snapshot;
  if Status.Stopped <> '' then
  begin
    { 上限に達した、あるいは書けなくなった。**印も外します。**入ったままだと、
      次に受信を始めたときに黙って録り始めます。
      A limit was reached or writing failed. **The box is cleared too**: left
      ticked, the next reception would quietly start recording again. }
    FSetRecord.OnChange := nil;
    FSetRecord.Checked := False;
    FSetRecord.OnChange := @RxRecordChanged;
    MarkSettingsDirty;
    StopRecording(Status.Stopped);
    Exit;
  end;
  SetRecordStatus(Format(RsRecordingStatus,
    [SecondsAsClock(Status.Seconds), Status.Bytes / (1000 * 1000)]));
end;

{ 録音の説明を出します。**どこに、どこまで残るのかを、印の隣で言います。**
  設定を入れたあとで「どこへ行ったのか」を探させないためです。
  Explains the recording beside its own box: **where it goes and how far it
  goes**, so that switching it on is not followed by hunting for the file. }
procedure TMainForm.UpdateRecordInfo;
begin
  if FSetRecordInfo = nil then
    Exit;
  FSetRecordInfo.Caption := Format(RsRecordInfo,
    [FitPath(FSetRecordInfo, RecordingDirectory,
       Format(RsRecordInfo, ['', RECORD_MAX_SECONDS / 3600])),
     RECORD_MAX_SECONDS / 3600]);
end;

{ 置き場所を、ラベルに残った幅へ収まるように途中を省きます（要件 NFR-5.1）。

  **置き場所の長さは利用者の手元で決まります。**Windows の
  `C:\Users\<名前>\AppData\Roaming\...` や長い利用者名では、枠の外へはみ出して
  読めなくなります。この容器の `/root/.config` は短いので、**試験の家を一時の
  場所へ移すまで、はみ出しに気づきませんでした**（付録 BN）。

  省いた部分は `...` になり、**元の置き場所はヒントに出します。**ファイル名は
  残します——どれを指しているかは、名前で分かるからです。

  `Around` は、置き場所を空にして組み立てた文言です。残りの幅はそれを引いて
  求めます。

  Shortens a location in the middle so that it fits in what is left of the
  label's width (requirement NFR-5.1).

  **How long the location is depends on the operator's machine.** On Windows,
  `C:\Users\<name>\AppData\Roaming\...` or a long user name runs it past the
  edge of the box, where it cannot be read. This container's `/root/.config`
  is short, so **the overflow went unnoticed until the tests were given a
  scratch home** (appendix BN).

  What is left out becomes `...`, and **the whole location goes into the
  hint.** The file name is kept: it is what says which file is meant.

  `Around` is the text built with the location left empty; the room left is
  found by taking it away. }
function TMainForm.FitPath(Lbl: TLabel; const Path, Around: string): string;
var
  Room: Integer;
begin
  Result := Path;
  Lbl.Hint := Path;
  Lbl.ShowHint := Path <> '';
  if Lbl.Parent = nil then
    Exit;
  if FMeasure = nil then
    FMeasure := TBitmap.Create;
  FMeasure.Canvas.Font := Lbl.Font;
  Room := Lbl.Parent.ClientWidth - Lbl.Left - Scale96ToForm(8)
    - FMeasure.Canvas.TextWidth(Around);
  Result := MinimizeName(Path, FMeasure.Canvas, Room);
end;

procedure TMainForm.OperatingResized(Sender: TObject);
begin
  UpdateRecordInfo;
  UpdateLogInfo;
end;

procedure TMainForm.RxRecordChanged(Sender: TObject);
begin
  MarkSettingsDirty;
  UpdateRecordInfo;
  if FSetRecord.Checked then
    StartRecording
  else
    StopRecording('');
end;

procedure TMainForm.RxJournalChanged(Sender: TObject);
begin
  if FJournal = nil then
    Exit;
  { 記録を始めるのは「ここから」です。それまでに確定していた分は、利用者が
    記録しないと決めていた間のものなので、遡って書きません（要件 FR-B.6）。
    Journalling starts here: what was confirmed beforehand belongs to the time
    the operator had chosen not to record, so it is not written retrospectively
    (requirement FR-B.6). }
  if FSetJournal.Checked and (FStream <> nil) then
    FJournalled := Length(FStream.ConfirmedChars);
  FJournal.Enabled := FSetJournal.Checked;
  MarkSettingsDirty;
  if FSetJournal.Checked then
    SetStatus('', '', Format(RsJournalOn, [JournalDirectory]))
  else
    SetStatus('', '', RsJournalOff);
  RefreshInfo;
end;

{ 確定した分だけを記録へ渡します。

  暫定の文字は渡しません。暫定は後から書き換わるため、書いてしまうと記録に
  取り消せない誤りが残ります。確定はもう変わらないので、そこだけを書きます。

  Hands the newly confirmed characters to the journal.

  Provisional characters are not handed over: they can still change, and writing
  them would leave errors in the record that cannot be taken back. Confirmed
  text no longer changes, so only that is written. }
procedure TMainForm.JournalConfirmed;
var
  Confirmed: TDecodedChars;
  Fresh: TDecodedChars;
  I, Count: Integer;
begin
  if (FJournal = nil) or (FStream = nil) or not FSetJournal.Checked then
    Exit;
  Confirmed := FStream.ConfirmedChars;
  Count := Length(Confirmed) - FJournalled;
  if Count <= 0 then
  begin
    { 確定が減るのは、受信をやり直したときだけです。印も戻します。戻さないと、
      次の受信の頭が「もう書いた」と見なされて記録から落ちます。
      Confirmed text only shrinks when reception restarts; the mark goes back
      with it. Leaving it high would treat the start of the next reception as
      already written and drop it from the record. }
    FJournalled := Length(Confirmed);
    Exit;
  end;
  SetLength(Fresh, Count);
  for I := 0 to Count - 1 do
    Fresh[I] := Confirmed[FJournalled + I];
  FJournalled := Length(Confirmed);
  FJournal.Add(Fresh);
  if FJournal.LastError <> '' then
    LogDiagnostic(RsCtxJournal, FJournal.LastError);
end;

{ ---- 聴き直し（要件 FR-E.10） / replay (requirement FR-E.10) ---- }

{ 保持時間の選択肢を秒に写します。選択肢と秒の対応はここ 1 か所だけに置きます。
  Maps the retention choice onto seconds, in this one place only. }
function TMainForm.SelectedRetention: Double;
begin
  case FSetRetention.ItemIndex of
    0: Result := 5 * 60;
    2: Result := 20 * 60;
    3: Result := 30 * 60;
  else
    Result := REVIEW_DEFAULT_SECONDS;
  end;
end;

procedure TMainForm.RxRetentionChanged(Sender: TObject);
begin
  if FHistory = nil then
    Exit;
  { 長さを変えると、それまで保管していた音は失われます。黙って消すのではなく、
    そう言います（第 10 章 10.9）。
    Changing the length loses what was held; it is said rather than done
    silently (chapter 10, rule 10.9). }
  FHistory.SetRetention(SelectedRetention);
  FRxTranscript.SelectedIndex := -1;
  UpdateReplayInfo;
  SetStatus('', '', Format(RsRetentionSet,
    [Round(SelectedRetention / 60)]));
  MarkSettingsDirty;
end;

procedure TMainForm.UpdateReplayInfo;
var
  Held: Double;
begin
  if (FHistory = nil) or (FRxReplay = nil) then
    Exit;
  FRxReplay.Enabled := (FRxTranscript.SelectedIndex >= 0) and
    (FHistory.RetainedSeconds > 0);
  FRxReplayStop.Enabled := FReviewPlay.Running;
  if FRxTranscript.SelectedIndex >= 0 then
    Exit;
  Held := FHistory.RetainedSeconds;
  if Held <= 0 then
    FRxReplayInfo.Caption := RsRxReplayHint
  else
    FRxReplayInfo.Caption := Format(RsReplayHintHeld,
      [Trunc(Held) div 60, Trunc(Held) mod 60]);
end;

{ 押された文字を含む「語」の音を鳴らします。

  1 文字だけでは短すぎて（短点は 0.06 秒ほど）耳では判じられません。前後の空白
  までを取り、語としてまとめて鳴らします。読み取りが怪しいときに運用者が確かめ
  たいのは、たいてい 1 文字ではなくコールサインや符丁ひとまとまりだからです。

  Plays the sound of the whole word containing the character pressed.

  One character alone is too short to judge by ear: a dit lasts about 0.06
  seconds. The stretch is extended to the surrounding spaces and played as a
  word, because what an operator wants to check is usually a call sign or a
  whole abbreviation rather than a single letter. }
{ 押された文字を含む「語」の範囲と、その音の時刻を返します。

  聴き直し（要件 FR-E.10）と読み直し（要件 FR-C.3）は、**同じ「語」を指して
  いなければなりません。**別々に数えれば、聴いた音と読み直した音が食い違います
  （教訓 10.11）。

  Returns the span of the word containing the pressed character.

  Replay (requirement FR-E.10) and re-reading (requirement FR-C.3) must **point
  at the same word**: counted separately, the audio heard and the audio re-read
  could differ (lesson 10.11). }
function TMainForm.WordSpan(Index: Integer; out First, Last: Integer;
  out FromSeconds, ToSeconds: Double): Boolean;
var
  Item: TDecodedChar;
  Back: Integer;
  Earlier: Double;
begin
  Result := False;
  First := Index;
  Last := Index;
  FromSeconds := 0;
  ToSeconds := 0;
  if (Index < 0) or (Index > High(FLiveChars)) then
    Exit;
  if not FRxTranscript.CharItem(Index, Item) then
    Exit;

  while (First > 0) and FRxTranscript.CharItem(First - 1, Item) and
        (Item.Text <> ' ') do
    Dec(First);
  while FRxTranscript.CharItem(Last + 1, Item) and (Item.Text <> ' ') do
    Inc(Last);

  { その語より前にある最後の文字を探します。空白そのものは音を持たないので
    飛ばします。**この文字の尻尾へ食い込まないことが、切り出しの要です。**
    The last character before the word; the space itself has no sound of its own
    and is stepped over. **Not cutting into that character's tail is what the
    span turns on.** }
  Earlier := -1;
  Back := First - 1;
  while Back >= 0 do
  begin
    if not FRxTranscript.CharItem(Back, Item) then
      Break;
    if Item.Text <> ' ' then
    begin
      Earlier := Item.EndSeconds;
      Break;
    end;
    Dec(Back);
  end;

  if not FRxTranscript.CharItem(First, Item) then
    Exit;
  FromSeconds := Item.Seconds;
  if not FRxTranscript.CharItem(Last, Item) then
    Exit;
  WordAudioSpan(FromSeconds, Item.EndSeconds, Earlier,
    FromSeconds, ToSeconds);
  Result := True;
end;

procedure TMainForm.ReplayFrom(Index: Integer);
var
  First, Last: Integer;
  FromSeconds, ToSeconds, GotFrom, GotTo: Double;
  Audio: TSingleArray;
  Rate: Integer;
begin
  if (FHistory = nil) or (FReviewPlay = nil) then
    Exit;
  if not WordSpan(Index, First, Last, FromSeconds, ToSeconds) then
    Exit;

  Audio := FHistory.Extract(FromSeconds, ToSeconds, GotFrom, GotTo, Rate);
  if Length(Audio) = 0 then
  begin
    { 保管の外へ出た音は戻りません。別の音を鳴らして誤魔化さず、そう言います。
      Audio that has fallen outside the retention is gone; rather than playing
      something else, it is said plainly. }
    FRxReplayInfo.Caption := RsReplayGone;
    { なぜ残っていないのかで案内を分けます。「設定を延ばせば遡れる」と言って
      よいのは、保持時間の外へ出た場合だけです。
      The guidance depends on why it is gone: telling the operator that a longer
      retention would reach it is only true when it fell off the far end. }
    if FromSeconds < FHistory.EarliestSeconds then
      SetStatus('', '', Format(RsReplayOutOfRange,
        [Round(SelectedRetention / 60)]))
    else
      SetStatus('', '', RsReplayNotHeld);
    Exit;
  end;

  { 送信の再生が鳴っていれば止めます。2 つの音が重なると、どちらを聴いているのか
    分からなくなります。
    Stop any transmit playback first: two sounds at once leave the operator
    unable to tell which is which. }
  if FPlayback.Running then
  begin
    FPlayback.Stop;
    FTxPlaying := False;
  end;
  FReviewPlay.Stop;
  FReviewPlay.Play(Audio, Rate);
  if FReviewPlay.LastError <> '' then
  begin
    LogDiagnostic(RsCtxReplay, FReviewPlay.LastError);
    SetStatus('', '', StatusLine(FReviewPlay.LastError));
    Exit;
  end;
  FRxReplayStop.Enabled := True;
  FRxReplayInfo.Caption := Format(RsReplayPlaying,
    [Trim(DecodedText(Copy(FLiveChars, First, Last - First + 1))),
     Trunc(GotFrom) div 60, Trunc(GotFrom) mod 60, GotTo - GotFrom]);
end;

{ ---- 語の読み直し（要件 FR-C.3） ---- }

{ 押された語を、その区間の音だけで読み直すよう頼みます。

  **流し込み受信は、前後の窓と継ぎ目の都合の中でその語を読んでいます。**同じ音を
  1 語だけ切り出して読ませると、別の答えが出ることがあります。どちらが正しいかを
  機械は知りませんが、**2 つ並べば、運用者は自分で判断できます。**

  読み直した結果で受信テキストを書き換えることはしません（要件 FR-B.2）。
  確定した文字が後から変わるなら、確定という言葉に意味がありません。

  Asks for the pressed word to be read again from its own span of audio.

  **Streaming reception read that word amid its neighbouring windows and their
  seams.** Cutting the same audio down to the one word and reading it alone can
  give a different answer. Which is right is not something the machine knows --
  but **with the two side by side the operator can judge.**

  The transcript is never rewritten from the result (requirement FR-B.2): if a
  confirmed character could change afterwards, "confirmed" would mean nothing. }
procedure TMainForm.RequestRecheck(Index: Integer);
var
  First, Last: Integer;
  FromSeconds, ToSeconds: Double;
begin
  if (FHistory = nil) or (FDecoder = nil) or (FMode <> rmContact) then
    Exit;
  if not WordSpan(Index, First, Last, FromSeconds, ToSeconds) then
    Exit;
  FRecheckIndex := Index;
  FRecheckWord := Trim(DecodedText(Copy(FLiveChars, First, Last - First + 1)));
  if FRecheckWord = '' then
    Exit;
  FRecheckPending := True;
  FRecheckAt := Now;
  TryStartRecheck;
end;

{ 頼まれた読み直しを、解析が空いていれば始めます。

  **塞がっていれば、そのまま待ちます。**受信中の解析は 0.2 秒ごとに動くので、
  待ちはその程度です（要件 NFR-1.3 の 1 秒に収まります）。割り込ませると、
  受信そのものが遅れます。

  Starts the requested re-reading if the analysis is free.

  **If it is busy the request simply waits.** During reception the analysis runs
  every 0.2 seconds, so the wait is about that long, well inside the second
  requirement NFR-1.3 allows. Pushing in front of it would delay reception
  itself. }
procedure TMainForm.TryStartRecheck;
var
  First, Last: Integer;
  FromSeconds, ToSeconds, GotFrom, GotTo: Double;
  Audio, Prepared: TSingleArray;
  Rate: Integer;
begin
  if not FRecheckPending then
    Exit;
  if DecoderBusy or (FDecoder = nil) or (FHistory = nil) then
    Exit;
  if not WordSpan(FRecheckIndex, First, Last, FromSeconds, ToSeconds) then
  begin
    FRecheckPending := False;
    Exit;
  end;
  Audio := FHistory.Extract(FromSeconds, ToSeconds, GotFrom, GotTo, Rate);
  FRecheckPending := False;
  if Length(Audio) = 0 then
    { 音が残っていない理由は、聴き直しの側が既に言っています。二重には言いません。
      Why the audio is gone has already been said by the replay; it is not said
      twice. }
    Exit;
  { 同調と帯域制限は、受信と同じものを掛けます。**別の音を読ませて「読み直し」と
    呼ぶことはできません。**
    The same tuning and band limit are applied as reception uses: **reading a
    different sound and calling it a re-reading would not be one.** }
  Prepared := PrepareForDecoder(ForDecoderAudio(Audio, Rate), Rate);
  FRecheckSent := FRecheckWord;
  FRecheckSentAt := FRecheckAt;
  FRxBusy.Caption := RsRecheckBusy;
  FDecodeThread := TDecodeThread.CreateRecheck(FDecoder, Prepared,
    FDecoder.Metadata.SampleRate, @DecodeFinished);
end;

{ 読み直した結果を、画面の語と並べて出します。

  **同じだったことにも値打ちがあります。**「怪しい」と思って押した語が、切り離して
  読んでも同じなら、それは確かめられたということです。

  Shows what the re-reading gave, beside what is on screen.

  **Agreement is worth saying too:** a word pressed because it looked doubtful,
  read the same way on its own, has been checked. }
procedure TMainForm.ShowRecheck(const Chars: TDecodedChars);
var
  Again: string;
  Elapsed: Int64;
begin
  FRxBusy.Caption := '';
  Again := Trim(DecodedText(Chars));
  Elapsed := MilliSecondsBetween(Now, FRecheckSentAt);
  { 目標（要件 NFR-1.3）を超えたときだけ、診断に残します。**間に合っている間は
    黙っています。**毎回書けば、本当に遅れた 1 件が埋もれます。
    Only a response past the target (requirement NFR-1.3) is recorded in the
    diagnostics: **while it keeps up, nothing is said.** Writing every time would
    bury the one that was late. }
  { **読み直した語そのものは残しません。**診断情報は不具合報告に添えるもので、
    そこに受信した文字が入れば、報告するたびに交信の中身を配ることになります
    （要件 FR-G.5・NFR-6）。遅かったのがどの語かは、長さで足ります。
    **The word itself is not kept.** The diagnostics are made to be attached to a
    bug report, and received characters in them would hand out the content of a
    contact with every report (requirements FR-G.5, NFR-6). Which word was slow
    is answered well enough by how long it was. }
  if Elapsed > 1000 then
    LogDiagnostic(RsCtxRecheck,
      Format(RsRecheckSlow, [Elapsed, Length(FRecheckSent)]));
  { 出す場所は状態表示の案内欄です。**聴き直しの欄は、既定の窓の幅では右端の
    外にあって見えません。**見えない場所に答えを書くのは、答えないのと同じです。
    It goes in the status bar's guidance panel: **the replay label sits beyond
    the right edge at the default window width and cannot be read.** An answer
    written where it cannot be seen is not an answer. }
  if Again = '' then
    SetStatus('', '', Format(RsRecheckNothing, [FRecheckSent]))
  else if Again = FRecheckSent then
    SetStatus('', '', Format(RsRecheckSame, [FRecheckSent]))
  else
    SetStatus('', '', Format(RsRecheckDiffer, [Again, FRecheckSent]));
end;

{ 押された文字が呼出符号の上なら、その符号を相手として採ります（要件 FR-E.1）。

  機械は DE の直後を相手と見ますが、外すことがあります。**外したときに指し直せる
  ことが、強調して見せることの意味です。**符号の上でなければ、これまでどおり
  聴き直しの起点になるだけです。

  A press landing on a call sign adopts it as the station being worked
  (requirement FR-E.1).

  The machine takes the one after DE, and it can be wrong. **Being able to point
  at the right one is what underlining them is for.** A press elsewhere still
  just sets where a replay starts. }
procedure TMainForm.RxCharChosen(Sender: TObject; Index: Integer);
var
  Which: Integer;
begin
  Which := FRxTranscript.CallsignAt(Index);
  if Which >= 0 then
  begin
    FChosenCallsign := FRxTranscript.CallsignSpan(Which).Text;
    FRxTranscript.SetCallsigns(FExchange.Callsigns, Which);
    UpdateLogInfo;
  end;
  ReplayFrom(Index);
  UpdateReplayInfo;
  { 聴かせるのと同時に、同じ語を読み直します（要件 FR-C.3）。**耳と機械の
    答え合わせが、押す 1 回で揃います。**
    The same word is re-read as it is played (requirement FR-C.3), so that
    **one press brings both the ear's answer and the machine's.** }
  RequestRecheck(Index);
end;

procedure TMainForm.RxReplayClick(Sender: TObject);
begin
  if FRxTranscript.SelectedIndex >= 0 then
    ReplayFrom(FRxTranscript.SelectedIndex);
end;

procedure TMainForm.RxReplayStopClick(Sender: TObject);
begin
  FReviewPlay.Stop;
  FRxReplayStop.Enabled := False;
end;

{ 「確定の速さ」を、実際の確定条件へ写します。末尾を長く残すほど確定は遅れますが、
  後から見直される危険は小さくなります（要件 FR-B.3）。

  Maps the confirm-speed choice onto the real commit conditions: a longer tail
  guard delays confirmation but makes it safer (requirement FR-B.3). }
procedure TMainForm.ApplyStreamSettings;
begin
  if FStream = nil then
    Exit;
  case FRxConfirmSpeed.ItemIndex of
    0: begin FStream.TailGuardSeconds := 0.8; FStream.MinConfirmedSeconds := 1.5; end;
    2: begin FStream.TailGuardSeconds := 2.0; FStream.MinConfirmedSeconds := 2.5; end;
  else
    begin FStream.TailGuardSeconds := 1.25; FStream.MinConfirmedSeconds := 2.0; end;
  end;
  FStream.AntiAlias := FRxAntiAlias.Checked;
  FStream.Bandwidth := SelectedBandwidth;
  FStream.TuneHz := FRxWaterfall.TuneHz;
  UpdateTuneInfo;
end;

function TMainForm.SelectedBandwidth: TTunerBandwidth;
begin
  if (FSetBandwidth = nil) or (FSetBandwidth.ItemIndex < 0) then
    Exit(tbAuto);
  Result := TTunerBandwidth(FSetBandwidth.ItemIndex);
end;

{ いま何に同調しているかを一目で示します（要件 FR-D.5）。
  Shows at a glance what is currently being tuned (requirement FR-D.5). }
procedure TMainForm.UpdateTuneInfo;
var
  Half: Double;
  Mode: string;
begin
  if FRxWaterfall = nil then
    Exit;
  if FRxWaterfall.TuneHz > 0 then
  begin
    Half := BandwidthHalfWidth(SelectedBandwidth);
    { 自動なら、実際に掛けている幅を出します（付録 CC）。受信中は流し込みの
      復号器が、ファイルなら最後に決めた幅が持っています（同じ同調のときだけ。
      同調を変えれば、もう当てはまりません）。
      For automatic, the width actually applied is shown (appendix CC): the
      streaming decoder holds it while receiving, the last worked out for a
      file otherwise (only for the same tuning; retuned, it no longer
      applies). }
    if SelectedBandwidth = tbAuto then
    begin
      if (FStream <> nil) and (FCapture <> nil) then
        Half := FStream.AppliedHalfWidthHz
      else if (FFileAutoHalf > 0) and
              (FFileAutoTune = FRxWaterfall.TuneHz) then
        Half := FFileAutoHalf;
    end;
    FShownHalf := Half;
    { 自動か手動かを添えます。自動は ±250 Hz で標準と同じ幅のため、数だけでは
      どちらで動いているのか区別が付きません（要件 FR-D.3・FR-D.8）。
      Says whether the width is automatic or chosen. Automatic is +/-250 Hz,
      the same as "normal", so the number alone does not tell them apart
      (requirements FR-D.3 and FR-D.8). }
    if (SelectedBandwidth = tbAuto) and
       (Half < BandwidthHalfWidth(tbAuto)) then
      Mode := RsTuneAutoNeighbour
    else if SelectedBandwidth = tbAuto then
      Mode := RsTuneAuto
    else
      Mode := RsTuneManual;
    if Half > 0 then
      FRxTuneInfo.Caption := Format(RsTunedBand,
        [FRxWaterfall.TuneHz, Half, Mode])
    else
      FRxTuneInfo.Caption := Format(RsTunedNoLimit,
        [FRxWaterfall.TuneHz]);
    FRxWaterfall.HalfWidthHz := Half;
  end
  else
  begin
    FRxTuneInfo.Caption := RsTunedNone;
    FRxWaterfall.HalfWidthHz := 0;
  end;
  FRxTuneClear.Enabled := FRxWaterfall.TuneHz > 0;
end;

{ デコーダが聴いている音を鳴らします（要件 FR-A.6）。

  **生の受信音ではありません。**同調・帯域制限・標本化周波数の変換まで、
  復号に渡すのとまったく同じ整形（`PrepareForDecoder`）を通した音です。
  経路が同じでなければ「機械が聴いている音」とは言えないので、**別の整形を
  書かず、復号と同じ 1 か所を通します**（教訓 10.11）。

  直近の数秒だけを鳴らします。長く鳴らしても、確かめたいのは「いま届いて
  いる音」だからです。

  Plays what the decoder is listening to (requirement FR-A.6).

  **Not the raw input**: the audio after the tuning, the band limiting and the
  rate conversion -- exactly the preparation the decode receives
  (`PrepareForDecoder`). It could not be called what the machine hears unless it
  came through the same path, so **no second preparation is written here**
  (lesson 10.11).

  Only the last few seconds sound: what is being checked is what is arriving
  now. }
procedure TMainForm.RxMonitorClick(Sender: TObject);
const
  MONITOR_SECONDS = 5.0;
var
  Audio, Prepared: TSingleArray;
  GotFrom, GotTo, Latest: Double;
  Rate: Integer;
begin
  if (FHistory = nil) or (FReviewPlay = nil) then
    Exit;
  if not EnsureDecoder then
    Exit;
  Latest := FHistory.LatestSeconds;
  Audio := FHistory.Extract(Max(0, Latest - MONITOR_SECONDS), Latest,
    GotFrom, GotTo, Rate);
  if Length(Audio) = 0 then
  begin
    SetStatus('', '', RsMonitorNoAudio);
    Exit;
  end;
  { 「モデルが聴いている音」なので、ノイズ低減も同じに通します（要件 FR-N）。
    This is "what the model hears", so it goes through noise reduction too. }
  Prepared := PrepareForDecoder(ForDecoderAudio(Audio, Rate), Rate);
  if Length(Prepared) = 0 then
  begin
    SetStatus('', '', RsMonitorNoPrepared);
    Exit;
  end;
  if FPlayback.Running then
  begin
    FPlayback.Stop;
    FTxPlaying := False;
  end;
  FReviewPlay.Stop;
  FReviewPlay.Play(Prepared, FDecoder.Metadata.SampleRate);
  if FReviewPlay.LastError <> '' then
  begin
    LogDiagnostic(RsCtxMonitorAudio, FReviewPlay.LastError);
    SetStatus('', '', StatusLine(FReviewPlay.LastError));
    Exit;
  end;
  FRxReplayStop.Enabled := True;
  { 何を鳴らしているのかを言います。**「もう一度聴く」と同じ音だと思われると、
    聴き比べの意味が無くなります。**
    What is sounding is said: **mistaken for the same audio as "listen again",
    the comparison would lose its point.** }
  if FRxWaterfall.TuneHz > 0 then
    SetStatus('', '', Format(RsMonitorPlayingTuned,
      [GotTo - GotFrom, FRxWaterfall.TuneHz, TUNER_TARGET_TONE_HZ,
       BandwidthHalfWidth(SelectedBandwidth)]))
  else
    SetStatus('', '', Format(RsMonitorPlayingUntuned,
      [GotTo - GotFrom]));
end;

procedure TMainForm.RxTuneClearClick(Sender: TObject);
begin
  FRxWaterfall.TuneHz := 0;
end;

procedure TMainForm.RxTrackChanged(Sender: TObject);
begin
  FRxWaterfall.Tracking := FRxTrack.Checked;
  if Sender <> nil then
    MarkSettingsDirty;
end;

{ ウォーターフォールで同調先が変わったときに呼ばれます。範囲の外を選ばれた
  ときは、断るのではなく、寄せた結果と受信機側でできることを伝えます
  （要件 FR-D.4）。

  Called when the waterfall's tuning changes. A pitch outside the tunable
  range is not refused: the operator is told where it landed and what they can
  do at the receiver instead (requirement FR-D.4). }
procedure TMainForm.RxTuneChanged(Sender: TObject);
var
  Tuned, Requested: Double;
begin
  Tuned := FRxWaterfall.TuneHz;
  Requested := FRxWaterfall.RequestedHz;
  if FStream <> nil then
    FStream.TuneHz := Tuned;
  UpdateTuneInfo;
  MarkSettingsDirty;

  { 追跡が動かしたときは、何も言いません。1 秒ごとに「同調しました」と言われては
    読むどころではなく、同調線と数字が動くことで十分に伝わります
    （要件 FR-D.7）。

    Nothing is said when tracking moved it. Being told "tuned" once a second
    would drown out the text being read, and the line and the number moving
    say it well enough (requirement FR-D.7). }
  if FRxWaterfall.AutoTuned then
    Exit;

  { 自分で同調をやり直したなら、別の信号へ移ったということです。指し示していた
    符号はもう相手ではありません。**持ち越すと、画面には別の局の文字が流れて
    いるのに、記録の釦は前の局を出し続けます。**
    A deliberate retune means a move to a different signal, so a call sign that
    was pointed at is no longer the station being worked. **Carried over, the
    log button would keep offering the previous station while another one's text
    runs down the screen.** }
  if FChosenCallsign <> '' then
  begin
    FChosenCallsign := '';
    UpdateLogInfo;
  end;

  { 求めた音程と実際の同調先が離れていれば、寄せたことになります。左端側を
    選ばれると求めた値は 0 に近づくため、0 を除外してはいけません。

    A gap between what was asked for and where the tuning landed means it was
    moved. A click towards the left edge asks for something close to 0, so 0
    must not be excluded here. }
  if (Tuned > 0) and (Abs(Requested - Tuned) > TUNER_STEP_HZ) then
    SetStatus('', '', Format(RsTunedSnap,
      [Tuned, FRxWaterfall.LowestHz, FRxWaterfall.HighestHz]))
  else if Tuned > 0 then
    SetStatus('', '', Format(RsTunedSignal, [Tuned]))
  else
    SetStatus('', '', RsTuneCleared);
end;

{ 入力装置の一覧を作り直します。Preferred と同じ名前の装置があればそれを、
  無ければ既定を選びます。番号ではなく名前で覚えるのは、装置を抜き差しすると
  番号がずれるためです（要件 FR-A.3、FR-A.5）。

  Rebuilds the list of input devices, selecting the one named Preferred if it
  is still there and the default otherwise. Names rather than indices are
  remembered because indices shift as hardware comes and goes
  (requirements FR-A.3, FR-A.5). }
procedure TMainForm.RefreshDeviceList(const Preferred: string);
var
  I, Choice: Integer;
  Caption_: string;
begin
  { 設定で指定された場所があればそれを使わせます。既定の探索で別のものを
    掴んでしまうと、一覧と実際に開く装置が食い違います。

    Let any path from the settings win, or the default search could pick a
    different library and the list would not match what actually opens. }
  LoadPortAudio(FSetPortAudio.Text);
  FDevices := InputDevices;
  FRxDevice.Items.BeginUpdate;
  try
    FRxDevice.Items.Clear;
    { 先頭は常に「おまかせ」です。何も選ばずに受信を始められることが立ち上がりの
      体験の要なので、既定を選ぶという選択肢を消してはいけません（要件 FR-A.2）。

      The first entry is always "let the system choose". Being able to start
      without picking anything is the point of the opening experience, so the
      option of the default must never disappear (requirement FR-A.2). }
    FRxDevice.Items.Add(RsDeviceDefault);
    Choice := 0;
    for I := 0 to High(FDevices) do
    begin
      Caption_ := FDevices[I].Name;
      if FDevices[I].HostApi <> '' then
        Caption_ := Caption_ + '  [' + FDevices[I].HostApi + ']';
      if FDevices[I].IsDefault then
        Caption_ := Caption_ + RsInfoDefaultMark;
      FRxDevice.Items.Add(Caption_);
      if (Preferred <> '') and (FDevices[I].Name = Preferred) then
        Choice := I + 1;
    end;
  finally
    FRxDevice.Items.EndUpdate;
  end;
  FRxDevice.ItemIndex := Choice;
  FRxDevice.Enabled := Length(FDevices) > 0;
  if Length(FDevices) = 0 then
    FRxDevice.Items[0] := RsDeviceNoList;
end;

function TMainForm.SelectedDeviceIndex: Integer;
begin
  if (FRxDevice = nil) or (FRxDevice.ItemIndex <= 0) then
    Exit(AUDIO_DEFAULT_DEVICE);
  if FRxDevice.ItemIndex - 1 > High(FDevices) then
    Exit(AUDIO_DEFAULT_DEVICE);
  Result := FDevices[FRxDevice.ItemIndex - 1].Index;
end;

function TMainForm.SelectedDeviceName: string;
begin
  Result := '';
  if (FRxDevice = nil) or (FRxDevice.ItemIndex <= 0) then
    Exit;
  if FRxDevice.ItemIndex - 1 > High(FDevices) then
    Exit;
  Result := FDevices[FRxDevice.ItemIndex - 1].Name;
end;

procedure TMainForm.RxDeviceRefreshClick(Sender: TObject);
var
  Wanted: string;
begin
  Wanted := SelectedDeviceName;
  RefreshDeviceList(Wanted);
  if Length(FDevices) = 0 then
    SetStatus('', '', RsDeviceNoneFound)
  else
    SetStatus('', '', Format(RsDeviceFound, [Length(FDevices)]));
end;

{ ウォーターフォール上で帯域の境界を引き終えたときの受け口（要件 FR-D.8）。

  **幅を持つ場所は設定 1 か所のままにします。**部品が自分で幅を持つと、
  設定タブの選択と画面の帯が別々の値を指し、どちらが効いているのか分からなく
  なります。ここでは引かれた幅を設定へ写し、通常の経路で復号へ伝えます。

  自動から手で引いたときは、幅の数値が変わらないことがあります（自動は
  ±250 Hz で、標準と同じ幅です）。**数が動かないと、引けたのかどうかが画面から
  分かりません。**そのため状態表示には選んだ名前を出します。

  Receives the release of a band edge dragged on the waterfall
  (requirement FR-D.8).

  **The width is still held in one place, the settings.** Were the control to
  hold a width of its own, the settings tab and the band on screen could point
  at different values with no telling which one is in force. The dragged width
  is copied into the setting and reaches the decoder by the usual path.

  Dragging away from automatic may leave the number unchanged, automatic being
  +/-250 Hz, the same width as "normal". **A number that does not move leaves
  no way to tell the drag took**, so the status line names the choice. }
procedure TMainForm.RxBandwidthDragged(Sender: TObject);
var
  Chosen: TTunerBandwidth;
begin
  if FSetBandwidth = nil then
    Exit;
  Chosen := NearestBandwidth(FRxWaterfall.RequestedHalfWidthHz);
  FSetBandwidth.ItemIndex := Ord(Chosen);
  { ItemIndex を書いても OnChange は呼ばれません。同じ後始末を明示的に
    通します。
    Writing ItemIndex raises no OnChange, so the same follow-up is run here. }
  RxConfirmSpeedChanged(Sender);
  SetStatus('', '', Format(RsBandwidthSet, [BandwidthCaption(Chosen)]));
end;

function TMainForm.ReportFileDecode(const FileName: string; TuneHz: Double;
  out LongestMs: Int64; out Decoded: string): TStringList;
var
  Started, Mark: QWord;
  Clicked, Spent: Int64;
begin
  Result := TStringList.Create;
  FRxFile.Text := FileName;
  if TuneHz > 0 then
  begin
    FRxWaterfall.TuneHz := TuneHz;
    UpdateTuneInfo;
  end;
  Started := GetTickCount64;
  RxDecodeFileClick(nil);
  Clicked := GetTickCount64 - Started;
  LongestMs := Clicked;
  { 待つ間は時間に入れません。数えるのは、届いた知らせを画面が処理する間だけ
    です。/ The waiting is not counted, only the time the UI spends handling
    what arrived. }
  while DecoderBusy do
  begin
    Sleep(5);
    Mark := GetTickCount64;
    CheckSynchronize(0);
    Application.ProcessMessages;
    Spent := GetTickCount64 - Mark;
    if Spent > LongestMs then
      LongestMs := Spent;
  end;
  CheckSynchronize(0);
  Application.ProcessMessages;
  Decoded := Trim(DecodedText(FLiveChars));
  { 待機モードは受信文ではなく一覧を出します。/ The waiting mode lists
    stations instead of a transcript. }
  if BandMode and (FRxBandMap.Count > 0) then
    Decoded := Format('%d stations in the band map', [FRxBandMap.Count]);
  Result.Add(Format('decode button: %d ms, longest UI stall: %d ms, total: %d ms',
    [Clicked, LongestMs, GetTickCount64 - Started]));
  Result.Add('width: ' + FRxTuneInfo.Caption);
  Result.Add('text: ' + Decoded);
end;

{ すべてのタブを順に前へ出して、組み方の破綻を数えます（要件 NFR-5.1）。
  Counts the layout breakages on every tab in turn (requirement NFR-5.1). }
function TMainForm.ReportLayout: TStringList;
var
  Was, I: Integer;
  Problems: TLayoutProblems;
  J: Integer;
begin
  Result := TStringList.Create;
  Was := FPages.ActivePageIndex;
  { 焦点を先頭へ戻してから数えます。**押したところから始まる輪は、押した場所に
    よって形が変わって見えます。**
    The focus is put back to the start first: **a loop begun wherever the mouse
    last landed looks different depending on where that was.** }
  try
    for I := 0 to FPages.PageCount - 1 do
    begin
      FPages.ActivePageIndex := I;
      Application.ProcessMessages;
      Problems := FindLayoutProblems(FPages.Pages[I]);
      for J := 0 to High(Problems) do
        Result.Add(Format('[%s] %s',
          [FPages.Pages[I].Caption, DescribeProblem(Problems[J])]));
      { タブ順序は窓全体で 1 本の輪になっているので、窓から辿ります。
        前へ出ているタブの部品だけが輪に入ります（要件 NFR-5.6）。
        The Tab chain is one loop over the whole window, so it is followed from
        the window; only the controls of the tab in front take part in it
        (requirement NFR-5.6). }
      Problems := FindTabOrderProblems(Self);
      for J := 0 to High(Problems) do
        Result.Add(Format('[%s] %s',
          [FPages.Pages[I].Caption, DescribeProblem(Problems[J])]));
    end;
    { 受信テキストの高さ（付録 BV.4）。**重なりを見る検査は、欄が押し潰されても
      気付かない**——受信タブへ行を 1 つ足したら、受信テキストが数画素に潰れた
      のに 0 件と言いました。いちばん狭い場合（「デコード中」の行が出ている・
      窓がいちばん低い）でも、決めた高さがあることを確かめます。
      The received text's height (appendix BV.4). **A check for overlaps never
      notices a squashed box**: one more row on the receive tab crushed the
      received text to a few pixels while the check said 0. Even in the
      tightest case (the "decoding" row showing, the window at its lowest) the
      set height must be there. }
    CheckTranscriptHeight(Result);
  finally
    FPages.ActivePageIndex := Was;
  end;
end;

{ 受信テキストに高さを残します（付録 BV.4）。**狭くなったらウォーターフォールが
  譲り**（最小まで）、広くなれば既定の高さへ戻します。受信テキストは受信タブの
  いちばん大事な欄で、欄が 1 つ増えるたびに押し潰されていました。
  Keeps height for the received text (appendix BV.4). **When space runs short
  the waterfall gives way** (down to its least height), and returns to its
  default when there is room. The received text is the most important box on
  the receive tab, and every added row was crushing it. }
procedure TMainForm.RxTranscriptResized(Sender: TObject);
var
  Wanted: Integer;
begin
  if FAdjustingLayout or (FRxWaterfallPanel = nil) or (FRxTranscript = nil) then
    Exit;
  Wanted := EnsureRange(
    FRxWaterfallPanel.Height + FRxTranscript.Height - Scale96ToForm(RX_TRANSCRIPT_MIN_96),
    Scale96ToForm(RX_WATERFALL_MIN_96), Scale96ToForm(RX_WATERFALL_DEFAULT_96));
  if Wanted = FRxWaterfallPanel.Height then
    Exit;
  FAdjustingLayout := True;
  try
    FRxWaterfallPanel.Height := Wanted;
  finally
    FAdjustingLayout := False;
  end;
end;

procedure TMainForm.CheckTranscriptHeight(Problems: TStringList);
var
  WasHeight, Want: Integer;
  WasBusy: string;
  WasMode, Mode: TReceiveMode;

  { 交信モードは受信テキスト、待機・コンテストはバンドマップが主役です。
    The received text is the main box in contact mode, the band map in the
    waiting and contest modes. }
  procedure Measure(const Situation: string);
  var
    Box: TControl;
  begin
    Application.ProcessMessages;
    Want := Scale96ToForm(RX_TRANSCRIPT_MIN_96);
    if FMode = rmContact then
      Box := FRxTranscript
    else
      Box := FRxBandMap;
    if Box.Height < Want then
      Problems.Add(Format('[%0:s] 受信テキストが低すぎる（%1:s）: %2:d < %3:d 画素',
        [FRxSheet.Caption, Situation, Box.Height, Want]));
  end;

begin
  FPages.ActivePage := FRxSheet;
  WasHeight := Height;
  WasBusy := FRxBusy.Caption;
  WasMode := FMode;
  try
    FRxBusy.Caption := RsDecodingBusy;
    for Mode := Low(TReceiveMode) to High(TReceiveMode) do
    begin
      FMode := Mode;
      ApplyMode;
      Height := WasHeight;
      Measure(Format('モード %0:d・窓 %1:d', [Ord(Mode), Height]));
      Height := Constraints.MinHeight;
      Measure(Format('モード %0:d・窓 %1:d（最小）', [Ord(Mode), Height]));
    end;
  finally
    FMode := WasMode;
    ApplyMode;
    FRxBusy.Caption := WasBusy;
    Height := WasHeight;
    Application.ProcessMessages;
  end;
end;

procedure TMainForm.RxConfirmSpeedChanged(Sender: TObject);
begin
  ApplyStreamSettings;
  { 受信していないあいだ `ApplyStreamSettings` は何もせずに戻るため、同調の
    表示だけは別に更新します。**これが無いと、帯域幅を変えても上の行は前の幅を
    出し続けます**（実機の画面で見つけました）。受信中は二度手間になりますが、
    文字列を 1 本作るだけです。

    While nothing is being received `ApplyStreamSettings` returns without doing
    anything, so the tuning line is refreshed separately. **Without this the
    line keeps showing the previous width after the bandwidth is changed**, as
    the screen showed. During reception it runs twice, which costs one string. }
  UpdateTuneInfo;
  if Sender <> nil then
    MarkSettingsDirty;
end;

procedure TMainForm.RxDisplayChanged(Sender: TObject);
begin
  FRxTranscript.ShowDoubt := FRxShowDoubt.Checked;
  FRxTranscript.DoubtStrength := FRxDoubtStrength.Position / 100;
  FRxTranscript.Font.Size := FRxFontSize.Value;
  FRxWaterfall.ShowCharacters := FRxAlign.Checked;
  if Sender <> nil then
    MarkSettingsDirty;
end;

procedure TMainForm.ShowStreamText;
var
  All: TDecodedChars;
  ConfirmedCount: Integer;
begin
  if FStream = nil then
    Exit;
  All := FStream.AllChars(ConfirmedCount);
  FLiveChars := All;
  FRxTranscript.PendingFrom := ConfirmedCount;
  FRxTranscript.SetChars(All);
  ReadTranscript;
  { 表示を更新したところで、確定した分を記録へ回します。画面と記録が同じ
    ところから出ていれば、食い違いません（要件 FR-B.6）。
    With the display updated, the newly confirmed text goes to the journal. Both
    coming from the same place is what keeps them from disagreeing (requirement
    FR-B.6). }
  JournalConfirmed;
  UpdateFindInfo;
end;

procedure TMainForm.UpdateLiveReceive;
var
  Fresh, Decoded: TSingleArray;
  Failure: string;
  Kept: Integer;
  Peak: Single;
  StartAt: Double;
  Muted: Boolean;
begin
  if FCapture = nil then
    Exit;
  if BandMode and (FMulti = nil) then
    Exit;
  if (FMode = rmContact) and (FStream = nil) then
    Exit;

  if FCapture.LastError <> '' then
  begin
    { 文言を先に控えます。RxStopClick が FCapture を解放するため、そのあとで
      LastError を読むことはできません。

      Copy the message first: RxStopClick frees FCapture, so LastError cannot
      be read after it. }
    Failure := FCapture.LastError;
    LogDiagnostic(RsCtxCapture, Failure);
    { 止めてから案内を出します。RxStopClick は「受信を停止しました」を出すため、
      順序が逆だと、なぜ止まったのかという肝心の説明が上書きされて消えます。

      Stop first, then explain: RxStopClick posts "reception stopped", so the
      other order would overwrite the one message that says why it stopped. }
    { **利用者の意思は残します。**装置が外れて止まったのであって、止めろと
      言われたのではありません。`RxStopClick` を呼ぶとその意思まで下りるので、
      呼んだあとに立て直し、待ちを始めます（要件 NFR-4.4）。
      **What the operator wants survives**: the device stopped it, nobody asked
      for it. `RxStopClick` would clear that too, so it is set again afterwards
      and the waiting begins (requirement NFR-4.4). }
    { **試した回数は持ち越します。**`RxStopClick` は利用者が止めたときのために
      数を戻しますが、ここは装置の都合で止まった場合です。
      **The attempt count is carried over**: `RxStopClick` clears it for the
      operator's own stop, and this is the device's doing. }
    Kept := FRetryCount;
    RxStopClick(nil);
    FRetryCount := Kept;
    if SecondsBetween(Now, FSaidDeviceAt) >= 30 then
    begin
      FSaidDeviceAt := Now;
      SetStatus('', '', StatusLine(Failure));
    end;
    FWantCapture := True;
    FWaiting := True;
    FLastRetryAt := Now;
    Exit;
  end;

  { ここまで来たということは、取り込みが生きているということです。**待ちが
    終わるのはここ**であって、装置が開けた瞬間ではありません。開けても読めない
    ことがあるので、開けた時点で「戻りました」と言うと、言ったそばからまた
    止まります（要件 NFR-4.4）。
    Reaching this point means the capture is alive. **This is where the wait
    ends**, not the moment the device opened: opening can be followed by a
    failure to read, and announcing the return then would be followed at once by
    another stop (requirement NFR-4.4). }
  if FWaiting then
  begin
    FWaiting := False;
    FRetryCount := 0;
    FSaidDeviceAt := 0;
    SetStatus('', Format(RsReceivingHz, [FCaptureRate]),
      RsDeviceReturned);
  end;

  Peak := FRing.PeakLevel(FCaptureRate, 0.2);
  FRxLevel.Position := ClampInt(Round(100 * Peak), 0, 100);
  { 無音かどうかをはっきり言います。受信できていないとき、それが装置の問題なのか
    信号が無いだけなのかを、利用者が切り分けられるようにするためです
    （要件 FR-A.3）。

    Say plainly whether it is silent, so that when nothing is being copied the
    operator can tell a device problem from simply having no signal
    (requirement FR-A.3). }
  { しきい値は復号側のスケルチと同じものを使います。二つ持つと、画面が
    「無音です」と言いながら文字が出る、あるいはその逆が起きます。
    The threshold is the decoder's own squelch. Two of them would let the
    display say "silent" while characters appear, or the other way round. }
  if Peak >= STREAM_SQUELCH_LEVEL then
    FRxSignal.Caption := RsAudioPresent
  else
    FRxSignal.Caption := RsAudioSilent;
  { 自局が送っている間は、復号を止めていると言います。**文字が出ない理由が
    見えなければ、壊れたと思われます**（要件 FR-T.4）。
    While the station is sending, say that decoding is paused: **characters
    that stop with no visible reason look like a fault** (FR-T.4). }
  Muted := ReceiveMutedForTx;
  if Muted then
    FRxSignal.Caption := RsRxMutedForTx;

  { 録音された分をそのまま流し込みます。窓を切り出すのではなく、確定点から
    先を溜め続けるのが流し込み受信です（要件 FR-B.2）。
    Feed everything captured. Streaming keeps the audio since the last split
    point rather than cutting fixed windows. }
  if not FRing.ReadSince(FRingPosition, Fresh) then
    LogDiagnostic(RsCtxReceive, 'Audio was dropped: the decoder fell behind the ring buffer.');
  if Length(Fresh) > 0 then
  begin
    { 帯域制限はここでは掛けません。0.2 秒ごとの細切れに FIR を掛けると継ぎ目
      ごとに過渡が出るため、解析の直前に 1 本の音声へまとめて掛けます。
      No filtering here: applying an FIR to 0.2 second pieces leaves a
      transient at every seam, so the stream applies it to one whole buffer
      just before analysis. }
    { 保管庫には、復号器の時計を渡してから同じ音を渡します。時刻の出どころを
      復号器ひとつに絞ることで、2 つが食い違えなくなります（要件 FR-E.10）。
      順序が要ります。**足したあとの時刻を渡すと、音がその長さぶん先の時刻に
      置かれます。**
      The store is handed the decoder's clock and then the same audio. Taking
      the time from the decoder alone is what makes the two unable to disagree
      (requirement FR-E.10). The order matters: **the time read after the append
      would place the audio one buffer too late.** }
    StartAt := ActiveElapsedSeconds;
    { 経過秒 0 に対応する実時刻は、最初の音が届いた瞬間です。受信を押した瞬間
      ではありません。装置が開くまでの間があるためです（要件 FR-B.6）。
      Elapsed second zero is the moment the first audio arrives, not the moment
      the button was pressed: opening the device takes time (requirement
      FR-B.6). }
    if StartAt = 0 then
    begin
      FClockOrigin := Now;
      FJournal.StartSession(FClockOrigin);
    end;
    { 復号へはノイズ低減を通した音を、保管庫とウォーターフォールには生の音を
      渡します（要件 FR-N）。/ The decoder gets the audio through noise
      reduction; the store and the waterfall get the raw audio (FR-N). }
    { 送っている間は、復号へは同じ長さの無音を渡します（要件 FR-T.4）。
      **ノイズ低減の前**で差し替えるので、低減には途切れない流れが届きます。
      While sending, the decoder gets silence of the same length (FR-T.4).
      It is swapped in **before noise reduction**, which so sees an unbroken
      stream. }
    if Muted then
      Decoded := ForDecoderAudio(SilenceLike(Fresh), FCaptureRate)
    else
      Decoded := ForDecoderAudio(Fresh, FCaptureRate);
    if FMode = rmWatch then
      FMulti.Append(Decoded, FCaptureRate)
    else
      FStream.Append(Decoded, FCaptureRate);
    FHistory.Append(Fresh, FCaptureRate, StartAt);
    { ウォーターフォールには、同調も帯域制限も掛ける前の音を見せます。まだ
      選んでいない信号も見えていなければ、選びようがないためです。
      The waterfall is fed the audio before any tuning or filtering: a signal
      that has not been chosen yet still has to be visible to be chosen. }
    { 保管庫へ渡すのと同じ時刻を渡します。**別々に数えさせると、重ねた文字が
      別の行を指します**（要件 FR-D.6）。
      The same time the store is given. **Counted separately, the characters
      laid over the display would point at the wrong row**
      (requirement FR-D.6). }
    FRxWaterfall.PushSamples(Fresh, FCaptureRate, StartAt);
  end;

  if DecoderBusy then
    Exit;
  if FMode = rmWatch then
  begin
    RefreshBandMap;
    if not FMulti.Ready then
      Exit;
    FRxBusy.Caption := RsDecodingBusy;
    FDecodeThread := TDecodeThread.CreateMulti(FMulti, @DecodeFinished);
    Exit;
  end;

  if not FStream.Ready then
    Exit;
  FAppendMode := True;
  FRxBusy.Caption := RsDecodingBusy;
  FDecodeThread := TDecodeThread.CreateStreaming(FStream, @DecodeFinished);
end;


{ ---- shared ---- }

{ 診断情報は起動時に作ったきりでは古くなります。困って設定タブを開いたときに
  最新でなければ、そこに答えがありません（要件 FR-G.3、NFR-5.7）。

  The diagnostics go stale if they are only built at startup. Opening the
  settings tab because something went wrong is no use if the answer is not
  there yet (requirements FR-G.3, NFR-5.7). }
procedure TMainForm.PagesChanged(Sender: TObject);
begin
  { 何番目か、ではなくどのタブか、で判じます。**番号で書くと、タブを 1 つ足した
    だけで別のタブの処理が動きます。**
    Which tab it is, not which number: **written as a number, adding one tab
    would run another tab's work.** }
  if FPages.ActivePage = FSettingsSheet then
    RefreshInfo;
end;

procedure TMainForm.PollTimer(Sender: TObject);
begin
  { 1 分ごとに地方時を OS に合わせ直します。夏時間の切り替え・利用者による
    時間帯の変更に、再起動せずに付いていきます（付録 BW.4）。
    Local time is re-aligned with the OS every minute, following a
    daylight-saving change or the operator changing the time zone without a
    restart (appendix BW.4). }
  if GetTickCount64 - FClockSyncedAt >= 60000 then
    SyncClock;
  { 自動の帯域が近くの局に合わせて変わったら、表示を追わせます（付録 CC）。
    When the automatic width changes with the stations nearby, the display
    follows (appendix CC). }
  if (FStream <> nil) and (FCapture <> nil) and (FRxWaterfall <> nil) and
     (FRxWaterfall.TuneHz > 0) and (SelectedBandwidth = tbAuto) and
     (FStream.AppliedHalfWidthHz <> FShownHalf) then
    UpdateTuneInfo;
  if FRigAutoConnectPending then
  begin
    FRigAutoConnectPending := False;
    SetStatus('', '', RsRigAutoConnecting);
    RigConnectClick(nil);
  end;
  UpdateRigStatus;
  { タイマーが動く時点でスレッドは Synchronize を抜けているため安全です。
  Safe here: the thread has left Synchronize by the time the timer runs. }
  if FCompletedThread <> nil then
    FreeAndNil(FCompletedThread);

  { 変更から数秒おいて書き出します。長時間の運用中に強制終了しても、直前の
    設定が残るようにするためです（終了処理だけに頼らない）。

    Written a few seconds after a change so that a forced exit during a long
    session still leaves the latest settings on disk, rather than relying on
    a clean shutdown. }
  if FSettingsDirty and (SecondsBetween(Now, FSettingsSavedAt) >= 3) then
    SaveSettings;

  UpdateTransmitProgress;
  UpdateLiveReceive;
  { 装置がつながるのを待っているなら、ここで試し直します（要件 NFR-4.4）。
    取り込みが動いているあいだは何もしません。
    If waiting for the device, this is where the next attempt happens
    (requirement NFR-4.4); it does nothing while capturing runs. }
  RetryCapture;
  UpdateRecording;
  { 出題が鳴り終われば「止める」は用済みです。押せるまま残すと、何も鳴って
    いないのに止められるように見えます（要件 FR-F.3）。
    Once the exercise has finished sounding, "stop" has served its purpose;
    left enabled it would offer to stop what is not playing
    (requirement FR-F.3). }
  if (FPrStop <> nil) and FPrStop.Enabled and not FPlayback.Running then
    FPrStop.Enabled := False;
  UpdatePracticeReveal;
  { 推論間隔を緩めたときは、そう言います（要件 FR-G.4）。**黙って遅くすると、
    「今日はなぜ確定が遅いのか」が誰にも分かりません。**速い機械では
    この案内は出ません。
    When the interval is eased, it is said (requirement FR-G.4): **eased in
    silence, nobody could tell why the text is slower to settle today.** On a
    machine that does not need it, this never appears. }
  if (FStream <> nil) and (FCapture <> nil) and
     (FStream.PaceSeconds > STREAM_MIN_PENDING_SECONDS) and
     (SecondsBetween(Now, FPaceToldAt) >= 60) then
  begin
    FPaceToldAt := Now;
    SetStatus('', '', Format(RsPaceEased,
      [FStream.PaceSeconds, FStream.RealTimeRatio]));
  end;
  { 訓練中は、経過した時間を出します。**押しっぱなしで席を立った人が、
    戻ってきて分かるようにするためです。**
    While training, the time so far is shown: **so that someone who left the
    room can see what happened when they come back.** }
  if (FFtCapture <> nil) and (FFtStatus <> nil) then
    FFtStatus.Caption := Format(RsFtRunningStatus,
      [SecondsAsClock((Now - FFtBegan) * SecsPerDay)]);
  { 解析が塞がっていて出せなかった読み直しを、ここで出します（要件 FR-C.3）。
    A re-reading that could not be issued because the analysis was busy is
    issued here (requirement FR-C.3). }
  TryStartRecheck;

  FTxSend.Enabled := (Length(FTxSamples) > 0) and not FPlayback.Running;
  FTxStop.Enabled := FPlayback.Running;
  FTxSave.Enabled := Length(FTxSamples) > 0;
  FTxVerify.Enabled := (Length(FTxSamples) > 0) and not DecoderBusy;
  FRxStart.Enabled := FCapture = nil;
  { 待っている最中も押せなければなりません（要件 NFR-4.4）。待ちは取り込みを
    持たないので `FCapture` は nil であり、それだけで無効にすると、**止めたくても
    止められない機械**になります。実機で押してみて気づきました。
    It has to work while waiting too (requirement NFR-4.4): waiting holds no
    capture, so `FCapture` is nil, and disabling on that alone leaves **a machine
    that cannot be stopped however much the operator wants to.** Pressing it on
    the running program is what showed this. }
  FRxStop.Enabled := (FCapture <> nil) or FWaiting;
  FRxDecodeFile.Enabled := not DecoderBusy;
  { 聴き直しの操作は、保管の中身と再生の状態で決まります。どちらもここでしか
    変わらないので、毎回まとめて映します。
    The replay controls follow what the store holds and whether it is playing;
    both change only here, so they are refreshed together. }
  UpdateReplayInfo;
  UpdateLogInfo;
end;

procedure TMainForm.SetStatus(const Engine, Audio, Message_: string);
begin
  if Engine <> '' then
    FStatus.Panels[0].Text := Engine;
  if Audio <> '' then
    FStatus.Panels[1].Text := Audio;
  if Message_ <> '' then
    FStatus.Panels[3].Text := Message_;
end;

{ 録音の欄。**同じ文字なら書き直しません。**毎秒 5 回の書き直しは、変わって
  いないものを描き直すだけの費用です。
  The recording panel. **The same text is not written again**: rewriting it five
  times a second would be the cost of redrawing what has not changed. }
procedure TMainForm.SetRecordStatus(const Shown: string);
begin
  if Shown = FRecordShown then
    Exit;
  FRecordShown := Shown;
  FStatus.Panels[2].Text := Shown;
end;

{ 技術的な文言を、次の一手が分かる日本語に置き換えます（要件 FR-A.4）。

  エンジン層の例外は開発者向けの英語で書かれています。それをそのまま出すと、
  利用者は何をすればよいか分かりません。ここで対処のある言葉に翻訳し、原文は
  診断画面にだけ残します。

  Turns a technical message into one an operator can act on (FR-A.4). The
  engine raises developer-facing English; shown as is, it tells the operator
  nothing to do. The raw text is kept for the diagnostics panel instead. }
{ ステータスバーへ出す 1 行を作ります。

  利用者向けの文言は、何が起きたかを述べる 1 行目と、対処を述べる続きの行から
  できています。バーの幅に収まらない長さを流し込むと文の途中で切れ、かえって
  読めません。ここでは 1 行目だけを出し、続きは診断情報に残します
  （要件 FR-A.4、NFR-5.7）。

  Builds the single line shown on the status bar. A message for the operator
  is a first line saying what happened followed by lines saying what to do;
  pouring the whole thing into a bar too narrow for it cuts a sentence in
  half and reads worse than nothing. Only the first line goes to the bar, and
  the rest stays in the diagnostics (requirements FR-A.4, NFR-5.7). }
function StatusLine(const Raw: string): string;
var
  Friendly: string;
  Break_: Integer;
begin
  Friendly := UserMessageFor(Raw);
  Break_ := Pos(LineEnding, Friendly);
  if Break_ > 0 then
    Result := Copy(Friendly, 1, Break_ - 1)
  else
    Result := Friendly;
end;

function UserMessageFor(const Raw: string): string;

  function Mentions(const Fragment: string): Boolean;
  begin
    Result := Pos(LowerCase(Fragment), LowerCase(Raw)) > 0;
  end;

begin
  if Mentions('PortAudio could not be loaded') or Mentions('Pa_Initialize') then
    Result := RsErrPortAudio
  else if Mentions('input stream') then
    Result := RsErrInputStream
  else if Mentions('output stream') then
    Result := RsErrOutputStream
  else if Mentions('Could not load the ONNX Runtime') then
    Result := RsErrRuntime
  else if Mentions('Model file not found') then
    Result := RsErrModelMissing
  else if Mentions('Metadata file not found') then
    Result := RsErrMetadataMissing
  else if Mentions('Metadata expects') or Mentions('the metadata declares') or
          Mentions('the metadata names') or Mentions('num_classes') then
    Result := RsErrMismatch
  else if Mentions('RIFF') or Mentions('WAV') or Mentions('PCM') then
    Result := RsErrWav
  else if Mentions('must last between') then
    Result := RsErrTooShort
  else
    Result := RsErrOther;
  { **見つけ出す手がかり（英語の原文）は訳しません。**例外の文面は OS と
    ライブラリが決めるもので、画面の言語とは関わりがありません。
    **The fragments matched on are not translated**: the wording of an
    exception comes from the platform and its libraries, not from the language
    of the screen. }
  Result := AsLines(Result);
end;

procedure TMainForm.SyncClock;
var
  Sync: TLocalClockSync;
begin
  FClockSyncedAt := GetTickCount64;
  Sync := SyncLocalClock;
  { 変えたときだけ残します。毎分同じ行が並ぶと、ほかの診断が押し出されます。
    Kept only when something changed; the same line every minute would push
    the other diagnostics out. }
  if Sync.Changed then
    LogDiagnostic(RsCtxClock, Format(RsClockAligned,
      [UtcOffsetText(Sync.RtlMinutes), UtcOffsetText(Sync.OsMinutes)]));
end;

procedure TMainForm.LogDiagnostic(const Context, Raw: string);
begin
  if FDiagnostics = nil then
    Exit;
  FDiagnostics.Add(Format('%s  %s: %s',
    [FormatDateTime('hh":"nn":"ss', Now), Context, Raw]));
  while FDiagnostics.Count > 50 do
    FDiagnostics.Delete(0);
end;

procedure TMainForm.ReportError(const Context: string; E: Exception);
begin
  ReportError(Context, E.Message);
end;

procedure TMainForm.ReportError(const Context, Raw: string);
var
  Friendly: string;
begin
  Friendly := UserMessageFor(Raw);
  LogDiagnostic(Context, Raw);
  SetStatus('', '', Format(RsErrStatusLine, [Context, StatusLine(Raw)]));
  MessageDlg(Format(RsErrFailedTitle, [Context]), Friendly, mtError, [mbOK], 0);
end;

end.
