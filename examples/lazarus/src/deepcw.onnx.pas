unit DeepCW.Onnx;

{ Minimal ONNX Runtime C API binding.

  onnxruntime exports a single symbol, OrtGetApiBase, which hands back a struct
  of function pointers. That struct is append-only across releases, so binding
  the leading members by position is stable: this unit declares every entry up
  to the release helpers, typing only the ones it actually calls and leaving
  the rest as opaque pointers.

  The library is loaded at run time, so the application starts even when
  onnxruntime is missing and can tell the user where to put it. }

{$mode objfpc}{$H+}
{$macro on}
{$packrecords c}

interface

uses
  SysUtils, Classes, DynLibs, DeepCW.Types;

{$IFDEF WINDOWS}
  {$DEFINE ORTCALL := stdcall}
type
  { CreateSession takes ORTCHAR_T*, which is wchar_t on Windows. }
  POrtPathChar = PWideChar;
{$ELSE}
  {$DEFINE ORTCALL := cdecl}
type
  POrtPathChar = PAnsiChar;
{$ENDIF}

const
  { ORT_API_VERSION of onnxruntime 1.10. Newer runtimes still serve this
    version, and everything this unit uses predates it. }
  ORT_API_VERSION_REQUESTED = 11;

  ORT_LOGGING_LEVEL_WARNING = 2;
  ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT = 1;
  ORT_ARENA_ALLOCATOR = 1;
  ORT_MEM_TYPE_DEFAULT = 0;
  ORT_ENABLE_ALL = 99;

