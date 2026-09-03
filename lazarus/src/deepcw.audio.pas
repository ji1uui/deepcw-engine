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
  SysUtils, Classes, Math, DynLibs, ctypes, DeepCW.Types;

const
  { 装置を選ばない、すなわち OS の既定の入力を使うことを表します。
    Means no device was chosen, i.e. use the operating system's default. }
  AUDIO_DEFAULT_DEVICE = -1;

  { 録音から受け取る値の上限。これを超えるものは壊れた値とみなします。
    Largest value accepted from a capture device; beyond this it is broken. }
  AUDIO_SANE_PEAK = 4.0;

type
  { 録音に使える装置 1 台の説明です。利用者に見せるのは名前と、どの音声方式
    （ALSA、WASAPI など）に属するかだけです。同じ装置が方式ごとに何度も現れる
    ため、方式が分からないと選びようがありません（要件 FR-A.3）。

    One device that can record. What the operator sees is its name and which
    host API (ALSA, WASAPI and so on) it belongs to; the same hardware appears
    once per host API, so without that they cannot tell the entries apart
    (requirement FR-A.3). }
  TAudioDevice = record
    Index: Integer;             { PortAudio の装置番号 / PortAudio device index }
    Name: string;
    HostApi: string;
    MaxInputChannels: Integer;
    DefaultSampleRate: Double;
    IsDefault: Boolean;
  end;
  TAudioDevices = array of TAudioDevice;

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
    FDeviceIndex: Integer;
    FLastError: string;
    function GetRunning: Boolean;
  public
    { ADeviceIndex に AUDIO_DEFAULT_DEVICE を渡すと、OS の既定の入力装置を
      使います。装置を選ばずに始められることが、立ち上がりの体験の要です
      （要件 FR-A.2）。

      Passing AUDIO_DEFAULT_DEVICE as ADeviceIndex uses the operating system's
      default input. Being able to start without choosing anything is the
      point of the opening experience (requirement FR-A.2). }
    constructor Create(ARing: TAudioRing; ASampleRate: Integer;
      ADeviceIndex: Integer = -1; AFramesPerBuffer: Integer = 512);
    destructor Destroy; override;
    procedure Start;
    procedure Stop;
    property Running: Boolean read GetRunning;
    property LastError: string read FLastError;
    property SampleRate: Integer read FSampleRate;
    property DeviceIndex: Integer read FDeviceIndex;
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

{ 録音に使える装置を列挙します。PortAudio を読み込めない場合は空を返します。
  例外を投げないのは、装置の一覧は「あれば便利」であって、無くても既定の装置
  で受信できるからです。

  Lists the devices that can record, returning an empty list when PortAudio
  cannot be loaded. It does not raise, because the list is a convenience:
  without it reception still works on the default device. }
function InputDevices: TAudioDevices;

{ 既定の入力装置の番号です。取得できない場合は AUDIO_DEFAULT_DEVICE を返します。
  The default input device index, or AUDIO_DEFAULT_DEVICE when unavailable. }
function DefaultInputDeviceIndex: Integer;

{ PortAudio の構造体の並びが C と一致しているかを確かめ、その内訳を返します。

  構造体は C の並びをそのまま読むため、詰め物の入り方が処理系で異なります。
  ずれていれば標本化周波数も装置名も嘘になりますが、動かしてみるまで
  分かりません。移植先ではまずこれを確かめてください（要件 NFR-3）。

  Checks that the PortAudio structures match the C layout and describes what
  it found. The structures are read as the C layout they are, and the padding
  differs between platforms; a mismatch makes sample rates and device names
  nonsense, and nothing says so until it is run. Check this first on any
  platform it is ported to (requirement NFR-3). }
function CheckStructureLayout(out Report: string): Boolean;

implementation

const
  PA_FLOAT32 = $00000001;
  PA_NO_FLAG = 0;
  PA_NO_ERROR = 0;
  PA_INPUT_OVERFLOWED = -9981;
  PA_OUTPUT_UNDERFLOWED = -9980;

{ ここから下の record は C の構造体そのものです。$PACKRECORDS C により、
  詰め物の入り方を C コンパイラに合わせます。並びを変えたり項目を省いたり
  すると、後続の項目の位置がずれて誤った値を読みます。

  The records below are the C structures themselves. $PACKRECORDS C makes the
  padding match a C compiler's. Reordering or omitting a field shifts every
  field after it and makes the values read back nonsense. }
{$PACKRECORDS C}
type
  TPaStream = Pointer;

  { PaSampleFormat と PaStreamFlags は C の unsigned long です。その大きさは
    処理系で異なる（Linux/macOS の 64 ビットで 8 バイト、Windows で 4 バイト）
    ため、culong を使います。構造体の中では、この違いが後続の項目の位置を
    変えてしまいます。

    PaSampleFormat and PaStreamFlags are C's unsigned long, whose width differs
    between platforms (8 bytes on 64-bit Linux and macOS, 4 on Windows), so
    culong is used. Inside a structure that difference moves every field after
    it. }
  TPaDeviceInfo = record
    StructVersion: cint;
    Name: PAnsiChar;
    HostApi: cint;
    MaxInputChannels: cint;
    MaxOutputChannels: cint;
    DefaultLowInputLatency: cdouble;
    DefaultLowOutputLatency: cdouble;
    DefaultHighInputLatency: cdouble;
    DefaultHighOutputLatency: cdouble;
    DefaultSampleRate: cdouble;
  end;
  PPaDeviceInfo = ^TPaDeviceInfo;

  TPaHostApiInfo = record
    StructVersion: cint;
    ApiType: cint;
    Name: PAnsiChar;
    DeviceCount: cint;
    DefaultInputDevice: cint;
    DefaultOutputDevice: cint;
  end;
  PPaHostApiInfo = ^TPaHostApiInfo;

  TPaStreamParameters = record
    Device: cint;
    ChannelCount: cint;
    SampleFormat: culong;
    SuggestedLatency: cdouble;
    HostApiSpecificStreamInfo: Pointer;
  end;
  PPaStreamParameters = ^TPaStreamParameters;

  TPaInitialize = function: LongInt; cdecl;
  TPaTerminate = function: LongInt; cdecl;
  TPaGetErrorText = function(Error: LongInt): PAnsiChar; cdecl;
  TPaGetVersionText = function: PAnsiChar; cdecl;
  TPaOpenDefaultStream = function(out Stream: TPaStream; InputChannels, OutputChannels: LongInt;
    SampleFormat: LongWord; SampleRate: Double; FramesPerBuffer: LongWord;
    Callback: Pointer; UserData: Pointer): LongInt; cdecl;
  TPaStreamAction = function(Stream: TPaStream): LongInt; cdecl;
  TPaTransfer = function(Stream: TPaStream; Buffer: Pointer; Frames: LongWord): LongInt; cdecl;
  TPaGetCount = function: cint; cdecl;
  TPaGetDeviceInfo = function(Device: cint): PPaDeviceInfo; cdecl;
  TPaGetHostApiInfo = function(HostApi: cint): PPaHostApiInfo; cdecl;
  TPaOpenStream = function(out Stream: TPaStream;
    InputParameters, OutputParameters: PPaStreamParameters;
    SampleRate: cdouble; FramesPerBuffer: culong; StreamFlags: culong;
    Callback: Pointer; UserData: Pointer): LongInt; cdecl;

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
  { 装置の列挙は必須ではありません。読み込めなくても、既定の装置で受信は
    できます（要件 FR-A.2）。
    Enumeration is optional: without it reception still works on the default
    device (requirement FR-A.2). }
  Pa_GetDeviceCount: TPaGetCount = nil;
  Pa_GetDefaultInputDevice: TPaGetCount = nil;
  Pa_GetDeviceInfo: TPaGetDeviceInfo = nil;
  Pa_GetHostApiInfo: TPaGetHostApiInfo = nil;
  Pa_OpenStream: TPaOpenStream = nil;

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
  Pa_GetDeviceCount := TPaGetCount(GetProcedureAddress(GHandle, 'Pa_GetDeviceCount'));
  Pa_GetDefaultInputDevice := TPaGetCount(GetProcedureAddress(GHandle, 'Pa_GetDefaultInputDevice'));
  Pa_GetDeviceInfo := TPaGetDeviceInfo(GetProcedureAddress(GHandle, 'Pa_GetDeviceInfo'));
  Pa_GetHostApiInfo := TPaGetHostApiInfo(GetProcedureAddress(GHandle, 'Pa_GetHostApiInfo'));
  Pa_OpenStream := TPaOpenStream(GetProcedureAddress(GHandle, 'Pa_OpenStream'));

  { 上の 5 つは一覧と装置指定のためのもので、無くても既定の装置で受信できる
    ため、成否には含めません。
    The five above serve enumeration and explicit device choice; reception
    works on the default device without them, so they do not gate success. }
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

function CheckStructureLayout(out Report: string): Boolean;
var
  Lines: TStringList;
  Offset, PointerAlign: Integer;
  Device: TPaDeviceInfo;
  Api: TPaHostApiInfo;
  Params: TPaStreamParameters;
  Base: PtrUInt;
  Matches: Boolean;

  { C コンパイラと同じ規則で、次の項目が始まる位置を求めます。
    Where the next member starts, by the same rule a C compiler uses. }
  function Advance(Alignment, Size: Integer): Integer;
  begin
    Offset := ((Offset + Alignment - 1) div Alignment) * Alignment;
    Result := Offset;
    Inc(Offset, Size);
  end;

  procedure Compare(const What: string; Actual, Expected: Integer);
  begin
    if Actual <> Expected then
    begin
      Lines.Add(Format('  NG   %-28s 実際 %d / C の規則では %d',
        [What, Actual, Expected]));
      Matches := False;
    end
    else
      Lines.Add(Format('  ok   %-28s %d', [What, Actual]));
  end;

begin
  Matches := True;
  PointerAlign := SizeOf(Pointer);
  Lines := TStringList.Create;
  try
    Lines.Add(Format('ポインタ %d / culong %d / cdouble %d / cint %d バイト',
      [SizeOf(Pointer), SizeOf(culong), SizeOf(cdouble), SizeOf(cint)]));

    Lines.Add('PaDeviceInfo');
    Base := PtrUInt(@Device);
    Offset := 0;
    Advance(SizeOf(cint), SizeOf(cint));
    Compare('name', Integer(PtrUInt(@Device.Name) - Base),
      Advance(PointerAlign, SizeOf(Pointer)));
    Compare('hostApi', Integer(PtrUInt(@Device.HostApi) - Base),
      Advance(SizeOf(cint), SizeOf(cint)));
    Compare('maxInputChannels', Integer(PtrUInt(@Device.MaxInputChannels) - Base),
      Advance(SizeOf(cint), SizeOf(cint)));
    Compare('maxOutputChannels', Integer(PtrUInt(@Device.MaxOutputChannels) - Base),
      Advance(SizeOf(cint), SizeOf(cint)));
    Advance(SizeOf(cdouble), SizeOf(cdouble));
    Advance(SizeOf(cdouble), SizeOf(cdouble));
    Advance(SizeOf(cdouble), SizeOf(cdouble));
    Compare('defaultHighOutputLatency',
      Integer(PtrUInt(@Device.DefaultHighOutputLatency) - Base),
      Advance(SizeOf(cdouble), SizeOf(cdouble)));
    Compare('defaultSampleRate', Integer(PtrUInt(@Device.DefaultSampleRate) - Base),
      Advance(SizeOf(cdouble), SizeOf(cdouble)));

    Lines.Add('PaHostApiInfo');
    Base := PtrUInt(@Api);
    Offset := 0;
    Advance(SizeOf(cint), SizeOf(cint));
    Compare('type', Integer(PtrUInt(@Api.ApiType) - Base),
      Advance(SizeOf(cint), SizeOf(cint)));
    Compare('name', Integer(PtrUInt(@Api.Name) - Base),
      Advance(PointerAlign, SizeOf(Pointer)));
    Compare('deviceCount', Integer(PtrUInt(@Api.DeviceCount) - Base),
      Advance(SizeOf(cint), SizeOf(cint)));

    Lines.Add('PaStreamParameters');
    Base := PtrUInt(@Params);
    Offset := 0;
    Advance(SizeOf(cint), SizeOf(cint));
    Compare('channelCount', Integer(PtrUInt(@Params.ChannelCount) - Base),
      Advance(SizeOf(cint), SizeOf(cint)));
    Compare('sampleFormat', Integer(PtrUInt(@Params.SampleFormat) - Base),
      Advance(SizeOf(culong), SizeOf(culong)));
    Compare('suggestedLatency', Integer(PtrUInt(@Params.SuggestedLatency) - Base),
      Advance(SizeOf(cdouble), SizeOf(cdouble)));
    Compare('hostApiSpecificStreamInfo',
      Integer(PtrUInt(@Params.HostApiSpecificStreamInfo) - Base),
      Advance(PointerAlign, SizeOf(Pointer)));

    Report := Lines.Text;
  finally
    Lines.Free;
  end;
  Result := Matches;
end;

function DefaultInputDeviceIndex: Integer;
begin
  Result := AUDIO_DEFAULT_DEVICE;
  { 入口の確認より先に確保します。読み込む前は関数の番地がまだ nil であり、
    先に確認すると必ず「取得できない」になります。

    Acquire before checking the entry points: before the library is loaded
    their addresses are still nil, so checking first always answers
    "unavailable". }
  try
    AcquirePortAudio;
  except
    Exit;
  end;
  try
    if not Assigned(Pa_GetDefaultInputDevice) then
      Exit;
    Result := Pa_GetDefaultInputDevice();
    if Result < 0 then
      Result := AUDIO_DEFAULT_DEVICE;
  finally
    ReleasePortAudio;
  end;
end;

function InputDevices: TAudioDevices;
var
  Count, I, Found, Default_: Integer;
  Info: PPaDeviceInfo;
  ApiInfo: PPaHostApiInfo;
begin
  Result := nil;
  { 入口の確認より先に確保します。読み込む前は関数の番地がまだ nil です。
    Acquire before checking the entry points; before loading they are nil. }
  try
    AcquirePortAudio;
  except
    { 音声装置が使えないことは、一覧が空であることで伝わります。ここで例外を
      投げると、設定画面を開いただけで叱られることになります。
      An unusable sound system shows up as an empty list; raising here would
      scold the operator merely for opening the settings panel. }
    Exit;
  end;
  try
    if not (Assigned(Pa_GetDeviceCount) and Assigned(Pa_GetDeviceInfo)) then
      Exit;
    Count := Pa_GetDeviceCount();
    if Count <= 0 then
      Exit;
    if Assigned(Pa_GetDefaultInputDevice) then
      Default_ := Pa_GetDefaultInputDevice()
    else
      Default_ := AUDIO_DEFAULT_DEVICE;

    SetLength(Result, Count);
    Found := 0;
    for I := 0 to Count - 1 do
    begin
      Info := Pa_GetDeviceInfo(I);
      if (Info = nil) or (Info^.MaxInputChannels <= 0) then
        Continue;
      Result[Found].Index := I;
      Result[Found].Name := string(Info^.Name);
      Result[Found].MaxInputChannels := Info^.MaxInputChannels;
      Result[Found].DefaultSampleRate := Info^.DefaultSampleRate;
      Result[Found].IsDefault := I = Default_;
      Result[Found].HostApi := '';
      if Assigned(Pa_GetHostApiInfo) then
      begin
        ApiInfo := Pa_GetHostApiInfo(Info^.HostApi);
        if ApiInfo <> nil then
          Result[Found].HostApi := string(ApiInfo^.Name);
      end;
      Inc(Found);
    end;
    SetLength(Result, Found);
  finally
    ReleasePortAudio;
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
      { 届いた値をここで正気の範囲に収めます。実際に、開けはするものの中身を
        埋めない録音装置（ALSA の null など）が、未初期化のメモリをそのまま
        返してきました。NaN が 1 つ混じればスペクトログラム全体が壊れ、無音の
        はずの入力から文字が湧きます。10^38 のような値も同じです。

        PortAudio の float32 は本来 -1〜+1 ですが、過大入力で少し超えることは
        あるため、余裕を見た範囲で頭打ちにします。本物の過大入力はレベル表示に
        残り、壊れた値だけが取り除かれます。

        Incoming values are brought into a sane range here. A capture device
        that opens but never fills the buffer (ALSA's null, for one) hands back
        uninitialised memory; a single NaN ruins the whole spectrogram and
        makes characters appear out of what should be silence, and so does a
        value of 10^38. PortAudio's float32 is nominally -1 to +1 but genuine
        overdrive can exceed that a little, so the clamp leaves room: real
        overdrive still shows on the level meter and only broken values go. }
      if IsNan(Source[I]) or IsInfinite(Source[I]) then
        FData[FHead] := 0
      else
        FData[FHead] := ClampDouble(Source[I], -AUDIO_SANE_PEAK, AUDIO_SANE_PEAK);
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
    FDeviceIndex: Integer;
    function OpenInput(out Stream: TPaStream): LongInt;
  protected
    procedure Execute; override;
  public
    constructor Create(AOwner: TAudioCapture; ARing: TAudioRing;
      ASampleRate, ADeviceIndex, AFramesPerBuffer: Integer);
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
  ASampleRate, ADeviceIndex, AFramesPerBuffer: Integer);
begin
  FOwner := AOwner;
  FRing := ARing;
  FSampleRate := ASampleRate;
  FDeviceIndex := ADeviceIndex;
  FFramesPerBuffer := AFramesPerBuffer;
  FreeOnTerminate := False;
  inherited Create(False);
end;

{ 装置を選んでいなければ、これまでどおり Pa_OpenDefaultStream を使います。
  既定の経路を変えずに残すことで、装置指定を足したことが、選んでいない人の
  受信に影響しないようにしています。

  With no device chosen this stays on Pa_OpenDefaultStream exactly as before.
  Leaving the default path untouched keeps the new device choice from
  affecting anyone who has not made one. }
function TCaptureThread.OpenInput(out Stream: TPaStream): LongInt;
var
  Params: TPaStreamParameters;
  Info: PPaDeviceInfo;
begin
  if (FDeviceIndex < 0) or not (Assigned(Pa_OpenStream) and Assigned(Pa_GetDeviceInfo)) then
    Exit(Pa_OpenDefaultStream(Stream, 1, 0, PA_FLOAT32, FSampleRate,
      LongWord(FFramesPerBuffer), nil, nil));

  Info := Pa_GetDeviceInfo(FDeviceIndex);
  if (Info = nil) or (Info^.MaxInputChannels <= 0) then
    { 装置が消えている（USB を抜いた等）場合は、黙って既定へ戻します。
      A device that has gone away, an unplugged USB interface say, quietly
      falls back to the default. }
    Exit(Pa_OpenDefaultStream(Stream, 1, 0, PA_FLOAT32, FSampleRate,
      LongWord(FFramesPerBuffer), nil, nil));

  FillChar(Params, SizeOf(Params), 0);
  Params.Device := FDeviceIndex;
  Params.ChannelCount := 1;
  Params.SampleFormat := PA_FLOAT32;
  Params.SuggestedLatency := Info^.DefaultHighInputLatency;
  Params.HostApiSpecificStreamInfo := nil;
  Result := Pa_OpenStream(Stream, @Params, nil, FSampleRate,
    culong(FFramesPerBuffer), PA_NO_FLAG, nil, nil);
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
      Code := OpenInput(Stream);
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
  ADeviceIndex: Integer; AFramesPerBuffer: Integer);
begin
  inherited Create;
  FRing := ARing;
  FSampleRate := ASampleRate;
  FDeviceIndex := ADeviceIndex;
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
  FThread := TCaptureThread.Create(Self, FRing, FSampleRate, FDeviceIndex,
    FFramesPerBuffer);
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
