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
  SysUtils, Classes, Math, IniFiles, FPimage, IntfGraphics, GraphType,
  Forms, Controls, Graphics, Dialogs, StdCtrls, ExtCtrls, ComCtrls, Spin,
  DeepCW.Types, DeepCW.Metadata, DeepCW.Dsp, DeepCW.Onnx, DeepCW.Wave,
  DeepCW.Morse, DeepCW.Decoder, DeepCW.Audio;

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
    FSamples: TSingleArray;
    FSampleRate: Integer;
    FText: string;
    FError: string;
    FSpectrogram: TSpectrogram;
    FOnDone: TNotifyEvent;
    procedure ReportDone;
  protected
    procedure Execute; override;
  public
    constructor Create(ADecoder: TDeepCWDecoder; const ASamples: TSingleArray;
      ASampleRate: Integer; AOnDone: TNotifyEvent);
    property Text: string read FText;
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

    { 音声 / audio }
    FRing: TAudioRing;
    FCapture: TAudioCapture;
    FPlayback: TAudioPlayback;
    FCaptureRate: Integer;

    { 送信の状態 / transmit state }
    FTxPlaying: Boolean;
    FTxSegments: TCWSegments;
    FTxSamples: TSingleArray;
    FTxNormalized: string;
    FTxSampleRate: Integer;

    { 受信の状態 / receive state }
    FLiveTranscript: string;
    FLiveLastDecodedTotal: Int64;
    FLastSpectrogram: TSpectrogram;

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
    FRxWindow: TSpinEdit;
    FRxInterval: TSpinEdit;
    FRxAntiAlias: TCheckBox;
    FRxText: TMemo;
    FRxLevel: TProgressBar;
    FRxWaterfall: TPaintBox;
    FRxBusy: TLabel;

    { 設定タブ / settings tab }
    FSetModel: TEdit;
    FSetMetadata: TEdit;
    FSetRuntime: TEdit;
    FSetPortAudio: TEdit;
    FSetCaptureRate: TComboBox;
    FSetThreads: TSpinEdit;
    FSetApply: TButton;
    FSetInfo: TMemo;

    procedure BuildUI;
    function BuildTransmitTab: TTabSheet;
    function BuildReceiveTab: TTabSheet;
    function BuildSettingsTab: TTabSheet;

    function ConfigFileName: string;
    procedure LoadSettings;
    procedure SaveSettings;
    procedure ApplySettings(Sender: TObject);
    procedure RefreshInfo;

    function EnsureDecoder(Silent: Boolean = False): Boolean;
    function DecoderBusy: Boolean;
    procedure StartDecode(const Samples: TSingleArray; SampleRate: Integer);
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
    procedure RxWaterfallPaint(Sender: TObject);

    procedure PollTimer(Sender: TObject);
    procedure UpdateTransmitProgress;
    procedure UpdateLiveReceive;
    procedure SetStatus(const Engine, Audio, Message_: string);
    procedure ReportError(const Context: string; E: Exception);
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
  end;

var
  MainForm: TMainForm;

implementation