type
  POrtStatus = Pointer;
  POrtEnv = Pointer;
  POrtSession = Pointer;
  POrtSessionOptions = Pointer;
  POrtRunOptions = Pointer;
  POrtValue = Pointer;
  POrtMemoryInfo = Pointer;
  POrtAllocator = Pointer;
  POrtTypeInfo = Pointer;
  POrtTensorTypeAndShapeInfo = Pointer;

  PPOrtValue = ^POrtValue;
  PPAnsiChar = ^PAnsiChar;

  POrtApi = ^TOrtApi;

  { Field order follows onnxruntime_c_api.h. Do not reorder or remove entries:
    each slot is an offset into the runtime's own struct. }
  TOrtApi = record
    CreateStatus: Pointer;                                                            {   1 }
    GetErrorCode: Pointer;                                                            {   2 }
    GetErrorMessage: function(Status: POrtStatus): PAnsiChar; ORTCALL;                {   3 }
    CreateEnv: function(LogLevel: Integer; LogId: PAnsiChar;
      out Env: POrtEnv): POrtStatus; ORTCALL;                                         {   4 }
    CreateEnvWithCustomLogger: Pointer;                                               {   5 }
    EnableTelemetryEvents: Pointer;                                                   {   6 }
    DisableTelemetryEvents: Pointer;                                                  {   7 }
    CreateSession: function(Env: POrtEnv; ModelPath: POrtPathChar;
      Options: POrtSessionOptions; out Session: POrtSession): POrtStatus; ORTCALL;    {   8 }
    CreateSessionFromArray: function(Env: POrtEnv; ModelData: Pointer;
      ModelDataLength: PtrUInt; Options: POrtSessionOptions;
      out Session: POrtSession): POrtStatus; ORTCALL;                                 {   9 }
    Run: function(Session: POrtSession; RunOptions: POrtRunOptions;
      InputNames: PPAnsiChar; Inputs: PPOrtValue; InputCount: PtrUInt;
      OutputNames: PPAnsiChar; OutputCount: PtrUInt;
      Outputs: PPOrtValue): POrtStatus; ORTCALL;                                      {  10 }
    CreateSessionOptions: function(out Options: POrtSessionOptions): POrtStatus; ORTCALL; { 11 }
    SetOptimizedModelFilePath: Pointer;                                               {  12 }
    CloneSessionOptions: Pointer;                                                     {  13 }
    SetSessionExecutionMode: Pointer;                                                 {  14 }
    EnableProfiling: Pointer;                                                         {  15 }
    DisableProfiling: Pointer;                                                        {  16 }
    EnableMemPattern: Pointer;                                                        {  17 }
    DisableMemPattern: Pointer;                                                       {  18 }
    EnableCpuMemArena: Pointer;                                                       {  19 }
    DisableCpuMemArena: Pointer;                                                      {  20 }
    SetSessionLogId: Pointer;                                                         {  21 }
    SetSessionLogVerbosityLevel: Pointer;                                             {  22 }
    SetSessionLogSeverityLevel: Pointer;                                              {  23 }
    SetSessionGraphOptimizationLevel: function(Options: POrtSessionOptions;
      GraphOptimizationLevel: Integer): POrtStatus; ORTCALL;                          {  24 }
    SetIntraOpNumThreads: function(Options: POrtSessionOptions;
      IntraOpNumThreads: Integer): POrtStatus; ORTCALL;                               {  25 }
    SetInterOpNumThreads: function(Options: POrtSessionOptions;
      InterOpNumThreads: Integer): POrtStatus; ORTCALL;                               {  26 }
    CreateCustomOpDomain: Pointer;                                                    {  27 }
    CustomOpDomain_Add: Pointer;                                                      {  28 }
    AddCustomOpDomain: Pointer;                                                       {  29 }
    RegisterCustomOpsLibrary: Pointer;                                                {  30 }
    SessionGetInputCount: function(Session: POrtSession;
      out Count: PtrUInt): POrtStatus; ORTCALL;                                       {  31 }
    SessionGetOutputCount: function(Session: POrtSession;
      out Count: PtrUInt): POrtStatus; ORTCALL;                                       {  32 }
    SessionGetOverridableInitializerCount: Pointer;                                   {  33 }
    SessionGetInputTypeInfo: Pointer;                                                 {  34 }
    SessionGetOutputTypeInfo: Pointer;                                                {  35 }
    SessionGetOverridableInitializerTypeInfo: Pointer;                                {  36 }
    SessionGetInputName: function(Session: POrtSession; Index: PtrUInt;
      Allocator: POrtAllocator; out Value: PAnsiChar): POrtStatus; ORTCALL;           {  37 }
    SessionGetOutputName: function(Session: POrtSession; Index: PtrUInt;
      Allocator: POrtAllocator; out Value: PAnsiChar): POrtStatus; ORTCALL;           {  38 }
    SessionGetOverridableInitializerName: Pointer;                                    {  39 }
    CreateRunOptions: Pointer;                                                        {  40 }
    RunOptionsSetRunLogVerbosityLevel: Pointer;                                       {  41 }
    RunOptionsSetRunLogSeverityLevel: Pointer;                                        {  42 }
    RunOptionsSetRunTag: Pointer;                                                     {  43 }
    RunOptionsGetRunLogVerbosityLevel: Pointer;                                       {  44 }
    RunOptionsGetRunLogSeverityLevel: Pointer;                                        {  45 }
    RunOptionsGetRunTag: Pointer;                                                     {  46 }
    RunOptionsSetTerminate: Pointer;                                                  {  47 }
    RunOptionsUnsetTerminate: Pointer;                                                {  48 }
    CreateTensorAsOrtValue: Pointer;                                                  {  49 }
    CreateTensorWithDataAsOrtValue: function(Info: POrtMemoryInfo; Data: Pointer;
      DataLength: PtrUInt; Shape: PInt64; ShapeLength: PtrUInt;
      ElementType: Integer; out Value: POrtValue): POrtStatus; ORTCALL;               {  50 }
    IsTensor: Pointer;                                                                {  51 }
    GetTensorMutableData: function(Value: POrtValue;
      out Data: Pointer): POrtStatus; ORTCALL;                                        {  52 }
    FillStringTensor: Pointer;                                                        {  53 }
    GetStringTensorDataLength: Pointer;                                               {  54 }
    GetStringTensorContent: Pointer;                                                  {  55 }
    CastTypeInfoToTensorInfo: Pointer;                                                {  56 }
    GetOnnxTypeFromTypeInfo: Pointer;                                                 {  57 }
    CreateTensorTypeAndShapeInfo: Pointer;                                            {  58 }
    SetTensorElementType: Pointer;                                                    {  59 }
    SetDimensions: Pointer;                                                           {  60 }
    GetTensorElementType: function(Info: POrtTensorTypeAndShapeInfo;
      out ElementType: Integer): POrtStatus; ORTCALL;                                 {  61 }
    GetDimensionsCount: function(Info: POrtTensorTypeAndShapeInfo;
      out Count: PtrUInt): POrtStatus; ORTCALL;                                       {  62 }
    GetDimensions: function(Info: POrtTensorTypeAndShapeInfo; Dims: PInt64;
      DimsLength: PtrUInt): POrtStatus; ORTCALL;                                      {  63 }
    GetSymbolicDimensions: Pointer;                                                   {  64 }
    GetTensorShapeElementCount: function(Info: POrtTensorTypeAndShapeInfo;
      out Count: PtrUInt): POrtStatus; ORTCALL;                                       {  65 }
    GetTensorTypeAndShape: function(Value: POrtValue;
      out Info: POrtTensorTypeAndShapeInfo): POrtStatus; ORTCALL;                     {  66 }
    GetTypeInfo: Pointer;                                                             {  67 }
    GetValueType: Pointer;                                                            {  68 }
    CreateMemoryInfo: Pointer;                                                        {  69 }
    CreateCpuMemoryInfo: function(AllocatorType: Integer; MemType: Integer;
      out Info: POrtMemoryInfo): POrtStatus; ORTCALL;                                 {  70 }
    CompareMemoryInfo: Pointer;                                                       {  71 }
    MemoryInfoGetName: Pointer;                                                       {  72 }
    MemoryInfoGetId: Pointer;                                                         {  73 }
    MemoryInfoGetMemType: Pointer;                                                    {  74 }
    MemoryInfoGetType: Pointer;                                                       {  75 }
    AllocatorAlloc: Pointer;                                                          {  76 }
    AllocatorFree: function(Allocator: POrtAllocator;
      P: Pointer): POrtStatus; ORTCALL;                                               {  77 }
    AllocatorGetInfo: Pointer;                                                        {  78 }
    GetAllocatorWithDefaultOptions: function(
      out Allocator: POrtAllocator): POrtStatus; ORTCALL;                             {  79 }
    AddFreeDimensionOverride: Pointer;                                                {  80 }
    GetValue: Pointer;                                                                {  81 }
    GetValueCount: Pointer;                                                           {  82 }
    CreateValue: Pointer;                                                             {  83 }
    CreateOpaqueValue: Pointer;                                                       {  84 }
    GetOpaqueValue: Pointer;                                                          {  85 }
    KernelInfoGetAttribute_float: Pointer;                                            {  86 }
    KernelInfoGetAttribute_int64: Pointer;                                            {  87 }
    KernelInfoGetAttribute_string: Pointer;                                           {  88 }
    KernelContext_GetInputCount: Pointer;                                             {  89 }
    KernelContext_GetOutputCount: Pointer;                                            {  90 }
    KernelContext_GetInput: Pointer;                                                  {  91 }
    KernelContext_GetOutput: Pointer;                                                 {  92 }
    ReleaseEnv: procedure(Value: POrtEnv); ORTCALL;                                   {  93 }
    ReleaseStatus: procedure(Value: POrtStatus); ORTCALL;                             {  94 }
    ReleaseMemoryInfo: procedure(Value: POrtMemoryInfo); ORTCALL;                     {  95 }
    ReleaseSession: procedure(Value: POrtSession); ORTCALL;                           {  96 }
    ReleaseValue: procedure(Value: POrtValue); ORTCALL;                               {  97 }
    ReleaseRunOptions: procedure(Value: POrtRunOptions); ORTCALL;                      {  98 }
    ReleaseTypeInfo: procedure(Value: POrtTypeInfo); ORTCALL;                         {  99 }
    ReleaseTensorTypeAndShapeInfo: procedure(Value: POrtTensorTypeAndShapeInfo); ORTCALL; { 100 }
    ReleaseSessionOptions: procedure(Value: POrtSessionOptions); ORTCALL;             { 101 }
    ReleaseCustomOpDomain: procedure(Value: Pointer); ORTCALL;                        { 102 }
    { Later releases append more entries here. This binding never reads them. }
  end;

  POrtApiBase = ^TOrtApiBase;
  TOrtApiBase = record
    GetApi: function(Version: LongWord): POrtApi; ORTCALL;
    GetVersionString: function: PAnsiChar; ORTCALL;
  end;

  { A float32 tensor read back from the runtime. }
  TOnnxFloatTensor = record
    Shape: TInt64Array;
    Data: TSingleArray;
  end;

  { One loaded model. Not thread safe: serialise Run calls, or create one
    session per worker thread. }
  TOnnxSession = class
  private
    FEnv: POrtEnv;
    FSession: POrtSession;
    FOptions: POrtSessionOptions;
    FMemoryInfo: POrtMemoryInfo;
    FAllocator: POrtAllocator;
    procedure Check(Status: POrtStatus; const Context: string);
    function ReadTensor(Value: POrtValue): TOnnxFloatTensor;
  public
    constructor Create(const ModelPath: string; IntraOpThreads: Integer = 1);
    destructor Destroy; override;

    { Runs the graph with a single float32 input and returns a single float32
      output. Data is copied into the runtime, so InputData may be reused. }
    function RunFloat(const InputName: string; const InputData: TSingleArray;
      const InputShape: array of Int64; const OutputName: string): TOnnxFloatTensor;

    function InputName(Index: Integer): string;
    function OutputName(Index: Integer): string;
    function InputCount: Integer;
    function OutputCount: Integer;
  end;

{ Loads libonnxruntime. Pass an explicit file name, or leave it empty to try
  DEEPCW_ONNXRUNTIME, the executable directory and then the system search path.
  Returns silently if the runtime is already loaded. }
procedure LoadOnnxRuntime(const LibraryPath: string = '');
procedure UnloadOnnxRuntime;
function OnnxRuntimeLoaded: Boolean;
function OnnxRuntimeVersion: string;
function OnnxRuntimeLibraryPath: string;

{ File names tried when no explicit path is given, most specific first. }
function DefaultOnnxRuntimeNames: TStringArray;

implementation

var
  GHandle: TLibHandle = NilHandle;
  GApi: POrtApi = nil;
  GApiBase: POrtApiBase = nil;
  GLibraryPath: string = '';

type
  TOrtGetApiBase = function: POrtApiBase; ORTCALL;

function DefaultOnnxRuntimeNames: TStringArray;
begin
  {$IF DEFINED(WINDOWS)}
  Result := TStringArray.Create('onnxruntime.dll');
  {$ELSEIF DEFINED(DARWIN)}
  Result := TStringArray.Create('libonnxruntime.dylib', 'libonnxruntime.1.dylib');
  {$ELSE}
  Result := TStringArray.Create('libonnxruntime.so', 'libonnxruntime.so.1');
  {$ENDIF}
end;

function TryLoad(const FileName: string): Boolean;
var
  GetApiBase: TOrtGetApiBase;
begin
  Result := False;
  if FileName = '' then
    Exit;
  GHandle := LoadLibrary(FileName);
  if GHandle = NilHandle then
    Exit;

  GetApiBase := TOrtGetApiBase(GetProcedureAddress(GHandle, 'OrtGetApiBase'));
  if GetApiBase = nil then
  begin
    UnloadLibrary(GHandle);
    GHandle := NilHandle;
    Exit;
  end;

  GApiBase := GetApiBase();
  if GApiBase = nil then
  begin
    UnloadLibrary(GHandle);
    GHandle := NilHandle;
    Exit;
  end;

  GApi := GApiBase^.GetApi(ORT_API_VERSION_REQUESTED);
  if GApi = nil then
  begin
    { The runtime is older than the API version this binding needs. }
    GApiBase := nil;
    UnloadLibrary(GHandle);
    GHandle := NilHandle;
    Exit;
  end;

  GLibraryPath := FileName;
  Result := True;
end;

procedure LoadOnnxRuntime(const LibraryPath: string = '');
var
  Candidates: TStringList;
  Names: TStringArray;
  ExeDir, Name: string;
  I: Integer;
begin
  if GApi <> nil then
    Exit;

  Candidates := TStringList.Create;
  try
    if LibraryPath <> '' then
      Candidates.Add(LibraryPath)
    else
    begin
      if GetEnvironmentVariable('DEEPCW_ONNXRUNTIME') <> '' then
        Candidates.Add(GetEnvironmentVariable('DEEPCW_ONNXRUNTIME'));
      ExeDir := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0)));
      Names := DefaultOnnxRuntimeNames;
      for Name in Names do
        Candidates.Add(ExeDir + Name);
      for Name in Names do
        Candidates.Add(Name);
    end;

    for I := 0 to Candidates.Count - 1 do
      if TryLoad(Candidates[I]) then
        Exit;

    raise EDeepCW.CreateFmt(
      'Could not load the ONNX Runtime shared library. Tried: %s. ' +
      'Install onnxruntime and either place the library next to the executable ' +
      'or point DEEPCW_ONNXRUNTIME at it.',
      [Candidates.CommaText]);
  finally
    Candidates.Free;
  end;
