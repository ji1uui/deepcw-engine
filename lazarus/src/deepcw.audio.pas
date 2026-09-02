unit DeepCW.Audio;

{ PortAudio を用いたサウンドカードの入出力です。

  PortAudio は実行時に読み込み、存在しない場合はいずれの関数も分かりやすい
  エラーとして報告します。そのため、WAV の読み書きだけを行うアプリケーション
  であれば PortAudio が無い環境でも動作します。

  コールバックではなく、待機を伴う読み書き API を用いています。PortAudio 自身
  の高優先度スレッド上で動く Pascal のコールバックは誤りを招きやすく、モールス
  通信程度の音声量では方式の違いが問題にならないためです。

  Live sound card input and output through PortAudio.

  PortAudio is loaded at run time and every entry point here reports its
  absence as a plain error, so an application that only reads and writes WAV
  files still runs on a machine without it.

  The blocking read/write API is used rather than callbacks: a Pascal callback
  running on PortAudio's own high priority thread is easy to get wrong, and a
  Morse station moves far too little audio for the difference to matter. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Math, DynLibs, DeepCW.Types;

type
  { 直近のサンプルを保持する固定長のモノラルリングバッファです。GUI が内容を
    取り出している間も、録音スレッドから安全に書き込めます。

    Fixed-size mono ring holding the most recent samples. Safe to fill from the
    capture thread while the GUI takes snapshots. }
  TAudioRing = class
  private
    FData: TSingleArray;
    FCapacity: Integer;
    FCount: Integer;
    FHead: Integer;
    FTotal: Int64;
    FLock: TRTLCriticalSection;
  public
    constructor Create(ACapacity: Integer);
    destructor Destroy; override;
    procedure Push(const Source: TSingleArray; Count: Integer);
    procedure Clear;
    { 現在保持している内容を、古い順に並べた複製として返します。

    Oldest to newest copy of everything currently held. }
    function Snapshot: TSingleArray;
    { 直近 Seconds 秒の振幅の最大値です。レベルメータに用います。

    Peak magnitude of the newest Seconds worth of audio, for a level meter. }
    function PeakLevel(SampleRate: Integer; Seconds: Double): Single;
    { これまでに書き込まれたサンプルの総数です。GUI が新しい音声の到着を知る
    ために参照します。

    Total samples ever pushed; the GUI uses it to notice new audio. }
    function TotalWritten: Int64;

    { Position 以降に書き込まれた分を取り出し、Position を進めます。読み出しが
      間に合わずリングを一周した場合は、取り出せる最も古い位置まで切り上げ、
      False を返して取りこぼしを知らせます。

      Reads whatever was written after Position and advances it. If reading
      fell behind and the ring wrapped, Position is moved up to the oldest
      sample still held and False reports the loss. }
    function ReadSince(var Position: Int64; out Data: TSingleArray): Boolean;
    property Capacity: Integer read FCapacity;
  end;

  TAudioCapture = class;
  TAudioPlayback = class;

  { 既定の入力デバイスから録音し、リングバッファへ書き込みます。

    Records from the default input device into a ring buffer. }
  TAudioCapture = class
  private
    FThread: TThread;
    FRing: TAudioRing;
    FSampleRate: Integer;
    FFramesPerBuffer: Integer;
    FLastError: string;
    function GetRunning: Boolean;
  public
    constructor Create(ARing: TAudioRing; ASampleRate: Integer;
      AFramesPerBuffer: Integer = 512);
    destructor Destroy; override;
    procedure Start;
    procedure Stop;
    property Running: Boolean read GetRunning;
    property LastError: string read FLastError;
    property SampleRate: Integer read FSampleRate;
  end;

  TPlaybackProgress = procedure(Sender: TObject; SamplesPlayed: Integer) of object;

  { 既定の出力デバイスからバッファを再生します。

    Plays a buffer through the default output device. }
  TAudioPlayback = class
  private
    FThread: TThread;
    FLastError: string;
    FPosition: Integer;
    FOnProgress: TPlaybackProgress;
    FOnFinished: TNotifyEvent;
    function GetRunning: Boolean;
  public
    destructor Destroy; override;
    { Samples の複製の再生を開始し、直ちに戻ります。

    Starts playing a copy of Samples and returns immediately. }
    procedure Play(const Samples: TSingleArray; ASampleRate: Integer);
    procedure Stop;
    property Running: Boolean read GetRunning;
    property Position: Integer read FPosition;
    property LastError: string read FLastError;
    { いずれのイベントも再生スレッド上で発生します。UI に触れる前に主スレッドへ
    処理を移してください。

    Both events fire on the playback thread; marshal before touching the UI. }
    property OnProgress: TPlaybackProgress read FOnProgress write FOnProgress;
    property OnFinished: TNotifyEvent read FOnFinished write FOnFinished;
  end;

{ libportaudio を読み込みます。パスを空にすると DEEPCW_PORTAUDIO、実行ファイル
  のディレクトリ、システムの検索パスの順に探索します。

  Loads libportaudio. Leave the path empty to try DEEPCW_PORTAUDIO, the
  executable directory and then the system search path. }
function LoadPortAudio(const LibraryPath: string = ''): Boolean;
function PortAudioAvailable: Boolean;
function PortAudioVersion: string;
function PortAudioLibraryPath: string;

{ 直前の LoadPortAudio が失敗した理由を、読みやすい文章で返します。

  Human-readable reason the last LoadPortAudio call failed. }
function PortAudioLoadError: string;

implementation

const
  PA_FLOAT32 = $00000001;
  PA_NO_ERROR = 0;
  PA_INPUT_OVERFLOWED = -9981;
  PA_OUTPUT_UNDERFLOWED = -9980;

type
  TPaStream = Pointer;

  TPaInitialize = function: LongInt; cdecl;
  TPaTerminate = function: LongInt; cdecl;
  TPaGetErrorText = function(Error: LongInt): PAnsiChar; cdecl;
  TPaGetVersionText = function: PAnsiChar; cdecl;
  TPaOpenDefaultStream = function(out Stream: TPaStream; InputChannels, OutputChannels: LongInt;
    SampleFormat: LongWord; SampleRate: Double; FramesPerBuffer: LongWord;
    Callback: Pointer; UserData: Pointer): LongInt; cdecl;
  TPaStreamAction = function(Stream: TPaStream): LongInt; cdecl;
  TPaTransfer = function(Stream: TPaStream; Buffer: Pointer; Frames: LongWord): LongInt; cdecl;

var
  GHandle: TLibHandle = NilHandle;
  GLibraryPath: string = '';
  GLoadError: string = '';
  GInitCount: Integer = 0;
  GInitLock: TRTLCriticalSection;

  Pa_Initialize: TPaInitialize = nil;
  Pa_Terminate: TPaTerminate = nil;
  Pa_GetErrorText: TPaGetErrorText = nil;
  Pa_GetVersionText: TPaGetVersionText = nil;
  Pa_OpenDefaultStream: TPaOpenDefaultStream = nil;
  Pa_StartStream: TPaStreamAction = nil;
  Pa_StopStream: TPaStreamAction = nil;
  Pa_CloseStream: TPaStreamAction = nil;
  Pa_ReadStream: TPaTransfer = nil;
  Pa_WriteStream: TPaTransfer = nil;

function DefaultPortAudioNames: TStringArray;
begin
  {$IF DEFINED(WINDOWS)}
  Result := TStringArray.Create('portaudio.dll', 'portaudio_x64.dll', 'libportaudio-2.dll');
  {$ELSEIF DEFINED(DARWIN)}
  Result := TStringArray.Create('libportaudio.dylib', 'libportaudio.2.dylib');
  {$ELSE}
  Result := TStringArray.Create('libportaudio.so.2', 'libportaudio.so');
  {$ENDIF}
end;

function BindPortAudio: Boolean;
begin
  Pa_Initialize := TPaInitialize(GetProcedureAddress(GHandle, 'Pa_Initialize'));
  Pa_Terminate := TPaTerminate(GetProcedureAddress(GHandle, 'Pa_Terminate'));
  Pa_GetErrorText := TPaGetErrorText(GetProcedureAddress(GHandle, 'Pa_GetErrorText'));
  Pa_GetVersionText := TPaGetVersionText(GetProcedureAddress(GHandle, 'Pa_GetVersionText'));
  Pa_OpenDefaultStream := TPaOpenDefaultStream(GetProcedureAddress(GHandle, 'Pa_OpenDefaultStream'));
  Pa_StartStream := TPaStreamAction(GetProcedureAddress(GHandle, 'Pa_StartStream'));
  Pa_StopStream := TPaStreamAction(GetProcedureAddress(GHandle, 'Pa_StopStream'));
  Pa_CloseStream := TPaStreamAction(GetProcedureAddress(GHandle, 'Pa_CloseStream'));
  Pa_ReadStream := TPaTransfer(GetProcedureAddress(GHandle, 'Pa_ReadStream'));
  Pa_WriteStream := TPaTransfer(GetProcedureAddress(GHandle, 'Pa_WriteStream'));

  Result := Assigned(Pa_Initialize) and Assigned(Pa_Terminate) and
    Assigned(Pa_OpenDefaultStream) and Assigned(Pa_StartStream) and
    Assigned(Pa_StopStream) and Assigned(Pa_CloseStream) and
    Assigned(Pa_ReadStream) and Assigned(Pa_WriteStream);
end;

function LoadPortAudio(const LibraryPath: string): Boolean;
var
  Candidates: TStringList;
  Names: TStringArray;
  ExeDir, Name: string;
  I: Integer;
begin
  if GHandle <> NilHandle then
    Exit(True);

  GLoadError := '';
  Candidates := TStringList.Create;
  try
    if LibraryPath <> '' then
      Candidates.Add(LibraryPath)
    else
    begin
      if GetEnvironmentVariable('DEEPCW_PORTAUDIO') <> '' then
        Candidates.Add(GetEnvironmentVariable('DEEPCW_PORTAUDIO'));
      ExeDir := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0)));
      Names := DefaultPortAudioNames;
      for Name in Names do
        Candidates.Add(ExeDir + Name);
      for Name in Names do
        Candidates.Add(Name);
    end;

    for I := 0 to Candidates.Count - 1 do
    begin
      GHandle := LoadLibrary(Candidates[I]);
      if GHandle = NilHandle then
        Continue;
      if BindPortAudio then
      begin
        GLibraryPath := Candidates[I];
        Exit(True);
      end;
      UnloadLibrary(GHandle);
      GHandle := NilHandle;
    end;

    GLoadError := Format('PortAudio could not be loaded. Tried: %s.', [Candidates.CommaText]);
    Result := False;
  finally
    Candidates.Free;
  end;
