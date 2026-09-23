unit DeepCW.Hamlib;

{ Hamlib を実行時に読み込み、無線機の内蔵キーヤーで CW を送らせます
  （要件 FR-T.2）。

  **送信は高い危険の境界です**（`lazarus-security-privacy`）。この単位は
  「無線機に文字列を渡す」「止める」「速度を合わせる」「応答を確かめる（周波数を
  読むだけ）」「電源を入れる」だけを持ち、**いつ送るか・いつ電源を入れるかは
  決めません。**その判断は `DeepCW.RigKeyer` と利用者の操作が持ちます。
  **周波数・モード・スプリット・PTT を変える命令と、電源を切る命令は持ちません。**

  取り決め:

  1. **再試行させません**（`retry` を 0 にします）。Hamlib は既定で、応答が
     無い命令を送り直します。`send_morse` を送り直すと、**同じ文が 2 度
     鍵に乗ります。**
  2. **読み込めなくても起動は妨げません。**受信は Hamlib を使いません
     （Receive は fail-soft）。
  3. **1 つの無線機の口は、1 つのスレッドだけが触ります。**Hamlib の口は
     スレッドの間で安全ではありません。
  4. C の型の大きさは Hamlib 4.5.5 の `rig.h` で確かめました。`token_t` は
     C の `long` で、**Windows では 4 バイト、他では 8 バイト**です（`clong`）。
     `value_t` は 16 バイトの共用体で、`rig_set_level` には**値で**渡します。
     並びは `dsp_check` がダミーの無線機で書いて読み戻して確かめます。

  Loads Hamlib at run time and has the rig's internal keyer send CW
  (requirement FR-T.2).

  **Transmission is a high-risk boundary.** This unit only hands the rig a
  string, stops it, sets the speed, checks that it answers (reading the
  frequency only) and powers it on; **it never decides when to send or when to
  power on.** Those decisions belong to `DeepCW.RigKeyer` and to the operator.
  **It has no command that changes frequency, mode, split or PTT, and none that
  powers the rig off.**

  Rules:

  1. **No retries** (`retry` is set to 0). By default Hamlib resends a command
     that got no answer; a resent `send_morse` **keys the same text twice.**
  2. **Failing to load never stops start-up.** Reception does not use Hamlib
     (Receive is fail-soft).
  3. **One rig handle is touched by one thread only.** Hamlib handles are not
     thread-safe.
  4. C type sizes were checked against Hamlib 4.5.5's `rig.h`. `token_t` is C
     `long`: **4 bytes on Windows, 8 elsewhere** (`clong`). `value_t` is a
     16-byte union passed **by value** to `rig_set_level`; `dsp_check` checks
     the layout by writing and reading back on the dummy rig. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, DynLibs, ctypes;

const
  { Hamlib の試験用の無線機（`rigctl -m 1`）と、`rigctld` へ繋ぐ網の口
    （`rigctl -m 2`）。/ Hamlib's test rig and the network client of `rigctld`. }
  HAMLIB_MODEL_DUMMY = 1;
  HAMLIB_MODEL_NETRIGCTL = 2;

  { キーヤーの速度として受け付ける範囲（WPM）。/ Keyer speed accepted (WPM). }
  HAMLIB_MIN_WPM = 5;
  HAMLIB_MAX_WPM = 60;

  { Hamlib の誤りの番号（`rig.h`。返るのは負の値）。
    Hamlib's error numbers (`rig.h`; returned negated). }
  RIG_OK = 0;
  RIG_EINVAL = 1;
  RIG_ECONF = 2;
  RIG_ENIMPL = 4;
  RIG_ETIMEOUT = 5;
  RIG_EIO = 6;
  RIG_EPROTO = 8;
  RIG_ENAVAIL = 11;
  RIG_EPOWER = 20;

type
  { どこで失敗したか。/ Where it failed. }
  THamlibStage = (hsOther, hsModel, hsConfig, hsOpen);

  EHamlib = class(Exception)
  public
    { Hamlib の返した番号（負）。無ければ 0。/ Hamlib's code (negative), or 0. }
    Code: Integer;
    Stage: THamlibStage;
    { 断られた設定名（`hsConfig` のとき）。/ The refused setting (`hsConfig`). }
    Setting: string;
  end;

  { Hamlib へそのまま渡す設定の 1 組（`DeepCW.RigConfig` が作る）。
    One setting passed to Hamlib as it is (made by `DeepCW.RigConfig`). }
  TRigConfPair = record
    Name: string;
    Value: string;
  end;
  TRigConfPairs = array of TRigConfPair;

  { 無線機への繋ぎ方。/ How to reach the rig. }
  TRigSettings = record
    { Hamlib の機種番号（`rigctl -l` の番号）。/ Hamlib model number. }
    Model: Integer;
    { 口（`COM3`・`/dev/ttyUSB0`・`localhost:4532` など）。/ The port. }
    Port: string;
    { 通信速度。0 なら機種の既定。/ Baud rate; 0 keeps the model's default. }
    Baud: Integer;
    { 詳しい接続設定（要件 FR-T.5）。**その機種に無い設定は断ります。**
      Detailed connection settings (FR-T.5). **A setting the model lacks is
      refused.** }
    Conf: TRigConfPairs;
    { 開くときに電源を入れさせるか（Hamlib の `auto_power_on`）。**利用者が
      「電源を入れる」を押したときだけ True**（要件 FR-T.6）。
      Whether opening powers the rig on (Hamlib's `auto_power_on`). **True only
      when the operator pressed "power on"** (FR-T.6). }
    PowerOnAtOpen: Boolean;
  end;

  { 1 台の無線機の口。**作ったスレッドだけが触ります。**
    One rig handle. **Only the thread that made it touches it.** }
  THamlibRig = class
  private
    FRig: Pointer;
    FOpen: Boolean;
    procedure Check(Code: cint; const What: string);
    procedure SetConf(const Name, Value: string; Required: Boolean);
  public
    { 口を用意します。まだ開きません。/ Prepares the handle; not yet open. }
    constructor Create(const Settings: TRigSettings);
    destructor Destroy; override;
    procedure Open;
    procedure Close;
    { 内蔵キーヤーに文字列を渡します。**Hamlib は渡すところまでで戻り、
      送り終わるのを待ちません。**
      Hands the string to the internal keyer. **Hamlib returns once it is
      handed over; it does not wait for the sending to finish.** }
    procedure SendMorse(const Text: string);
    { 送出を止めます。**止められない機種があります**（Hamlib のダミーも、
      多くの実機も `stop_morse` を持ちません）。その場合は例外ではなく False を
      返します。止められないことを前提に、送る側が文を短く区切って渡します
      （`DeepCW.RigKeyer`）。
      Stops the sending. **Some models cannot** (Hamlib's dummy, and many real
      rigs, lack `stop_morse`); then it returns False rather than raising. The
      sender plans for that by handing the text over in short pieces
      (`DeepCW.RigKeyer`). }
    function StopMorse: Boolean;
    procedure SetKeyerWpm(Wpm: Integer);
    function KeyerWpm: Integer;
    { 無線機が応答するかを、**読むだけの命令**（周波数を訊く）で確かめます。
      Hamlib の番号をそのまま返し、例外は投げません（`RIG_OK` なら応答あり）。
      **電源の状態を訊く命令は使いません**——ダミーは値を書かずに成功を返し、
      網の口では答えが 1 つずれました（付録 BT.2）。
      Checks whether the rig answers, with **a read-only command** (asking the
      frequency). Returns Hamlib's code and never raises (`RIG_OK` means it
      answered). **The power-status query is not used**: the dummy returned
      success without writing a value, and through the network client the
      answers came one command late (appendix BT.2). }
    function Probe: Integer;
    { 電源を入れる命令を送ります。**利用者が頼んだときだけ呼びます。**番号を
      返し、例外は投げません。
      Sends the power-on command. **Called only on the operator's request.**
      Returns the code; never raises. }
    function PowerOn: Integer;
    { 設定の今の値（試験と診断のため）。読めなければ空。
      A setting's current value (for tests and diagnostics); empty if unreadable. }
    function GetConf(const Name: string): string;
    property IsOpen: Boolean read FOpen;
  end;

{ Hamlib を読み込みます。**失敗しても例外は投げません**（理由は
  `HamlibLoadError`）。/ Loads Hamlib; **never raises** (see `HamlibLoadError`). }
function LoadHamlib(const LibraryPath: string = ''): Boolean;
function HamlibAvailable: Boolean;
function HamlibLibraryPath: string;
function HamlibLoadError: string;

implementation

uses
  DeepCW.Platform;

const
  RIG_DEBUG_NONE = 0;
  { `powerstat_t` の「入」（`rig.h`）。/ `RIG_POWER_ON` in `rig.h`. }
  RIG_POWER_ON = 1;
  { `RIG_VFO_N(29)` = `1 shl 29`（`rig.h`）。/ `RIG_VFO_N(29)` in `rig.h`. }
  RIG_VFO_CURR = cuint(1 shl 29);
  { `CONSTANT_64BIT_FLAG(14)`。/ `CONSTANT_64BIT_FLAG(14)` in `rig.h`. }
  RIG_LEVEL_KEYSPD = cuint64(1) shl 14;

type
  { `value_t`。16 バイト、境界 8。/ `value_t`: 16 bytes, 8-byte aligned. }
  THamlibValue = record
    case Integer of
      0: (I: cint);
      1: (F: cfloat);
      2: (S: PAnsiChar);
      3: (Raw: array[0..15] of Byte);
  end;

  TRigInit = function(Model: cuint32): Pointer; cdecl;
  TRigCall = function(Rig: Pointer): cint; cdecl;
  TRigTokenLookup = function(Rig: Pointer; Name: PAnsiChar): clong; cdecl;
  TRigSetConf = function(Rig: Pointer; Token: clong; Value: PAnsiChar): cint; cdecl;
  TRigSendMorse = function(Rig: Pointer; Vfo: cuint; Msg: PAnsiChar): cint; cdecl;
  TRigStopMorse = function(Rig: Pointer; Vfo: cuint): cint; cdecl;
  TRigSetLevel = function(Rig: Pointer; Vfo: cuint; Level: cuint64;
    Value: THamlibValue): cint; cdecl;
  TRigGetLevel = function(Rig: Pointer; Vfo: cuint; Level: cuint64;
    var Value: THamlibValue): cint; cdecl;
  TRigError = function(Code: cint): PAnsiChar; cdecl;
  TRigGetFreq = function(Rig: Pointer; Vfo: cuint; var Freq: cdouble): cint; cdecl;
  TRigSetPowerstat = function(Rig: Pointer; Status: cint): cint; cdecl;
  TRigGetConf2 = function(Rig: Pointer; Token: clong; Value: PAnsiChar;
    Length_: cint): cint; cdecl;
  TRigSetDebug = procedure(Level: cint); cdecl;

var
  GHandle: TLibHandle = NilHandle;
  GLibraryPath: string = '';
  GLoadError: string = '';
  rig_init: TRigInit = nil;
  rig_open: TRigCall = nil;
  rig_close: TRigCall = nil;
  rig_cleanup: TRigCall = nil;
  rig_token_lookup: TRigTokenLookup = nil;
  rig_set_conf: TRigSetConf = nil;
  rig_send_morse: TRigSendMorse = nil;
  rig_stop_morse: TRigStopMorse = nil;
  rig_set_level: TRigSetLevel = nil;
  rig_get_level: TRigGetLevel = nil;
  rigerror: TRigError = nil;
  { 4.5 から。`rigerror` は 4.5 で**直前の記録の束を前に付けて**返すので、
    有ればこちらを使います。
    From 4.5. In 4.5 `rigerror` **prepends the recent debug history**, so this
    is preferred when present. }
  rigerror2: TRigError = nil;
  rig_set_debug: TRigSetDebug = nil;
  rig_get_freq: TRigGetFreq = nil;
  rig_set_powerstat: TRigSetPowerstat = nil;
  { 4.5 から。無ければ `GetConf` は空を返します。
    From 4.5; without it `GetConf` returns empty. }
  rig_get_conf2: TRigGetConf2 = nil;

function DefaultHamlibNames: TStringArray;
begin
  {$IF DEFINED(WINDOWS)}
  Result := TStringArray.Create('libhamlib-4.dll');
  {$ELSEIF DEFINED(DARWIN)}
  Result := TStringArray.Create('libhamlib.4.dylib', 'libhamlib.dylib');
  {$ELSE}
  Result := TStringArray.Create('libhamlib.so.4', 'libhamlib.so');
  {$ENDIF}
end;

function Bind: Boolean;
begin
  rig_init := TRigInit(GetProcedureAddress(GHandle, 'rig_init'));
  rig_open := TRigCall(GetProcedureAddress(GHandle, 'rig_open'));
  rig_close := TRigCall(GetProcedureAddress(GHandle, 'rig_close'));
  rig_cleanup := TRigCall(GetProcedureAddress(GHandle, 'rig_cleanup'));
  rig_token_lookup := TRigTokenLookup(GetProcedureAddress(GHandle, 'rig_token_lookup'));
  rig_set_conf := TRigSetConf(GetProcedureAddress(GHandle, 'rig_set_conf'));
  rig_send_morse := TRigSendMorse(GetProcedureAddress(GHandle, 'rig_send_morse'));
  rig_stop_morse := TRigStopMorse(GetProcedureAddress(GHandle, 'rig_stop_morse'));
  rig_set_level := TRigSetLevel(GetProcedureAddress(GHandle, 'rig_set_level'));
  rig_get_level := TRigGetLevel(GetProcedureAddress(GHandle, 'rig_get_level'));
  rigerror := TRigError(GetProcedureAddress(GHandle, 'rigerror'));
  rigerror2 := TRigError(GetProcedureAddress(GHandle, 'rigerror2'));
  rig_set_debug := TRigSetDebug(GetProcedureAddress(GHandle, 'rig_set_debug'));
  rig_get_freq := TRigGetFreq(GetProcedureAddress(GHandle, 'rig_get_freq'));
  rig_set_powerstat := TRigSetPowerstat(GetProcedureAddress(GHandle, 'rig_set_powerstat'));
  rig_get_conf2 := TRigGetConf2(GetProcedureAddress(GHandle, 'rig_get_conf2'));
  { **止める手段が無い版は使いません**（`rig_stop_morse` は 4.0 から）。
    送れるのに止められないのは、fail-safe の逆です。
    **A version that cannot stop is not used** (`rig_stop_morse` arrived in
    4.0): able to send but not to stop is the opposite of fail-safe. }
  Result := Assigned(rig_init) and Assigned(rig_open) and Assigned(rig_close) and
    Assigned(rig_cleanup) and Assigned(rig_token_lookup) and
    Assigned(rig_set_conf) and Assigned(rig_send_morse) and
    Assigned(rig_stop_morse) and Assigned(rig_set_level) and
    Assigned(rig_get_level) and Assigned(rigerror) and Assigned(rig_set_debug) and
    Assigned(rig_get_freq) and Assigned(rig_set_powerstat);
end;

function LoadHamlib(const LibraryPath: string): Boolean;
var
  Candidates: TStringArray;
  ExeDir, Name: string;
  I: Integer;
begin
  if GHandle <> NilHandle then
    Exit(True);
  GLoadError := '';
  Candidates := nil;
  if LibraryPath <> '' then
    Candidates := TStringArray.Create(LibraryPath)
  else
  begin
    if GetEnvironmentVariable('DEEPCW_HAMLIB') <> '' then
      Candidates := TStringArray.Create(GetEnvironmentVariable('DEEPCW_HAMLIB'));
    ExeDir := IncludeTrailingPathDelimiter(ExtractFilePath(ExecutablePath));
    for Name in DefaultHamlibNames do
      Candidates := Concat(Candidates, TStringArray.Create(ExeDir + Name));
    for Name in DefaultHamlibNames do
      Candidates := Concat(Candidates, TStringArray.Create(Name));
  end;
  for I := 0 to High(Candidates) do
  begin
    GHandle := LoadLibrary(Candidates[I]);
    if GHandle = NilHandle then
      Continue;
    if Bind then
    begin
      GLibraryPath := Candidates[I];
      { Hamlib は既定で標準エラーへ多くを書きます。黙らせます。
        Hamlib writes a lot to standard error by default; silence it. }
      rig_set_debug(RIG_DEBUG_NONE);
      Exit(True);
    end;
    UnloadLibrary(GHandle);
    GHandle := NilHandle;
  end;
  GLoadError := Format('Hamlib could not be loaded. Tried: %s.',
    [string.Join(',', Candidates)]);
  Result := False;
end;

function HamlibAvailable: Boolean;
begin
  Result := GHandle <> NilHandle;
end;

function HamlibLibraryPath: string;
begin
  Result := GLibraryPath;
end;

function HamlibLoadError: string;
begin
  Result := GLoadError;
end;

{ THamlibRig }

function HamlibError(const Msg: string; Code: Integer; Stage: THamlibStage;
  const Setting: string = ''): EHamlib;
begin
  Result := EHamlib.Create(Msg);
  Result.Code := Code;
  Result.Stage := Stage;
  Result.Setting := Setting;
end;

constructor THamlibRig.Create(const Settings: TRigSettings);
var
  Pair: TRigConfPair;
begin
  inherited Create;
  if not HamlibAvailable then
    raise EHamlib.Create('Hamlib is not loaded.');
  FRig := rig_init(cuint32(Settings.Model));
  if FRig = nil then
    raise HamlibError(Format('Hamlib does not know rig model %d.', [Settings.Model]),
      0, hsModel);
  SetConf('retry', '0', True);
  { **電源は、利用者が頼んだときだけ**（要件 FR-T.6）。閉じるときに切らせず、
    開くときも頼まれたとき以外は入れさせません。
    **Power only on the operator's request** (FR-T.6): never switched off on
    close, and switched on at open only when asked. }
  SetConf('auto_power_off', '0', False);
  if Settings.PowerOnAtOpen then
    SetConf('auto_power_on', '1', True)
  else
    SetConf('auto_power_on', '0', False);
  if Settings.Port <> '' then
    SetConf('rig_pathname', Settings.Port, True);
  if Settings.Baud > 0 then
    SetConf('serial_speed', IntToStr(Settings.Baud), False);
  for Pair in Settings.Conf do
    SetConf(Pair.Name, Pair.Value, True);
end;

destructor THamlibRig.Destroy;
begin
  if FRig <> nil then
  begin
    Close;
    rig_cleanup(FRig);
    FRig := nil;
  end;
  inherited Destroy;
end;

{ 誤りの番号を 1 行の文にします。/ Turns an error number into one line. }
function ErrorLine(Code: cint): string;
var
  Lines: TStringArray;
  I: Integer;
begin
  if Assigned(rigerror2) then
    Result := Trim(string(rigerror2(Code)))
  else
  begin
    { 記録の束の最後の行が、誤りそのものです。
      The last line of the history is the error itself. }
    Result := '';
    Lines := string(rigerror(Code)).Split([#10, #13]);
    for I := High(Lines) downto 0 do
      if Trim(Lines[I]) <> '' then
        Exit(Trim(Lines[I]));
  end;
end;

procedure THamlibRig.Check(Code: cint; const What: string);
begin
  if Code <> RIG_OK then
    raise HamlibError(Format('%s: %s (%d)', [What, ErrorLine(Code), Code]),
      Code, hsOther);
end;

procedure THamlibRig.SetConf(const Name, Value: string; Required: Boolean);
var
  Token: clong;
  Code: cint;
begin
  Token := rig_token_lookup(FRig, PAnsiChar(AnsiString(Name)));
  { 0 は「その機種にはこの設定が無い」（`RIG_CONF_END`）。
    0 means the model has no such setting (`RIG_CONF_END`). }
  if Token = 0 then
  begin
    if Required then
      raise HamlibError(Format('This rig model has no "%s" setting.', [Name]),
        -RIG_ECONF, hsConfig, Name);
    Exit;
  end;
  Code := rig_set_conf(FRig, Token, PAnsiChar(AnsiString(Value)));
  if Code <> RIG_OK then
    raise HamlibError(Format('set %s=%s: %s (%d)', [Name, Value, ErrorLine(Code), Code]),
      Code, hsConfig, Name);
end;

procedure THamlibRig.Open;
var
  Code: cint;
begin
  if FOpen then
    Exit;
  Code := rig_open(FRig);
  if Code <> RIG_OK then
    raise HamlibError(Format('open: %s (%d)', [ErrorLine(Code), Code]), Code, hsOpen);
  FOpen := True;
end;

procedure THamlibRig.Close;
begin
  if not FOpen then
    Exit;
  FOpen := False;
  rig_close(FRig);
end;

procedure THamlibRig.SendMorse(const Text: string);
begin
  if not FOpen then
    raise EHamlib.Create('The rig is not open.');
  Check(rig_send_morse(FRig, RIG_VFO_CURR, PAnsiChar(AnsiString(Text))), 'send_morse');
end;

function THamlibRig.StopMorse: Boolean;
var
  Code: cint;
begin
  if not FOpen then
    Exit(False);
  Code := rig_stop_morse(FRig, RIG_VFO_CURR);
  if (Code = -RIG_ENAVAIL) or (Code = -RIG_ENIMPL) then
    Exit(False);
  Check(Code, 'stop_morse');
  Result := True;
end;

procedure THamlibRig.SetKeyerWpm(Wpm: Integer);
var
  Value: THamlibValue;
begin
  if not FOpen then
    raise EHamlib.Create('The rig is not open.');
  if (Wpm < HAMLIB_MIN_WPM) or (Wpm > HAMLIB_MAX_WPM) then
    raise EHamlib.CreateFmt('Keyer speed %d WPM is out of range.', [Wpm]);
  FillChar(Value, SizeOf(Value), 0);
  Value.I := Wpm;
  Check(rig_set_level(FRig, RIG_VFO_CURR, RIG_LEVEL_KEYSPD, Value), 'set KEYSPD');
end;

function THamlibRig.Probe: Integer;
var
  Freq: cdouble;
begin
  if not FOpen then
    Exit(-RIG_EIO);
  Freq := 0;
  Result := rig_get_freq(FRig, RIG_VFO_CURR, Freq);
end;

function THamlibRig.PowerOn: Integer;
begin
  if not FOpen then
    Exit(-RIG_EIO);
  Result := rig_set_powerstat(FRig, RIG_POWER_ON);
end;

function THamlibRig.GetConf(const Name: string): string;
var
  Token: clong;
  Buffer: array[0..255] of AnsiChar;
begin
  Result := '';
  if (FRig = nil) or not Assigned(rig_get_conf2) then
    Exit;
  Token := rig_token_lookup(FRig, PAnsiChar(AnsiString(Name)));
  if Token = 0 then
    Exit;
  FillChar(Buffer, SizeOf(Buffer), 0);
  if rig_get_conf2(FRig, Token, @Buffer[0], SizeOf(Buffer) - 1) = RIG_OK then
    Result := string(PAnsiChar(@Buffer[0]));
end;

function THamlibRig.KeyerWpm: Integer;
var
  Value: THamlibValue;
begin
  if not FOpen then
    raise EHamlib.Create('The rig is not open.');
  FillChar(Value, SizeOf(Value), 0);
  Check(rig_get_level(FRig, RIG_VFO_CURR, RIG_LEVEL_KEYSPD, Value), 'get KEYSPD');
  Result := Value.I;
end;

end.