end;

procedure UnloadOnnxRuntime;
begin
  if GHandle <> NilHandle then
    UnloadLibrary(GHandle);
  GHandle := NilHandle;
  GApi := nil;
  GApiBase := nil;
  GLibraryPath := '';
end;

function OnnxRuntimeLoaded: Boolean;
begin
  Result := GApi <> nil;
end;

function OnnxRuntimeVersion: string;
begin
  if GApiBase = nil then
    Result := ''
  else
    Result := string(GApiBase^.GetVersionString());
end;

function OnnxRuntimeLibraryPath: string;
begin
  Result := GLibraryPath;
end;

{ TOnnxSession }

procedure TOnnxSession.Check(Status: POrtStatus; const Context: string);
var
  Message: string;
begin
  if Status = nil then
    Exit;
  Message := string(GApi^.GetErrorMessage(Status));
  GApi^.ReleaseStatus(Status);
  raise EDeepCW.CreateFmt('ONNX Runtime failed during %s: %s', [Context, Message]);
end;

constructor TOnnxSession.Create(const ModelPath: string; IntraOpThreads: Integer);
{$IFDEF WINDOWS}
var
  WidePath: UnicodeString;
{$ENDIF}
begin
  inherited Create;
  LoadOnnxRuntime;
  if not FileExists(ModelPath) then
    raise EDeepCW.CreateFmt('Model file not found: %s', [ModelPath]);

  Check(GApi^.CreateEnv(ORT_LOGGING_LEVEL_WARNING, 'deepcw', FEnv), 'CreateEnv');
  Check(GApi^.CreateSessionOptions(FOptions), 'CreateSessionOptions');
  Check(GApi^.SetSessionGraphOptimizationLevel(FOptions, ORT_ENABLE_ALL),
    'SetSessionGraphOptimizationLevel');
  if IntraOpThreads > 0 then
    Check(GApi^.SetIntraOpNumThreads(FOptions, IntraOpThreads), 'SetIntraOpNumThreads');

  {$IFDEF WINDOWS}
  WidePath := UnicodeString(ModelPath);
  Check(GApi^.CreateSession(FEnv, POrtPathChar(WidePath), FOptions, FSession), 'CreateSession');
  {$ELSE}
  Check(GApi^.CreateSession(FEnv, POrtPathChar(PAnsiChar(AnsiString(ModelPath))), FOptions,
    FSession), 'CreateSession');
  {$ENDIF}

  Check(GApi^.CreateCpuMemoryInfo(ORT_ARENA_ALLOCATOR, ORT_MEM_TYPE_DEFAULT, FMemoryInfo),
    'CreateCpuMemoryInfo');
  Check(GApi^.GetAllocatorWithDefaultOptions(FAllocator), 'GetAllocatorWithDefaultOptions');