end;

function PortAudioAvailable: Boolean;
begin
  Result := GHandle <> NilHandle;
end;

function PortAudioVersion: string;
begin
  if (GHandle = NilHandle) or not Assigned(Pa_GetVersionText) then
    Result := ''
  else
    Result := string(Pa_GetVersionText());
end;

function PortAudioLibraryPath: string;
begin
  Result := GLibraryPath;
end;

function PortAudioLoadError: string;
begin
  Result := GLoadError;
end;

function ErrorText(Code: LongInt): string;
begin
  if Assigned(Pa_GetErrorText) then
    Result := string(Pa_GetErrorText(Code))
  else
    Result := Format('PortAudio error %d', [Code]);
end;

{ PortAudio の初期化はプロセスにつき一度だけ行う必要があります。アプリケー
  ションの各所が開くストリームは、参照数を通じてこの初期化を共有します。

  PortAudio must be initialised once per process; streams from different parts
  of the application share that initialisation through a reference count. }
procedure AcquirePortAudio;
var
  Code: LongInt;
begin
  if not LoadPortAudio then
    raise EDeepCW.Create(PortAudioLoadError + ' Install PortAudio to use the sound card.');
  EnterCriticalSection(GInitLock);
  try
    if GInitCount = 0 then
    begin
      Code := Pa_Initialize();
      if Code <> PA_NO_ERROR then
        raise EDeepCW.CreateFmt('Pa_Initialize failed: %s', [ErrorText(Code)]);
    end;
    Inc(GInitCount);
  finally
    LeaveCriticalSection(GInitLock);
  end;
