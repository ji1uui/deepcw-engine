program perf_report;

{ 性能の報告です（計画 6.1 の P2）。

  要件 NFR-1 の数は、これまで `cw_stream`・`cw_tune --tests scale,soak`・
  `gui_probe`・起動の計時・ファイルの止まりの測りに散っていて、**基準機
  （Intel N150 相当）で走らせてもらうには手順が多すぎました。**しかも既定の
  遅延の測りは同調しないので、**同調した交信モードの経路を通っていません
  でした**（教訓 10.107）。これを 1 本の命令にまとめ、表を 1 枚出します。

  この道具自身は測りません。**回帰試験と同じ道具を呼び、その出力を読む**
  だけです。別に測り直す道を書けば、報告の数と回帰試験の数が食い違います。

  本物のアプリを走らせるときは、設定と記録の置き場所を一時の場所へ移します
  （`DEEPCW_CONFIG_DIR`）。**利用者の設定・交信記録に触れません。**

  使い方: `perf_report [--full]`。Linux の画面の無い機械では
  `xvfb-run -a cli/perf_report`。`--full` は 12 分の連続受信（NFR-1.8）と
  30 分のファイルを足します（合わせて約 15 分）。

  The performance report (plan 6.1, P2).

  The NFR-1 figures were scattered over `cw_stream`, `cw_tune --tests
  scale,soak`, `gui_probe`, timing the start-up and measuring the file stall:
  **too many steps to ask anyone to run on the baseline machine** (Intel N150
  class). And the default latency measurement does not tune, so **it never
  passed through the tuned contact-mode path** (lesson 10.107). This gathers
  them into one command and one table.

  It measures nothing itself: **it runs the same tools the regression runs and
  reads what they print.** A second way of measuring would let the report and
  the regression disagree.

  When the real application runs, its settings and records are moved to a
  scratch place (`DEEPCW_CONFIG_DIR`): **the operator's settings and contact
  log are not touched.**

  Usage: `perf_report [--full]`. On Linux without a display,
  `xvfb-run -a cli/perf_report`. `--full` adds the 12-minute run (NFR-1.8) and
  a 30-minute file (about 15 minutes more). }

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  SysUtils, Classes, Math, Process,
  DeepCW.Types, DeepCW.Morse, DeepCW.Wave, DeepCW.Platform;