end;

destructor TOnnxSession.Destroy;
begin
  if GApi <> nil then
  begin
    if FMemoryInfo <> nil then GApi^.ReleaseMemoryInfo(FMemoryInfo);
    if FSession <> nil then GApi^.ReleaseSession(FSession);
    if FOptions <> nil then GApi^.ReleaseSessionOptions(FOptions);
    if FEnv <> nil then GApi^.ReleaseEnv(FEnv);
  end;
  inherited Destroy;
end;

function TOnnxSession.InputCount: Integer;
var
  Count: PtrUInt;
begin
  Check(GApi^.SessionGetInputCount(FSession, Count), 'SessionGetInputCount');
  Result := Integer(Count);
end;

function TOnnxSession.OutputCount: Integer;
var
  Count: PtrUInt;
begin
  Check(GApi^.SessionGetOutputCount(FSession, Count), 'SessionGetOutputCount');
  Result := Integer(Count);
end;

function TOnnxSession.InputName(Index: Integer): string;
var
  Value: PAnsiChar;
begin
  Check(GApi^.SessionGetInputName(FSession, Index, FAllocator, Value), 'SessionGetInputName');
  Result := string(Value);
  GApi^.AllocatorFree(FAllocator, Value);
end;

function TOnnxSession.OutputName(Index: Integer): string;
var
  Value: PAnsiChar;