end;

procedure ReleasePortAudio;
begin
  EnterCriticalSection(GInitLock);
  try
    if GInitCount > 0 then
    begin
      Dec(GInitCount);
      if (GInitCount = 0) and Assigned(Pa_Terminate) then
        Pa_Terminate();
    end;
  finally
    LeaveCriticalSection(GInitLock);
  end;
end;

{ TAudioRing }

constructor TAudioRing.Create(ACapacity: Integer);
begin
  inherited Create;
  FCapacity := Max(1, ACapacity);
  SetLength(FData, FCapacity);
  InitCriticalSection(FLock);
end;

destructor TAudioRing.Destroy;
begin
  DoneCriticalSection(FLock);
  inherited Destroy;
end;

procedure TAudioRing.Push(const Source: TSingleArray; Count: Integer);
var
  I, Start: Integer;
begin
  if Count <= 0 then
    Exit;
  EnterCriticalSection(FLock);
  try
    { リングより大きなまとまりを受け取った場合、残せるのは末尾の新しい部分だけです。
    A burst larger than the ring can only leave its newest tail. }
    Start := Max(0, Count - FCapacity);
    for I := Start to Count - 1 do
    begin
      FData[FHead] := Source[I];
      FHead := (FHead + 1) mod FCapacity;
      if FCount < FCapacity then
        Inc(FCount);
    end;
    Inc(FTotal, Count);
  finally
    LeaveCriticalSection(FLock);
  end;
