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
  LCLType,
  DeepCW.Types, DeepCW.Metadata, DeepCW.Dsp, DeepCW.Onnx, DeepCW.Wave,
  DeepCW.Exchange, DeepCW.Watch,
  DeepCW.Morse, DeepCW.Decoder, DeepCW.Audio, DeepCW.Stream, DeepCW.Tuner,
  DeepCW.Review, DeepCW.Journal, DeepCW.Multi, DeepCW.BandMap, DeepCW.Log,
  DeepCW.Callsign, DeepCW.Recorder, DeepCW.Practice, DeepCW.Fist,
  DeepCW.FistLog, DeepCW.Diagnostics, DeepCW.Reference,
  TranscriptView, WaterfallView, BandMapView, TrendView, HistogramView;

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
  TDecodeThread = class(TThread)
  private
    FDecoder: TDeepCWDecoder;
    FStream: TStreamingDecoder;
    FMulti: TMultiStationDecoder;
    FSamples: TSingleArray;
    FSampleRate: Integer;
    FChars: TDecodedChars;
    FError: string;
    FRecheck: Boolean;
    { 送信訓練の採点のための解析かどうか。**受信テキストへ流さないのは
      読み直しと同じ理由です。**
      Whether this analysis is for scoring send practice. **It does not flow
      into the transcript, for the same reason a re-reading does not.** }
    FFist: Boolean;
    FOnDone: TNotifyEvent;
    procedure ReportDone;
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
    { 録音全体を、待機モードの経路で読み切ります。取り込みと同じように少しずつ
      流し込むのは、一度に入れると溜め込みの上限で大半が捨てられるためです。
      Reads a whole recording through the waiting mode's path. It is fed in
      pieces, as capture would, because all at once most of it would fall off the
      buffer's limit. }
    constructor CreateMultiFile(AMulti: TMultiStationDecoder;
      const ASamples: TSingleArray; ASampleRate: Integer;
      AOnDone: TNotifyEvent);
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
    function PrepareForDecoder(const Samples: TSingleArray; SampleRate: Integer): TSingleArray;

    procedure TxTextChanged(Sender: TObject);
    procedure TxOptionsChanged(Sender: TObject);
    procedure RenderTransmit;
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
    procedure ShowStationLabels;
    function SelectedBand: string;
    function WithoutWorked(const Entries: TBandEntries): TBandEntries;
    procedure RxContestChanged(Sender: TObject);
    procedure UpdateRate(Force: Boolean = False);
    function WatchedCall(const Callsign: string): string;
    procedure RxWatchChanged(Sender: TObject);
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
    procedure RxTuneClearClick(Sender: TObject);
    procedure RxMonitorClick(Sender: TObject);
    procedure RxTrackChanged(Sender: TObject);
    procedure UpdateTuneInfo;

    procedure PagesChanged(Sender: TObject);
    procedure PollTimer(Sender: TObject);
    procedure UpdateTransmitProgress;
    procedure UpdateLiveReceive;
    procedure SetStatus(const Engine, Audio, Message_: string);
    procedure ReportError(const Context: string; E: Exception);
    procedure LogDiagnostic(const Context, Raw: string);
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
  end;

var
  MainForm: TMainForm;

implementation

{ 実装の後方で定義します。/ Defined further down. }
function UserMessageFor(const Raw: string): string; forward;
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

constructor TDecodeThread.CreateMultiFile(AMulti: TMultiStationDecoder;
  const ASamples: TSingleArray; ASampleRate: Integer; AOnDone: TNotifyEvent);
begin
  FMulti := AMulti;
  FSamples := ASamples;
  FSampleRate := ASampleRate;
  FOnDone := AOnDone;
  FreeOnTerminate := False;
  inherited Create(False);
end;

procedure TDecodeThread.Execute;
const
  { 流し込む刻み。取り込みの脈動と同じ程度にします。
    The size of each piece, about what a pulse of capture delivers. }
  FILE_CHUNK_SECONDS = 1.0;
var
  Position, Taken: Integer;
begin
  try
    if (FMulti <> nil) and (Length(FSamples) > 0) then
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
    end
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
  Caption := 'DeepCW モールス通信 - 送受信';
  Width := 940;
  Height := 700;
  { グループ枠の中の操作列は固定位置で配置しているため、読みやすさを保つには
    おおよそこの幅が必要です。

    The control rows inside the group boxes are laid out at fixed offsets and
    need roughly this much width to stay readable. }
  Constraints.MinWidth := 900;
  Constraints.MinHeight := 560;
  Position := poScreenCenter;

  FDiagnostics := TStringList.Create;
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

  BuildUI;
  LoadSettings;
  { ステータスバーと設定タブに有用な情報を出すため、モデルは起動時に読み込み
    ます。ただしランタイムが無くても起動は妨げません。

    Load the model up front so the status bar and the settings tab say
    something useful, but never block startup on a missing runtime. }
  { 読み込んだ表示設定を実際に反映します。設定は代入だけでは効きません。
    Apply the loaded display settings; assigning the controls is not enough. }
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
    LogDiagnostic('交信記録', FLog.LastError);
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
  FDiagnostics.Free;
  FCapture.Free;
  FFtRing.Free;
  FPlayback.Free;
  FReviewPlay.Free;
  FAlerts.Free;
  { 書き残しを出してから解放します。閉じるときの 1 語は、記録として要ります。
    The remainder is written before releasing: the last word of a session
    belongs in the record. }
  if FJournal <> nil then
    FJournal.Flush;
  FJournal.Free;
  FLog.Free;
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
  BuildReceiveTab;
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

function AddLabel(Parent: TWinControl; const Text: string; Left, Top: Integer): TLabel;
begin
  Result := TLabel.Create(Parent);
  Result.Parent := Parent;
  Result.Caption := Text;
  Result.Left := Left;
  Result.Top := Top;
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
  Buttons, Current: TPanel;
begin
  Sheet := FPages.AddTabSheet;
  Sheet.Caption := '送信';
  Result := Sheet;

  AddTopLabel(Sheet, '送信する文（A-Z 0-9 . , ? / と空白）');
  FTxText := TMemo.Create(Sheet);
  FTxText.Parent := Sheet;
  FTxText.Height := 90;
  FTxText.ScrollBars := ssAutoVertical;
  FTxText.Text := 'CQ CQ DE JA1ABC K';
  FTxText.OnChange := @TxTextChanged;
  Stretch(FTxText, alTop);

  AddTopLabel(Sheet, 'モールス符号');
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
  Options.Caption := '送信設定';
  Stretch(Options, alTop);

  AddLabel(Options, '文字速度 (WPM)', 14, 6);
  FTxCharWpm := AddSpin(Options, 14, 26, 5, 60, 20, @TxOptionsChanged);
  AddLabel(Options, '実効速度 (WPM)', 134, 6);
  FTxTextWpm := AddSpin(Options, 134, 26, 5, 60, 20, @TxOptionsChanged);
  AddLabel(Options, '音程 (Hz)', 254, 6);
  FTxToneHz := AddSpin(Options, 254, 26, 300, 1500, 700, @TxOptionsChanged);

  AddLabel(Options, '音量', 360, 6);
  FTxVolume := TTrackBar.Create(Options);
  FTxVolume.Parent := Options;
  FTxVolume.SetBounds(360, 24, 160, 36);
  FTxVolume.Min := 0;
  FTxVolume.Max := 100;
  FTxVolume.Position := 60;
  FTxVolume.OnChange := @TxOptionsChanged;

  AddLabel(Options, '受信練習用ノイズ', 540, 6);
  FTxNoise := TTrackBar.Create(Options);
  FTxNoise.Parent := Options;
  FTxNoise.SetBounds(540, 24, 160, 36);
  FTxNoise.Min := 0;
  FTxNoise.Max := 40;
  FTxNoise.Position := 0;
  FTxNoise.OnChange := @TxOptionsChanged;

  FTxSummary := AddLabel(Options, '', 726, 30);

  Buttons := AddTopPanel(Sheet, 40);
  FTxSend := AddButton(Buttons, '送信', 12, 4, 110, @TxSendClick);
  FTxStop := AddButton(Buttons, '停止', 130, 4, 110, @TxStopClick);
  FTxSave := AddButton(Buttons, 'WAV に保存', 248, 4, 130, @TxSaveClick);
  FTxVerify := AddButton(Buttons, '自己デコード確認', 386, 4, 160, @TxVerifyClick);

  FTxProgress := TProgressBar.Create(Sheet);
  FTxProgress.Parent := Sheet;
  FTxProgress.Height := 18;
  Stretch(FTxProgress, alTop);

  AddTopLabel(Sheet, '送信中の文字');
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
  Sheet.Caption := '受信';
  Result := Sheet;

  FileBox := TGroupBox.Create(Sheet);
  FileBox.Parent := Sheet;
  FileBox.Height := 76;
  FileBox.Caption := 'WAV ファイルから受信';
  Stretch(FileBox, alTop);

  { alRight は生成順に右から詰めるため、デコードボタンを先に作って最も右へ
    配置します。

    alRight fills from the right in creation order, so the decode button is
    created first and ends up furthest right. }
  FRxDecodeFile := AddButton(FileBox, 'デコード', 0, 0, 120, @RxDecodeFileClick);
  Stretch(FRxDecodeFile, alRight);
  FRxBrowse := AddButton(FileBox, '参照...', 0, 0, 90, @RxBrowseClick);
  Stretch(FRxBrowse, alRight);
  FRxFile := TEdit.Create(FileBox);
  FRxFile.Parent := FileBox;
  FRxFile.Text := '';
  Stretch(FRxFile, alClient);

  LiveBox := TGroupBox.Create(Sheet);
  LiveBox.Parent := Sheet;
  LiveBox.Height := 120;
  LiveBox.Caption := 'マイク / ライン入力から受信';
  Stretch(LiveBox, alTop);

  LevelPanel := TPanel.Create(LiveBox);
  LevelPanel.Parent := LiveBox;
  LevelPanel.Align := alRight;
  LevelPanel.Width := 190;
  LevelPanel.BevelOuter := bvNone;
  AddLabel(LevelPanel, '入力レベル', 6, 4);
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

  FRxStart := AddButton(LiveControls, '受信開始', 8, 22, 110, @RxStartClick);
  FRxStop := AddButton(LiveControls, '受信停止', 126, 22, 110, @RxStopClick);
  FRxClear := AddButton(LiveControls, '表示をクリア', 244, 22, 130, @RxClearClick);

  AddLabel(LiveControls, '入力装置', 8, 56);
  FRxDevice := TComboBox.Create(LiveControls);
  FRxDevice.Parent := LiveControls;
  FRxDevice.SetBounds(78, 52, 380, 28);
  FRxDevice.Style := csDropDownList;
  FRxDevice.OnChange := @RxConfirmSpeedChanged;
  FRxDeviceRefresh := AddButton(LiveControls, '再検出', 466, 52, 80,
    @RxDeviceRefreshClick);

  AddLabel(LiveControls, '文字が決まるまで', 390, 4);
  FRxConfirmSpeed := TComboBox.Create(LiveControls);
  FRxConfirmSpeed.Parent := LiveControls;
  FRxConfirmSpeed.SetBounds(390, 22, 150, 28);
  FRxConfirmSpeed.Style := csDropDownList;
  FRxConfirmSpeed.Items.Add('速さ優先');
  FRxConfirmSpeed.Items.Add('標準');
  FRxConfirmSpeed.Items.Add('確実さ優先');
  FRxConfirmSpeed.ItemIndex := 1;
  FRxConfirmSpeed.OnChange := @RxConfirmSpeedChanged;

  { 受信のしかたを選びます。**いま何モードかが常に見えていること**が要件です
    （FR-I.6）ので、選択そのものを操作列に置き、説明を隣に添えます。
    How reception is used. The requirement is that the mode **is always visible**
    (FR-I.6), so the choice itself sits in the control row with a word of
    explanation beside it. }
  AddLabel(LiveControls, '受信のしかた', 556, 56);
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
  FRxMode.Items.Add('交信モード');
  FRxMode.Items.Add('待機モード');
  FRxMode.Items.Add('コンテスト');
  FRxMode.ItemIndex := 0;
  { 通知は設定を読み終えてから繋ぎます。読み込みの代入で通知が走ると、起動した
    だけで「モードにしました」という身に覚えのない案内が出ます。
    The notification is attached after the settings are read: assigning during the
    load would announce a mode change the operator never made. }

  FRxAntiAlias := TCheckBox.Create(LiveControls);
  FRxAntiAlias.Parent := LiveControls;
  FRxAntiAlias.SetBounds(556, 26, 190, 24);
  FRxAntiAlias.Caption := '帯域外の雑音を抑える';
  FRxAntiAlias.Checked := True;
  FRxAntiAlias.OnChange := @RxConfirmSpeedChanged;

  FRxBusy := AddTopLabel(Sheet, '');

  WaterfallPanel := TPanel.Create(Sheet);
  WaterfallPanel.Parent := Sheet;
  WaterfallPanel.Align := alBottom;
  WaterfallPanel.Height := 230;
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
  AddLabel(TuneTools, '読みたい信号をクリック。ホイールで微調整。', 6, 7);
  FRxTuneClear := AddButton(TuneTools, '同調を解除', 0, 2, 110, @RxTuneClearClick);
  Stretch(FRxTuneClear, alRight);
  { **デコーダが聴いている音**を、そのまま鳴らします（要件 FR-A.6）。生の受信音
    ではありません。同調して帯域を絞ったあとの音なので、**機械が読み違えたとき
    に、機械に何が届いていたのかが耳で分かります。**
    Plays **what the decoder is listening to** (requirement FR-A.6), not the raw
    input: the audio after tuning and band limiting, so that when the machine
    reads something wrongly, **what reached the machine can be heard.** }
  FRxMonitor := AddButton(TuneTools, '復調音を聴く', 0, 2, 120, @RxMonitorClick);
  Stretch(FRxMonitor, alRight);
  { 動いていく信号を追いかけるかどうか。既定は有効です。周波数を決め打ちで
    見張りたい場合のために、切れるようにしてあります（要件 FR-D.7）。

    Whether to follow a signal that moves; on by default, and switchable off
    for an operator deliberately watching one frequency (FR-D.7). }
  FRxTrack := TCheckBox.Create(TuneTools);
  FRxTrack.Parent := TuneTools;
  FRxTrack.Caption := '信号を自動で追う';
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
  Stretch(FRxWaterfall, alClient);

  TextPanel := TPanel.Create(Sheet);
  TextPanel.Parent := Sheet;
  TextPanel.Align := alClient;
  TextPanel.BevelOuter := bvNone;
  AddTopLabel(TextPanel, '受信テキスト');

  TextTools := TPanel.Create(TextPanel);
  TextTools.Parent := TextPanel;
  TextTools.Height := 34;
  StackBelow(TextTools);
  TextTools.Align := alTop;
  TextTools.BevelOuter := bvNone;

  FRxShowDoubt := TCheckBox.Create(TextTools);
  FRxShowDoubt.Parent := TextTools;
  FRxShowDoubt.SetBounds(6, 7, 240, 22);
  FRxShowDoubt.Caption := '確からしさを濃淡で示す';
  FRxShowDoubt.Checked := True;
  FRxShowDoubt.OnChange := @RxDisplayChanged;

  AddLabel(TextTools, '濃淡', 254, 9);
  FRxDoubtStrength := TTrackBar.Create(TextTools);
  FRxDoubtStrength.Parent := TextTools;
  FRxDoubtStrength.SetBounds(288, 2, 120, 30);
  FRxDoubtStrength.Min := 0;
  FRxDoubtStrength.Max := 100;
  FRxDoubtStrength.Position := 100;
  FRxDoubtStrength.ShowSelRange := False;
  FRxDoubtStrength.OnChange := @RxDisplayChanged;

  AddLabel(TextTools, '文字の大きさ', 424, 9);
  FRxFontSize := AddSpin(TextTools, 512, 5, 9, 32, 14, @RxDisplayChanged);
  FRxCopy := AddButton(TextTools, 'コピー', 604, 2, 90, @RxCopyClick);
  { 呼出符号と信号報告だけを送る口です（要件 FR-E.2）。全文をコピーしてから
    目で探して切り出すのでは「操作 1 回」になりません。
    Sends just the call sign and the report (requirement FR-E.2). Copying the
    whole transcript and then hunting through it by eye is not "one press". }
  FRxCopyCall := AddButton(TextTools, '符号と RST', 700, 2, 130,
    @RxCopyCallClick);
  FRxCopyCall.Enabled := False;

  { 読んだ文字をウォーターフォールに重ねるか（要件 FR-D.6）。重ねた文字は信号を
    隠すので、切れるようにしてあります。
    Whether to lay the characters over the waterfall (requirement FR-D.6). They
    cover the signals, so they can be turned off. }
  FRxAlign := TCheckBox.Create(TextTools);
  FRxAlign.Parent := TextTools;
  FRxAlign.SetBounds(840, 6, 200, 24);
  FRxAlign.Caption := '文字を波形に重ねる';
  FRxAlign.Checked := True;
  FRxAlign.OnChange := @RxDisplayChanged;

  { 検索と聴き直しは、表示の設定とは別の行に置きます。同じ行に並べると、窓を
    狭くしたときに右端の操作が画面の外へ出て、押せなくなります（最小幅 900）。
    Search and replay go on their own row: on the same row as the display
    settings, narrowing the window pushes the right-hand controls off the screen
    where they cannot be pressed (the minimum width is 900). }
  FindTools := TPanel.Create(TextPanel);
  FindTools.Parent := TextPanel;
  FindTools.Height := 34;
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
  AddLabel(FindTools, '検索', 6, 9);
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
  FRxWorked := AddButton(FindTools, '交信を記録', 396, 2, 100, @RxWorkedClick);
  FRxWorked.Enabled := False;
  FRxLogInfo := TLabel.Create(FindTools);
  FRxLogInfo.Parent := FindTools;
  FRxLogInfo.SetBounds(504, 9, 250, 20);

  FRxReplay := AddButton(FindTools, 'もう一度聴く', 760, 2, 110, @RxReplayClick);
  FRxReplay.Enabled := False;
  FRxReplayStop := AddButton(FindTools, '停止', 874, 2, 60, @RxReplayStopClick);
  FRxReplayStop.Enabled := False;
  FRxReplayInfo := TLabel.Create(FindTools);
  FRxReplayInfo.Parent := FindTools;
  FRxReplayInfo.SetBounds(944, 9, 300, 20);
  { 窓の幅に合わせて伸ばします。固定幅だと、狭い窓では文が途中で切れ、広い窓では
    余白が空きます。
    Stretched with the window: at a fixed width the sentence is cut off in a
    narrow window and leaves a gap in a wide one. }
  FRxReplayInfo.Anchors := [akLeft, akTop, akRight];
  FRxReplayInfo.BorderSpacing.Right := 8;
  FRxReplayInfo.Caption := '文字を押すと、その音を聴き直せます。';

  FRxTranscript := TTranscriptView.Create(TextPanel);
  FRxTranscript.Parent := TextPanel;
  FRxTranscript.OnCharChosen := @RxCharChosen;
  FRxTranscript.Font.Size := 14;
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
  AddLabel(FWatchTools, '待つ符号', 6, 9);
  FRxWatch := TEdit.Create(FWatchTools);
  FRxWatch.Parent := FWatchTools;
  FRxWatch.SetBounds(80, 4, 260, 26);
  FRxWatch.TextHint := 'JA1ABC JH2XYZ';
  FRxWatchInfo := TLabel.Create(FWatchTools);
  FRxWatchInfo.Parent := FWatchTools;
  FRxWatchInfo.SetBounds(352, 9, 600, 20);

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
  AddLabel(FContestTools, '運用バンド', 6, 9);
  FRxBand := TComboBox.Create(FContestTools);
  FRxBand.Parent := FContestTools;
  FRxBand.SetBounds(96, 4, 130, 26);
  FRxBand.Style := csDropDownList;
  { 表記は運用者の言葉（MHz）で、記録には ADIF の名前で残します。
    Shown in the operator's terms (MHz) and recorded under the ADIF name. }
  FRxBand.Items.Add('指定なし');
  FRxBand.Items.Add('1.9 MHz');
  FRxBand.Items.Add('3.5 MHz');
  FRxBand.Items.Add('7 MHz');
  FRxBand.Items.Add('14 MHz');
  FRxBand.Items.Add('21 MHz');
  FRxBand.Items.Add('28 MHz');
  FRxBand.Items.Add('50 MHz');
  FRxBand.Items.Add('144 MHz');
  FRxBand.Items.Add('430 MHz');
  FRxBand.ItemIndex := 0;
  FRxBand.OnChange := @RxContestChanged;

  FRxHideWorked := TCheckBox.Create(FContestTools);
  FRxHideWorked.Parent := FContestTools;
  FRxHideWorked.SetBounds(240, 6, 190, 24);
  FRxHideWorked.Caption := '交信済みを隠す';
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
  Sheet.Caption := '練習';
  Result := Sheet;

  Options := TGroupBox.Create(Sheet);
  Options.Parent := Sheet;
  Options.Height := 124;
  Options.Caption := '出題';
  Stretch(Options, alTop);

  AddLabel(Options, '出す内容', 14, 8);
  FPrKind := TComboBox.Create(Options);
  FPrKind.Parent := Options;
  FPrKind.SetBounds(14, 28, 200, 28);
  FPrKind.Style := csDropDownList;
  for Kind := Low(TExerciseKind) to High(TExerciseKind) do
    FPrKind.Items.Add(EXERCISE_NAMES[Kind]);
  FPrKind.ItemIndex := 0;
  FPrKind.OnChange := @PrOptionsChanged;

  AddLabel(Options, '出す数', 230, 8);
  FPrGroups := AddSpin(Options, 230, 30, 1, 50, 10, @PrOptionsChanged);
  AddLabel(Options, '速度 (WPM)', 330, 8);
  FPrWpm := AddSpin(Options, 330, 30, 5, 40, 20, @PrOptionsChanged);

  AddLabel(Options, '雑音', 440, 8);
  FPrNoise := TTrackBar.Create(Options);
  FPrNoise.Parent := Options;
  FPrNoise.SetBounds(440, 26, 160, 36);
  FPrNoise.Min := 0;
  FPrNoise.Max := 40;
  FPrNoise.Position := 10;
  FPrNoise.OnChange := @PrOptionsChanged;

  AddLabel(Options,
    '音程と音量は送信タブの設定を使います。', 620, 34);

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
  FPrDelay.Caption := '遅らせて正解を出す';
  FPrDelay.Checked := True;
  FPrDelay.OnChange := @PrOptionsChanged;

  AddLabel(Options, '遅らせる秒数', 230, 78);
  FPrDelaySeconds := AddSpin(Options, 330, 74, 0, REVEAL_DELAY_MAX_SECONDS,
    REVEAL_DELAY_DEFAULT_SECONDS, @PrOptionsChanged);
  AddLabel(Options,
    '鳴った文字が、この秒数だけ遅れて「正解」に出ます。', 440, 78);

  Buttons := AddTopPanel(Sheet, 40);
  FPrPlay := AddButton(Buttons, '出題して鳴らす', 12, 4, 150, @PrPlayClick);
  FPrAgain := AddButton(Buttons, 'もう一度鳴らす', 170, 4, 150, @PrAgainClick);
  FPrAgain.Enabled := False;
  FPrStop := AddButton(Buttons, '止める', 328, 4, 100, @PrStopClick);
  FPrStop.Enabled := False;
  FPrSummary := AddLabel(Buttons, '「出題して鳴らす」を押すと始まります。', 440, 12);

  AddTopLabel(Sheet, '写した文字を書いてください');
  FPrCopy := TMemo.Create(Sheet);
  FPrCopy.Parent := Sheet;
  FPrCopy.Height := 90;
  FPrCopy.ScrollBars := ssAutoVertical;
  FPrCopy.Font.Size := 14;
  Stretch(FPrCopy, alTop);

  Buttons := AddTopPanel(Sheet, 40);
  FPrMark := AddButton(Buttons, '答え合わせ', 12, 4, 130, @PrMarkClick);
  FPrMark.Enabled := False;
  FPrResult := AddLabel(Buttons, '', 156, 12);

  AddTopLabel(Sheet, '正解');
  FPrAnswer := TMemo.Create(Sheet);
  FPrAnswer.Parent := Sheet;
  FPrAnswer.Height := 70;
  FPrAnswer.ReadOnly := True;
  FPrAnswer.ScrollBars := ssAutoVertical;
  FPrAnswer.Font.Size := 14;
  Stretch(FPrAnswer, alTop);

  FPrMistakes := AddTopLabel(Sheet, '');
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
    FPrSummary.Caption := Format('%d 文字 / %.1f 秒',
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
    SetStatus('', '', '出題を鳴らしています。');
  except
    on E: Exception do
      ReportError('練習', E);
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
begin
  if FPrText = '' then
  begin
    SetStatus('', '', '先に「出題して鳴らす」を押してください。');
    Exit;
  end;
  { 答え合わせが済めば、遅らせて出す意味はもうありません。全部を出します。
    Once the copy is marked there is nothing left to delay; the whole answer
    goes up. }
  FPrRevealing := False;
  Score := ScoreCopy(FPrText, FPrCopy.Text);
  FPrAnswer.Text := FPrText;
  FPrResult.Caption := Format(
    '正答率 %.0f%%（%d 文字中 %d 文字）／ 違い %d ・ 落とし %d ・ 足し %d',
    [Score.Percent, Score.Total, Score.Same, Score.Wrong, Score.Missed,
     Score.Extra]);
  Mistakes := MistakeSummary(Score);
  if Mistakes = '' then
    FPrMistakes.Caption := '間違いはありません。'
  else
    FPrMistakes.Caption := '間違えやすかった符号: ' + Mistakes;
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
    SetStatus('', '', '音を鳴らせませんでした。正解は「答え合わせ」で出せます。');
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
  SetStatus('', '', Format('診断情報を %d 行コピーしました。' +
    '不具合報告にそのまま貼れます。',
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
  Bottom: TPanel;
begin
  Sheet := FPages.AddTabSheet;
  Sheet.Caption := '送信訓練';
  Result := Sheet;

  Options := TGroupBox.Create(Sheet);
  Options.Parent := Sheet;
  Options.Height := 124;
  Options.Caption := '課題文と採点';
  Stretch(Options, alTop);

  AddLabel(Options, '課題文の内容', 14, 8);
  FFtKind := TComboBox.Create(Options);
  FFtKind.Parent := Options;
  FFtKind.SetBounds(14, 28, 200, 28);
  FFtKind.Style := csDropDownList;
  for Kind := Low(TExerciseKind) to High(TExerciseKind) do
    FFtKind.Items.Add(EXERCISE_NAMES[Kind]);
  FFtKind.ItemIndex := Ord(ekQso);
  FFtKind.OnChange := @FtOptionsChanged;

  AddLabel(Options, '出す数', 230, 8);
  FFtGroups := AddSpin(Options, 230, 30, 1, 20, 3, @FtOptionsChanged);

  AddLabel(Options, '鍵の種類', 330, 8);
  FFtKey := TComboBox.Create(Options);
  FFtKey.Parent := Options;
  FFtKey.SetBounds(330, 28, 150, 28);
  FFtKey.Style := csDropDownList;
  FFtKey.Items.Add('縦振り');
  FFtKey.Items.Add('パドル');
  FFtKey.Items.Add('バグ');
  FFtKey.Items.Add('エレキー');
  FFtKey.ItemIndex := 0;
  FFtKey.OnChange := @FtOptionsChanged;

  AddLabel(Options, '採点の基準', 496, 8);
  FFtBasis := TComboBox.Create(Options);
  FFtBasis.Parent := Options;
  FFtBasis.SetBounds(496, 28, 180, 28);
  FFtBasis.Style := csDropDownList;
  for Standard_ := Low(TFistStandard) to High(TFistStandard) do
    FFtBasis.Items.Add(FIST_STANDARD_NAMES[Standard_]);
  FFtBasis.ItemIndex := 0;
  FFtBasis.OnChange := @FtOptionsChanged;
  AddLabel(Options,
    '基準は「正しさ」ではありません。バグキーの符号は、バグキーの基準で測ります。',
    692, 34);

  { 課題文なしでも測れますが、間隔の種別をしきい値で分けるため**参考値**に
    なります（要件 FR-H.3）。画面でそう分かるようにします。
    Without a text it still measures, but the kinds of gap are split at a
    threshold and the result is **indicative only** (FR-H.3); the screen says
    so. }
  FFtFree := TCheckBox.Create(Options);
  FFtFree.Parent := Options;
  FFtFree.SetBounds(14, 74, 300, 24);
  FFtFree.Caption := '課題文なしで送る（採点は参考値）';
  FFtFree.OnChange := @FtOptionsChanged;

  FFtNew := AddButton(Options, '課題文を出す', 330, 70, 150, @FtNewClick);

  Buttons := AddTopPanel(Sheet, 40);
  FFtStart := AddButton(Buttons, '訓練開始', 12, 4, 120, @FtStartClick);
  FFtStop := AddButton(Buttons, '終了して採点', 140, 4, 150, @FtStopClick);
  FFtStop.Enabled := False;
  FFtWav := AddButton(Buttons, 'WAV から採点', 298, 4, 150, @FtWavClick);
  FFtStatus := AddLabel(Buttons,
    '「課題文を出す」を押し、無線機のモニター音が届く状態で「訓練開始」を押してください。',
    460, 12);

  AddTopLabel(Sheet, '課題文（この文を自分の鍵で送ってください。書き換えられます）');
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

  AddTopLabel(Sheet, '採点');
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
  AddTopLabel(Bottom, 'これまでの記録');
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
  AddLabel(Buttons, '下に出すもの', 12, 12);
  FFtBottomKind := TComboBox.Create(Buttons);
  FFtBottomKind.Parent := Buttons;
  FFtBottomKind.SetBounds(104, 6, 130, 28);
  FFtBottomKind.Style := csDropDownList;
  FFtBottomKind.Items.Add('推移');
  FFtBottomKind.Items.Add('分布');
  FFtBottomKind.ItemIndex := 0;
  FFtBottomKind.OnChange := @FtBottomChanged;

  AddLabel(Buttons, '推移に出す項目', 252, 12);
  FFtTrendItem := TComboBox.Create(Buttons);
  FFtTrendItem.Parent := Buttons;
  FFtTrendItem.SetBounds(360, 6, 150, 28);
  FFtTrendItem.Style := csDropDownList;
  FFtTrendItem.Items.Add('総合');
  FFtTrendItem.Items.Add('5 項目すべて');
  for Item := Succ(Low(TFistItem)) to High(TFistItem) do
    FFtTrendItem.Items.Add(FIST_ITEM_NAMES[Item]);
  FFtTrendItem.ItemIndex := 0;
  FFtTrendItem.OnChange := @FtTrendChanged;

  AddLabel(Buttons, '鍵の種類', 526, 12);
  FFtTrendKey := TComboBox.Create(Buttons);
  FFtTrendKey.Parent := Buttons;
  FFtTrendKey.SetBounds(596, 6, 140, 28);
  FFtTrendKey.Style := csDropDownList;
  FFtTrendKey.Items.Add('すべて');
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
      FFtText.Text := '課題文なしで送ります。採点は参考値です。';
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
  SetStatus('', '', '課題文を出しました。準備ができたら「訓練開始」を押してください。');
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
    SetStatus('', '', '受信中は訓練を始められません。先に「受信停止」を押してください。');
    Exit;
  end;
  if (not FFtFree.Checked) and (Trim(FFtText.Text) = '') then
  begin
    SetStatus('', '', '先に「課題文を出す」を押すか、送る文を書いてください。');
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
    SetStatus('', Format('訓練中 %d Hz', [FFtRate]),
      '送ってください。終わったら「終了して採点」を押してください。');
  except
    on E: Exception do
    begin
      FreeAndNil(FFtCapture);
      FFtStart.Enabled := True;
      FFtStop.Enabled := False;
      ReportError('送信訓練の開始', E);
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
    SetStatus('', '', '訓練中です。先に「終了して採点」を押してください。');
    Exit;
  end;
  if FRxFile.Text = '' then
  begin
    SetStatus('', '', '受信タブの「WAV ファイルから受信」に、採点したい録音を選んでください。');
    Exit;
  end;
  try
    LoadWavMono(FRxFile.Text, Samples, SampleRate);
  except
    on E: Exception do
    begin
      ReportError('WAV の読み込み', E);
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
    FFtResult.Text := '音が取り込めませんでした。入力装置と音量を確かめてください。';
    Exit;
  end;
  ToneHz := DetectToneHz(Samples, SampleRate);
  if ToneHz <= 0 then
  begin
    FFtResult.Text := 'モニター音が見つかりませんでした。' + LineEnding +
      '無線機のモニター音量と、受信タブで選んだ入力装置を確かめてください。';
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
    FFtResult.Text := '採点できませんでした。' + LineEnding + FFtMeasured.Note;
    FFtAdvice.Caption := '';
    SetStatus('', '', '採点できませんでした。');
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
    SetStatus('', '', '採点しています…');
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
    Lines.Add(Format('総合 %.0f 点（%s の基準）', [Score.Overall,
      FIST_STANDARD_NAMES[FistBasis]]));
    Lines.Add(Format('  速度の安定 %3.0f ／ 短長の明瞭 %3.0f ／ 区切りの明瞭 %3.0f ／ 間隔の正確 %3.0f',
      [Score.Speed, Score.Clarity, Score.Separation, Score.Spacing]));
    if Score.HasCopyability then
      Lines.Add(Format('  写しやすさ %3.0f（文字誤り率 %.1f%%）',
        [Score.Copyability, 100 * Cer]))
    else
      Lines.Add('  写しやすさ —（課題文と読み合わせていません）');
    Lines.Add('');
    Lines.Add(Format('実効 %.1f WPM ／ 短点 %.1f ms（ばらつき %.1f%%）／ 長短比 %.2f',
      [FFtMeasured.EffectiveWpm, FFtMeasured.DitSeconds * 1000,
       100 * FFtMeasured.Stats[ekDit].Cv, FFtMeasured.Ratio]));
    Lines.Add(Format('間隔の比: 符号内 %.2f ／ 文字間 %.2f ／ 語間 %.2f',
      [FFtMeasured.IntraRatio, FFtMeasured.CharRatio, FFtMeasured.WordRatio]));
    Lines.Add(Format('分離度: 短点と長点 %.1f ／ 符号内と文字間 %.1f ／ 速度の変化 %.0f%%',
      [FFtMeasured.ToneSeparation, FFtMeasured.GapSeparation,
       100 * FFtMeasured.Drift]));
    if FFtMeasured.Reference then
      Lines.Add('※ 課題文なしで測りました。間隔の種別はしきい値で分けています（参考値）。');
    if FFtLost then
      Lines.Add('※ 10 分を超えた分は保持から落ちました。最後の 10 分だけを採点しています。');
    FFtResult.Text := Lines.Text;
  finally
    Lines.Free;
  end;
  { **点数の低さは、余地であって誤りではありません。**助言はそのように書きます。
    **A low score is room to grow, not a fault**, and the advice is written to
    say so. }
  FFtAdvice.Caption := '直すとよい点: ' + Score.Advice;

  Item := Default(TFistRecord);
  Item.When_ := Now;
  Item.Seconds := FFtMeasured.Seconds;
  if FFtKey.ItemIndex >= 0 then
    Item.Key := FFtKey.Items[FFtKey.ItemIndex];
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
      LogDiagnostic('送信訓練の記録', E.Message);
  end;
  { 分布は、いま採点した回のものを出します（要件 FR-H.9）。**記録には要素まで
    残していない**ので、出せるのはこの 1 回だけです。
    The distributions are those of the session just scored (FR-H.9): **the
    record does not keep the elements**, so this one session is what there is
    to show. }
  if FFtHistogram <> nil then
    FFtHistogram.SetMeasurement(FFtMeasured);
  FtShowHistory;
  SetStatus('', '', Format('採点しました。総合 %.0f 点。', [Score.Overall]));
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
      Lines.Add('まだ記録はありません。記録は ' + FistLogFileName + ' に CSV で残ります。')
    else
    begin
      Best := 0;
      for I := 0 to High(Records_) do
        if Records_[I].Score.Overall > Best then
          Best := Records_[I].Score.Overall;
      Lines.Add(Format('%d 件 ／ 自己ベスト 総合 %.0f 点 ／ %s',
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
  if FFtTrendKey.ItemIndex > 0 then
    Kept := FFtTrendKey.Items[FFtTrendKey.ItemIndex];
  FFtTrendKeyWanted := '';
  Keys := KeysUsed(Items);
  FFtTrendKey.Items.BeginUpdate;
  try
    FFtTrendKey.Items.Clear;
    FFtTrendKey.Items.Add('すべて');
    for I := 0 to High(Keys) do
      FFtTrendKey.Items.Add(Keys[I]);
  finally
    FFtTrendKey.Items.EndUpdate;
  end;
  FFtTrendKey.ItemIndex := Max(0, FFtTrendKey.Items.IndexOf(Kept));

  Key := '';
  if FFtTrendKey.ItemIndex > 0 then
    Key := FFtTrendKey.Items[FFtTrendKey.ItemIndex];
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
    FFtStreak.Caption := Format('%d 日続いています', [Days])
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
  Operating, Advanced: TGroupBox;
  Row, Apply: TPanel;
  Choice: TTunerBandwidth;

  { 技術的な設定は「詳細・診断」側にだけ置きます（要件 FR-G.1）。
    Technical settings live only under the advanced group (FR-G.1). }
  function AddPathEdit(Parent: TWinControl; const Caption, Value: string): TEdit;
  begin
    AddTopLabel(Parent, Caption);
    Result := TEdit.Create(Parent);
    Result.Parent := Parent;
    Result.Text := Value;
    Stretch(Result, alTop);
  end;

begin
  Sheet := FPages.AddTabSheet;
  Sheet.Caption := '設定';
  Result := Sheet;

  { ── 運用設定：普段さわるもの。技術用語を置かない ──
    Operating settings: what an operator actually changes. No jargon here. }
  Operating := TGroupBox.Create(Sheet);
  Operating.Parent := Sheet;
  Operating.Height := 210;
  Operating.Caption := '運用設定';
  Stretch(Operating, alTop);

  AddLabel(Operating, '音の細かさ', 14, 8);
  FSetCaptureRate := TComboBox.Create(Operating);
  FSetCaptureRate.Parent := Operating;
  FSetCaptureRate.SetBounds(14, 30, 200, 28);
  FSetCaptureRate.Style := csDropDownList;
  FSetCaptureRate.Items.Add('8000 Hz（推奨）');
  FSetCaptureRate.Items.Add('11025 Hz');
  FSetCaptureRate.Items.Add('16000 Hz');
  FSetCaptureRate.Items.Add('22050 Hz');
  FSetCaptureRate.Items.Add('44100 Hz');
  FSetCaptureRate.Items.Add('48000 Hz');
  FSetCaptureRate.ItemIndex := 0;
  AddLabel(Operating, '受信機の音を取り込む細かさです。うまく取り込めないときだけ変えてください。',
    232, 36);

  AddLabel(Operating, '聴き直せる長さ', 14, 62);
  FSetRetention := TComboBox.Create(Operating);
  FSetRetention.Parent := Operating;
  FSetRetention.SetBounds(120, 58, 110, 28);
  FSetRetention.Style := csDropDownList;
  FSetRetention.Items.Add('5 分');
  FSetRetention.Items.Add('10 分（推奨）');
  FSetRetention.Items.Add('20 分');
  FSetRetention.Items.Add('30 分');
  FSetRetention.ItemIndex := 1;
  FSetRetention.OnChange := @RxRetentionChanged;
  AddLabel(Operating,
    '受信テキストの文字を押して音を聴き直せる範囲です。長くするほど記憶を使います。',
    248, 62);

  FSetJournal := TCheckBox.Create(Operating);
  FSetJournal.Parent := Operating;
  FSetJournal.SetBounds(14, 90, 300, 22);
  FSetJournal.Caption := '受信テキストを時刻付きで記録する';
  FSetJournal.Checked := True;
  FSetJournal.OnChange := @RxJournalChanged;
  AddLabel(Operating,
    '確定するそばからファイルへ書き足します。異常終了しても直前まで残ります。',
    330, 92);

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
  FSetRecord.Caption := '受信した音を WAV で録音する';
  FSetRecord.Checked := False;
  FSetRecord.OnChange := @RxRecordChanged;
  FSetRecordInfo := AddLabel(Operating, '', 330, 120);

  { 交信記録の出し入れ。運用者が別のソフトで積み上げた記録を取り込めば、その場で
    「交信済み」が効きます（要件 FR-E.3・FR-J.4）。
    Taking the contact log in and out. Importing a log an operator built in
    another program makes the worked marks work at once (requirements FR-E.3 and
    FR-J.4). }
  AddLabel(Operating, '交信記録', 14, 150);
  FSetLogImport := AddButton(Operating, 'ADIF を取り込む', 120, 146, 150,
    @SetLogImportClick);
  FSetLogExport := AddButton(Operating, 'ADIF を書き出す', 278, 146, 150,
    @SetLogExportClick);
  FSetLogInfo := AddLabel(Operating, '', 440, 150);

  { ── 詳細・診断：困ったときだけ見るもの ──
    Advanced and diagnostics: only looked at when something is wrong. }
  Advanced := TGroupBox.Create(Sheet);
  Advanced.Parent := Sheet;
  Advanced.Caption := '詳細・診断';
  Stretch(Advanced, alClient);

  Row := AddTopPanel(Advanced, 40);
  FSetApply := AddButton(Row, '設定を適用してエンジンを読み込み直す', 8, 4, 300, @ApplySettings);
  AddLabel(Row, '推論スレッド', 328, 12);
  FSetThreads := TComboBox.Create(Row);
  FSetThreads.Parent := Row;
  FSetThreads.SetBounds(408, 8, 110, 28);
  FSetThreads.Style := csDropDownList;
  FSetThreads.Items.Add('自動');
  FSetThreads.Items.Add('1');
  FSetThreads.Items.Add('2');
  FSetThreads.Items.Add('4');
  FSetThreads.ItemIndex := 0;

  { 帯域幅は自動のままで実用に足ります。手で選びたい人のためだけに残します
    （要件 FR-D.3）。
    Automatic is good enough in practice; the manual choice exists only for
    those who want it (requirement FR-D.3). }
  AddLabel(Row, '同調時の帯域幅', 536, 12);
  FSetBandwidth := TComboBox.Create(Row);
  FSetBandwidth.Parent := Row;
  FSetBandwidth.SetBounds(632, 8, 160, 28);
  FSetBandwidth.Style := csDropDownList;
  for Choice := Low(TTunerBandwidth) to High(TTunerBandwidth) do
    FSetBandwidth.Items.Add(BandwidthCaption(Choice));
  FSetBandwidth.ItemIndex := 0;
  FSetBandwidth.OnChange := @RxConfirmSpeedChanged;

  FSetModel := AddPathEdit(Advanced, 'モデル (model.onnx)', LocateDataFile('model.onnx'));
  FSetMetadata := AddPathEdit(Advanced, 'メタデータ (model.onnx.json)',
    LocateDataFile('model.onnx.json'));
  FSetRuntime := AddPathEdit(Advanced, 'ONNX Runtime ライブラリ（空欄なら自動検索）', '');
  FSetPortAudio := AddPathEdit(Advanced, 'PortAudio ライブラリ（空欄なら自動検索）', '');

  { 不具合報告に添えられるように、まとめて写せるようにします（要件 FR-G.5）。
    **画面を撮って送るより、貼れるほうが正確です。**
    So that it can be attached to a bug report (requirement FR-G.5): **pasting
    is more accurate than sending a picture of the screen.** }
  Row := AddTopPanel(Advanced, 40);
  FSetCopyInfo := AddButton(Row, '診断情報をコピー', 12, 4, 180,
    @SetCopyInfoClick);
  AddLabel(Row,
    '受信した文章・交信記録の中身・待っている符号は入りません。' +
    'ファイルの場所の利用者名は ~ に置き換えます。', 200, 12);

  AddTopLabel(Advanced, '診断情報');
  FSetInfo := TMemo.Create(Advanced);
  FSetInfo.Parent := Advanced;
  FSetInfo.ReadOnly := True;
  FSetInfo.ScrollBars := ssAutoBoth;
  FSetInfo.WordWrap := False;
  FSetInfo.Font.Name := 'Monospace';
  Stretch(FSetInfo, alClient);
end;

{ ---- settings ---- }

function TMainForm.ConfigFileName: string;
begin
  Result := GetAppConfigFile(False);
end;

procedure TMainForm.LoadSettings;
var
  Ini: TIniFile;
  Rate: string;
  Index: Integer;
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
    FFtTrendKeyWanted := Ini.ReadString('fist', 'trend_key', '');
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
      Ini.WriteInteger('receive', 'confirm_speed', FRxConfirmSpeed.ItemIndex);
      Ini.WriteBool('receive', 'anti_alias', FRxAntiAlias.Checked);
      Ini.WriteBool('receive', 'show_doubt', FRxShowDoubt.Checked);
      Ini.WriteBool('receive', 'align_characters', FRxAlign.Checked);
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
        Ini.WriteString('fist', 'trend_key',
          FFtTrendKey.Items[FFtTrendKey.ItemIndex])
      else
        Ini.WriteString('fist', 'trend_key', '');
      Ini.WriteInteger('receive', 'mode', FRxMode.ItemIndex);
      Ini.WriteString('receive', 'watch', FRxWatch.Text);
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
      LogDiagnostic('設定の保存', E.Message);
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
  FreeAndNil(FMulti);
  FreeAndNil(FDecoder);
  FEngineError := '';
  UnloadOnnxRuntime;
  EnsureDecoder;
  RefreshInfo;
end;

procedure TMainForm.RefreshInfo;
var
  Lines: TStringList;
  I, Device: Integer;
  Alphabet: string;
begin
  Lines := TStringList.Create;
  try
    if FDecoder <> nil then
    begin
      Lines.Add('エンジン: 読み込み済み');
      Lines.Add(Format('ONNX Runtime: %s (%s)', [OnnxRuntimeVersion, OnnxRuntimeLibraryPath]));
      Lines.Add(Format('サンプリング周波数: %d Hz', [FDecoder.Metadata.SampleRate]));
      Lines.Add(Format('FFT 長 / ホップ長: %d / %d',
        [FDecoder.Metadata.FFTLength, FDecoder.Metadata.HopLength]));
      Lines.Add(Format('周波数帯: %.0f - %.0f Hz (%d ビン)',
        [FDecoder.Metadata.MinFreqHz, FDecoder.Metadata.MaxFreqHz,
         FDecoder.Metadata.FrequencyBins]));
      Lines.Add(Format('入力 / 出力: %s / %s',
        [FDecoder.Metadata.InputName, FDecoder.Metadata.OutputName]));
      Alphabet := '';
      for I := 0 to FDecoder.Metadata.CharCount - 1 do
        Alphabet := Alphabet + FDecoder.Metadata.Chars[I];
      Lines.Add(Format('文字集合 (%d): %s', [FDecoder.Metadata.CharCount, Alphabet]));
      Lines.Add(Format('音声長の制約: %.0f - %.0f 秒（長い録音は自動的に分割）',
        [DEEPCW_MIN_SECONDS, DEEPCW_MAX_SECONDS]));
    end
    else
    begin
      Lines.Add('エンジン: 未読み込み');
      if FEngineError <> '' then
        Lines.Add(FEngineError);
    end;

    Lines.Add('');
    if LoadPortAudio(FSetPortAudio.Text) then
      Lines.Add(Format('PortAudio: %s (%s)', [PortAudioVersion, PortAudioLibraryPath]))
    else
    begin
      Lines.Add('PortAudio: 利用不可（送信の再生とマイク受信は使えません）');
      Lines.Add(PortAudioLoadError);
    end;
    Lines.Add('');
    if FStream <> nil then
    begin
      Lines.Add(Format('未解析の音声: %.1f 秒', [FStream.PendingSeconds]));
      { 実時間比と、いま守っている解析の間隔（要件 FR-G.4・FR-G.3）。
        **どちらも、遅い機械で何が起きているのかを説明する数字です。**
        The real-time ratio and the interval now kept (FR-G.4, FR-G.3): **the
        two numbers that explain what is happening on a slow machine.** }
      if FStream.RealTimeRatio > 0 then
        Lines.Add(Format('解析 1 回: %.2f 秒 / 実時間比 %.0f 倍 / 推論間隔 %.2f 秒',
          [FStream.StepCostSeconds, FStream.RealTimeRatio,
           FStream.PaceSeconds]));
      { 追いつけずに捨てた分は、黙って消えてはいけません。読めなかった理由が
        そこにあるかもしれないからです（要件 NFR-4、FR-G.3）。
        Audio dropped through falling behind must not vanish silently: it may
        be why something was not read (requirements NFR-4, FR-G.3). }
      if FStream.DroppedSeconds > 0 then
        Lines.Add(Format('追いつけずに捨てた音声: %.1f 秒', [FStream.DroppedSeconds]));
    end;
    if FJournal <> nil then
    begin
      if not FSetJournal.Checked then
        Lines.Add('受信テキストの記録: 取っていません')
      else if FJournal.FileName = '' then
        Lines.Add('受信テキストの記録: ' + JournalDirectory + '（まだ書いていません）')
      else
        Lines.Add(Format('受信テキストの記録: %s（%d 行 / %d バイト）',
          [FJournal.FileName, FJournal.LinesWritten, FJournal.BytesWritten]));
      if FJournal.LastError <> '' then
        Lines.Add('  ' + FJournal.LastError);
    end;
    if FLog <> nil then
    begin
      Lines.Add(Format('交信記録: %d 件（%s）', [FLog.Count, FLog.FileName]));
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
      Lines.Add(Format('聴き直せる音声: %.0f 秒 / 保持の上限 %.0f 分（約 %.0f MB）',
        [FHistory.RetainedSeconds, FHistory.RetentionSeconds / 60,
         FHistory.RetentionSeconds * FHistory.SampleRate * SizeOf(Single) / (1024 * 1024)]));
    if Length(FDevices) = 0 then
      Lines.Add('入力装置: 見つかりません')
    else
      for Device := 0 to High(FDevices) do
        Lines.Add(Format('入力装置 %d: %s [%s] %d ch / %.0f Hz%s',
          [FDevices[Device].Index, FDevices[Device].Name, FDevices[Device].HostApi,
           FDevices[Device].MaxInputChannels, FDevices[Device].DefaultSampleRate,
           BoolToStr(FDevices[Device].IsDefault, '  ← 既定', '')]));

    Lines.Add('');
    Lines.Add('設定ファイル: ' + ConfigFileName);
    if (FDiagnostics <> nil) and (FDiagnostics.Count > 0) then
    begin
      Lines.Add('');
      Lines.Add('診断情報（技術的な原文）');
      Lines.AddStrings(FDiagnostics);
    end;
    FSetInfo.Lines.Assign(Lines);
  finally
    Lines.Free;
  end;

  if FDecoder <> nil then
    SetStatus('エンジン: ONNX Runtime ' + OnnxRuntimeVersion, '', '')
  else
    SetStatus('エンジン: 未読み込み', '', '');
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
        LogDiagnostic('エンジンの読み込み', E.Message);
        SetStatus('エンジン: 未読み込み', '',
          StatusLine(E.Message));
      end
      else
        ReportError('エンジンの読み込み', E);
      Result := False;
    end;
  end;
end;

function TMainForm.DecoderBusy: Boolean;
begin
  Result := FDecodeThread <> nil;
end;

{ ファイルからの復号も、流し込み受信とまったく同じ整形を通します。同調して
  いれば録音済みの音声にも効きます。戻り値はモデルの周波数になっているため、
  呼び出し側はモデルの周波数を渡します。

  File decoding goes through exactly the same preparation as streaming
  reception, so a tuning applies to recordings too. The result is already at
  the model's rate, which is what the caller then passes on. }
function TMainForm.PrepareForDecoder(const Samples: TSingleArray;
  SampleRate: Integer): TSingleArray;
begin
  Result := DeepCW.Tuner.PrepareForModel(Samples, SampleRate,
    FDecoder.Metadata.SampleRate, FRxWaterfall.TuneHz, SelectedBandwidth,
    FRxAntiAlias.Checked);
end;

procedure TMainForm.StartDecode(const Samples: TSingleArray; SampleRate: Integer);
begin
  if DecoderBusy or not EnsureDecoder then
    Exit;
  FRxBusy.Caption := 'デコード中...';
  FDecodeThread := TDecodeThread.Create(FDecoder, Samples, SampleRate, @DecodeFinished);
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
      LogDiagnostic('送信訓練の採点', Thread.Error);
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
      LogDiagnostic('語の読み直し', Thread.Error);
      SetStatus('', '', StatusLine(Thread.Error));
    end
    else
      ShowRecheck(Thread.Chars);
    FCompletedThread := Thread;
    Exit;
  end;

  if Thread.Error <> '' then
  begin
    LogDiagnostic('デコード', Thread.Error);
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
      FRxTranscript.PendingFrom := MaxInt;
      FRxTranscript.SetChars(FLiveChars);
      ReadTranscript;
      SetStatus('', '', Format('デコード完了: %d 文字', [Length(Thread.Chars)]));
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
        LogDiagnostic('受信の終了', E.Message);
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
  RenderTransmit;
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
    FTxSummary.Caption := Format('%d 文字 / %.1f 秒',
      [Length(FTxNormalized), Length(FTxSamples) / FTxSampleRate]);
  except
    on E: Exception do
    begin
      FTxSegments := nil;
      FTxSamples := nil;
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
    SetStatus('', '', '送信できる文字がありません。');
    Exit;
  end;
  try
    if not LoadPortAudio(FSetPortAudio.Text) then
      raise EDeepCW.Create(PortAudioLoadError);
    FPlayback.Play(FTxSamples, FTxSampleRate);
    FTxPlaying := True;
    SetStatus('', '', '送信中');
  except
    on E: Exception do
      ReportError('送信', E);
  end;
end;

procedure TMainForm.TxStopClick(Sender: TObject);
begin
  FPlayback.Stop;
  FTxPlaying := False;
  FTxProgress.Position := 0;
  FTxCurrentChar.Caption := '-';
  FTxCurrentCode.Caption := '';
  SetStatus('', '', '送信を停止しました。');
end;

procedure TMainForm.TxSaveClick(Sender: TObject);
var
  Dialog: TSaveDialog;
begin
  if Length(FTxSamples) = 0 then
    Exit;
  Dialog := TSaveDialog.Create(Self);
  try
    Dialog.Title := 'モールス音声を保存';
    Dialog.Filter := 'WAV ファイル|*.wav';
    Dialog.DefaultExt := 'wav';
    Dialog.FileName := 'morse.wav';
    if not Dialog.Execute then
      Exit;
    try
      SaveWavMono(Dialog.FileName, FTxSamples, FTxSampleRate);
      SetStatus('', '', '保存しました: ' + Dialog.FileName);
    except
      on E: Exception do
        ReportError('WAV の保存', E);
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
        LogDiagnostic('再生', FPlayback.LastError);
        SetStatus('', '', StatusLine(FPlayback.LastError));
      end
      else
        SetStatus('', '', '送信完了');
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
    Dialog.Title := 'モールス音声を開く';
    Dialog.Filter := 'WAV ファイル|*.wav|すべてのファイル|*.*';
    if Dialog.Execute then
      FRxFile.Text := Dialog.FileName;
  finally
    Dialog.Free;
  end;
end;

procedure TMainForm.RxDecodeFileClick(Sender: TObject);
var
  Samples: TSingleArray;
  SampleRate: Integer;
begin
  if DecoderBusy then
    Exit;
  try
    LoadWavMono(FRxFile.Text, Samples, SampleRate);
  except
    on E: Exception do
    begin
      ReportError('WAV の読み込み', E);
      Exit;
    end;
  end;

  RxStopClick(nil);
  { 整形にモデルの標本化周波数が要るため、先にエンジンを用意します。
    The preparation needs the model's sample rate, so the engine comes first. }
  if not EnsureDecoder then
    Exit;
  FLiveChars := nil;
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
  FHistory.Clear;
  { ファイルの音そのものを保管します。これで、ファイルから読んだ文字も押せば
    聴き直せます。保持時間より長いファイルは、後ろのぶんだけが残ります。
    The file's own audio is stored, so characters read from a file can be
    replayed too. A file longer than the retention keeps only its tail. }
  FHistory.Append(Samples, SampleRate, 0);
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
  FRxWaterfall.PushSamples(Samples, SampleRate, 0);
  UpdateReplayInfo;
  { 待機モードでは、録音も帯域として読みます。混み合ったバンドを録った音から
    一覧を作れますし、**音声装置の無い機械でもこの経路を確かめられます。**
    In the waiting mode a recording is read as a band: a list can be built from a
    recording of a crowded band, and **the path can be checked on a machine with
    no sound hardware.** }
  if BandMode then
  begin
    if FMulti = nil then
      FMulti := TMultiStationDecoder.Create(FDecoder);
    FRxBusy.Caption := 'デコード中...';
    FDecodeThread := TDecodeThread.CreateMultiFile(FMulti, Samples, SampleRate,
      @DecodeFinished);
    Exit;
  end;
  StartDecode(PrepareForDecoder(Samples, SampleRate),
    FDecoder.Metadata.SampleRate);
end;

procedure TMainForm.RxStartClick(Sender: TObject);
begin
  if FCapture <> nil then
    Exit;
  { 送信訓練が同じ入力を握っています。**両方が同じ装置を開こうとすると、
    開けないか、どちらが何を測っているのか分からなくなります。**
    Send practice holds the same input. **Both opening the one device would
    either fail or leave it unclear which is measuring what.** }
  if FFtCapture <> nil then
  begin
    SetStatus('', '', '送信訓練の最中です。先に「終了して採点」を押してください。');
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

    FCapture := TAudioCapture.Create(FRing, FCaptureRate, SelectedDeviceIndex);
    FCapture.Start;
    { 音の細かさが変わればウォーターフォールの目盛りも変わります。溜まって
      いた絵は意味を失うので消します。
      A change of capture rate changes the waterfall's scale, so whatever is
      already drawn no longer means anything and is cleared. }
    FRxWaterfall.Clear;
    FRxWaterfall.Message_ := '信号を待っています。読みたい信号が見えたらクリックしてください。';
    { 「録音」はファイルへ残すこと（要件 FR-E.8）に使う語なので、取り込んで
      いる状態は「受信中」と言います。**1 つの語に 2 つの意味を持たせると、
      録音していないのに録音中と読めます。**
      "Recording" is the word for keeping a file (requirement FR-E.8), so
      capturing is called receiving: **one word with two meanings would read as
      recording when nothing is being recorded.** }
    SetStatus('', Format('受信中 %d Hz', [FCaptureRate]), '受信を開始しました。');
    if FSetRecord.Checked then
      StartRecording;
  except
    on E: Exception do
    begin
      FreeAndNil(FCapture);
      ReportError('受信の開始', E);
    end;
  end;
end;

procedure TMainForm.RxStopClick(Sender: TObject);
begin
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
          LogDiagnostic('受信の終了', E.Message);
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
        LogDiagnostic('受信の終了', E.Message);
    end;
  if FJournal <> nil then
    FJournal.Flush;
  SetStatus('', '待機中', '受信を停止しました。');
end;

procedure TMainForm.RxClearClick(Sender: TObject);
begin
  FLiveChars := nil;
  { 消した受信文の添字は、もう何も指しません。頼まれていた読み直しは捨てます。
    An index into a cleared transcript points at nothing; a re-reading that was
    asked for is dropped. }
  FRecheckPending := False;
  ReadTranscript;
  FAlerts.Reset;
  if FStream <> nil then
    FStream.Reset;
  if FMulti <> nil then
    FMulti.Reset;
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
  SetStatus('', '', Format('受信テキスト %d 文字をコピーしました。',
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
  SetStatus('', '', Latest + ' を読みました。');
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
    SetStatus('', '', Format('%s をコピーしました。', [Sent]))
  else
    SetStatus('', '', Format('%s をコピーしました（RST は聞こえていません）。',
      [Sent]));
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
function TMainForm.SelectedBand: string;
const
  { 選択肢の並びと同じ順です。ADIF の名前をそのまま使います。
    In the same order as the choices, using ADIF's own names. }
  NAMES: array[0..9] of string = ('', '160M', '80M', '40M', '20M', '15M',
    '10M', '6M', '2M', '70CM');
begin
  if (FRxBand = nil) or (FRxBand.ItemIndex < Low(NAMES)) or
     (FRxBand.ItemIndex > High(NAMES)) then
    Exit('');
  Result := NAMES[FRxBand.ItemIndex];
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
  Result := FLog.WorkedCountOn(Callsign, SelectedBand) > 0;
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
  FRxRate.Caption := Format('直近 1 時間: %d 局 ／ 記録全体: %d 局',
    [Hour, Total]);
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
    Note := '（1 回だけ）';
  if Call = '' then
    FRxLogInfo.Caption := '相手の符号が読めたら記録できます'
  else if WorkedBefore(Call) then
    { 日付も同じバンドから採ります。回数だけをバンドごとに答えて日付を全体から
      採ると、そのバンドで交信していない日付を「交信済み」の証拠として示します。
      The date comes from the same band: answering the count band by band while
      taking the date from every band would offer, as the evidence of a duplicate,
      a date on which that band was not worked. }
    FRxLogInfo.Caption := Format('%s%s（%s に交信済み）',
      [Call, Note, FLog.LastWorkedOn(Call, SelectedBand)])
  else
    FRxLogInfo.Caption := Call + Note;
  if FSetLogInfo <> nil then
    FSetLogInfo.Caption := Format('%d 件 / %s', [FLog.Count, FLog.FileName]);
end;

{ 交信を 1 件記録します（要件 FR-E.3）。時刻は協定世界時で持ちます。ADIF の
  QSO_DATE と TIME_ON はいずれも協定世界時と決まっており、地方時で書くと、
  読み込んだログソフトが別の時刻として扱います。

  Records one contact (requirement FR-E.3). The times are UTC: ADIF defines
  QSO_DATE and TIME_ON as UTC, and writing local time would have the logger that
  reads it treat them as a different moment. }
procedure TMainForm.RxWorkedClick(Sender: TObject);
var
  Item: TAdifRecord;
  Call: string;
  Moment: TDateTime;
begin
  Call := CallsignToLog;
  if Call = '' then
    Exit;
  { 地方時を協定世界時へ直してから渡します。ADIF はこの 2 つの欄を協定世界時と
    定めており、地方時のまま書くと、読み込んだログソフトが別の時刻として扱います。
    The local time is converted to UTC before it is handed over: ADIF defines
    these two fields as UTC, and left local the logger that reads them would
    treat them as a different moment. }
  Moment := LocalTimeToUniversal(Now);
  Item := BuildContact(Call, Moment, 'CW', SelectedBand);
  if not FLog.Add(Item) then
  begin
    LogDiagnostic('交信記録', FLog.LastError);
    SetStatus('', '', StatusLine(FLog.LastError));
    Exit;
  end;
  { 記録したら、指し示していた符号は用済みです。持ち越すと、次の局を読み始めても
    記録の候補が前の相手のままになります。
    Once recorded, the pointed-at call sign has served its purpose; carried over,
    the candidate to log would stay the previous station even as the next one
    starts coming in. }
  FChosenCallsign := '';
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
  if SelectedBand <> '' then
    SetStatus('', '', Format('%s との交信を %s で記録しました（%s UTC）。',
      [Call, FRxBand.Text, FormatDateTime('yyyy-mm-dd hh":"nn', Moment)]))
  else
    SetStatus('', '', Format('%s との交信を記録しました（%s UTC）。',
      [Call, FormatDateTime('yyyy-mm-dd hh":"nn', Moment)]));
end;

procedure TMainForm.SetLogImportClick(Sender: TObject);
var
  Dialog: TOpenDialog;
  Added, Skipped: Integer;
begin
  Dialog := TOpenDialog.Create(Self);
  try
    Dialog.Title := '交信記録（ADIF）を取り込む';
    Dialog.Filter := 'ADIF (*.adi;*.adif)|*.adi;*.adif|すべて (*.*)|*.*';
    if not Dialog.Execute then
      Exit;
    if not FLog.ImportAdif(Dialog.FileName, Added, Skipped) then
    begin
      LogDiagnostic('交信記録', FLog.LastError);
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
    SetStatus('', '', Format('%d 件を取り込みました（既にある %d 件は飛ばしました）。',
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
    Dialog.Title := '交信記録（ADIF）を書き出す';
    Dialog.Filter := 'ADIF (*.adi)|*.adi|すべて (*.*)|*.*';
    Dialog.DefaultExt := 'adi';
    Dialog.FileName := 'contacts.adi';
    if not Dialog.Execute then
      Exit;
    if not FLog.ExportAdif(Dialog.FileName) then
    begin
      LogDiagnostic('交信記録', FLog.LastError);
      SetStatus('', '', StatusLine(FLog.LastError));
      Exit;
    end;
    SetStatus('', '', Format('%d 件を %s へ書き出しました。',
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
    SetStatus('', '', 'コンテストモードにしました。交信済みの局を隠せます。' +
      '得点計算は行いません。')
  else if FMode = rmWatch then
    SetStatus('', '', '待機モードにしました。帯域内の局を一覧に出します。' +
      '受信文は改めて取り直します。')
  else
    SetStatus('', '', '交信モードにしました。選んだ 1 局を読みます。' +
      '受信文は改めて取り直します。');
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
        Evidence := Format('（%s にあり＝実在は確かです）',
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
  SetStatus('', '', Format('%.0f Hz の局に同調し、交信モードへ移りました。%s%s',
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
    FRxWatchInfo.Caption :=
      '符号を書くと、その局が聞こえたときに知らせます'
  else if Kept < Given then
    { 形にならない符号を黙って捨てると、いつまでも知らせが来ない理由が分かりません。
      Dropping a malformed call sign silently leaves no way to tell why nothing is
      ever announced. }
    FRxWatchInfo.Caption := Format(
      '%d 局を待っています（%d 件は呼出符号の形になっていません）',
      [Kept, Given - Kept])
  else
    FRxWatchInfo.Caption := Format('%d 局を待っています', [Kept]);
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
        Found := Found + '、';
      Found := Found + Format('%s（%.0f Hz）',
        [FBandEntries[I].Callsign, FBandEntries[I].Hz]);
    end;
  if Found <> '' then
    SetStatus('', '', Format('待っていた %s が出ています。', [Found]));
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
    @WorkedBefore, @WatchedCall);
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
    FRxFindInfo.Caption := '見つかりません'
  else
    FRxFindInfo.Caption := Format('%d / %d 件',
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
    LogDiagnostic('録音', FRecorder.LastError);
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
  SetStatus('', '', '録音を始めました: ' + Path);
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
    SetStatus('', '', Format('%s録音は残していません（音が届きませんでした）。',
      [Why]));
    Exit;
  end;
  Lost := '';
  if Status.Lost > 0 then
    { 取りこぼしは黙って飲み込みません（教訓 10.1）。**穴の空いた録音を、
      無傷の録音と同じ顔で渡さないためです。**
      Dropped audio is not swallowed in silence (lesson 10.1): **a recording with
      a hole in it must not be handed over wearing the face of a whole one.** }
    Lost := Format('（%.1f 秒を取りこぼしました）', [Status.Lost / FCaptureRate]);
  SetStatus('', '', Format('%s録音を終えました: %s（%s）%s',
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
  SetRecordStatus(Format('録音 %s（%.1f MB）',
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
  FSetRecordInfo.Caption := Format(
    '受信と同時に %s へ書きます。上限は %.0f 時間で、そこで止めて知らせます。',
    [RecordingDirectory, RECORD_MAX_SECONDS / 3600]);
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
    SetStatus('', '', Format('受信テキストを %s に記録します。',
      [JournalDirectory]))
  else
    SetStatus('', '', '受信テキストの記録を止めました。');
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
    LogDiagnostic('記録', FJournal.LastError);
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
  SetStatus('', '', Format(
    '聴き直せる長さを %d 分にしました。それまでに保管していた音は消えました。',
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
    FRxReplayInfo.Caption := '文字を押すと、その音を聴き直せます。'
  else
    FRxReplayInfo.Caption := Format(
      '文字を押すと、その音を聴き直せます（直近 %d 分 %d 秒を保管中）。',
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
    FRxReplayInfo.Caption := 'この部分の音はもう残っていません。';
    { なぜ残っていないのかで案内を分けます。「設定を延ばせば遡れる」と言って
      よいのは、保持時間の外へ出た場合だけです。
      The guidance depends on why it is gone: telling the operator that a longer
      retention would reach it is only true when it fell off the far end. }
    if FromSeconds < FHistory.EarliestSeconds then
      SetStatus('', '', Format(
        'この部分の音は保管の範囲（直近 %d 分）から出ています。' +
        '設定タブの「聴き直せる長さ」を延ばすと、より前まで遡れます。',
        [Round(SelectedRetention / 60)]))
    else
      SetStatus('', '', 'この部分の音は保管していません。' +
        '受信テキストを消したか、録音の設定を変えたあとの文字です。');
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
    LogDiagnostic('聴き直し', FReviewPlay.LastError);
    SetStatus('', '', StatusLine(FReviewPlay.LastError));
    Exit;
  end;
  FRxReplayStop.Enabled := True;
  FRxReplayInfo.Caption := Format('%s：受信開始から %d 分 %d 秒の音（%.1f 秒）',
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
  Prepared := PrepareForDecoder(Audio, Rate);
  FRecheckSent := FRecheckWord;
  FRecheckSentAt := FRecheckAt;
  FRxBusy.Caption := '読み直し中...';
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
    LogDiagnostic('語の読み直し',
      Format('%d ms (target 1000 ms): %d 文字', [Elapsed, Length(FRecheckSent)]));
  { 出す場所は状態表示の案内欄です。**聴き直しの欄は、既定の窓の幅では右端の
    外にあって見えません。**見えない場所に答えを書くのは、答えないのと同じです。
    It goes in the status bar's guidance panel: **the replay label sits beyond
    the right edge at the default window width and cannot be read.** An answer
    written where it cannot be seen is not an answer. }
  if Again = '' then
    SetStatus('', '', Format(
      '読み直すと、この区間からは何も読めませんでした（画面は %s）。',
      [FRecheckSent]))
  else if Again = FRecheckSent then
    SetStatus('', '', Format('読み直しても %s でした。', [FRecheckSent]))
  else
    SetStatus('', '', Format('読み直すと %s（画面は %s）。',
      [Again, FRecheckSent]));
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
begin
  if FRxWaterfall = nil then
    Exit;
  if FRxWaterfall.TuneHz > 0 then
  begin
    Half := BandwidthHalfWidth(SelectedBandwidth);
    if Half > 0 then
      FRxTuneInfo.Caption := Format('同調: %.0f Hz ／ 帯域 ±%.0f Hz',
        [FRxWaterfall.TuneHz, Half])
    else
      FRxTuneInfo.Caption := Format('同調: %.0f Hz ／ 帯域制限なし',
        [FRxWaterfall.TuneHz]);
    FRxWaterfall.HalfWidthHz := Half;
  end
  else
  begin
    FRxTuneInfo.Caption := '同調: なし（受信機の音程のまま）';
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
    SetStatus('', '', '鳴らせる音がまだありません。受信を始めてからお試しください。');
    Exit;
  end;
  Prepared := PrepareForDecoder(Audio, Rate);
  if Length(Prepared) = 0 then
  begin
    SetStatus('', '', '復調音を作れませんでした。');
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
    LogDiagnostic('復調音', FReviewPlay.LastError);
    SetStatus('', '', StatusLine(FReviewPlay.LastError));
    Exit;
  end;
  FRxReplayStop.Enabled := True;
  { 何を鳴らしているのかを言います。**「もう一度聴く」と同じ音だと思われると、
    聴き比べの意味が無くなります。**
    What is sounding is said: **mistaken for the same audio as "listen again",
    the comparison would lose its point.** }
  if FRxWaterfall.TuneHz > 0 then
    SetStatus('', '', Format(
      'デコーダが聴いている音を %.1f 秒鳴らしています（%.0f Hz を %.0f Hz へ寄せ、帯域 ±%.0f Hz）。',
      [GotTo - GotFrom, FRxWaterfall.TuneHz, TUNER_TARGET_TONE_HZ,
       BandwidthHalfWidth(SelectedBandwidth)]))
  else
    SetStatus('', '', Format(
      'デコーダが聴いている音を %.1f 秒鳴らしています（同調していないので、受信機の音程のままです）。',
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
    SetStatus('', '', Format(
      '%.0f Hz に寄せました。受信機の音程を %.0f〜%.0f Hz にしてください。',
      [Tuned, FRxWaterfall.LowestHz, FRxWaterfall.HighestHz]))
  else if Tuned > 0 then
    SetStatus('', '', Format('%.0f Hz の信号に同調しました。', [Tuned]))
  else
    SetStatus('', '', '同調を解除しました。受信機の音程のまま読みます。');
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
    FRxDevice.Items.Add('既定の装置（おまかせ）');
    Choice := 0;
    for I := 0 to High(FDevices) do
    begin
      Caption_ := FDevices[I].Name;
      if FDevices[I].HostApi <> '' then
        Caption_ := Caption_ + '  [' + FDevices[I].HostApi + ']';
      if FDevices[I].IsDefault then
        Caption_ := Caption_ + '  ← 既定';
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
    FRxDevice.Items[0] := '既定の装置（一覧を取得できません）';
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
    SetStatus('', '', '録音に使える装置が見つかりませんでした。接続と OS 側の設定を確認してください。')
  else
    SetStatus('', '', Format('入力装置を %d 台見つけました。', [Length(FDevices)]));
end;

procedure TMainForm.RxConfirmSpeedChanged(Sender: TObject);
begin
  ApplyStreamSettings;
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
  Fresh: TSingleArray;
  Failure: string;
  Peak: Single;
  StartAt: Double;
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
    LogDiagnostic('取り込み', Failure);
    { 止めてから案内を出します。RxStopClick は「受信を停止しました」を出すため、
      順序が逆だと、なぜ止まったのかという肝心の説明が上書きされて消えます。

      Stop first, then explain: RxStopClick posts "reception stopped", so the
      other order would overwrite the one message that says why it stopped. }
    RxStopClick(nil);
    SetStatus('', '', StatusLine(Failure));
    Exit;
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
    FRxSignal.Caption := '音が届いています'
  else
    FRxSignal.Caption := '無音です';

  { 録音された分をそのまま流し込みます。窓を切り出すのではなく、確定点から
    先を溜め続けるのが流し込み受信です（要件 FR-B.2）。
    Feed everything captured. Streaming keeps the audio since the last split
    point rather than cutting fixed windows. }
  if not FRing.ReadSince(FRingPosition, Fresh) then
    LogDiagnostic('受信', 'Audio was dropped: the decoder fell behind the ring buffer.');
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
    if FMode = rmWatch then
      FMulti.Append(Fresh, FCaptureRate)
    else
      FStream.Append(Fresh, FCaptureRate);
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
    FRxBusy.Caption := 'デコード中...';
    FDecodeThread := TDecodeThread.CreateMulti(FMulti, @DecodeFinished);
    Exit;
  end;

  if not FStream.Ready then
    Exit;
  FAppendMode := True;
  FRxBusy.Caption := 'デコード中...';
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
    SetStatus('', '', Format(
      'この機械では解析が追いつきにくいため、確定の間隔を %.0f 秒に緩めています' +
      '（実時間比 %.1f 倍）。読み落としはしません。',
      [FStream.PaceSeconds, FStream.RealTimeRatio]));
  end;
  { 訓練中は、経過した時間を出します。**押しっぱなしで席を立った人が、
    戻ってきて分かるようにするためです。**
    While training, the time so far is shown: **so that someone who left the
    room can see what happened when they come back.** }
  if (FFtCapture <> nil) and (FFtStatus <> nil) then
    FFtStatus.Caption := Format('訓練中 %s。終わったら「終了して採点」を押してください。',
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
  FRxStop.Enabled := FCapture <> nil;
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
    Result := '音声ライブラリ PortAudio を利用できません。' + LineEnding +
      '同梱されていない場合は、設定タブでライブラリの場所を指定してください。' + LineEnding +
      'WAV ファイルの読み書きは、この状態でも利用できます。'
  else if Mentions('input stream') then
    Result := 'マイク（ライン入力）を開けませんでした。' + LineEnding +
      '別の入力装置を選ぶか、他のアプリが装置を使用していないか確認してください。'
  else if Mentions('output stream') then
    Result := '再生装置を開けませんでした。' + LineEnding +
      '別の出力装置を選ぶか、他のアプリが装置を使用していないか確認してください。'
  else if Mentions('Could not load the ONNX Runtime') then
    Result := '推論ライブラリ ONNX Runtime を読み込めませんでした。' + LineEnding +
      '設定タブでライブラリの場所を指定してください。' + LineEnding +
      '送信音の生成と WAV への保存は、この状態でも利用できます。'
  else if Mentions('Model file not found') then
    Result := 'モデルファイル model.onnx が見つかりません。' + LineEnding +
      '設定タブで場所を指定してください。'
  else if Mentions('Metadata file not found') then
    Result := '設定ファイル model.onnx.json が見つかりません。' + LineEnding +
      '設定タブで場所を指定してください。'
  else if Mentions('Metadata expects') or Mentions('the metadata declares') or
          Mentions('the metadata names') or Mentions('num_classes') then
    Result := 'モデルと設定ファイルの組み合わせが正しくありません。' + LineEnding +
      '同じ配布物に入っている model.onnx と model.onnx.json を指定してください。'
  else if Mentions('RIFF') or Mentions('WAV') or Mentions('PCM') then
    Result := 'この音声ファイルを読み取れませんでした。' + LineEnding +
      'PCM 形式のモノラルまたはステレオの WAV ファイルをお使いください。'
  else if Mentions('must last between') then
    Result := '音声が短すぎます。もう少し長い録音でお試しください。'
  else
    Result := '問題が起きたため、処理を中止しました。' + LineEnding +
      '詳しい内容は設定タブの診断情報に記録しています。';
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
var
  Friendly: string;
begin
  Friendly := UserMessageFor(E.Message);
  LogDiagnostic(Context, E.Message);
  SetStatus('', '', Context + ': ' + StatusLine(E.Message));
  MessageDlg(Context + 'できませんでした', Friendly, mtError, [mbOK], 0);
end;

end.
