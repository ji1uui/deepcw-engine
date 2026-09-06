unit DeepCW.Recorder;

{ 受信した音を WAV へ録り続けます（要件 FR-E.8）。

  聴き直し（要件 FR-E.10）は直近の数分を記憶に置くもので、その先は捨てられます。
  **捨てられては困る運用――コンテスト、パイルアップ、珍しい局――のために、
  受信と同時にファイルへ残す道がここです。**録ったファイルは、そのまま
  「WAV ファイルから受信」で読み直せます（要件 FR-E.9）。

  作りは 3 つの約束でできています。

  1. **音を取り出すのは専用のスレッドです。**録音の書き込みは待たされうる操作
     なので、これを画面のスレッドで行うと、書き込みが詰まった分だけ画面が
     止まります。音声のコールバックで行えば、取りこぼしになります。
  2. **輪バッファの読み手として振る舞います。**`TAudioRing.ReadSince` は読み手
     ごとに位置を持てるので、復号器の読み出しを 1 標本も邪魔しません。
  3. **上限を持ち、超えたら止めて、そう言います**（教訓 10.1）。ディスクを
     黙って埋め尽くさないためです。

  Keeps what is being received in a WAV file (requirement FR-E.8).

  Replay (requirement FR-E.10) holds the last few minutes in memory and drops
  the rest. **This is the path for operating where losing it matters -- a
  contest, a pile-up, a rare station -- writing to a file as reception goes.**
  What is written can be read straight back by "receive from a WAV file"
  (requirement FR-E.9).

  Three promises shape it:

  1. **A thread of its own takes the audio out.** Writing can block; on the GUI
     thread the display would stop for as long as a write took, and in the audio
     callback it would cost dropped samples.
  2. **It behaves as one more reader of the ring.** `TAudioRing.ReadSince`
     carries a position per reader, so the decoder's own reading is untouched.
  3. **It has a limit, stops at it, and says so** (lesson 10.1), rather than
     filling the disk in silence. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, DeepCW.Types, DeepCW.Audio, DeepCW.Wave;

const
  { 録音の上限。**一晩のコンテストを通して録れる長さ**を採り、そこで止めます。
    8000 Hz なら 12 時間で約 345 MB です。

    大きさの上限も併せ持ちます。WAV の大きさの欄は 32 ビットで、細かさを上げた
    まま長時間録ると溢れます。**溢れた WAV は、書けているのに開けません。**

    The recording limits. The length is **as long as a contest through the
    night**, 12 hours, which is about 345 MB at 8000 Hz.

    There is a size limit beside it: a WAV's size fields are 32-bit, and a long
    recording at a high rate overruns them. **An overrun WAV is written and
    still cannot be opened.** }
  RECORD_MAX_SECONDS = 12 * 60 * 60;
  RECORD_MAX_BYTES = Int64(2000) * 1000 * 1000;

  { 音を取り出す間隔。**復号器と同じ 0.2 秒より短くします。**輪バッファの取り
    こぼしは復号にも録音にも同じだけ効くので、録音のほうが遅れて先に落ちる、
    という並びにはしません。
    How often the audio is taken out. **Shorter than the decoder's 0.2 seconds**:
    a ring that overruns costs the decoder and the recording alike, so the
    recording is not left to fall behind first. }
  RECORD_POLL_MS = 100;

type
  { 画面へ見せる録音の状態です。**ワーカースレッドが書き、画面が読みます。**
    公開するのは複製であり、録音そのものではありません。
    The state of the recording as the display sees it. **The worker writes it and
    the display reads it**, and what is handed over is a copy, not the recording
    itself. }
  TRecorderStatus = record
    Running: Boolean;
    Seconds: Double;
    Bytes: Int64;
    { 追いつけずに失った標本の数。0 でなければ、その分は録れていません。
      Samples lost by falling behind; anything but zero was not recorded. }
    Lost: Int64;
    { 自ら止まった理由。空なら止まっていません。上限に達した、書けなくなった、
      のいずれかです。**黙って止まらないための欄です。**
      Why it stopped by itself, empty while it has not: a limit reached or a
      write that failed. **The field exists so that it cannot stop in silence.** }
    Stopped: string;
  end;

  TAudioRecorder = class;

  TRecorderThread = class(TThread)
  private
    FOwner: TAudioRecorder;
  protected
    procedure Execute; override;
  public
    constructor Create(AOwner: TAudioRecorder);
  end;

  { 輪バッファから音を取り出し、WAV へ書き続けます。

    Takes audio out of the ring and keeps writing it to a WAV file. }
  TAudioRecorder = class
  private
    FRing: TAudioRing;
    FSampleRate: Integer;
    FMaxSeconds: Double;
    FMaxBytes: Int64;
    FThread: TRecorderThread;
    FWriter: TWavWriter;
    FPosition: Int64;
    FFileName: string;
    FLastError: string;
    FLock: TRTLCriticalSection;
    { 以下は錠の下でだけ触ります。/ Only touched under the lock. }
    FSeconds: Double;
    FBytes: Int64;
    FLost: Int64;
    FStopped: string;
    procedure Publish;
    { 輪バッファに溜まった分を書き出します。**ワーカースレッドだけが呼びます。**
      書き出し中に錠を持たないのは、遅い書き込みが画面の状態表示を待たせない
      ようにするためです。
      Writes out whatever the ring has accumulated. **Called only by the worker
      thread.** No lock is held across the write, so a slow disk never makes the
      display wait for the status. }
    procedure Drain;
  public
    { 録音の器を作ります。ここではまだファイルを触りません。

      上限は既定の値を使いますが、**試験が小さな上限を渡せるようにしてあります。**
      12 時間録らなければ確かめられない上限は、確かめられない上限です。

      Creates the recorder; no file is touched yet.

      The limits default to the constants, but **a test can pass small ones**: a
      limit that takes twelve hours to reach is a limit that never gets
      checked. }
    constructor Create(ARing: TAudioRing; ASampleRate: Integer;
      AMaxSeconds: Double = RECORD_MAX_SECONDS;
      AMaxBytes: Int64 = RECORD_MAX_BYTES);
    destructor Destroy; override;

    { 録音を始めます。**始まりは「いまから」です。**輪バッファに残っている
      数十秒は、利用者が録ると決める前のものなので遡って書きません
      （`DeepCW.Journal` と同じ考え方）。

      失敗すれば False を返し、理由が `LastError` に入ります。

      Starts recording. **It starts from now**: the tens of seconds still in the
      ring belong to the time before the operator chose to record, so they are
      not written retrospectively (the reasoning `DeepCW.Journal` follows).

      Returns False on failure, with the reason in `LastError`. }
    function Start(const AFileName: string): Boolean;

    { 録音を終えます。**止める前に、輪バッファに残っている分を書き切ります。**
      止めた瞬間の 0.1 秒が落ちると、最後の 1 文字の音が無くなります。
      Stops recording. **What is still in the ring is written out first**: losing
      the last tenth of a second would lose the sound of the last character. }
    procedure Stop;

    function Running: Boolean;
    function Snapshot: TRecorderStatus;
    property FileName: string read FFileName;
    property LastError: string read FLastError;
  end;

{ 録音 1 本のファイル名を組み立てます。時刻は**地方時**です。受信テキストの
  記録（`DeepCW.Journal`）が地方時の日付でファイルを作るので、同じ運用の音と
  文字が並んで見えるようにします。ADIF の交信記録が協定世界時なのは、ADIF が
  そう定めているからで、こちらは運用者が自分の記録を探すためのものです。

  Builds the file name for one recording, in **local time**. The transcript
  journal (`DeepCW.Journal`) names its files by the local date, so the sound and
  the characters of one session sit side by side. The ADIF contact log is UTC
  because ADIF defines it so; this is for the operator finding their own
  material. }
function RecordingFileFor(const Directory: string; When: TDateTime): string;

implementation

function RecordingFileFor(const Directory: string; When: TDateTime): string;
begin
  Result := IncludeTrailingPathDelimiter(Directory) +
    FormatDateTime('yyyy-mm-dd-hhnnss', When) + '.wav';
end;

{ TRecorderThread }

constructor TRecorderThread.Create(AOwner: TAudioRecorder);
begin
  FOwner := AOwner;
  FreeOnTerminate := False;
  inherited Create(False);
end;

procedure TRecorderThread.Execute;
begin
  while not Terminated do
  begin
    FOwner.Drain;
    { 上限に達した、あるいは書けなくなったなら、ここで終わります。**画面へは
      状態で伝えます。**ワーカーから画面を触ることはしません。
      A limit reached or a write that failed ends it here. **The display learns
      of it from the status**; a worker never touches the display. }
    if FOwner.FStopped <> '' then
      Break;
    if not Terminated then
      Sleep(RECORD_POLL_MS);
  end;
  { 最後にもう一度読み切ります。止める指示が来たあとに届いた音も残します。
    One last read: audio that arrived after the stop was asked for is kept
    too. }
  if FOwner.FStopped = '' then
    FOwner.Drain;
end;

{ TAudioRecorder }

constructor TAudioRecorder.Create(ARing: TAudioRing; ASampleRate: Integer;
  AMaxSeconds: Double; AMaxBytes: Int64);
begin
  inherited Create;
  InitCriticalSection(FLock);
  FRing := ARing;
  FSampleRate := ASampleRate;
  FMaxSeconds := AMaxSeconds;
  FMaxBytes := AMaxBytes;
end;

destructor TAudioRecorder.Destroy;
begin
  Stop;
  DoneCriticalSection(FLock);
  inherited Destroy;
end;

function TAudioRecorder.Start(const AFileName: string): Boolean;
var
  Directory: string;
begin
  Result := False;
  FLastError := '';
  if FThread <> nil then
    Exit(True);
  if (FRing = nil) or (FSampleRate <= 0) then
  begin
    FLastError := '録音を始められません: 受信が動いていません。';
    Exit;
  end;
  try
    Directory := ExtractFilePath(AFileName);
    if (Directory <> '') and not DirectoryExists(Directory) then
      if not ForceDirectories(Directory) then
      begin
        FLastError := '録音の保存先を作れません: ' + Directory;
        Exit;
      end;
    FWriter := TWavWriter.Create(AFileName, FSampleRate);
  except
    on E: Exception do
    begin
      FreeAndNil(FWriter);
      FLastError := '録音を始められません: ' + E.Message;
      Exit;
    end;
  end;
  FFileName := AFileName;
  { いまの書き込み総数を始まりの位置にします。これで、輪バッファに残っている
    過去は読まれません。
    The ring's current total becomes the starting position, so the past still
    held in the ring is not read. }
  FPosition := FRing.Written;
  FSeconds := 0;
  FBytes := FWriter.Bytes;
  FLost := 0;
  FStopped := '';
  FThread := TRecorderThread.Create(Self);
  Result := True;
end;

procedure TAudioRecorder.Stop;
begin
  if FThread <> nil then
  begin
    FThread.Terminate;
    FThread.WaitFor;
    FreeAndNil(FThread);
  end;
  FreeAndNil(FWriter);
end;

function TAudioRecorder.Running: Boolean;
begin
  Result := FThread <> nil;
end;

procedure TAudioRecorder.Publish;
begin
  EnterCriticalSection(FLock);
  try
    if FWriter <> nil then
    begin
      FSeconds := FWriter.SampleCount / FSampleRate;
      FBytes := FWriter.Bytes;
    end;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

procedure TAudioRecorder.Drain;
var
  Fresh: TSingleArray;
  Before, Missing: Int64;
  Reason: string;
begin
  if FWriter = nil then
    Exit;
  Before := FPosition;
  if not FRing.ReadSince(FPosition, Fresh) then
  begin
    { 追いつけずに一周しました。**失った長さを数えて残します。**黙って穴の
      空いた録音を渡すことはしません（教訓 10.1）。
      The ring wrapped before this reader caught up. **How much was lost is
      counted and kept**: a recording with a silent hole in it is not handed
      over as if nothing happened (lesson 10.1). }
    Missing := (FPosition - Before) - Length(Fresh);
    if Missing > 0 then
    begin
      EnterCriticalSection(FLock);
      try
        FLost := FLost + Missing;
      finally
        LeaveCriticalSection(FLock);
      end;
    end;
  end;
  if Length(Fresh) = 0 then
  begin
    Publish;
    Exit;
  end;
  Reason := '';
  try
    FWriter.Append(Fresh, Length(Fresh));
  except
    on E: Exception do
      Reason := '録音を続けられません: ' + E.Message;
  end;
  Publish;
  if Reason = '' then
  begin
    if FWriter.SampleCount / FSampleRate >= FMaxSeconds then
      Reason := Format('録音の上限（%.0f 時間）に達しました。',
        [FMaxSeconds / 3600])
    else if FWriter.Bytes >= FMaxBytes then
      Reason := Format('録音の上限（%.0f MB）に達しました。',
        [FMaxBytes / (1000 * 1000)]);
  end;
  if Reason <> '' then
  begin
    EnterCriticalSection(FLock);
    try
      FStopped := Reason;
    finally
      LeaveCriticalSection(FLock);
    end;
  end;
end;

function TAudioRecorder.Snapshot: TRecorderStatus;
begin
  EnterCriticalSection(FLock);
  try
    { 上限に達して自ら止まったものは「動いている」とは言いません。**動いて
      いると言い続ければ、画面は止まった録音の時間を数え続けます。**
      One that stopped itself at a limit is not called running: **saying
      otherwise would have the display go on counting a recording that
      ended.** }
    Result.Running := (FThread <> nil) and (FStopped = '');
    Result.Seconds := FSeconds;
    Result.Bytes := FBytes;
    Result.Lost := FLost;
    Result.Stopped := FStopped;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

end.