end;

procedure TAudioRing.Clear;
begin
  EnterCriticalSection(FLock);
  try
    FCount := 0;
    FHead := 0;
    FTotal := 0;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TAudioRing.Snapshot: TSingleArray;
var
  I, Start: Integer;
begin
  Result := nil;
  EnterCriticalSection(FLock);
  try
    SetLength(Result, FCount);
    Start := (FHead - FCount + FCapacity) mod FCapacity;
    for I := 0 to FCount - 1 do
      Result[I] := FData[(Start + I) mod FCapacity];
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TAudioRing.PeakLevel(SampleRate: Integer; Seconds: Double): Single;
var
  I, Wanted, Index: Integer;
  Value: Single;
begin
  Result := 0;
  EnterCriticalSection(FLock);
  try
    Wanted := Min(FCount, Max(1, Round(Seconds * SampleRate)));
    for I := 1 to Wanted do
    begin
      Index := (FHead - I + FCapacity) mod FCapacity;
      Value := Abs(FData[Index]);
      if Value > Result then
        Result := Value;
    end;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TAudioRing.ReadSince(var Position: Int64; out Data: TSingleArray): Boolean;
var
  Available: Int64;
  Count, Start, I: Integer;
begin
  Data := nil;
  Result := True;
  EnterCriticalSection(FLock);
  try
    if Position > FTotal then
      Position := FTotal;
    Available := FTotal - Position;
    if Available <= 0 then
      Exit;
    if Available > FCount then
    begin
      { 追いつけずに古い音声を失いました。/ Fell behind and lost older audio. }
      Position := FTotal - FCount;
      Available := FCount;
      Result := False;
    end;
    Count := Integer(Available);
    SetLength(Data, Count);
    Start := (FHead - Count + FCapacity) mod FCapacity;
    for I := 0 to Count - 1 do
      Data[I] := FData[(Start + I) mod FCapacity];
    Position := FTotal;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TAudioRing.TotalWritten: Int64;
