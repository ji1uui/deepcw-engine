unit DeepCW.RigConfig;

{ 無線機の詳しい接続設定です（要件 FR-T.5）。画面・設定ファイル・Hamlib の
  間を取り持ちます。

  1. **設定ファイルには Hamlib の設定名をそのまま鍵にして書きます**
     （`[rig] civaddr=94` など）。空は「機種の既定」で、Hamlib へ渡しません。
  2. **Hamlib は受け付けてしまう誤りがあるので、ここで確かめます。**実測で、
     `civaddr=zz` は 0 に、`data_bits=9` はそのまま通りました（付録 BT.1）。
  3. **設定ファイルの読めない値は、黙って捨てません。**既定に戻し、捨てた値を
     `Rejected` で返します（呼ぶ側が診断に残す）。CI-V アドレスだけは書かれた
     まま残し、繋ぐ前の確かめで理由を言って断ります（利用者が見て直せるように）。
  4. **利用者が変えられないもの**: `retry`（0 に固定。命令の二重送出を防ぐ）、
     `auto_power_on`・`auto_power_off`（電源は利用者が頼んだときだけ）、PTT の
     設定。どれもここの項目に無いので、設定ファイルに書かれても渡りません。

  Detailed connection settings for the rig (requirement FR-T.5), bridging the
  screen, the settings file and Hamlib. **The settings file uses Hamlib's own
  setting names as keys** (`[rig] civaddr=94`); empty means the model's default
  and nothing is passed. **Hamlib accepts some mistakes, so they are checked
  here**: measured, `civaddr=zz` became 0 and `data_bits=9` went through
  (appendix BT.1). **Unreadable values in the settings file are not dropped
  silently**: they fall back to the default and are returned in `Rejected` for
  the caller to log; the CI-V address alone is kept as written and refused, with
  the reason, when connecting. **What the operator cannot change**: `retry`
  (fixed at 0 against duplicated commands), `auto_power_on` and
  `auto_power_off` (power only on request), and the PTT settings -- none are
  items here, so none reach Hamlib even if written into the file. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, DeepCW.Hamlib;

const
  { 選択肢。先頭の空は「機種の既定」。画面の項目と同じ順です。
    The choices; the leading empty one is "the model's default". The order is
    that of the items on screen. }
  RIG_PARITY_CHOICES: array[0..3] of string = ('', 'None', 'Even', 'Odd');
  RIG_HANDSHAKE_CHOICES: array[0..3] of string = ('', 'None', 'XONXOFF', 'Hardware');
  RIG_LINE_CHOICES: array[0..2] of string = ('', 'ON', 'OFF');
  RIG_DATA_BITS_CHOICES: array[0..2] of Integer = (0, 7, 8);
  RIG_STOP_BITS_CHOICES: array[0..2] of Integer = (0, 1, 2);

  { ミリ秒の範囲。0 は「機種の既定」。/ Millisecond ranges; 0 is the default. }
  RIG_TIMEOUT_MIN = 100;
  RIG_TIMEOUT_MAX = 10000;
  RIG_DELAY_MAX = 1000;

type
  TRigConf = record
    CivAddr: string;
    DataBits: Integer;
    StopBits: Integer;
    Parity: string;
    Handshake: string;
    Dtr: string;
    Rts: string;
    TimeoutMs: Integer;
    WriteDelayMs: Integer;
    PostWriteDelayMs: Integer;
  end;

  { 確かめの結果の種類。**言葉にするのは画面の側です。**
    The kind of check result; **the screen puts it into words.** }
  TRigConfProblem = (rcpNone, rcpCivAddr, rcpChoice, rcpRange, rcpRtsWithHardware);

{ すべて「機種の既定」。/ Everything at the model's default. }
function DefaultRigConf: TRigConf;

{ 繋ぐ前に確かめます。通らなければ `Setting` に設定名（Hamlib の名前）を返します。
  Checked before connecting; on failure `Setting` names the setting (Hamlib's
  name). }
function CheckRigConf(const Conf: TRigConf; out Problem: TRigConfProblem;
  out Setting: string): Boolean;

{ Hamlib へ渡す組。**既定のものは入りません。**`CheckRigConf` を通したものに
  使います。`serial_handshake` は `rts_state` より先です。
  The pairs to pass to Hamlib. **Defaults are left out.** Use on a `TRigConf`
  that passed `CheckRigConf`; `serial_handshake` comes before `rts_state`. }
function RigConfPairs(const Conf: TRigConf): TRigConfPairs;

{ 設定ファイルの `[rig]` の値（名前=値）から読みます。**読めない値は既定に
  戻し**、`名前=値` を `Rejected` に入れます。
  Reads from the `[rig]` values (name=value) of the settings file. **An
  unreadable value falls back to the default** and `name=value` goes into
  `Rejected`. }
function RigConfFromValues(Values: TStrings; out Rejected: TStringArray): TRigConf;

{ 設定ファイルへ書く組（名前=値）。既定は空で書きます。
  The name=value pairs to write; defaults are written empty. }
procedure RigConfToValues(const Conf: TRigConf; Values: TStrings);

{ CI-V アドレスを、16 進の 2 桁（`94`）から Hamlib の形（`0x94`）へ。
  空や読めないものは空。/ The CI-V address from two hex digits (`94`) to
  Hamlib's form (`0x94`); empty or unreadable gives empty. }
function CivAddrForHamlib(const Text: string): string;

implementation

function DefaultRigConf: TRigConf;
begin
  Result.CivAddr := '';
  Result.DataBits := 0;
  Result.StopBits := 0;
  Result.Parity := '';
  Result.Handshake := '';
  Result.Dtr := '';
  Result.Rts := '';
  Result.TimeoutMs := 0;
  Result.WriteDelayMs := 0;
  Result.PostWriteDelayMs := 0;
end;

{ CI-V アドレスは 01〜DF（E0 は操作側の番号）。16 進の 1〜2 桁で書きます。
  A CI-V address is 01..DF (E0 belongs to the controller), one or two hex
  digits. }
function CivAddrValue(const Text: string): Integer;
var
  S: string;
  I: Integer;
begin
  Result := -1;
  S := UpperCase(Trim(Text));
  if (Length(S) < 1) or (Length(S) > 2) then
    Exit;
  for I := 1 to Length(S) do
    if not (S[I] in ['0'..'9', 'A'..'F']) then
      Exit;
  Result := StrToInt('$' + S);
  if (Result < $01) or (Result > $DF) then
    Result := -1;
end;

function CivAddrForHamlib(const Text: string): string;
var
  Value: Integer;
begin
  Value := CivAddrValue(Text);
  if Value < 0 then
    Result := ''
  else
    Result := '0x' + IntToHex(Value, 2);
end;

function InStrings(const Value: string; const Choices: array of string): Boolean;
var
  S: string;
begin
  for S in Choices do
    if S = Value then
      Exit(True);
  Result := False;
end;

function InInts(Value: Integer; const Choices: array of Integer): Boolean;
var
  I: Integer;
begin
  for I in Choices do
    if I = Value then
      Exit(True);
  Result := False;
end;

function CheckRigConf(const Conf: TRigConf; out Problem: TRigConfProblem;
  out Setting: string): Boolean;

  function Fail(P: TRigConfProblem; const Name: string): Boolean;
  begin
    Problem := P;
    Setting := Name;
    Result := False;
  end;

begin
  Problem := rcpNone;
  Setting := '';
  if (Trim(Conf.CivAddr) <> '') and (CivAddrValue(Conf.CivAddr) < 0) then
    Exit(Fail(rcpCivAddr, 'civaddr'));
  if not InInts(Conf.DataBits, RIG_DATA_BITS_CHOICES) then
    Exit(Fail(rcpChoice, 'data_bits'));
  if not InInts(Conf.StopBits, RIG_STOP_BITS_CHOICES) then
    Exit(Fail(rcpChoice, 'stop_bits'));
  if not InStrings(Conf.Parity, RIG_PARITY_CHOICES) then
    Exit(Fail(rcpChoice, 'serial_parity'));
  if not InStrings(Conf.Handshake, RIG_HANDSHAKE_CHOICES) then
    Exit(Fail(rcpChoice, 'serial_handshake'));
  if not InStrings(Conf.Dtr, RIG_LINE_CHOICES) then
    Exit(Fail(rcpChoice, 'dtr_state'));
  if not InStrings(Conf.Rts, RIG_LINE_CHOICES) then
    Exit(Fail(rcpChoice, 'rts_state'));
  if (Conf.TimeoutMs <> 0) and
     ((Conf.TimeoutMs < RIG_TIMEOUT_MIN) or (Conf.TimeoutMs > RIG_TIMEOUT_MAX)) then
    Exit(Fail(rcpRange, 'timeout'));
  if (Conf.WriteDelayMs < 0) or (Conf.WriteDelayMs > RIG_DELAY_MAX) then
    Exit(Fail(rcpRange, 'write_delay'));
  if (Conf.PostWriteDelayMs < 0) or (Conf.PostWriteDelayMs > RIG_DELAY_MAX) then
    Exit(Fail(rcpRange, 'post_write_delay'));
  { ハードウェアのフロー制御は RTS 線を自分で使います。RTS を手で決めると
    ぶつかります（Hamlib は設定の時点では断らない）。
    Hardware flow control drives the RTS line itself; fixing RTS by hand
    conflicts with it (Hamlib does not refuse at setting time). }
  if (Conf.Handshake = 'Hardware') and (Conf.Rts <> '') then
    Exit(Fail(rcpRtsWithHardware, 'rts_state'));
  Result := True;
end;

function RigConfPairs(const Conf: TRigConf): TRigConfPairs;

  procedure Add(const Name, Value: string);
  begin
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)].Name := Name;
    Result[High(Result)].Value := Value;
  end;

begin
  Result := nil;
  if CivAddrForHamlib(Conf.CivAddr) <> '' then
    Add('civaddr', CivAddrForHamlib(Conf.CivAddr));
  if Conf.DataBits > 0 then
    Add('data_bits', IntToStr(Conf.DataBits));
  if Conf.StopBits > 0 then
    Add('stop_bits', IntToStr(Conf.StopBits));
  if Conf.Parity <> '' then
    Add('serial_parity', Conf.Parity);
  if Conf.Handshake <> '' then
    Add('serial_handshake', Conf.Handshake);
  if Conf.Dtr <> '' then
    Add('dtr_state', Conf.Dtr);
  if Conf.Rts <> '' then
    Add('rts_state', Conf.Rts);
  if Conf.TimeoutMs > 0 then
    Add('timeout', IntToStr(Conf.TimeoutMs));
  if Conf.WriteDelayMs > 0 then
    Add('write_delay', IntToStr(Conf.WriteDelayMs));
  if Conf.PostWriteDelayMs > 0 then
    Add('post_write_delay', IntToStr(Conf.PostWriteDelayMs));
end;

function RigConfFromValues(Values: TStrings; out Rejected: TStringArray): TRigConf;

  procedure Reject(const Name, Value: string);
  begin
    SetLength(Rejected, Length(Rejected) + 1);
    Rejected[High(Rejected)] := Name + '=' + Value;
  end;

  function ReadChoice(const Name: string; const Choices: array of string): string;
  var
    Value: string;
  begin
    Value := Trim(Values.Values[Name]);
    if InStrings(Value, Choices) then
      Exit(Value);
    Reject(Name, Value);
    Result := '';
  end;

  function ReadInt(const Name: string; const Choices: array of Integer): Integer;
  var
    Value: string;
  begin
    Value := Trim(Values.Values[Name]);
    if Value = '' then
      Exit(0);
    Result := StrToIntDef(Value, -1);
    if not InInts(Result, Choices) then
    begin
      Reject(Name, Value);
      Result := 0;
    end;
  end;

  function ReadMs(const Name: string; Low_, High_: Integer): Integer;
  var
    Value: string;
  begin
    Value := Trim(Values.Values[Name]);
    if Value = '' then
      Exit(0);
    Result := StrToIntDef(Value, -1);
    if (Result <> 0) and ((Result < Low_) or (Result > High_)) then
    begin
      Reject(Name, Value);
      Result := 0;
    end;
  end;

begin
  Rejected := nil;
  Result := DefaultRigConf;
  { CI-V アドレスは書かれたまま残します（繋ぐときに理由を言って断る）。
    The CI-V address is kept as written (refused with a reason on connecting). }
  Result.CivAddr := Trim(Values.Values['civaddr']);
  Result.DataBits := ReadInt('data_bits', RIG_DATA_BITS_CHOICES);
  Result.StopBits := ReadInt('stop_bits', RIG_STOP_BITS_CHOICES);
  Result.Parity := ReadChoice('serial_parity', RIG_PARITY_CHOICES);
  Result.Handshake := ReadChoice('serial_handshake', RIG_HANDSHAKE_CHOICES);
  Result.Dtr := ReadChoice('dtr_state', RIG_LINE_CHOICES);
  Result.Rts := ReadChoice('rts_state', RIG_LINE_CHOICES);
  Result.TimeoutMs := ReadMs('timeout', RIG_TIMEOUT_MIN, RIG_TIMEOUT_MAX);
  Result.WriteDelayMs := ReadMs('write_delay', 1, RIG_DELAY_MAX);
  Result.PostWriteDelayMs := ReadMs('post_write_delay', 1, RIG_DELAY_MAX);
end;

procedure RigConfToValues(const Conf: TRigConf; Values: TStrings);

  function IntOrEmpty(Value: Integer): string;
  begin
    if Value = 0 then
      Result := ''
    else
      Result := IntToStr(Value);
  end;

begin
  { `Values[...] := ''` は行を消すので、空を残すために直接書きます。
    Assigning '' through Values[] deletes the line, so the lines are written
    directly to keep the empty ones. }
  Values.Clear;
  Values.Add('civaddr=' + Conf.CivAddr);
  Values.Add('data_bits=' + IntOrEmpty(Conf.DataBits));
  Values.Add('stop_bits=' + IntOrEmpty(Conf.StopBits));
  Values.Add('serial_parity=' + Conf.Parity);
  Values.Add('serial_handshake=' + Conf.Handshake);
  Values.Add('dtr_state=' + Conf.Dtr);
  Values.Add('rts_state=' + Conf.Rts);
  Values.Add('timeout=' + IntOrEmpty(Conf.TimeoutMs));
  Values.Add('write_delay=' + IntOrEmpty(Conf.WriteDelayMs));
  Values.Add('post_write_delay=' + IntOrEmpty(Conf.PostWriteDelayMs));
end;

end.