const
  { ライブ受信ではリングバッファの最新部分を復号します。15 秒はモデルが扱う
    5〜20 秒の範囲に余裕をもって収まります。

    Live reception decodes the newest slice of the ring buffer. Fifteen
    seconds sits inside the model's 5-20 second range with room to spare. }
  DEFAULT_LIVE_WINDOW = 15;
  DEFAULT_LIVE_INTERVAL = 3;
  { モデルが学習した通過帯域の上限は 1200 Hz です。そこから少し上で遮断すれば
    CW の信号音を損ないません。

    The passband the model is trained on tops out at 1200 Hz; filtering a
    little above that keeps the CW note intact. }
  ANTI_ALIAS_CUTOFF_HZ = 1400;

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

procedure TDecodeThread.Execute;
begin
  try
    FText := FDecoder.DecodeLongSamples(FSamples, FSampleRate);
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
  FStatus.Panels.Add.Width := 320;
  FStatus.Panels.Add.Width := 300;
  FStatus.Panels.Add.Width := 300;

  FPages := TPageControl.Create(Self);
  FPages.Parent := Self;
  FPages.Align := alClient;
  FPages.AddTabSheet.Free;      { 仮のシートを取り除きます / drop the placeholder sheet }
  BuildTransmitTab;
  BuildReceiveTab;
  BuildSettingsTab;
  FPages.PageIndex := 0;

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
  LiveControls, LevelPanel, WaterfallPanel, TextPanel: TPanel;
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
  LiveBox.Height := 88;
  LiveBox.Caption := 'マイク / ライン入力から受信';
  Stretch(LiveBox, alTop);

  LevelPanel := TPanel.Create(LiveBox);
  LevelPanel.Parent := LiveBox;
  LevelPanel.Align := alRight;
  LevelPanel.Width := 150;
  LevelPanel.BevelOuter := bvNone;
  AddLabel(LevelPanel, '入力レベル', 6, 4);
  FRxLevel := TProgressBar.Create(LevelPanel);
  FRxLevel.Parent := LevelPanel;
  FRxLevel.SetBounds(6, 24, 138, 20);
  FRxLevel.Max := 100;

  LiveControls := TPanel.Create(LiveBox);
  LiveControls.Parent := LiveBox;
  LiveControls.Align := alClient;
  LiveControls.BevelOuter := bvNone;

  FRxStart := AddButton(LiveControls, '受信開始', 8, 22, 110, @RxStartClick);
  FRxStop := AddButton(LiveControls, '受信停止', 126, 22, 110, @RxStopClick);
  FRxClear := AddButton(LiveControls, '表示をクリア', 244, 22, 130, @RxClearClick);

  AddLabel(LiveControls, '窓 (秒)', 390, 4);
  FRxWindow := AddSpin(LiveControls, 390, 22, Round(DEEPCW_MIN_SECONDS) + 1,
    Round(DEEPCW_MAX_SECONDS), DEFAULT_LIVE_WINDOW, nil);
  AddLabel(LiveControls, '間隔 (秒)', 480, 4);
  FRxInterval := AddSpin(LiveControls, 480, 22, 1, 15, DEFAULT_LIVE_INTERVAL, nil);

  FRxAntiAlias := TCheckBox.Create(LiveControls);
  FRxAntiAlias.Parent := LiveControls;
  FRxAntiAlias.SetBounds(576, 26, 160, 24);
  FRxAntiAlias.Caption := 'アンチエイリアス';
  FRxAntiAlias.Checked := True;

  FRxBusy := AddTopLabel(Sheet, '');

  WaterfallPanel := TPanel.Create(Sheet);
  WaterfallPanel.Parent := Sheet;
  WaterfallPanel.Align := alBottom;
  WaterfallPanel.Height := 200;
  WaterfallPanel.BevelOuter := bvNone;
  AddTopLabel(WaterfallPanel, 'スペクトログラム（400-1200 Hz）');
  FRxWaterfall := TPaintBox.Create(WaterfallPanel);
  FRxWaterfall.Parent := WaterfallPanel;
  FRxWaterfall.OnPaint := @RxWaterfallPaint;
  Stretch(FRxWaterfall, alClient);

  TextPanel := TPanel.Create(Sheet);
  TextPanel.Parent := Sheet;
  TextPanel.Align := alClient;
  TextPanel.BevelOuter := bvNone;
  AddTopLabel(TextPanel, '受信テキスト');
  FRxText := TMemo.Create(TextPanel);
  FRxText.Parent := TextPanel;
  FRxText.ReadOnly := True;
  FRxText.ScrollBars := ssAutoVertical;
  FRxText.Font.Size := 12;
  Stretch(FRxText, alClient);
end;

function TMainForm.BuildSettingsTab: TTabSheet;
var
  Sheet: TTabSheet;
  Row, Apply: TPanel;

  function AddPathEdit(const Caption, Value: string): TEdit;
  begin
    AddTopLabel(Sheet, Caption);
    Result := TEdit.Create(Sheet);
    Result.Parent := Sheet;
    Result.Text := Value;
    Stretch(Result, alTop);
  end;

begin
  Sheet := FPages.AddTabSheet;
  Sheet.Caption := '設定';
  Result := Sheet;

  FSetModel := AddPathEdit('モデル (model.onnx)', LocateDataFile('model.onnx'));
  FSetMetadata := AddPathEdit('メタデータ (model.onnx.json)', LocateDataFile('model.onnx.json'));
  FSetRuntime := AddPathEdit('ONNX Runtime ライブラリ（空欄なら自動検索）', '');
  FSetPortAudio := AddPathEdit('PortAudio ライブラリ（空欄なら自動検索）', '');

  Row := AddTopPanel(Sheet, 60);
  AddLabel(Row, '録音サンプリング周波数 (Hz)', 12, 4);
  FSetCaptureRate := TComboBox.Create(Row);
  FSetCaptureRate.Parent := Row;
  FSetCaptureRate.SetBounds(12, 24, 140, 28);
  FSetCaptureRate.Style := csDropDownList;
  FSetCaptureRate.Items.CommaText := '8000,11025,16000,22050,44100,48000';
  FSetCaptureRate.ItemIndex := 0;

  AddLabel(Row, '推論スレッド数', 260, 4);
  FSetThreads := AddSpin(Row, 260, 24, 1, 16, 1, nil);

  Apply := AddTopPanel(Sheet, 44);
  FSetApply := AddButton(Apply, '適用してエンジンを読み込む', 12, 6, 250, @ApplySettings);

  FSetInfo := TMemo.Create(Sheet);
  FSetInfo.Parent := Sheet;
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
    FSetThreads.Value := Ini.ReadInteger('engine', 'threads', 1);

    Rate := Ini.ReadString('audio', 'capture_rate', '8000');
    Index := FSetCaptureRate.Items.IndexOf(Rate);
    if Index >= 0 then
      FSetCaptureRate.ItemIndex := Index;

    FTxCharWpm.Value := Ini.ReadInteger('transmit', 'char_wpm', 20);
    FTxTextWpm.Value := Ini.ReadInteger('transmit', 'text_wpm', 20);
    FTxToneHz.Value := Ini.ReadInteger('transmit', 'tone_hz', 700);
    FTxVolume.Position := Ini.ReadInteger('transmit', 'volume', 60);
    FTxText.Text := Ini.ReadString('transmit', 'text', FTxText.Text);

    FRxWindow.Value := Ini.ReadInteger('receive', 'window', DEFAULT_LIVE_WINDOW);
    FRxInterval.Value := Ini.ReadInteger('receive', 'interval', DEFAULT_LIVE_INTERVAL);
    FRxAntiAlias.Checked := Ini.ReadBool('receive', 'anti_alias', True);
  finally
    Ini.Free;
  end;
end;

procedure TMainForm.SaveSettings;
var
  Ini: TIniFile;
begin
  try
    ForceDirectories(ExtractFilePath(ConfigFileName));
    Ini := TIniFile.Create(ConfigFileName);
    try
      Ini.WriteString('engine', 'model', FSetModel.Text);
      Ini.WriteString('engine', 'metadata', FSetMetadata.Text);
      Ini.WriteString('engine', 'onnxruntime', FSetRuntime.Text);
      Ini.WriteInteger('engine', 'threads', FSetThreads.Value);
      Ini.WriteString('audio', 'portaudio', FSetPortAudio.Text);
      Ini.WriteString('audio', 'capture_rate', FSetCaptureRate.Text);
      Ini.WriteInteger('transmit', 'char_wpm', FTxCharWpm.Value);
      Ini.WriteInteger('transmit', 'text_wpm', FTxTextWpm.Value);
      Ini.WriteInteger('transmit', 'tone_hz', FTxToneHz.Value);
      Ini.WriteInteger('transmit', 'volume', FTxVolume.Position);
      Ini.WriteString('transmit', 'text', FTxText.Text);
      Ini.WriteInteger('receive', 'window', FRxWindow.Value);
      Ini.WriteInteger('receive', 'interval', FRxInterval.Value);
      Ini.WriteBool('receive', 'anti_alias', FRxAntiAlias.Checked);
    finally
      Ini.Free;
    end;
  except
    { 設定は利便のためのものです。保存に失敗しても終了を妨げません。
      Settings are a convenience; failing to store them must not block exit. }
  end;
end;

procedure TMainForm.ApplySettings(Sender: TObject);
begin
  RxStopClick(nil);
  FreeAndNil(FDecoder);
  FEngineError := '';
  UnloadOnnxRuntime;
  EnsureDecoder;
  RefreshInfo;
end;

procedure TMainForm.RefreshInfo;
var
  Lines: TStringList;
  I: Integer;
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

function TMainForm.EnsureDecoder(Silent: Boolean): Boolean;
begin
  if FDecoder <> nil then
    Exit(True);
  try
    LoadOnnxRuntime(FSetRuntime.Text);
    FDecoder := TDeepCWDecoder.Create(FSetModel.Text, FSetMetadata.Text, FSetThreads.Value);
    FEngineError := '';
    Result := True;
  except
    on E: Exception do
    begin
      FEngineError := E.Message;
      FDecoder := nil;
      if Silent then
        SetStatus('エンジン: 未読み込み', '', E.Message)
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

function TMainForm.PrepareForDecoder(const Samples: TSingleArray;
  SampleRate: Integer): TSingleArray;
begin
  Result := Samples;
  { 入力がモデルの帯域より十分に高い場合にのみ、フィルタを掛ける意味があります。
    Only worth filtering when the source runs well above the model's band. }
  if FRxAntiAlias.Checked and (SampleRate > 2 * ANTI_ALIAS_CUTOFF_HZ) then
    Result := LowPassFilter(Result, SampleRate, ANTI_ALIAS_CUTOFF_HZ);
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
    SetStatus('', '', 'デコード失敗: ' + Thread.Error)
  else
  begin
    FLastSpectrogram := Thread.Spectrogram;
    FRxWaterfall.Invalidate;
    if FAppendMode then
    begin
      { ライブ受信では、窓の重なりをたたみながら追記します。
      Live reception appends, folding away the overlap between windows. }
      FLiveTranscript := MergeOverlappingText(FLiveTranscript, Thread.Text);
      FRxText.Text := FLiveTranscript;
    end
    else
      FRxText.Text := Thread.Text;
    FRxText.SelStart := Length(FRxText.Text);
    SetStatus('', '', Format('デコード完了: %d 文字', [Length(Thread.Text)]));
  end;

  FCompletedThread := Thread;
end;

{ ---- transmit ---- }

procedure TMainForm.TxTextChanged(Sender: TObject);
begin
  RenderTransmit;
end;

procedure TMainForm.TxOptionsChanged(Sender: TObject);
begin
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
        SetStatus('', '', '送信エラー: ' + FPlayback.LastError)
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
  FLiveTranscript := '';
  FAppendMode := False;
  StartDecode(PrepareForDecoder(Samples, SampleRate), SampleRate);
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

    FCaptureRate := StrToIntDef(FSetCaptureRate.Text, 8000);
    { 最長の窓の 2 倍を保持し、復号が遅れても次の窓が不足しないようにします。
    Hold twice the longest window so a slow decode never starves the next. }
    FreeAndNil(FRing);
    FRing := TAudioRing.Create(FCaptureRate * 2 * Round(DEEPCW_MAX_SECONDS));
    FCapture := TAudioCapture.Create(FRing, FCaptureRate);
    FCapture.Start;
    FLiveLastDecodedTotal := 0;
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
  SetStatus('', '待機中', '受信を停止しました。');
end;

procedure TMainForm.RxClearClick(Sender: TObject);
begin
  FLiveTranscript := '';
  FRxText.Clear;
end;

procedure TMainForm.UpdateLiveReceive;
var
  Snapshot, Window: TSingleArray;
  Total: Int64;
  Wanted, Available: Integer;
begin
  if FCapture = nil then
    Exit;

  if FCapture.LastError <> '' then
  begin
    SetStatus('', '待機中', '録音エラー: ' + FCapture.LastError);
    RxStopClick(nil);
    Exit;
  end;

  FRxLevel.Position := Round(100 * FRing.PeakLevel(FCaptureRate, 0.2));

  Total := FRing.TotalWritten;
  Wanted := FRxWindow.Value * FCaptureRate;
  if Total < Wanted then
    Exit;
  if (FLiveLastDecodedTotal > 0) and
     (Total - FLiveLastDecodedTotal < Int64(FRxInterval.Value) * FCaptureRate) then
    Exit;
  if DecoderBusy then
    Exit;

  Snapshot := FRing.Snapshot;
  Available := Length(Snapshot);
  if Available < Wanted then
    Exit;
  Window := Copy(Snapshot, Available - Wanted, Wanted);

  FLiveLastDecodedTotal := Total;
  FAppendMode := True;
  StartDecode(PrepareForDecoder(Window, FCaptureRate), FCaptureRate);
end;

procedure TMainForm.RxWaterfallPaint(Sender: TObject);
var
  Image: TLazIntfImage;
  Bitmap: TBitmap;
  X, Y, Frame, Bin, Step: Integer;
  Value, Lowest, Highest, Level: Double;
  Pixel: TFPColor;
  Width_, Height_: Integer;
begin
  FRxWaterfall.Canvas.Brush.Color := clBlack;
  FRxWaterfall.Canvas.FillRect(0, 0, FRxWaterfall.Width, FRxWaterfall.Height);
  if (FLastSpectrogram.Frames <= 0) or (FLastSpectrogram.Bins <= 0) then
  begin
    FRxWaterfall.Canvas.Font.Color := clSilver;
    FRxWaterfall.Canvas.TextOut(8, 8, 'デコードするとスペクトログラムを表示します');
    Exit;
  end;

  { この窓の最小値と最大値で正規化し、弱い信号も見えるようにします。モデルへは
    正規化前の値がそのまま渡ります。

    Normalise against the extremes of this window so faint signals stay
    visible; the model sees the raw values regardless. }
  Lowest := FLastSpectrogram.Data[0];
  Highest := Lowest;
  for X := 0 to High(FLastSpectrogram.Data) do
  begin
    Value := FLastSpectrogram.Data[X];
    if Value < Lowest then Lowest := Value;
    if Value > Highest then Highest := Value;
  end;
  if Highest - Lowest < 1E-6 then
    Highest := Lowest + 1;

  { 画面 1 列につき画像 1 列とすることで、長い窓でも描画の負担を抑えます。
    One image column per screen column keeps long windows cheap to draw. }
  Width_ := Max(1, Min(FRxWaterfall.Width, FLastSpectrogram.Frames));
  Height_ := FLastSpectrogram.Bins;
  Step := Max(1, FLastSpectrogram.Frames div Width_);

  Image := TLazIntfImage.Create(Width_, Height_, [riqfRGB]);
  try
    for X := 0 to Width_ - 1 do
    begin
      Frame := Min(FLastSpectrogram.Frames - 1, X * Step);
      for Y := 0 to Height_ - 1 do
      begin
        { 行 0 は枠の上端であるため、周波数軸を反転します。
        Row 0 is the top of the box, so flip the frequency axis. }
        Bin := Height_ - 1 - Y;
        Level := (FLastSpectrogram.Data[Frame * FLastSpectrogram.Bins + Bin] - Lowest) /
          (Highest - Lowest);
        Level := ClampDouble(Level, 0, 1);
        { 黒から青、橙を経て白へ変化させます。
        Black through blue and orange to white. }
        Pixel.Red := Round(65535 * ClampDouble(1.6 * Level - 0.3, 0, 1));
        Pixel.Green := Round(65535 * ClampDouble(1.8 * Level - 0.7, 0, 1));
        Pixel.Blue := Round(65535 * ClampDouble(2.2 * Level - 1.2, 0, 1) +
          40000 * ClampDouble(1.4 * Level, 0, 1) * (1 - Level));
        Pixel.Alpha := alphaOpaque;
        Image.Colors[X, Y] := Pixel;
      end;
    end;

    Bitmap := TBitmap.Create;
    try
      Bitmap.LoadFromIntfImage(Image);
      FRxWaterfall.Canvas.StretchDraw(
        Rect(0, 0, FRxWaterfall.Width, FRxWaterfall.Height), Bitmap);
    finally
      Bitmap.Free;
    end;
  finally
    Image.Free;
  end;
end;

{ ---- shared ---- }

procedure TMainForm.PollTimer(Sender: TObject);
begin
  { タイマーが動く時点でスレッドは Synchronize を抜けているため安全です。
  Safe here: the thread has left Synchronize by the time the timer runs. }
  if FCompletedThread <> nil then
    FreeAndNil(FCompletedThread);

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

procedure TMainForm.ReportError(const Context: string; E: Exception);
begin
  SetStatus('', '', Context + ': ' + E.Message);
  MessageDlg(Context + 'に失敗しました', E.Message, mtError, [mbOK], 0);
end;

end.