begin
  EnterCriticalSection(FLock);
  try
    Result := FTotal;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

type
  TCaptureThread = class(TThread)
  private
    FOwner: TAudioCapture;
    FRing: TAudioRing;
    FSampleRate: Integer;
    FFramesPerBuffer: Integer;
  protected
    procedure Execute; override;
  public
    constructor Create(AOwner: TAudioCapture; ARing: TAudioRing;
      ASampleRate, AFramesPerBuffer: Integer);
  end;

  TPlaybackThread = class(TThread)
  private
    FOwner: TAudioPlayback;
    FSamples: TSingleArray;
    FSampleRate: Integer;
  protected
    procedure Execute; override;
  public
    constructor Create(AOwner: TAudioPlayback; const ASamples: TSingleArray;
      ASampleRate: Integer);
  end;

constructor TCaptureThread.Create(AOwner: TAudioCapture; ARing: TAudioRing;
  ASampleRate, AFramesPerBuffer: Integer);
begin
  FOwner := AOwner;
  FRing := ARing;
  FSampleRate := ASampleRate;
  FFramesPerBuffer := AFramesPerBuffer;
  FreeOnTerminate := False;
  inherited Create(False);
end;

procedure TCaptureThread.Execute;
var
  Stream: TPaStream;
  Buffer: TSingleArray;
  Code: LongInt;
  Opened, Started: Boolean;
begin
  Stream := nil;
  Opened := False;
  Started := False;
  SetLength(Buffer, FFramesPerBuffer);
  try
    AcquirePortAudio;
    try
      Code := Pa_OpenDefaultStream(Stream, 1, 0, PA_FLOAT32, FSampleRate,
        LongWord(FFramesPerBuffer), nil, nil);
      if Code <> PA_NO_ERROR then
        raise EDeepCW.CreateFmt('Could not open the input stream: %s', [ErrorText(Code)]);
      Opened := True;

      Code := Pa_StartStream(Stream);
      if Code <> PA_NO_ERROR then
        raise EDeepCW.CreateFmt('Could not start the input stream: %s', [ErrorText(Code)]);
      Started := True;

      while not Terminated do
      begin
        Code := Pa_ReadStream(Stream, @Buffer[0], LongWord(FFramesPerBuffer));
        { オーバーフローは取りこぼしを意味し、録音の失敗ではありません。
        An overflow means samples were dropped, not that recording failed. }
        if (Code <> PA_NO_ERROR) and (Code <> PA_INPUT_OVERFLOWED) then
          raise EDeepCW.CreateFmt('Reading the input stream failed: %s', [ErrorText(Code)]);
        FRing.Push(Buffer, FFramesPerBuffer);
      end;
    finally
      if Started then Pa_StopStream(Stream);
      if Opened then Pa_CloseStream(Stream);
      ReleasePortAudio;
    end;
  except
    on E: Exception do
      FOwner.FLastError := E.Message;
  end;
end;

{ TAudioCapture }

constructor TAudioCapture.Create(ARing: TAudioRing; ASampleRate: Integer;
  AFramesPerBuffer: Integer);
begin
  inherited Create;
  FRing := ARing;
  FSampleRate := ASampleRate;
  FFramesPerBuffer := Max(64, AFramesPerBuffer);
end;

destructor TAudioCapture.Destroy;
begin
  Stop;
  inherited Destroy;
end;

function TAudioCapture.GetRunning: Boolean;
begin
  Result := (FThread <> nil) and not FThread.Finished;
end;

procedure TAudioCapture.Start;
begin
  if FThread <> nil then
    Exit;
  FLastError := '';
  FThread := TCaptureThread.Create(Self, FRing, FSampleRate, FFramesPerBuffer);
end;

