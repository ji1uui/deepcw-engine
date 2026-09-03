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
  DeepCW.Types, DeepCW.Metadata, DeepCW.Dsp, DeepCW.Onnx, DeepCW.Wave,
  DeepCW.Morse, DeepCW.Decoder, DeepCW.Audio, DeepCW.Stream, DeepCW.Tuner,
  TranscriptView, WaterfallView;

type
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
    FSamples: TSingleArray;
    FSampleRate: Integer;
    FChars: TDecodedChars;
    FError: string;
    FSpectrogram: TSpectrogram;
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
    property Chars: TDecodedChars read FChars;
    property Error: string read FError;
    property Spectrogram: TSpectrogram read FSpectrogram;
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

    { 音声 / audio }
    FRing: TAudioRing;
    FCapture: TAudioCapture;
    FPlayback: TAudioPlayback;
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
    FRingPosition: Int64;

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
    FRxTuneInfo: TLabel;
    FRxTuneClear: TButton;
    FRxTrack: TCheckBox;
    FRxBusy: TLabel;

    { 設定タブ / settings tab }
    FSetModel: TEdit;
    FSetMetadata: TEdit;
    FSetRuntime: TEdit;
    FSetPortAudio: TEdit;
    FSetCaptureRate: TComboBox;
    FSetThreads: TComboBox;
    FSetBandwidth: TComboBox;
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

procedure TDecodeThread.Execute;
begin
  try
    if FStream <> nil then
      FStream.Step
    else
      FChars := FDecoder.DecodeLongSamplesTimed(FSamples, FSampleRate);
    FSpectrogram := FDecoder.LastSpectrogram;
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

  BuildUI;
  LoadSettings;
  { ステータスバーと設定タブに有用な情報を出すため、モデルは起動時に読み込み
    ます。ただしランタイムが無くても起動は妨げません。

    Load the model up front so the status bar and the settings tab say
    something useful, but never block startup on a missing runtime. }
  { 読み込んだ表示設定を実際に反映します。設定は代入だけでは効きません。
    Apply the loaded display settings; assigning the controls is not enough. }
  RxDisplayChanged(nil);
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
  LiveControls, LevelPanel, WaterfallPanel, TuneTools, TextPanel, TextTools: TPanel;
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

  FRxTranscript := TTranscriptView.Create(TextPanel);
  FRxTranscript.Parent := TextPanel;
  FRxTranscript.Font.Size := 14;
  Stretch(FRxTranscript, alClient);
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
  Operating.Height := 92;
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
  if (FStream <> nil) and not DecoderBusy then
  begin
    try
      FStream.Finish;
      ShowStreamText;
    except
      on E: Exception do
        LogDiagnostic('受信の終了', E.Message);
    end;
  end;
  SetStatus('', '待機中', '受信を停止しました。');
end;

procedure TMainForm.RxClearClick(Sender: TObject);
begin
  FLiveChars := nil;
  if FStream <> nil then
    FStream.Reset;
  FRxTranscript.Clear;
  FRxWaterfall.Clear;
end;

procedure TMainForm.RxCopyClick(Sender: TObject);
begin
  Clipboard.AsText := FRxTranscript.AsText;
  SetStatus('', '', Format('受信テキスト %d 文字をコピーしました。',
    [FRxTranscript.CharCount]));
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
end;

procedure TMainForm.UpdateLiveReceive;
var
  Fresh: TSingleArray;
  Failure: string;
  Peak: Single;
begin
  if (FCapture = nil) or (FStream = nil) then
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
    FStream.Append(Fresh, FCaptureRate);
    { ウォーターフォールには、同調も帯域制限も掛ける前の音を見せます。まだ
      選んでいない信号も見えていなければ、選びようがないためです。
      The waterfall is fed the audio before any tuning or filtering: a signal
      that has not been chosen yet still has to be visible to be chosen. }
    FRxWaterfall.PushSamples(Fresh, FCaptureRate);
  end;

  if DecoderBusy or not FStream.Ready then
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