const
  { 回帰試験と同じ本文（付録 C.5）。/ The regression's texts (appendix C.5). }
  SHORT_TEXT = 'TNX FER QSO 73 ES GL WX IS FB HR RIG IS 100W ANT IS GP';
  CALLSIGN_TEXT = 'CQ CQ DE JH2XYZ JH2XYZ K JA1ABC DE JH2XYZ UR 599 599 QTH NAGOYA';

type
  TRow = record
    What, Target, Value, Verdict, How: string;
  end;

var
  Rows: array of TRow;
  Base, Ext, Work: string;
  Full: Boolean = False;

procedure Add(const What, Target, Value, Verdict, How: string);
begin
  SetLength(Rows, Length(Rows) + 1);
  Rows[High(Rows)].What := What;
  Rows[High(Rows)].Target := Target;
  Rows[High(Rows)].Value := Value;
  Rows[High(Rows)].Verdict := Verdict;
  Rows[High(Rows)].How := How;
end;

function Tool(const Dir, Name: string): string;
begin
  Result := Base + Dir + PathDelim + Name + Ext;
end;

{ 道具を走らせ、出力をすべて受け取ります。`Env` は `名前=値` の並びで、同じ名前の
  既存の値を置き換えます。`Limit` 秒を超えたら止め、-2 を返します。見つからなければ
  -1 です。
  Runs a tool and collects all it prints. `Env` holds `NAME=value` entries that
  replace any existing value of the same name. Past `Limit` seconds it is
  stopped and -2 returned; -1 when the tool is missing. }
function RunTool(const Exe: string; const Args, Env: array of string;
  Limit: Double; out Output: string; out Seconds: Double): Integer;
var
  P: TProcess;
  Buffer: array[0..4095] of Byte;
  Count, I, J: Integer;
  Name: string;
  Started: TDateTime;
  Collected: TStringStream;

  procedure Drain;
  begin
    while P.Output.NumBytesAvailable > 0 do
    begin
      Count := P.Output.Read(Buffer[0], Min(SizeOf(Buffer), P.Output.NumBytesAvailable));
      if Count <= 0 then
        Break;
      Collected.WriteBuffer(Buffer[0], Count);
    end;
  end;

begin
  Output := '';
  Seconds := 0;
  if not FileExists(Exe) then
  begin
    Output := 'not found: ' + Exe;
    Exit(-1);
  end;
  P := TProcess.Create(nil);
  Collected := TStringStream.Create('');
  try
    P.Executable := Exe;
    for I := 0 to High(Args) do
      P.Parameters.Add(Args[I]);
    if Length(Env) > 0 then
    begin
      for I := 1 to GetEnvironmentVariableCount do
        P.Environment.Add(GetEnvironmentString(I));
      for I := 0 to High(Env) do
      begin
        Name := Copy(Env[I], 1, Pos('=', Env[I]));
        for J := P.Environment.Count - 1 downto 0 do
          if SameText(Copy(P.Environment[J], 1, Length(Name)), Name) then
            P.Environment.Delete(J);
        P.Environment.Add(Env[I]);
      end;
    end;
    P.Options := [poUsePipes, poStderrToOutPut];
    Started := Now;
    P.Execute;
    while P.Running do
    begin
      Drain;
      if (Now - Started) * SecsPerDay > Limit then
      begin
        P.Terminate(1);
        Drain;
        Output := Collected.DataString;
        Seconds := (Now - Started) * SecsPerDay;
        Exit(-2);
      end;
      Sleep(5);
    end;
    Seconds := (Now - Started) * SecsPerDay;
    Drain;
    Output := Collected.DataString;
    Result := P.ExitCode;
  finally
    Collected.Free;
    P.Free;
  end;
end;

{ 出力の中で `Marker` の直後にある数を読みます。/ Reads the number that
  follows `Marker` in the output. }
function NumberAfter(const Output, Marker: string; out Value: Double): Boolean;
var
  At, Stop: Integer;
  Settings: TFormatSettings;
begin
  Result := False;
  Value := 0;
  At := Pos(Marker, Output);
  if At = 0 then
    Exit;
  At := At + Length(Marker);
  while (At <= Length(Output)) and (Output[At] = ' ') do
    Inc(At);
  Stop := At;
  while (Stop <= Length(Output)) and (Output[Stop] in ['0'..'9', '.', '-']) do
    Inc(Stop);
  Settings := DefaultFormatSettings;
  Settings.DecimalSeparator := '.';
  Result := TryStrToFloat(Copy(Output, At, Stop - At), Value, Settings);
end;

{ `Marker` の直前にある数（「0.316 コア相当」の 0.316）。/ The number just
  before `Marker` (0.316 in "0.316 cores"). }
function NumberBefore(const Output, Marker: string; out Value: Double): Boolean;
var
  At, Start: Integer;
  Settings: TFormatSettings;
begin
  Result := False;
  Value := 0;
  At := Pos(Marker, Output);
  if At = 0 then
    Exit;
  Dec(At);
  while (At > 0) and (Output[At] = ' ') do
    Dec(At);
  Start := At;
  while (Start > 0) and (Output[Start] in ['0'..'9', '.']) do
    Dec(Start);
  Settings := DefaultFormatSettings;
  Settings.DecimalSeparator := '.';
  Result := TryStrToFloat(Copy(Output, Start + 1, At - Start), Value, Settings);
end;

{ 測れなかった理由として、出力の最後の空でない行を返します。/ The last
  non-empty line of the output, as the reason nothing could be measured. }
function LastLine(const Output: string): string;
var
  Lines: TStringList;
  I: Integer;
begin
  Result := '';
  Lines := TStringList.Create;
  try
    Lines.Text := Output;
    for I := Lines.Count - 1 downto 0 do
      if Trim(Lines[I]) <> '' then
        { 表の区切りと取り違えないように。/ Not to be taken for a column
          separator. }
        Exit(StringReplace(Copy(Trim(Lines[I]), 1, 80), '|', '/', [rfReplaceAll]));
  finally
    Lines.Free;
  end;
end;

function Judge(Passed: Boolean): string;
begin
  if Passed then
    Result := '達成'
  else
    Result := '**未達**';
end;

function Seconds2(Value: Double): string;
begin
  Result := FormatFloat('0.00', Value) + ' 秒';
end;

{ ---- 遅延（NFR-1.1・NFR-1.2）と交信モードの同調した経路 ---- }

procedure MeasureStream(const Title, Text: string; Ceiling: Double;
  const Extra: array of string; Known: Boolean);
var
  Output, Args: string;
  Seconds, Pending, Confirm, Cores, StepMs: Double;
  Rc, I: Integer;
  List: array of string;
  How: string;
begin
  SetLength(List, 6 + Length(Extra));
  List[0] := '--quiet';
  List[1] := '--check';
  List[2] := '--max-confirmed';
  List[3] := FormatFloat('0.0', Ceiling);
  List[4] := '--text';
  List[5] := Text;
  for I := 0 to High(Extra) do
    List[6 + I] := Extra[I];
  Args := '';
  for I := 0 to High(Extra) do
    Args := Args + ' ' + Extra[I];
  How := '`cw_stream --text …' + Args + '`';
  Rc := RunTool(Tool('cli', 'cw_stream'), List, [], 600, Output, Seconds);
  if not (NumberAfter(Output, '暫定文字の遅延 95%:', Pending) and
          NumberAfter(Output, '確定文字の遅延 95%:', Confirm)) then
  begin
    Add('NFR-1.1・1.2・1.5（' + Title + '）', '', '測れない: ' + LastLine(Output),
      '—', How);
    Exit;
  end;
  NumberBefore(Output, 'コア相当', Cores);
  NumberAfter(Output, '/ 1 回', StepMs);
  Add('NFR-1.1 暫定の遅延 95%（' + Title + '）', '1.5 秒', Seconds2(Pending),
    Judge(Pending <= 1.5), How);
  if Known and (Confirm > 5.0) then
    Add('NFR-1.2 確定の遅延 95%（' + Title + '）', '5.0 秒',
      Seconds2(Confirm), Format('**未達**（既知・天井 %.1f 秒%s）',
        [Ceiling, BoolToStr(Confirm <= Ceiling, 'の内', 'を超えた')]), How)
  else
    Add('NFR-1.2 確定の遅延 95%（' + Title + '）', '5.0 秒',
      Seconds2(Confirm), Judge(Confirm <= 5.0), How);
  Add('NFR-1.5 CPU（' + Title + '）', '1 コア',
    Format('%.3f コア相当（解析 1 回 %.1f ms）', [Cores, StepMs]),
    Judge(Cores <= 1.0), How);
  if Rc <> 0 then
    Add('（' + Title + '）の検査', '', LastLine(Output), '**未達**', How);
end;

{ ---- CPU（NFR-1.5、多局 24 局）---- }

procedure MeasureScale;
var
  Output, Line: string;
  Seconds, Percent: Double;
  Lines: TStringList;
  I: Integer;
  Found: Boolean;
begin
  RunTool(Tool('cli', 'cw_tune'), ['--tests', 'scale'], [], 900, Output, Seconds);
  Found := False;
  Lines := TStringList.Create;
  try
    Lines.Text := Output;
    for I := 0 to Lines.Count - 1 do
    begin
      Line := Trim(Lines[I]);
      if (Copy(Line, 1, 3) = '24 ') and (Pos('%', Line) > 0) then
      begin
        Found := NumberBefore(Line, '%', Percent);
        Break;
      end;
    end;
  finally
    Lines.Free;
  end;
  if Found then
    Add('NFR-1.5 CPU（待機モード 24 局）', '1 コア',
      Format('%.2f コア相当', [Percent / 100]), Judge(Percent <= 100),
      '`cw_tune --tests scale`')
  else
    Add('NFR-1.5 CPU（待機モード 24 局）', '1 コア', '測れない: ' + LastLine(Output),
      '—', '`cw_tune --tests scale`');
end;

{ ---- 語の読み直し（NFR-1.3）と、遅い機械での間隔の調整（NFR-1.4）----
  実時間比は、**基準機でいちばん知りたい数**です。これが小さい機械ほど、
  解析の間隔が自動で広がります（FR-G.4）。
  The real-time ratio is **the number most wanted from the baseline machine**:
  the smaller it is, the wider the analysis interval grows by itself (FR-G.4). }

procedure MeasureRecheckPace;
var
  Output: string;
  Seconds, WordMs, Ratio, Interval: Double;
  Rc: Integer;
begin
  Rc := RunTool(Tool('cli', 'cw_tune'), ['--tests', 'recheck,pace'], [], 900,
    Output, Seconds);
  if NumberAfter(Output, '／ 1 語', WordMs) then
    Add('NFR-1.3 語の読み直しの応答', '1 秒', Format('%.0f ms', [WordMs]),
      Judge((WordMs < 1000) and (Pos('NG ', Output) = 0)), '`cw_tune --tests recheck`')
  else
    Add('NFR-1.3 語の読み直しの応答', '1 秒', '測れない: ' + LastLine(Output), '—',
      '`cw_tune --tests recheck`');
  { 「測る前は、実時間比も…」の行が先に出るので、数の付く書き方で探します。
    A line "before measuring, the ratio …" comes first, so the spelling that
    carries the number is searched for. }
  if NumberAfter(Output, '/ 実時間比 ', Ratio) and
     NumberAfter(Output, '倍 / 間隔 ', Interval) then
    Add('NFR-1.4 間隔の自動調整（予算を絞っても本文が読める）', '破綻しない',
      Format('実時間比 %.0f 倍 → 間隔 %.2f 秒', [Ratio, Interval]),
      Judge(Rc = 0), '`cw_tune --tests pace`')
  else
    Add('NFR-1.4 間隔の自動調整（予算を絞っても本文が読める）', '破綻しない',
      '測れない: ' + LastLine(Output), '—', '`cw_tune --tests pace`');
end;

{ ---- 描画（NFR-1.6）---- }

procedure MeasurePaint;
var
  Output: string;
  Seconds, Ms: Double;
begin
  RunTool(Tool('app', 'gui_probe'), [], [], 900, Output, Seconds);
  if NumberAfter(Output, '1 回の描画:', Ms) then
    Add('NFR-1.6 ウォーターフォールの描画', '33 ms（30 fps）',
      Format('%.2f ms', [Ms]), Judge(Ms <= 33.3), '`gui_probe`')
  else
    Add('NFR-1.6 ウォーターフォールの描画', '33 ms（30 fps）',
      '測れない: ' + LastLine(Output), '—', '`gui_probe`');
end;

{ ---- 起動（NFR-1.7）---- }

procedure MeasureStartup;
var
  Output: string;
  Times: array[0..2] of Double;
  I, J, Rc: Integer;
  Swap: Double;
begin
  for I := 0 to 2 do
  begin
    Rc := RunTool(Tool('app', 'deepcw_station'), [],
      ['DEEPCW_LAYOUT_CHECK=1', 'DEEPCW_CONFIG_DIR=' + Work + 'startup'], 120,
      Output, Times[I]);
    { 窓を出して全タブを走査できたことを、報告の行で確かめます。画面が無くて
      すぐ落ちたものを「速い」と数えないためです。
      That the window came up and every tab was scanned is confirmed from the
      report line, so that a quick failure for want of a display is not
      counted as fast. }
    if (Rc < 0) or (Pos('組み方の破綻', Output) = 0) then
    begin
      Add('NFR-1.7 起動（窓＋全タブの走査）', '5 秒', '測れない: ' + LastLine(Output),
        '—', '`DEEPCW_LAYOUT_CHECK=1 deepcw_station`');
      Exit;
    end;
  end;
  for I := 0 to 1 do
    for J := 0 to 1 - I do
      if Times[J] > Times[J + 1] then
      begin
        Swap := Times[J];
        Times[J] := Times[J + 1];
        Times[J + 1] := Swap;
      end;
  Add('NFR-1.7 起動（窓＋全タブの走査、3 回の中央値）', '5 秒',
    Seconds2(Times[1]), Judge(Times[1] <= 5.0),
    '`DEEPCW_LAYOUT_CHECK=1 deepcw_station`');
end;

{ ---- メモリ（NFR-1.8）---- }

procedure MeasureSoak;
var
  Output: string;
  Seconds, Before, After_: Double;
begin
  RunTool(Tool('cli', 'cw_tune'), ['--tests', 'soak'], [], 1800, Output, Seconds);
  if NumberAfter(Output, '常駐 ', Before) and NumberAfter(Output, 'kB →', After_) then
    Add('NFR-1.8 常駐メモリ（12 分の連続受信の後）', '500 MB',
      Format('%.0f kB（始め %.0f kB から %s%.0f）', [After_, Before,
        BoolToStr(After_ >= Before, '+', '-'), Abs(After_ - Before)]),
      Judge(After_ <= 500 * 1024), '`cw_tune --tests soak`')
  else
    Add('NFR-1.8 常駐メモリ（12 分の連続受信の後）', '500 MB',
      '測れない: ' + LastLine(Output), '—', '`cw_tune --tests soak`');
end;

{ ---- ファイルの復号で画面が止まる時間（NFR-4.2、付録 CE）---- }

{ `file_decode_stall_test.sh` と同じ場面の録音を作ります: 700 Hz の局と、300 Hz
  横の強い局と、弱い雑音。/ The recording of `file_decode_stall_test.sh`: a
  station at 700 Hz, a strong one 300 Hz away, and weak noise. }
function MakeRecording(Seconds: Integer): string;
var
  Timing: TCWTiming;
  Tone: TCWToneOptions;
  Near, Far, Mixed: TSingleArray;
  I: Integer;
begin
  Result := Work + Format('file_%d.wav', [Seconds]);
  Tone := DefaultToneOptions;
  Tone.SampleRate := 8000;
  Tone.NoiseAmplitude := 0;
  Timing := DefaultTiming;
  Timing.CharWpm := 20;
  Timing.TextWpm := 20;
  Tone.ToneHz := 700;
  Tone.Amplitude := 0.3;
  Near := TextToPCM('CQ CQ DE JA1ABC JA1ABC K', Timing, Tone);
  Timing.CharWpm := 24;
  Timing.TextWpm := 24;
  Tone.ToneHz := 1000;
  Tone.Amplitude := 0.6;
  Far := TextToPCM('TEST DE JH2XYZ JH2XYZ TEST', Timing, Tone);
  SetLength(Mixed, 8000 * Seconds);
  RandSeed := 1;
  for I := 0 to High(Mixed) do
    Mixed[I] := Near[I mod Length(Near)] + Far[I mod Length(Far)] +
      0.03 * (Random + Random + Random - 1.5);
  SaveWavMono(Result, Mixed, 8000);
end;

procedure MeasureFileStall(Seconds: Integer);
var
  Output, Title: string;
  Taken, Stall: Double;
begin
  Title := Format('NFR-4.2 ファイルを開いて画面が止まる時間（%d 分・8 kHz）',
    [Seconds div 60]);
  RunTool(Tool('app', 'deepcw_station'), [],
    ['DEEPCW_FILE_CHECK=' + MakeRecording(Seconds), 'DEEPCW_FILE_CHECK_TUNE=700',
     'DEEPCW_FILE_CHECK_LIMIT_MS=100000', 'DEEPCW_CONFIG_DIR=' + Work + 'file'],
    1800, Output, Taken);
  if NumberAfter(Output, 'longest UI stall:', Stall) and
     (Pos('JA1ABC', Output) > 0) then
    Add(Title, '100 ms', Format('%.0f ms（復号まで %.1f 秒）', [Stall, Taken]),
      Judge(Stall <= 100), '`DEEPCW_FILE_CHECK` 付きで `deepcw_station`')
  else
    Add(Title, '100 ms', '測れない: ' + LastLine(Output), '—',
      '`DEEPCW_FILE_CHECK` 付きで `deepcw_station`');
end;

procedure RemoveTree(const Dir: string);
var
  Found: TSearchRec;
begin
  if FindFirst(Dir + '*', faAnyFile, Found) = 0 then
  try
    repeat
      if (Found.Name = '.') or (Found.Name = '..') then
        Continue;
      if (Found.Attr and faDirectory) <> 0 then
        RemoveTree(Dir + Found.Name + PathDelim)
      else
        DeleteFile(Dir + Found.Name);
    until FindNext(Found) <> 0;
  finally
    FindClose(Found);
  end;
  RemoveDir(Dir);
end;

var
  I: Integer;
  Cpu: string;
begin
  for I := 1 to CommandLineArgCount do
    if CommandLineArg(I) = '--full' then
      Full := True
    else
    begin
      WriteLn(StdErr, 'Usage: perf_report [--full]');
      Halt(2);
    end;
  { 道具は、この道具の 1 つ上（`lazarus/`）の `cli/` と `app/` にあります。
    拡張子はこの道具と同じです（Windows なら `.exe`）。
    The tools live in `cli/` and `app/` one level above this one (`lazarus/`),
    with this tool's own extension (`.exe` on Windows). }
  Base := ExpandFileName(ExtractFilePath(ExecutablePath) + '..') + PathDelim;
  Ext := ExtractFileExt(ExecutablePath);
  Work := IncludeTrailingPathDelimiter(GetTempDir(False)) +
    Format('deepcw_perf_%d', [GetProcessID]) + PathDelim;
  ForceDirectories(Work);
  try
    MeasureStream('短い語の交信', SHORT_TEXT, 5.0, [], False);
    MeasureStream('符号の多い本文', CALLSIGN_TEXT, 7.0, [], True);
    MeasureStream('交信モード・同調・自動の幅・30 dB 強い隣が 250 Hz 横',
      CALLSIGN_TEXT, 7.0, ['--tune', '700', '--bandwidth', 'auto',
      '--neighbour', '950'], True);
    MeasureScale;
    MeasureRecheckPace;
    MeasurePaint;
    MeasureStartup;
    MeasureFileStall(300);
    if Full then
    begin
      MeasureFileStall(1800);
      MeasureSoak;
    end;
  finally
    RemoveTree(Work);
  end;

  Cpu := CpuDescription;
  if Cpu = '' then
    Cpu := '（名前を読めない）';
  WriteLn('# DeepCW 性能の報告');
  WriteLn;
  WriteLn('- 日時: ', FormatDateTime('yyyy"-"mm"-"dd hh":"nn', Now));
  WriteLn('- 機械: ', Cpu, ' / 論理コア ', LogicalProcessorCount, ' / ',
    {$I %FPCTARGETOS%}, '-', {$I %FPCTARGETCPU%});
  WriteLn('- ONNX Runtime: ', GetEnvironmentVariable('DEEPCW_ONNXRUNTIME'));
  if Full then
    WriteLn('- 範囲: すべて（--full）')
  else
    WriteLn('- 範囲: 既定（12 分の連続受信 NFR-1.8 と 30 分のファイルは `--full`）');
  WriteLn('- CPU の「コア相当」は、解析に掛かった壁時計 ÷ 音の時間（`cw_tune` と同じ定義）');
  WriteLn;
  WriteLn('| 要件 | 目標 | 測った値 | 判定 | 測り方 |');
  WriteLn('| --- | --- | --- | --- | --- |');
  for I := 0 to High(Rows) do
    WriteLn('| ', Rows[I].What, ' | ', Rows[I].Target, ' | ', Rows[I].Value,
      ' | ', Rows[I].Verdict, ' | ', Rows[I].How, ' |');
end.
