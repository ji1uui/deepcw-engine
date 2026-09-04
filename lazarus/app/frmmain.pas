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
  DeepCW.Morse, DeepCW.Decoder, DeepCW.Audio, DeepCW.Stream, DeepCW.Tuner,
  DeepCW.Review, DeepCW.Journal, DeepCW.Multi, DeepCW.BandMap,
  TranscriptView, WaterfallView, BandMapView;

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
    rmWatch);

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
    property Chars: TDecodedChars read FChars;
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
    FRxDoubtStrength: TTrackBar;
    FRxFontSize: TSpinEdit;
    FRxCopy: TButton;
    FRxLevel: TProgressBar;
    FRxSignal: TLabel;
    FRxDevice: TComboBox;
    FRxDeviceRefresh: TButton;
    FRxWaterfall: TWaterfallView;
    FRxBandMap: TBandMapView;
    FRxMode: TComboBox;
    FRxTuneInfo: TLabel;
    FRxTuneClear: TButton;
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
    FSetApply: TButton;
    FSetInfo: TMemo;

    procedure BuildUI;
    function BuildTransmitTab: TTabSheet;
    function BuildReceiveTab: TTabSheet;
    function BuildSettingsTab: TTabSheet;

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
    procedure JournalConfirmed;

    { 聴き直し（要件 FR-E.10） / replay (requirement FR-E.10) }
    procedure RxCharChosen(Sender: TObject; Index: Integer);
    procedure RxReplayClick(Sender: TObject);
    procedure RxReplayStopClick(Sender: TObject);
    procedure RxRetentionChanged(Sender: TObject);
    procedure ReplayFrom(Index: Integer);
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
  FHistory := TAudioHistory.Create(REVIEW_DEFAULT_SECONDS, FCaptureRate);
  FJournal := TTranscriptJournal.Create(JournalDirectory);
  FMode := rmContact;

  BuildUI;
  LoadSettings;
  { ステータスバーと設定タブに有用な情報を出すため、モデルは起動時に読み込み
    ます。ただしランタイムが無くても起動は妨げません。

    Load the model up front so the status bar and the settings tab say
    something useful, but never block startup on a missing runtime. }
  { 読み込んだ表示設定を実際に反映します。設定は代入だけでは効きません。
    Apply the loaded display settings; assigning the controls is not enough. }
  RxDisplayChanged(nil);
  FRxMode.OnChange := @RxModeChanged;
  { 読み込んだ保持時間を保管庫へ反映します。設定を読むだけでは効きません。
    Apply the retention that was loaded; reading the setting is not enough. }
  FHistory.SetRetention(SelectedRetention);
  UpdateReplayInfo;
  { 読み込んだ設定を記録へも反映します。控えるだけでは効きません。
    Apply the loaded setting to the journal too; holding it in a control is not
    enough. }
  FJournal.Enabled := FSetJournal.Checked;
  { 読み込んだモードを画面へ反映します。控えるだけでは効きません。
    Apply the mode that was loaded; holding it in a control is not enough. }
  if FRxMode.ItemIndex = 1 then
    FMode := rmWatch
  else
    FMode := rmContact;
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
  FPlayback.Free;
  FReviewPlay.Free;
  { 書き残しを出してから解放します。閉じるときの 1 語は、記録として要ります。
    The remainder is written before releasing: the last word of a session
    belongs in the record. }
  if FJournal <> nil then
    FJournal.Flush;
  FJournal.Free;
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
  { 3 つ目には対処つきの案内が入るため、残りの幅をすべて与えます。切り詰められ
    ると「次に何をすればよいか」が読めなくなります（要件 FR-A.4）。

    The third panel carries guidance with a remedy in it, so it takes all the
    remaining width; truncating it would cut off what to do next
    (requirement FR-A.4). }
  FStatus.Panels.Add.Width := 4000;

  FPages := TPageControl.Create(Self);
  FPages.Parent := Self;
  FPages.Align := alClient;
  FPages.AddTabSheet.Free;      { 仮のシートを取り除きます / drop the placeholder sheet }
  BuildTransmitTab;
  BuildReceiveTab;
  BuildSettingsTab;
  { 起動直後の画面は受信です。ここから受信開始まで操作 1 回で届きます
    （要件 FR-A.2）。
    The window opens on the receive tab, one action away from starting
    reception (requirement FR-A.2). }
  FPages.PageIndex := 1;
  FPages.OnChange := @PagesChanged;

  FPollTimer := TTimer.Create(Self);
  FPollTimer.Interval := 200;
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
  FRxReplay := AddButton(FindTools, 'もう一度聴く', 396, 2, 110, @RxReplayClick);
  FRxReplay.Enabled := False;
  FRxReplayStop := AddButton(FindTools, '停止', 510, 2, 60, @RxReplayStopClick);
  FRxReplayStop.Enabled := False;
  FRxReplayInfo := TLabel.Create(FindTools);
  FRxReplayInfo.Parent := FindTools;
  FRxReplayInfo.SetBounds(580, 9, 400, 20);
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
  FRxBandMap := TBandMapView.Create(TextPanel);
  FRxBandMap.Parent := TextPanel;
  FRxBandMap.OnStationChosen := @RxStationChosen;
  FRxBandMap.Visible := False;
  Stretch(FRxBandMap, alClient);
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
  Operating.Height := 152;
  Operating.Caption := '運用設定';
  Stretch(Operating, alTop);

  AddLabel(Operating, '録音の細かさ', 14, 8);
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
  AddLabel(Operating, '受信機の音を取り込む細かさです。うまく録音できないときだけ変えてください。',
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
    FRxDoubtStrength.Position := ClampInt(
      Ini.ReadInteger('receive', 'doubt_strength', 100), 0, 100);
    FRxFontSize.Value := ClampInt(Ini.ReadInteger('receive', 'font_size', 14), 9, 32);
    FSetRetention.ItemIndex := ClampInt(Ini.ReadInteger('receive', 'retention', 1), 0, 3);
    FSetJournal.Checked := Ini.ReadBool('receive', 'journal', True);
    FRxMode.ItemIndex := ClampInt(Ini.ReadInteger('receive', 'mode', 0), 0, 1);
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
      Ini.WriteInteger('receive', 'doubt_strength', FRxDoubtStrength.Position);
      Ini.WriteInteger('receive', 'font_size', FRxFontSize.Value);
      Ini.WriteInteger('receive', 'tune_hz', Round(FRxWaterfall.TuneHz));
      Ini.WriteInteger('receive', 'bandwidth', FSetBandwidth.ItemIndex);
      Ini.WriteInteger('receive', 'retention', FSetRetention.ItemIndex);
      Ini.WriteBool('receive', 'journal', FSetJournal.Checked);
      Ini.WriteInteger('receive', 'mode', FRxMode.ItemIndex);
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

  if Thread.Error <> '' then
  begin
    LogDiagnostic('デコード', Thread.Error);
    SetStatus('', '', StatusLine(Thread.Error));
  end
  else if FMode = rmWatch then
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
      SetStatus('', '', Format('デコード完了: %d 文字', [Length(Thread.Chars)]));
    end;
  end;

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
      if FMode = rmWatch then
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
  UpdateReplayInfo;
  { 待機モードでは、録音も帯域として読みます。混み合ったバンドを録った音から
    一覧を作れますし、**音声装置の無い機械でもこの経路を確かめられます。**
    In the waiting mode a recording is read as a band: a list can be built from a
    recording of a crowded band, and **the path can be checked on a machine with
    no sound hardware.** }
  if FMode = rmWatch then
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
  if not EnsureDecoder then
    Exit;
  try
    if not LoadPortAudio(FSetPortAudio.Text) then
      raise EDeepCW.Create(PortAudioLoadError);

    FCaptureRate := SelectedCaptureRate;
    { 最長の窓の 2 倍を保持し、復号が遅れても次の窓が不足しないようにします。
    Hold twice the longest window so a slow decode never starves the next. }
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
    { 録音の細かさが変わればウォーターフォールの目盛りも変わります。溜まって
      いた絵は意味を失うので消します。
      A change of capture rate changes the waterfall's scale, so whatever is
      already drawn no longer means anything and is cleared. }
    FRxWaterfall.Clear;
    FRxWaterfall.Message_ := '信号を待っています。読みたい信号が見えたらクリックしてください。';
    SetStatus('', Format('録音中 %d Hz', [FCaptureRate]), '受信を開始しました。');
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
  if (FMode = rmWatch) and (FMulti <> nil) and not DecoderBusy then
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
  UpdateReplayInfo;
  UpdateFindInfo;
end;

procedure TMainForm.RxCopyClick(Sender: TObject);
begin
  Clipboard.AsText := FRxTranscript.AsText;
  SetStatus('', '', Format('受信テキスト %d 文字をコピーしました。',
    [FRxTranscript.CharCount]));
end;

{ ---- 受信のしかた（要件 FR-I.6・FR-J） ---- }

function TMainForm.ActiveElapsedSeconds: Double;
begin
  if (FMode = rmWatch) and (FMulti <> nil) then
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
  if FMode = rmWatch then
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
  FRxTranscript.Clear;
  FRxBandMap.Clear;

  FRxTranscript.Visible := FMode = rmContact;
  FRxBandMap.Visible := FMode = rmWatch;
  UpdateReplayInfo;
  UpdateFindInfo;
end;

procedure TMainForm.RxModeChanged(Sender: TObject);
begin
  if FRxMode.ItemIndex = 1 then
    FMode := rmWatch
  else
    FMode := rmContact;
  ApplyMode;
  MarkSettingsDirty;
  if FMode = rmWatch then
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
begin
  FRxWaterfall.TuneHz := Hz;
  FRxMode.ItemIndex := 0;
  FMode := rmContact;
  ApplyMode;
  if FStream <> nil then
    FStream.TuneHz := FRxWaterfall.TuneHz;
  UpdateTuneInfo;
  SetStatus('', '', Format('%.0f Hz の局に同調し、交信モードへ移りました。',
    [FRxWaterfall.TuneHz]));
end;

{ 一覧を作り直します。毎秒 1 回で足ります。局の並びが 0.2 秒ごとに変わる必要は
  なく、そのたびに全局の受信文を複製するのは無駄です。
  Rebuilds the list, once a second. The order of stations need not change five
  times a second, and copying every transcript that often would be waste. }
procedure TMainForm.RefreshBandMap;
begin
  if (FMulti = nil) or (FMode <> rmWatch) then
    Exit;
  if MilliSecondsBetween(Now, FBandMapAt) < 1000 then
    Exit;
  FBandMapAt := Now;
  FRxBandMap.SetEntries(
    BuildBandEntries(FMulti.Logs, FMulti.ElapsedSeconds),
    FMulti.ElapsedSeconds);
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
procedure TMainForm.ReplayFrom(Index: Integer);
var
  First, Last: Integer;
  Item: TDecodedChar;
  FromSeconds, ToSeconds, GotFrom, GotTo: Double;
  Audio: TSingleArray;
  Rate: Integer;
begin
  if (FHistory = nil) or (FReviewPlay = nil) then
    Exit;
  if not FRxTranscript.CharItem(Index, Item) then
    Exit;

  First := Index;
  while (First > 0) and FRxTranscript.CharItem(First - 1, Item) and
        (Item.Text <> ' ') do
    Dec(First);
  Last := Index;
  while FRxTranscript.CharItem(Last + 1, Item) and (Item.Text <> ' ') do
    Inc(Last);

  if not FRxTranscript.CharItem(First, Item) then
    Exit;
  FromSeconds := Item.Seconds - REVIEW_PAD_SECONDS;
  if not FRxTranscript.CharItem(Last, Item) then
    Exit;
  ToSeconds := Item.EndSeconds + REVIEW_PAD_SECONDS;

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

procedure TMainForm.RxCharChosen(Sender: TObject; Index: Integer);
begin
  ReplayFrom(Index);
  UpdateReplayInfo;
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
  if (FMode = rmWatch) and (FMulti = nil) then
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
    LogDiagnostic('録音', Failure);
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
    FRxWaterfall.PushSamples(Fresh, FCaptureRate);
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
  if FPages.PageIndex = 2 then
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
end;

procedure TMainForm.SetStatus(const Engine, Audio, Message_: string);
begin
  if Engine <> '' then
    FStatus.Panels[0].Text := Engine;
  if Audio <> '' then
    FStatus.Panels[1].Text := Audio;
  if Message_ <> '' then
    FStatus.Panels[2].Text := Message_;
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
    [FormatDateTime('hh:nn:ss', Now), Context, Raw]));
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