begin
  Check(GApi^.SessionGetOutputName(FSession, Index, FAllocator, Value), 'SessionGetOutputName');
  Result := string(Value);
  GApi^.AllocatorFree(FAllocator, Value);
end;

function TOnnxSession.ReadTensor(Value: POrtValue): TOnnxFloatTensor;
var
  Info: POrtTensorTypeAndShapeInfo;
  ElementType: Integer;
  DimCount, ElementCount: PtrUInt;
  Data: Pointer;
begin
  Result.Shape := nil;
  Result.Data := nil;
  Info := nil;
  Check(GApi^.GetTensorTypeAndShape(Value, Info), 'GetTensorTypeAndShape');
  try
    Check(GApi^.GetTensorElementType(Info, ElementType), 'GetTensorElementType');
    if ElementType <> ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT then
      raise EDeepCW.CreateFmt('Expected a float32 output tensor, got element type %d.',
        [ElementType]);

    Check(GApi^.GetDimensionsCount(Info, DimCount), 'GetDimensionsCount');
    SetLength(Result.Shape, DimCount);
    if DimCount > 0 then
      Check(GApi^.GetDimensions(Info, @Result.Shape[0], DimCount), 'GetDimensions');

    Check(GApi^.GetTensorShapeElementCount(Info, ElementCount), 'GetTensorShapeElementCount');
    SetLength(Result.Data, ElementCount);
    if ElementCount > 0 then
    begin
      Check(GApi^.GetTensorMutableData(Value, Data), 'GetTensorMutableData');
      Move(Data^, Result.Data[0], ElementCount * SizeOf(Single));
    end;
  finally
    GApi^.ReleaseTensorTypeAndShapeInfo(Info);
  end;