procedure TAudioCapture.Stop;
begin
  if FThread = nil then
    Exit;
  FThread.Terminate;
  FThread.WaitFor;
  FreeAndNil(FThread);
end;

{ TPlaybackThread }

constructor TPlaybackThread.Create(AOwner: TAudioPlayback; const ASamples: TSingleArray;
  ASampleRate: Integer);
begin
  FOwner := AOwner;
  FSamples := Copy(ASamples, 0, Length(ASamples));
  FSampleRate := ASampleRate;
  FreeOnTerminate := False;
  inherited Create(False);
end;

procedure TPlaybackThread.Execute;
const
  ChunkFrames = 512;
var
  Stream: TPaStream;
  Chunk: TSingleArray;
  Code: LongInt;
  Position, Count, I: Integer;
  Opened, Started: Boolean;
begin
  Stream := nil;
  Opened := False;
  Started := False;
  SetLength(Chunk, ChunkFrames);
  try
    AcquirePortAudio;
    try
      Code := Pa_OpenDefaultStream(Stream, 0, 1, PA_FLOAT32, FSampleRate,
        LongWord(ChunkFrames), nil, nil);
      if Code <> PA_NO_ERROR then
        raise EDeepCW.CreateFmt('Could not open the output stream: %s', [ErrorText(Code)]);
      Opened := True;

      Code := Pa_StartStream(Stream);
      if Code <> PA_NO_ERROR then
        raise EDeepCW.CreateFmt('Could not start the output stream: %s', [ErrorText(Code)]);
      Started := True;

      Position := 0;
      while (not Terminated) and (Position < Length(FSamples)) do
      begin
        Count := Min(ChunkFrames, Length(FSamples) - Position);
        for I := 0 to Count - 1 do
          Chunk[I] := FSamples[Position + I];
        { デバイスは常に満たされたバッファを求めるため、最後は無音で埋めます。
        The device always wants a full buffer; pad the last one with silence. }
        for I := Count to ChunkFrames - 1 do
          Chunk[I] := 0;

        Code := Pa_WriteStream(Stream, @Chunk[0], LongWord(ChunkFrames));
        if (Code <> PA_NO_ERROR) and (Code <> PA_OUTPUT_UNDERFLOWED) then
          raise EDeepCW.CreateFmt('Writing the output stream failed: %s', [ErrorText(Code)]);

        Inc(Position, Count);
        FOwner.FPosition := Position;
        if Assigned(FOwner.FOnProgress) then
          FOwner.FOnProgress(FOwner, Position);
      end;
    finally
      if Started then Pa_StopStream(Stream);
      if Opened then Pa_CloseStream(Stream);
      ReleasePortAudio;
    end;
  except
    on E: Exception do
      FOwner.FLastError := E.Message;
  end;
  if Assigned(FOwner.FOnFinished) then
    FOwner.FOnFinished(FOwner);
end;

{ TAudioPlayback }

destructor TAudioPlayback.Destroy;
begin
  Stop;
  inherited Destroy;
end;

function TAudioPlayback.GetRunning: Boolean;
begin
  Result := (FThread <> nil) and not FThread.Finished;
end;

procedure TAudioPlayback.Play(const Samples: TSingleArray; ASampleRate: Integer);
begin
  Stop;
  FLastError := '';
  FPosition := 0;
  if Length(Samples) = 0 then
    Exit;
  FThread := TPlaybackThread.Create(Self, Samples, ASampleRate);
end;

procedure TAudioPlayback.Stop;
begin
  if FThread = nil then
    Exit;
  FThread.Terminate;
  FThread.WaitFor;
  FreeAndNil(FThread);
end;

initialization
  InitCriticalSection(GInitLock);

finalization
  if GHandle <> NilHandle then
  begin
    if (GInitCount > 0) and Assigned(Pa_Terminate) then
      Pa_Terminate();
    UnloadLibrary(GHandle);
    GHandle := NilHandle;
  end;
  DoneCriticalSection(GInitLock);

end.
