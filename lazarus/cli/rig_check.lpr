program rig_check;

{ 無線機の鍵の操作が fail-safe であることを、Hamlib の本物で確かめます
  （要件 FR-T.2・FR-T.3）。

  **無線機は要りません。**Hamlib の `rigctld` をダミーの無線機（機種 1）で
  立て、網の口（機種 2）から繋ぎます。`rigctld` が受け取った命令をその記録から
  読むので、**実際に鍵に乗った文字列**を突き合わせられます。`rigctld` はこの
  プログラムが自分で立て、自分で落とします（繋がりが切れた場合を作るため）。

  Checks, against the real Hamlib, that operating the rig's key is fail-safe
  (requirements FR-T.2, FR-T.3). **No rig is needed**: Hamlib's `rigctld` runs
  the dummy rig (model 1) and is reached through the network model (2); what
  `rigctld` received is read from its log, so **the strings that actually
  reached the key** can be compared. This program starts and kills `rigctld`
  itself, to create a lost connection.

  無線機の詳しい接続設定（要件 FR-T.5）と、応答の確かめ・電源を入れる流れ
  （要件 FR-T.6）も確かめます。後者は `tools/rig_proxy.py` を `rigctld` の前に
  立て、**電源が切れた・応答しない・遠隔で電源を入れると起きる**無線機を真似ます。

  It also checks the detailed connection settings (FR-T.5) and the answer check
  and power-on flow (FR-T.6); for the latter `tools/rig_proxy.py` stands in
  front of `rigctld` and imitates **a rig that is switched off, one that does
  not answer, and one that wakes after a remote power-on**.

    使い方 / usage: rig_check [--rigctld PATH] [--port N] [--work DIR]
                              [--proxy PATH] }

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Classes, SysUtils, Process, DeepCW.Hamlib, DeepCW.RigKeyer, DeepCW.TxMessage,
  DeepCW.RigConfig, DeepCW.Platform;

var
  Failures: Integer = 0;
  RigctldPath: string = 'rigctld';
  Port: Integer = 45321;
  WorkDir: string = '';
  ProxyPath: string = 'tools/rig_proxy.py';

procedure Check(const What: string; Passed: Boolean; const Detail: string = '');
begin
  if Passed then
    WriteLn('  ok   ', What)
  else
  begin
    WriteLn('  NG   ', What, '  ', Detail);
    Inc(Failures);
  end;
end;

{ `rigctld` を立てます。記録は `LogName` へ。/ Starts `rigctld`, logging to `LogName`. }
function StartRigctld(const LogName: string): TProcess;
begin
  { `rigctld` は記録を標準エラーへ書くので、殻を通して振り向けます。
    **`exec` で置き換える**ので、落とすときは `rigctld` そのものが落ちます。
    `rigctld` writes its log to standard error, so it is redirected through a
    shell; **`exec` replaces the shell**, so terminating it ends `rigctld`
    itself. }
  Result := TProcess.Create(nil);
  Result.Executable := '/bin/sh';
  Result.Parameters.Add('-c');
  Result.Parameters.Add(Format('exec "%s" -m 1 -t %d -vvvvv 2>"%s"',
    [RigctldPath, Port, LogName]));
  Result.Options := [poNoConsole];
  Result.Execute;
  Sleep(700);
end;

procedure StopRigctld(var P: TProcess);
begin
  if P = nil then
    Exit;
  P.Terminate(0);
  P.WaitOnExit;
  FreeAndNil(P);
end;

{ `rigctld` が受け取った `send_morse` の文字列を、順に返します。
  The `send_morse` strings `rigctld` received, in order. }
function MorseSent(const LogName: string): TStringList;
var
  Lines: TStringList;
  I, A, B: Integer;
  Line: string;