end;

function TOnnxSession.RunFloat(const InputName: string; const InputData: TSingleArray;
  const InputShape: array of Int64; const OutputName: string): TOnnxFloatTensor;
var
  Shape: TInt64Array;
  Expected: Int64;
  I: Integer;
  InputTensor, OutputTensor: POrtValue;
  InputNameC, OutputNameC: AnsiString;
  InputNames, OutputNames: array[0..0] of PAnsiChar;
  Inputs, Outputs: array[0..0] of POrtValue;
begin
  if Length(InputShape) = 0 then
    raise EDeepCW.Create('The input tensor needs at least one dimension.');
  if Length(InputData) = 0 then
    raise EDeepCW.Create('The input tensor holds no data.');

  SetLength(Shape, Length(InputShape));
  Expected := 1;
  for I := 0 to High(InputShape) do
  begin
    Shape[I] := InputShape[I];
    Expected := Expected * InputShape[I];
  end;
  if Expected <> Length(InputData) then
    raise EDeepCW.CreateFmt('The input shape describes %d values but %d were supplied.',
      [Expected, Length(InputData)]);

  InputNameC := AnsiString(InputName);
  OutputNameC := AnsiString(OutputName);
  InputTensor := nil;
  OutputTensor := nil;

  Check(GApi^.CreateTensorWithDataAsOrtValue(FMemoryInfo, @InputData[0],
    PtrUInt(Length(InputData) * SizeOf(Single)), @Shape[0], PtrUInt(Length(Shape)),
    ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, InputTensor), 'CreateTensorWithDataAsOrtValue');
  try
    InputNames[0] := PAnsiChar(InputNameC);
    OutputNames[0] := PAnsiChar(OutputNameC);
    Inputs[0] := InputTensor;
    Outputs[0] := nil;

    Check(GApi^.Run(FSession, nil, @InputNames[0], @Inputs[0], 1, @OutputNames[0], 1,
      @Outputs[0]), 'Run');
    OutputTensor := Outputs[0];
    if OutputTensor = nil then
      raise EDeepCW.Create('The model produced no output tensor.');
    try
      Result := ReadTensor(OutputTensor);
    finally
      GApi^.ReleaseValue(OutputTensor);
    end;
  finally
    GApi^.ReleaseValue(InputTensor);
  end;
end;

finalization
  UnloadOnnxRuntime;

end.
