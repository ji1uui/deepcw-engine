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

    使い方 / usage: rig_check [--rigctld PATH] [--port N] [--work DIR] }

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Classes, SysUtils, Process, DeepCW.Hamlib, DeepCW.RigKeyer, DeepCW.TxMessage,
  DeepCW.Platform;

var
  Failures: Integer = 0;
  RigctldPath: string = 'rigctld';
  Port: Integer = 45321;
  WorkDir: string = '';

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

function Settings: TRigSettings;
begin
  Result.Model := HAMLIB_MODEL_NETRIGCTL;
  Result.Port := Format('localhost:%d', [Port]);
  Result.Baud := 0;
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
begin
  I := 1;
  while I <= CommandLineArgCount do
  begin
    if (CommandLineArg(I) = '--rigctld') and (I < CommandLineArgCount) then
      RigctldPath := CommandLineArg(I + 1)
    else if (CommandLineArg(I) = '--port') and (I < CommandLineArgCount) then
      Port := StrToIntDef(CommandLineArg(I + 1), Port)
    else if (CommandLineArg(I) = '--work') and (I < CommandLineArgCount) then
      WorkDir := CommandLineArg(I + 1);
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
    Check('失敗の種類は「繋げない」', Keyer.Snapshot.Fault = kfConnect,
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

  WriteLn;
  if Failures = 0 then
    WriteLn('無線機の鍵の操作はすべて通りました。')
  else
    WriteLn(Format('%d 件が通りませんでした。', [Failures]));
  Halt(Ord(Failures > 0));
end.
