program cw_devices;

{ 録音に使える装置を一覧します。

  PortAudio の構造体は C の並びをそのまま読むため、詰め物の入り方が処理系で
  異なります。値が壊れていれば、標本化周波数や名前がすぐに嘘になります。
  この道具は、その並びが正しいことを移植先で確かめるためのものです
  （要件 FR-A.3、NFR-3、NFR-7.4）。

  Lists the devices that can record.

  The PortAudio structures are read as the C layout they are, and the padding
  differs between platforms; if the layout is wrong the sample rates and names
  go visibly wrong at once. This tool is how that layout gets checked on a
  platform it has been ported to (requirements FR-A.3, NFR-3, NFR-7.4). }

{$mode objfpc}{$H+}

uses
  { 録音は別スレッドで行うため、スレッド支援を最初に取り込みます。
    Capture runs on its own thread, so thread support comes first. }
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Math, DeepCW.Types, DeepCW.Audio;

{ 指定した装置から少しのあいだ録音し、届いた音の大きさを報告します。
  「音が届いているか」の表示（要件 FR-A.3）のしきい値を、思い込みではなく
  実際の値から決めるためのものです。

  Records briefly from a device and reports how loud what arrived was. It is
  how the threshold behind the "audio is arriving" display (requirement
  FR-A.3) gets chosen from real values rather than from a guess. }
procedure Listen(DeviceIndex, SampleRate: Integer; Seconds: Double);
var
  Ring: TAudioRing;
  Capture: TAudioCapture;
  Samples: TSingleArray;
  I, Waited: Integer;
  Peak, Total: Double;
begin
  Ring := TAudioRing.Create(Round(SampleRate * (Seconds + 2)));
  Capture := TAudioCapture.Create(Ring, SampleRate, DeviceIndex);
  try
    Capture.Start;
    Waited := 0;
    while (Waited < Round(Seconds * 1000)) and (Capture.LastError = '') do
    begin
      Sleep(100);
      Inc(Waited, 100);
    end;
    Capture.Stop;
    if Capture.LastError <> '' then
    begin
      WriteLn(StdErr, '録音できませんでした: ', Capture.LastError);
      Halt(1);
    end;
    Samples := Ring.Snapshot;
    if Length(Samples) = 0 then
    begin
      WriteLn('サンプルが 1 つも届きませんでした。');
      Halt(1);
    end;
    Peak := 0;
    Total := 0;
    for I := 0 to High(Samples) do
    begin
      Peak := Max(Peak, Abs(Samples[I]));
      Total := Total + Sqr(Samples[I]);
    end;
    WriteLn(Format('%d サンプル（%.1f 秒）: 最大 %.6f / 実効値 %.6f',
      [Length(Samples), Length(Samples) / SampleRate, Peak,
       Sqrt(Total / Length(Samples))]));
  finally
    Capture.Free;
    Ring.Free;
  end;
end;

var
  Devices: TAudioDevices;
  I, Index: Integer;
  Key, Value, LibraryPath, Report: string;
  Marker: string;
  Verbose: Boolean;
  ListenSeconds: Double;
  ListenDevice, ListenRate: Integer;
begin
  LibraryPath := '';
  Verbose := False;
  ListenSeconds := 0;
  ListenDevice := AUDIO_DEFAULT_DEVICE;
  ListenRate := 8000;
  Index := 1;
  while Index <= ParamCount do
  begin
    Key := ParamStr(Index);
    Value := '';
    if Index < ParamCount then
      Value := ParamStr(Index + 1);
    if Key = '--abi' then
    begin
      Verbose := True;
      Inc(Index);
      Continue;
    end;
    if Key = '--portaudio' then
      LibraryPath := Value
    else if Key = '--listen' then
      ListenSeconds := StrToFloatDef(Value, 2)
    else if Key = '--device' then
      ListenDevice := StrToIntDef(Value, AUDIO_DEFAULT_DEVICE)
    else if Key = '--rate' then
      ListenRate := StrToIntDef(Value, 8000)
    else
    begin
      WriteLn(StdErr, 'Unknown option: ', Key);
      Halt(2);
    end;
    Inc(Index, 2);
  end;

  { 構造体の並びは装置が 1 台も無くても確かめられます。ここが崩れていれば
    一覧の中身はすべて信用できないため、先に出します。

    The layout can be checked with no devices present at all, and if it is
    wrong nothing in the list can be trusted, so it comes first. }
  if not CheckStructureLayout(Report) then
  begin
    WriteLn(StdErr, '構造体の並びが C と一致していません。');
    WriteLn(StdErr, Report);
    Halt(1);
  end;
  WriteLn('構造体の並び: C と一致');
  if Verbose then
    Write(Report);
  WriteLn;

  if not LoadPortAudio(LibraryPath) then
  begin
    WriteLn(StdErr, PortAudioLoadError);
    Halt(1);
  end;
  WriteLn('PortAudio: ', PortAudioVersion);
  WriteLn('ライブラリ: ', PortAudioLibraryPath);
  WriteLn;

  Devices := InputDevices;
  if Length(Devices) = 0 then
  begin
    WriteLn('録音に使える装置が見つかりませんでした。');
    WriteLn('（装置が無い環境では正常です。既定の装置での受信は別途試してください。）');
    Halt(0);
  end;

  WriteLn(Format('%-4s %-9s %-34s %-16s %s',
    ['番号', '既定', '装置名', '音声方式', '入力ch / 既定の周波数']));
  for I := 0 to High(Devices) do
  begin
    if Devices[I].IsDefault then
      Marker := '既定'
    else
      Marker := '';
    WriteLn(Format('%-4d %-9s %-34s %-16s %d ch / %.0f Hz',
      [Devices[I].Index, Marker, Devices[I].Name, Devices[I].HostApi,
       Devices[I].MaxInputChannels, Devices[I].DefaultSampleRate]));
  end;
  WriteLn;
  WriteLn(Format('%d 台。既定の入力装置は %d 番です。',
    [Length(Devices), DefaultInputDeviceIndex]));

  if ListenSeconds > 0 then
  begin
    WriteLn;
    WriteLn(Format('装置 %d から %.1f 秒 %d Hz で録音します。',
      [ListenDevice, ListenSeconds, ListenRate]));
    Listen(ListenDevice, ListenRate, ListenSeconds);
  end;
end.