begin
  Result := TStringList.Create;
  if not FileExists(LogName) then
    Exit;
  Lines := TStringList.Create;
  try
    Lines.LoadFromFile(LogName);
    for I := 0 to Lines.Count - 1 do
    begin
      Line := Lines[I];
      { 形: rigctl(d): b 'currVFO' ' CQ ' '' '' / Shape of the line. }
      if Pos('rigctl(d): b ', Line) <> 1 then
        Continue;
      A := Pos('''', Line, Pos('''currVFO''', Line) + 9);
      B := Pos('''', Line, A + 1);
      if (A > 0) and (B > A) then
        Result.Add(Trim(Copy(Line, A + 1, B - A - 1)));
    end;
  finally
    Lines.Free;
  end;
end;

function WaitFor(Keyer: TRigKeyer; State: TKeyerState; Seconds: Double): Boolean;
var
  Until_: QWord;
begin
  Until_ := GetTickCount64 + QWord(Round(Seconds * 1000));
  repeat
    if Keyer.Snapshot.State = State then
      Exit(True);
    Sleep(20);
  until GetTickCount64 > Until_;
  Result := Keyer.Snapshot.State = State;
end;

function WaitForFreq(Keyer: TRigKeyer; Hz: Integer; const Mode: string;
  Seconds: Double): Boolean;
var
  Until_: QWord;
  Status: TKeyerStatus;
begin
  Until_ := GetTickCount64 + QWord(Round(Seconds * 1000));
  repeat
    Status := Keyer.Snapshot;
    if (Round(Status.RigFreqHz) = Hz) and (Status.RigMode = Mode) then
      Exit(True);
    Sleep(50);
  until GetTickCount64 > Until_;
  Result := False;
end;

function WaitForPower(Keyer: TRigKeyer; Power: TPowerResult; Seconds: Double): Boolean;
var
  Until_: QWord;
begin
  Until_ := GetTickCount64 + QWord(Round(Seconds * 1000));
  repeat
    if Keyer.Snapshot.Power = Power then
      Exit(True);
    Sleep(20);
  until GetTickCount64 > Until_;
  Result := Keyer.Snapshot.Power = Power;
end;

{ 中継の記録の行のうち、その文字列を含むものの数（状態を問わない）。
  Lines of the relay log containing the text, whatever the mode. }
function CountLines(const LogName, Text: string): Integer;
var
  Lines: TStringList;
  I: Integer;
begin
  Result := 0;
  if not FileExists(LogName) then
    Exit;
  Lines := TStringList.Create;
  try
    Lines.LoadFromFile(LogName);
    for I := 0 to Lines.Count - 1 do
      if Pos(Text, Lines[I]) > 0 then
        Inc(Result);
  finally
    Lines.Free;
  end;
end;

function Settings: TRigSettings;
begin
  Result.Model := HAMLIB_MODEL_NETRIGCTL;
  Result.Port := Format('localhost:%d', [Port]);
  Result.Baud := 0;
  Result.Conf := nil;
  Result.PowerOnAtOpen := False;
end;

{ 詳しい接続設定が Hamlib に渡ること、断るべきものを断ること（要件 FR-T.5）。
  **口は開きません**（設定は開く前に渡るため）。
  Detailed settings reach Hamlib, and what must be refused is (FR-T.5). **No
  port is opened** (settings are passed before opening). }
procedure TestConf;
var
  Conf: TRigConf;
  S: TRigSettings;
  Rig: THamlibRig;
  Problem: TRigConfProblem;
  Name: string;

  function Refused(const ASettings: TRigSettings; out E: EHamlib): Boolean;
  begin
    E := nil;
    try
      THamlibRig.Create(ASettings).Free;
      Result := False;
    except
      on X: EHamlib do
      begin
        E := EHamlib.Create(X.Message);
        E.Stage := X.Stage;
        E.Setting := X.Setting;
        E.Code := X.Code;
        Result := True;
      end;
    end;
  end;

var
  E: EHamlib;
begin
  WriteLn('詳しい接続設定 / detailed connection settings (FR-T.5)');
  Conf := DefaultRigConf;
  Conf.CivAddr := '94';
  Conf.DataBits := 8;
  Conf.StopBits := 2;
  Conf.Parity := 'Even';
  Conf.Handshake := 'None';
  Conf.Dtr := 'OFF';
  Conf.Rts := 'OFF';
  Conf.TimeoutMs := 1500;
  Conf.WriteDelayMs := 5;
  Conf.PostWriteDelayMs := 7;
  Check('確かめを通る', CheckRigConf(Conf, Problem, Name), Name);
  S.Model := 3073;  { IC-7300 }
  S.Port := '/dev/null';
  S.Baud := 19200;
  S.Conf := RigConfPairs(Conf);
  S.PowerOnAtOpen := False;
  Rig := THamlibRig.Create(S);
  try
    Check('CI-V アドレスが渡る（94 は 16 進 = 148）', Rig.GetConf('civaddr') = '148',
      Rig.GetConf('civaddr'));
    Check('データビット・ストップビット・パリティが渡る',
      (Rig.GetConf('data_bits') = '8') and (Rig.GetConf('stop_bits') = '2') and
      (Rig.GetConf('serial_parity') = 'Even'),
      Rig.GetConf('data_bits') + '/' + Rig.GetConf('stop_bits') + '/' +
      Rig.GetConf('serial_parity'));
    Check('フロー制御・DTR・RTS が渡る',
      (Rig.GetConf('serial_handshake') = 'None') and
      (Rig.GetConf('dtr_state') = 'OFF') and (Rig.GetConf('rts_state') = 'OFF'));
    Check('応答待ち・書き込み間隔が渡る',
      (Rig.GetConf('timeout') = '1500') and (Rig.GetConf('write_delay') = '5') and
      (Rig.GetConf('post_write_delay') = '7'));
    Check('通信速度が渡る', Rig.GetConf('serial_speed') = '19200',
      Rig.GetConf('serial_speed'));
    Check('再試行は 0（機種の既定 3 を上書き）', Rig.GetConf('retry') = '0',
      Rig.GetConf('retry'));
    Check('開くときに電源を入れさせない・閉じるときに切らせない',
      (Rig.GetConf('auto_power_on') = '0') and (Rig.GetConf('auto_power_off') = '0'));
  finally
    Rig.Free;
  end;

  S.Conf := nil;
  S.PowerOnAtOpen := True;
  Rig := THamlibRig.Create(S);
  try
    Check('「電源を入れて繋ぐ」のときだけ、開くときに電源を入れさせる',
      Rig.GetConf('auto_power_on') = '1', Rig.GetConf('auto_power_on'));
  finally
    Rig.Free;
  end;

  S := Settings;
  SetLength(S.Conf, 1);
  S.Conf[0].Name := 'data_bits';
  S.Conf[0].Value := '8';
  Check('その機種（網の口）に無い設定は断る', Refused(S, E) and (E.Stage = hsConfig) and
    (E.Setting = 'data_bits'));
  E.Free;
  S.Model := 3073;
  S.Port := '/dev/null';
  S.Conf[0].Name := 'serial_parity';
  S.Conf[0].Value := 'Bogus';
  Check('Hamlib が断る値は、名指しして断る', Refused(S, E) and (E.Stage = hsConfig) and
    (E.Setting = 'serial_parity'));
  E.Free;
  S.Conf := nil;
  S.Model := 999999;
  Check('知らない機種は「機種」の失敗', Refused(S, E) and (E.Stage = hsModel));
  E.Free;
end;

procedure SetMode(const ControlFile, Mode: string);
var
  F: TStringList;
begin
  F := TStringList.Create;
  try
    F.Text := Mode;
    F.SaveToFile(ControlFile);
  finally
    F.Free;
  end;
end;

{ 中継の記録に、その命令が何回届いたか（`pass` のときだけ数える）。
  How many times a command reached the relay while passing. }
function RelayCount(const LogName, Command: string): Integer;
var
  Lines: TStringList;
  I: Integer;
begin
  Result := 0;
  if not FileExists(LogName) then
    Exit;
  Lines := TStringList.Create;
  try
    Lines.LoadFromFile(LogName);
    for I := 0 to Lines.Count - 1 do
      if (Pos(' pass ', Lines[I]) > 0) and (Pos(Command, Lines[I]) > 0) then
        Inc(Result);
  finally
    Lines.Free;
  end;
end;

{ 応答の確かめと、電源を入れる流れ（要件 FR-T.6）。
  The answer check and the power-on flow (FR-T.6). }
procedure TestLiveness;
var
  Daemon, Relay: TProcess;
  Keyer: TRigKeyer;
  S: TRigSettings;
  Control, RelayLog, DaemonLog: string;
  RelayPort, Speeds: Integer;
  Status: TKeyerStatus;
begin
  WriteLn('応答の確かめと電源 / answer check and power (FR-T.6)');
  if not FileExists(ProxyPath) then
  begin
    WriteLn('  中継（', ProxyPath, '）がありません。この部分は確かめていません。');
    Inc(Failures);
    Exit;
  end;
  Control := WorkDir + 'rig-proxy.mode';
  RelayLog := WorkDir + 'rig-proxy.log';
  DaemonLog := WorkDir + 'rigctld-c.log';
  DeleteFile(RelayLog);
  DeleteFile(DaemonLog);
  RelayPort := Port + 1;
  SetMode(Control, 'off');
  Daemon := StartRigctld(DaemonLog);
  Relay := TProcess.Create(nil);
  Relay.Executable := 'python3';
  Relay.Parameters.Add(ProxyPath);
  Relay.Parameters.Add('--listen');
  Relay.Parameters.Add(IntToStr(RelayPort));
  Relay.Parameters.Add('--upstream');
  Relay.Parameters.Add(IntToStr(Port));
  Relay.Parameters.Add('--control');
  Relay.Parameters.Add(Control);
  Relay.Parameters.Add('--log');
  Relay.Parameters.Add(RelayLog);
  Relay.Parameters.Add('--boot');
  Relay.Parameters.Add('2');
  Relay.Options := [poNoConsole];
  Relay.Execute;
  Sleep(700);
  Keyer := TRigKeyer.Create;
  try
    S := Settings;
    S.Port := Format('localhost:%d', [RelayPort]);
    { 網の口の既定の応答待ちは 10 秒。試験では 0.8 秒にします（FR-T.5 の設定）。
      The network client waits 10 s by default; 0.8 s here (an FR-T.5 setting). }
    SetLength(S.Conf, 1);
    S.Conf[0].Name := 'timeout';
    S.Conf[0].Value := '800';

    WriteLn('  電源が切れている無線機に繋ぐ / connecting to a rig that is off');
    Keyer.Connect(S, 20);
    Check('開くときに応答が無ければ「失敗（応答なし）」', WaitFor(Keyer, ksFailed, 15) and
      (Keyer.Snapshot.Fault = kfNoAnswer), Keyer.Snapshot.Detail);
    Check('応答なしのときは送らない（断る）', not Keyer.Send('CQ'));
    Check('電源を入れて繋ぐを頼める', Keyer.PowerOn);
    Check('開くときに電源を入れられない接続では「失敗」に戻る',
      WaitFor(Keyer, ksFailed, 20) and (Keyer.Snapshot.Fault = kfNoAnswer) and
      (Keyer.Snapshot.Power = prFailed), IntToStr(Ord(Keyer.Snapshot.Power)));

    WriteLn('  電源が入っている / the rig is on');
    SetMode(Control, 'pass');
    Keyer.Connect(S, 20);
    Check('応答を確かめてから「待機」になる', WaitFor(Keyer, ksReady, 10),
      Keyer.Snapshot.Detail);
    Check('待機中は電源を頼めない', not Keyer.PowerOn);
    Keyer.Stop;
    Sleep(300);
    Check('送っていなければ、止めても無線機へ止める命令を送らない',
      CountLines(RelayLog, 'stop_morse') = 0, IntToStr(CountLines(RelayLog, 'stop_morse')));
    Speeds := RelayCount(RelayLog, 'KEYSPD');

    WriteLn('  途中で応答しなくなる / the rig stops answering');
    SetMode(Control, 'silent');
    Check('待機中に応答が無くなれば「応答なし」（10 秒以内）',
      WaitFor(Keyer, ksNoAnswer, 10), IntToStr(Ord(Keyer.Snapshot.State)));
    Check('応答なしのときは送らない（断る）', not Keyer.Send('CQ'));
    Check('口は閉じない（失敗にしない）', Keyer.Snapshot.Fault = kfNone);
    { 送っていないのに「止める」を押しても（音の停止ボタンも無線機を止める）、
      応答しない無線機へ止める命令を送って「失敗」にしない（付録 BU.1）。
      Pressing a stop while nothing is being sent (the audio stop button stops
      the rig too) must not send a stop to a silent rig and fail (BU.1). }
    Keyer.Stop;
    Sleep(2500);
    Check('送っていなければ、止めても「応答なし」のまま（止める命令を送らない）',
      (Keyer.Snapshot.State = ksNoAnswer) and (Keyer.Snapshot.Fault = kfNone),
      IntToStr(Ord(Keyer.Snapshot.State)) + ' ' + Keyer.Snapshot.Detail);
    SetMode(Control, 'pass');
    Check('応答が戻れば「待機」に戻る（6 秒以内）', WaitFor(Keyer, ksReady, 6),
      IntToStr(Ord(Keyer.Snapshot.State)));
    Sleep(300);
    Check('戻ったら速度を合わせ直す', RelayCount(RelayLog, 'KEYSPD') > Speeds,
      Format('%d → %d', [Speeds, RelayCount(RelayLog, 'KEYSPD')]));
    Check('戻っても何も送らない', RelayCount(RelayLog, 'send_morse') = 0,
      IntToStr(RelayCount(RelayLog, 'send_morse')));
    Check('頼まなければ、電源の命令は 1 度も送らない',
      CountLines(RelayLog, 'set_powerstat') = 0,
      IntToStr(CountLines(RelayLog, 'set_powerstat')));

    WriteLn('  電源を切られ、遠隔で入れる / switched off, then powered on remotely');
    SetMode(Control, 'silent');
    Check('応答なしになる', WaitFor(Keyer, ksNoAnswer, 10));
    Check('応答しない無線機に電源を頼むと「入れられない」', Keyer.PowerOn and
      WaitForPower(Keyer, prFailed, 5) and (Keyer.Snapshot.State = ksNoAnswer),
      IntToStr(Ord(Keyer.Snapshot.Power)));
    SetMode(Control, 'off');
    Check('電源を入れる命令を送る', Keyer.PowerOn);
    Check('起きるのを待つ（「電源を入れています」）', WaitFor(Keyer, ksPoweringOn, 5),
      IntToStr(Ord(Keyer.Snapshot.State)));
    Check('起きたら「待機」になる（起動 2 秒）', WaitFor(Keyer, ksReady, 10),
      IntToStr(Ord(Keyer.Snapshot.State)));
    Status := Keyer.Snapshot;
    Check('起きたと知らせる', Status.Power = prAwake, IntToStr(Ord(Status.Power)));
    Check('電源を入れる命令は、頼んだ 1 回につき 1 度だけ（送り直さない）',
      CountLines(RelayLog, ' off \set_powerstat 1') = 1,
      IntToStr(CountLines(RelayLog, ' off \set_powerstat 1')));
    Check('電源を切る命令は 1 度も送らない', CountLines(RelayLog, 'set_powerstat 0') = 0);
    Check('送る', Keyer.Send('TU'));
    Check('送り終える', WaitFor(Keyer, ksReady, 10));
    Check('送ったのは頼んだ文だけ', RelayCount(RelayLog, 'send_morse') = 1,
      IntToStr(RelayCount(RelayLog, 'send_morse')));

    WriteLn('  繋がりそのものが切れる / the link itself is lost');
    StopRigctld(Daemon);
    Check('切れたら「失敗」になる（送っていなくても気付く）', WaitFor(Keyer, ksFailed, 15),
      IntToStr(Ord(Keyer.Snapshot.State)));
    Status := Keyer.Snapshot;
    Check('失敗の種類は「繋がりが切れた」か「応答なし」',
      Status.Fault in [kfLink, kfNoAnswer], IntToStr(Ord(Status.Fault)) + ' ' + Status.Detail);
    Check('失敗のあとは送らない（断る）', not Keyer.Send('CQ'));
  finally
    Keyer.Free;
    StopRigctld(Daemon);
    Relay.Terminate(0);
    Relay.WaitOnExit;
    Relay.Free;
  end;
end;

var
  I: Integer;
  Keyer: TRigKeyer;
  Daemon: TProcess;
  LogA, LogB: string;
  Sent: TStringList;
  Status: TKeyerStatus;
  Wrong: TRigSettings;
  HandedAtStop: Integer;
  Started: QWord;
  Elapsed: Double;
  Output_: string;
begin
  I := 1;
  while I <= CommandLineArgCount do
  begin
    if (CommandLineArg(I) = '--rigctld') and (I < CommandLineArgCount) then
      RigctldPath := CommandLineArg(I + 1)
    else if (CommandLineArg(I) = '--port') and (I < CommandLineArgCount) then
      Port := StrToIntDef(CommandLineArg(I + 1), Port)
    else if (CommandLineArg(I) = '--work') and (I < CommandLineArgCount) then
      WorkDir := CommandLineArg(I + 1)
    else if (CommandLineArg(I) = '--proxy') and (I < CommandLineArgCount) then
      ProxyPath := CommandLineArg(I + 1);
    Inc(I, 2);
  end;
  if WorkDir = '' then
    WorkDir := GetTempDir;
  WorkDir := IncludeTrailingPathDelimiter(WorkDir);
  LogA := WorkDir + 'rigctld-a.log';
  LogB := WorkDir + 'rigctld-b.log';
  DeleteFile(LogA);
  DeleteFile(LogB);

  if not LoadHamlib then
  begin
    WriteLn('Hamlib を読み込めません: ', HamlibLoadError);
    Halt(2);
  end;
  WriteLn('Hamlib: ', HamlibLibraryPath);

  Keyer := TRigKeyer.Create;
  Daemon := nil;
  try
    WriteLn('繋がる前 / before connecting');
    Check('繋がっていなければ送らない（断る）', not Keyer.Send('CQ'));

    WriteLn('繋がらない口 / a port that does not answer');
    Wrong := Settings;
    Wrong.Port := 'localhost:1';
    Keyer.Connect(Wrong, 30);
    Check('繋がらなければ「失敗」になる', WaitFor(Keyer, ksFailed, 10),
      IntToStr(Ord(Keyer.Snapshot.State)));
    Check('失敗の種類は「口を開けない」', Keyer.Snapshot.Fault = kfPort,
      Keyer.Snapshot.Detail);
    Check('失敗したら送らない（断る）', not Keyer.Send('CQ'));

    Daemon := StartRigctld(LogA);
    WriteLn('送る / sending');
    Keyer.Connect(Settings, 40);
    Check('繋がる', WaitFor(Keyer, ksReady, 10), Keyer.Snapshot.Detail);
    Sleep(200);
    Check('速度を無線機に合わせた', Keyer.Snapshot.SpeedSet);
    Check('無線機に訊き直した速度で間合いを計る', Keyer.Snapshot.RigWpm = 40,
      IntToStr(Keyer.Snapshot.RigWpm));
    { 周波数とモード（要件 FR-T.7）。ダミーは 145 MHz・FM で始まります。別の
      口から 7.0234 MHz・CW にすると、次の確かめ（5 秒以内）で読める。
      Frequency and mode (FR-T.7). The dummy starts at 145 MHz FM; set to
      7.0234 MHz CW from another client, the next check (within 5 s) reads it. }
    Status := Keyer.Snapshot;
    Check('繋いだときに周波数とモードを読む（145 MHz・FM）',
      (Round(Status.RigFreqHz) = 145000000) and (Status.RigMode = 'FM'),
      Format('%.0f %s', [Status.RigFreqHz, Status.RigMode]));
    RunCommand('rigctl', ['-m', '2', '-r', Format('localhost:%d', [Port]),
      'F', '7023400', 'M', 'CW', '500'], Output_);
    Check('無線機で周波数とモードを変えれば、読み取りも変わる（7 秒以内）',
      WaitForFreq(Keyer, 7023400, 'CW', 7),
      Format('%.0f %s', [Keyer.Snapshot.RigFreqHz, Keyer.Snapshot.RigMode]));
    Started := GetTickCount64;
    Check('送る', Keyer.Send('CQ DE JA1ABC K'));
    Check('送っている間は、次の文を受け付けない', not Keyer.Send('TEST'));
    Sleep(100);
    Check('送り終える見込みを知らせる（受信の抑制が使う）',
      Keyer.Snapshot.KeyedUntil > GetTickCount64,
      Format('%d / %d', [Keyer.Snapshot.KeyedUntil, GetTickCount64]));
    Check('送り終えて「待機」に戻る', WaitFor(Keyer, ksReady, 15));
    { 送り終えるまでの時間は、文全体の見積もりと合うこと（付録 BS.1）。
      語間を数え落とすと、語ごとに早まって短く終わる。
      Sending takes as long as the whole text is estimated to (appendix BS.1);
      dropping the word gaps makes it finish early, one gap per word. }
    Elapsed := (GetTickCount64 - Started) / 1000;
    Check('送り終えるまでの時間が、文全体の見積もりと合う（±0.25 秒）',
      Abs(Elapsed - EstimateTransmitSeconds('CQ DE JA1ABC K', 40)) < 0.25,
      Format('%.2f / %.2f 秒', [Elapsed, EstimateTransmitSeconds('CQ DE JA1ABC K', 40)]));
    Sent := MorseSent(LogA);
    try
      Check('語ごとに、順に、1 度ずつ渡した',
        Sent.CommaText = 'CQ,DE,JA1ABC,K', Sent.CommaText);
    finally
      Sent.Free;
    end;

    WriteLn('間合い / pacing');
    Keyer.SetWpm(10);
    Sleep(200);
    Check('速度を変えれば、訊き直した速度も変わる', Keyer.Snapshot.RigWpm = 10,
      IntToStr(Keyer.Snapshot.RigWpm));
    Started := GetTickCount64;
    Check('送る（遅い速度）', Keyer.Send('ONE TWO THREE FOUR FIVE'));
    Sleep(300);
    Status := Keyer.Snapshot;
    Check('一度に全部は渡さない（語ずつ、間合いを取る）',
      (Status.Handed > 0) and (Status.Handed < Length('ONE TWO THREE FOUR FIVE')),
      IntToStr(Status.Handed));

    WriteLn('止める / stopping');
    HandedAtStop := Keyer.Snapshot.Handed;
    Keyer.Stop;
    Check('止めたあと、送り終える見込みで「待機」に戻る', WaitFor(Keyer, ksReady, 10));
    Status := Keyer.Snapshot;
    Check('止めたあとは 1 語も渡さない', Status.Handed = HandedAtStop,
      Format('%d → %d', [HandedAtStop, Status.Handed]));
    Check('ダミーの無線機は止められないと分かる', Status.Stop = ssNo);
    Sent := MorseSent(LogA);
    try
      Check('記録にも、止めたあとの語が無い',
        (Sent.IndexOf('FOUR') < 0) and (Sent.IndexOf('FIVE') < 0), Sent.CommaText);
    finally
      Sent.Free;
    end;
    WriteLn(Format('    （止めるまで %d ms、渡したのは %d 文字）',
      [GetTickCount64 - Started, HandedAtStop]));

    WriteLn('繋がりが切れる / the connection is lost');
    Keyer.SetWpm(20);
    Sleep(200);
    Check('送る', Keyer.Send('LOST LINK TEST MESSAGE'));
    Sleep(150);
    StopRigctld(Daemon);
    Check('切れたら「失敗」になる', WaitFor(Keyer, ksFailed, 15),
      IntToStr(Ord(Keyer.Snapshot.State)));
    Check('失敗の種類は「送れない」', Keyer.Snapshot.Fault = kfSend,
      Keyer.Snapshot.Detail);
    Check('失敗しても、送り終える見込みは残す（無線機は渡された語を送りうる）',
      Keyer.Snapshot.KeyedUntil > 0);

    Daemon := StartRigctld(LogB);
    Sleep(1500);
    Check('繋ぎ直さない（「失敗」のまま）', Keyer.Snapshot.State = ksFailed);
    Check('失敗のあとは送らない（断る）', not Keyer.Send('CQ'));
    Keyer.Connect(Settings, 20);
    Check('利用者が繋ぎ直せば繋がる', WaitFor(Keyer, ksReady, 10),
      Keyer.Snapshot.Detail);
    Sleep(1000);
    Sent := MorseSent(LogB);
    try
      Check('繋ぎ直しても、古い文を送らない', Sent.Count = 0, Sent.CommaText);
    finally
      Sent.Free;
    end;
    Check('新しい文は送れる', Keyer.Send('TU'));
    Check('送り終える', WaitFor(Keyer, ksReady, 10));
    Sent := MorseSent(LogB);
    try
      Check('新しい文だけが届いた', Sent.CommaText = 'TU', Sent.CommaText);
    finally
      Sent.Free;
    end;
  finally
    Keyer.Free;
    StopRigctld(Daemon);
  end;

  TestConf;
  TestLiveness;

  WriteLn;
  if Failures = 0 then
    WriteLn('無線機の鍵の操作はすべて通りました。')
  else
    WriteLn(Format('%d 件が通りませんでした。', [Failures]));
  Halt(Ord(Failures > 0));
end.
