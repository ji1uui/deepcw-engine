unit DeepCW.RigKeyer;

{ 無線機の鍵を、fail-safe に操作します（要件 FR-T.2・FR-T.3・FR-T.6）。

  **Transmit は fail-safe**（`CLAUDE.md`）。ここがその約束の置き場所です。

  1. **送るのは `Send` を呼んだときだけ**です。無線機が応答していて（「待機」）、
     送っていないときだけ受け付けます。**受け付けなかった文は溜めません**——
     あとで繋がったときに、古い文が勝手に送られないためです。
  2. **無線機には語ずつ渡します**（`SplitForKeying`）。次の語は、前の語を
     送り終える見込みの少し前に渡します。**`Stop` は残りの語を錠の下で捨てる
     ので、`Stop` が戻ったあとは 1 語も渡しません。**`stop_morse` を持たない
     機種でも、止まるのは遅くとも「渡し済みの語」の終わりです。
  3. **送っている途中の誤りでは**: 残りを捨て、止めを試み、無線機の口を閉じ、
     「失敗」になります。**自動で送り直したり繋ぎ直したりしません**（同じ文が
     2 度出る）。
  4. **無線機の口は、このスレッドだけが触ります**（`DeepCW.Hamlib`）。画面は
     `Snapshot` で様子を読むだけです（画面をワーカーから触らない）。
  5. **無線機が応答しているかを確かめ続けます**（要件 FR-T.6）。繋いだ直後・
     待機中は 5 秒ごと・応答が無い間は 3 秒ごとに、**読むだけの命令**で訊きます。
     応答が無くなれば「応答なし」になり（口は開いたまま）、送りません。応答が
     戻れば「待機」に戻り、鍵の速度を合わせ直します。**戻っても、何も送りません。**
  6. **電源を入れるのは、利用者が頼んだときだけ**（`PowerOn`）。口が開いていれば
     電源を入れる命令を送り、起きるまで 1 秒ごとに 30 秒まで訊きます。開くときに
     応答が無かったのなら、開くときに入れさせて（Hamlib の `auto_power_on`）
     繋ぎ直します。**電源を切る命令は持ちません。**
  7. **口を開き直す再試行はしません。**口を開くと DTR・RTS の線が動く機器があり、
     その線で送信や鍵を操作する配線では、開き直すたびに電波が出うるためです。

  Operates the rig's key in a fail-safe way (requirements FR-T.2, FR-T.3,
  FR-T.6).

  **Transmit is fail-safe** (`CLAUDE.md`); this is where that promise lives.

  1. **Nothing is sent except on `Send`**, accepted only while the rig answers
     ("ready") and nothing is being sent. **A refused text is not kept**, so
     that no stale text goes out on its own after a later connection.
  2. **The rig is handed one word at a time** (`SplitForKeying`); the next
     word goes a little before the previous one is expected to finish. **`Stop`
     drops the remaining words under the lock, so after `Stop` returns not one
     more word is handed over.** Even on a model without `stop_morse`, sending
     ends at the latest with the words already handed over.
  3. **On an error while sending** the rest is dropped, a stop is attempted,
     the rig is closed, and the state becomes Failed. **Nothing is resent or
     reconnected automatically** (the same text would go out twice).
  4. **Only this thread touches the rig handle** (`DeepCW.Hamlib`). The screen
     only reads `Snapshot`; no worker touches the screen.
  5. **Whether the rig answers is checked continually** (FR-T.6): right after
     connecting, every 5 s while ready and every 3 s while silent, with **a
     read-only command**. When it stops answering the state becomes "no answer"
     (the port stays open) and nothing is sent; when it answers again the state
     returns to ready and the keyer speed is set again. **Coming back sends
     nothing.**
  6. **The rig is powered on only at the operator's request** (`PowerOn`). With
     the port open the power-on command is sent and the rig is asked once a
     second, for up to 30 s, until it wakes; if it did not answer at open, the
     port is reopened with Hamlib's `auto_power_on`. **There is no power-off
     command.**
  7. **Opening the port is never retried on its own.** Opening moves the DTR and
     RTS lines on some interfaces, and where those lines key the transmitter
     every reopening could put out a signal. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs, DeepCW.Hamlib;

const
  { 次の語を渡すのは、渡し済みの語が送り終わる見込みのこれだけ前（ミリ秒）。
    **短いほど止めてから止まるまでが短く、長いほど語の間が空きにくい。**
    The next word is handed over this long before the words already handed
    over are expected to finish (ms). **Shorter makes a stop take effect
    sooner; longer keeps gaps from opening between words.** }
  KEYER_LEAD_MS = 600;
  { 送っている間に、次の語を渡すかを見る間隔（ミリ秒）。
    How often, while sending, the next hand-over is considered (ms). }
  KEYER_TICK_MS = 50;
  { 応答を確かめる間隔（ミリ秒）: 待機中・応答なしの間・電源を入れたあと。
    How often the rig is asked (ms): while ready, while silent, after power-on. }
  PROBE_READY_MS = 5000;
  PROBE_SILENT_MS = 3000;
  PROBE_WAKING_MS = 1000;
  { 電源を入れてから起きるのを待つ上限（ミリ秒）。/ How long to wait for the
    rig to wake after power-on (ms). }
  POWER_WAKE_LIMIT_MS = 30000;
  { 渡し済みの語を送り終える見込みのあと、なお「鍵を操作しているかもしれない」
    とみなす余白（ミリ秒）。無線機が見込みより遅いときのためです。
    The margin after the expected end of the handed-over words during which
    the rig is still taken to be possibly keying (ms), for a rig slower than
    expected. }
  STOP_MARGIN_MS = 2000;

type
  TKeyerState = (ksOff, ksConnecting, ksReady, ksSending, ksNoAnswer,
    ksPoweringOn, ksFailed);
  { 失敗の種類。**言葉にするのは画面の側です。**
    The kind of failure; **the screen puts it into words.** }
  TKeyerFault = (kfNone, kfNoLibrary, kfModel, kfConfig, kfPort, kfNoAnswer,
    kfLink, kfSend, kfStop);
  { 止められる機種か。繋いだだけでは分かりません（止めて初めて分かる）。
    Whether the model can stop; unknown until a stop is tried. }
  TStopSupport = (ssUnknown, ssYes, ssNo);
  { 電源を入れる頼みの結果。/ The outcome of a power-on request. }
  TPowerResult = (prNone, prAsked, prNotSupported, prFailed, prNoWake, prAwake);

  TKeyerStatus = record
    State: TKeyerState;
    Fault: TKeyerFault;
    { 技術的な原文（英語）。診断に残し、画面には種類から作った言葉を出します。
      The technical original (English): kept for diagnostics; the screen shows
      words made from the kind. }
    Detail: string;
    { 断られた設定の名前（`kfConfig` のとき）。/ The refused setting. }
    Setting: string;
    Text: string;
    { 渡し済みの文字数。/ Characters handed over so far. }
    Handed: Integer;
    Stop: TStopSupport;
    { キーヤーの速度を無線機に合わせられたか。/ Whether the rig took the speed. }
    SpeedSet: Boolean;
    Wpm: Integer;
    { 無線機が答えた、いまの鍵の速度。読めなければ 0。**語を渡す間合いは
      これで計ります**（機種が範囲に丸めることがあるため。付録 BS.2）。
      The keyer speed the rig reports; 0 if it cannot be read. **Words are
      paced by this** (a model may clamp to its range; appendix BS.2). }
    RigWpm: Integer;
    { 渡し済みの語を無線機が送り終える見込みの時刻（`GetTickCount64`）。
      無ければ 0。**「失敗」のあとも残します**——無線機は渡された語を送り
      続けうるためです（受信の抑制が使う。要件 FR-T.4）。
      When the rig is expected to finish the words handed over
      (`GetTickCount64`), 0 for none. **Kept after a failure too**: the rig may
      go on sending what it was given (used by receive suppression, FR-T.4). }
    KeyedUntil: QWord;
    Power: TPowerResult;
    { 応答を確かめられる機種か（読む命令を持たない機種では確かめない）。
      Whether the answer can be checked (not on a model without the read). }
    CanProbe: Boolean;
    { 応答の確かめで読んだ周波数（Hz）とモード、読んだ時刻
      （`GetTickCount64`）。読めていなければ 0 と空（要件 FR-T.7）。**古い値を
      使わないため、使う側は時刻で新しさを確かめます。**
      The frequency (Hz) and mode read by the answer check, and when
      (`GetTickCount64`); 0 and empty if unread (FR-T.7). **Users check the
      time for freshness, so that a stale value is not used.** }
    RigFreqHz: Double;
    RigMode: string;
    RigReadAt: QWord;
  end;

  TRigKeyer = class
  private
    FLock: TCriticalSection;
    FWake: TEvent;
    FThread: TThread;
    { 以下は錠の下でだけ触ります。/ Only touched under the lock. }
    FStatus: TKeyerStatus;
    FWords: TStringArray;
    FNextWord: Integer;
    FConnectWanted: Boolean;
    FDisconnectWanted: Boolean;
    FStopWanted: Boolean;
    FPowerWanted: Boolean;
    FWpmWanted: Integer;
    FSettings: TRigSettings;
    FLibraryPath: string;
    { 終わりの合図。/ The signal to finish. }
    FQuit: Boolean;
    procedure Run;
  public
    constructor Create;
    { 送りかけていれば止め、無線機の口を閉じてから終わります。
      Stops anything in progress and closes the rig before finishing. }
    destructor Destroy; override;
    { 繋ぎます。**電源は入れません**（`Settings.PowerOnAtOpen` は無視して偽）。
      Connects. **Never powers on** (`Settings.PowerOnAtOpen` is forced off). }
    procedure Connect(const Settings: TRigSettings; Wpm: Integer;
      const LibraryPath: string = '');
    procedure Disconnect;
    { 送ります。**待機（応答あり）で、送っていないときだけ True。**`Clean` は
      `CheckTransmitText` を通した文です。
      Sends. **True only while ready (answering) and idle.** `Clean` is text
      that has passed `CheckTransmitText`. }
    function Send(const Clean: string): Boolean;
    { 止めます。**いつでも呼べ、戻ったあとは 1 語も渡しません。**
      Stops. **Always callable; after it returns no further word is handed
      over.** }
    procedure Stop;
    procedure SetWpm(Wpm: Integer);
    { 電源を入れます。**利用者が押したときだけ呼びます。**頼めるのは「応答なし」
      か、開くときに応答が無かった「失敗」のときだけで、それ以外は False。
      Powers the rig on. **Call only when the operator pressed for it.** It can
      be asked only in "no answer", or in "failed" because the rig did not
      answer at open; otherwise False. }
    function PowerOn: Boolean;
    function Snapshot: TKeyerStatus;
  end;

{ Hamlib の番号が「応答が無い」類か（口は開けた・開いているが、無線機が
  答えない）。/ Whether a Hamlib code means "no answer" (the port opened or is
  open, but the rig does not reply). }
function IsNoAnswerCode(Code: Integer): Boolean;

implementation

uses
  Math, DeepCW.TxMessage;

type
  TKeyerThread = class(TThread)
  private
    FOwner: TRigKeyer;
  protected
    procedure Execute; override;
  public
    constructor Create(AOwner: TRigKeyer);
  end;

function IsNoAnswerCode(Code: Integer): Boolean;
begin
  Result := (Code = -RIG_ETIMEOUT) or (Code = -RIG_EPOWER) or (Code = -RIG_EPROTO);
end;

constructor TKeyerThread.Create(AOwner: TRigKeyer);
begin
  FOwner := AOwner;
  inherited Create(False);
end;

procedure TKeyerThread.Execute;
begin
  FOwner.Run;
end;

{ TRigKeyer }

constructor TRigKeyer.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FWake := TEvent.Create(nil, False, False, '');
  FStatus.State := ksOff;
  FStatus.Stop := ssUnknown;
  FThread := TKeyerThread.Create(Self);
end;

destructor TRigKeyer.Destroy;
begin
  Stop;
  Disconnect;
  FLock.Enter;
  FQuit := True;
  FLock.Leave;
  FThread.Terminate;
  FWake.SetEvent;
  FThread.WaitFor;
  FThread.Free;
  FWake.Free;
  FLock.Free;
  inherited Destroy;
end;

procedure TRigKeyer.Connect(const Settings: TRigSettings; Wpm: Integer;
  const LibraryPath: string);
begin
  FLock.Enter;
  try
    { **繋ぎ直しは、送りかけの文を捨ててから**です。
      **Reconnecting first drops whatever was being sent.** }
    FWords := nil;
    FNextWord := 0;
    FSettings := Settings;
    FSettings.PowerOnAtOpen := False;
    FLibraryPath := LibraryPath;
    FWpmWanted := Wpm;
    FConnectWanted := True;
    FDisconnectWanted := False;
    FPowerWanted := False;
    FStatus.State := ksConnecting;
    FStatus.Fault := kfNone;
    FStatus.Detail := '';
    FStatus.Setting := '';
    FStatus.Power := prNone;
    FStatus.Wpm := Wpm;
  finally
    FLock.Leave;
  end;
  FWake.SetEvent;
end;

procedure TRigKeyer.Disconnect;
begin
  FLock.Enter;
  try
    FWords := nil;
    FNextWord := 0;
    FConnectWanted := False;
    FPowerWanted := False;
    FDisconnectWanted := True;
  finally
    FLock.Leave;
  end;
  FWake.SetEvent;
end;

function TRigKeyer.Send(const Clean: string): Boolean;
begin
  FLock.Enter;
  try
    Result := (FStatus.State = ksReady) and not FConnectWanted and
      not FDisconnectWanted and (Clean <> '');
    if not Result then
      Exit;
    FWords := SplitForKeying(Clean);
    FNextWord := 0;
    FStatus.State := ksSending;
    FStatus.Text := Clean;
    FStatus.Handed := 0;
  finally
    FLock.Leave;
  end;
  FWake.SetEvent;
end;

procedure TRigKeyer.Stop;
begin
  FLock.Enter;
  try
    { **ここで捨てます。**ワーカーが次の語を取るのも錠の下なので、この錠を
      抜けたあとは 1 語も渡りません。
      **Dropped here.** The worker takes the next word under this same lock, so
      once it is released no further word gets through. }
    FWords := nil;
    FNextWord := 0;
    FStopWanted := True;
  finally
    FLock.Leave;
  end;
  FWake.SetEvent;
end;

procedure TRigKeyer.SetWpm(Wpm: Integer);
begin
  FLock.Enter;
  try
    FWpmWanted := Wpm;
    FStatus.Wpm := Wpm;
  finally
    FLock.Leave;
  end;
  FWake.SetEvent;
end;

function TRigKeyer.PowerOn: Boolean;
begin
  FLock.Enter;
  try
    Result := False;
    if (FStatus.State = ksNoAnswer) and not FConnectWanted and
       not FDisconnectWanted then
    begin
      FPowerWanted := True;
      FStatus.Power := prAsked;
      Result := True;
    end
    else if (FStatus.State = ksFailed) and (FStatus.Fault = kfNoAnswer) and
            not FDisconnectWanted then
    begin
      { 開くときに応答が無かった。**開くときに電源を入れさせて**繋ぎ直します。
        It did not answer at open: reconnect **letting the opening power it on**. }
      FSettings.PowerOnAtOpen := True;
      FConnectWanted := True;
      FStatus.State := ksConnecting;
      FStatus.Fault := kfNone;
      FStatus.Detail := '';
      FStatus.Power := prAsked;
      Result := True;
    end;
  finally
    FLock.Leave;
  end;
  if Result then
    FWake.SetEvent;
end;

function TRigKeyer.Snapshot: TKeyerStatus;
begin
  FLock.Enter;
  try
    Result := FStatus;
  finally
    FLock.Leave;
  end;
end;

procedure TRigKeyer.Run;
var
  Rig: THamlibRig;
  QueuedUntil, NextProbe, WakeDeadline, NowMs: QWord;
  ConnectNow, DisconnectNow, StopNow, PowerNow: Boolean;
  Settings: TRigSettings;
  LibraryPath, Word_: string;
  Wpm, WantedWpm, PaceWpm, Code: Integer;
  FreqHz: Double;
  ModeName: string;
  Stopped, SpeedTaken, CanProbe: Boolean;
  State: TKeyerState;
  Wait: Cardinal;

  function CurrentState: TKeyerState;
  begin
    FLock.Enter;
    try
      Result := FStatus.State;
    finally
      FLock.Leave;
    end;
  end;

  procedure SetState(AState: TKeyerState);
  begin
    FLock.Enter;
    try
      FStatus.State := AState;
    finally
      FLock.Leave;
    end;
  end;

  procedure SetPower(Result_: TPowerResult);
  begin
    FLock.Enter;
    try
      FStatus.Power := Result_;
    finally
      FLock.Leave;
    end;
  end;

  { 無線機が鍵を操作しているかもしれないか。送っている最中か、渡し済みの語を
    送り終える見込み（と余白）より前なら真。**そうでなければ止める命令は
    要りません**——止めるものが無いうえ、応答しない無線機へ送れば待たされて
    「失敗」になります（付録 BU.1）。
    Whether the rig may be keying: while sending, or before the handed-over
    words are expected to finish (plus a margin). **Otherwise no stop command is
    needed**: there is nothing to stop, and sent to a silent rig it would wait
    out the timeout and fail (appendix BU.1). }
  function MayBeKeying: Boolean;
  begin
    Result := (CurrentState = ksSending) or
      ((QueuedUntil > 0) and (QueuedUntil + STOP_MARGIN_MS > GetTickCount64));
  end;

  procedure CloseRig;
  begin
    if Rig = nil then
      Exit;
    if MayBeKeying then
    try
      Rig.StopMorse;
    except
      { 止めの失敗は、閉じるのを妨げません。/ A failed stop does not block closing. }
    end;
    try
      Rig.Free;
    except
    end;
    Rig := nil;
  end;

  { 誤りのあとの後始末。**送り直さず、繋ぎ直さず、止めを試みて閉じる。**
    After an error: **no resending, no reconnecting; try to stop, then close.** }
  procedure Fail(Fault: TKeyerFault; const Detail: string; const Setting: string = '');
  begin
    FLock.Enter;
    try
      FWords := nil;
      FNextWord := 0;
      FStatus.State := ksFailed;
      FStatus.Fault := Fault;
      FStatus.Detail := Detail;
      FStatus.Setting := Setting;
    finally
      FLock.Leave;
    end;
    CloseRig;
  end;

  { 開くまでの誤りを種類に分けます。/ Sorts an error before opening. }
  procedure FailOpening(E: Exception);
  var
    H: EHamlib;
  begin
    if not (E is EHamlib) then
    begin
      Fail(kfPort, E.Message);
      Exit;
    end;
    H := EHamlib(E);
    case H.Stage of
      hsModel: Fail(kfModel, H.Message);
      hsConfig: Fail(kfConfig, H.Message, H.Setting);
      hsOpen:
        if IsNoAnswerCode(H.Code) then
          Fail(kfNoAnswer, H.Message)
        else
          Fail(kfPort, H.Message);
    else
      Fail(kfPort, H.Message);
    end;
  end;

begin
  Rig := nil;
  QueuedUntil := 0;
  NextProbe := 0;
  WakeDeadline := 0;
  Wpm := 0;
  PaceWpm := 0;
  CanProbe := True;
  while True do
  begin
    FLock.Enter;
    try
      if FQuit then
        Break;
      State := FStatus.State;
    finally
      FLock.Leave;
    end;
    { 間合いを計るのは送っている間だけ、応答を確かめるのは繋がっている間だけ
      です。**それ以外は起こされるまで眠ります**（呼ぶ側はどれも `FWake` を
      鳴らす）。版 2.70 は使わなくても毎秒 20 回起きていた（付録 BS.3）。
      Pacing is only needed while sending and probing only while connected;
      **otherwise the thread sleeps until woken** (every caller signals
      `FWake`). Version 2.70 woke 20 times a second even when unused
      (appendix BS.3). }
    if State = ksSending then
      Wait := KEYER_TICK_MS
    else if (Rig <> nil) and CanProbe and
            (State in [ksReady, ksNoAnswer, ksPoweringOn]) then
    begin
      NowMs := GetTickCount64;
      if NextProbe <= NowMs then
        Wait := 0
      else
        Wait := Cardinal(Min(NextProbe - NowMs, PROBE_READY_MS));
    end
    else
      Wait := INFINITE;
    if Wait > 0 then
      FWake.WaitFor(Wait);

    FLock.Enter;
    try
      ConnectNow := FConnectWanted;
      FConnectWanted := False;
      DisconnectNow := FDisconnectWanted;
      FDisconnectWanted := False;
      StopNow := FStopWanted;
      FStopWanted := False;
      PowerNow := FPowerWanted;
      FPowerWanted := False;
      Settings := FSettings;
      LibraryPath := FLibraryPath;
      WantedWpm := FWpmWanted;
    finally
      FLock.Leave;
    end;

    { 1. 止める。**何より先に。**送っていない・渡した語も送り終えたのなら、
       待ちの語は `Stop` が既に捨てたので、無線機へは何も送りません。
       1. Stop, **before anything else.** If nothing is being sent and the
       handed-over words are done, `Stop` has already dropped the pending ones
       and nothing is sent to the rig. }
    if StopNow and (Rig <> nil) and MayBeKeying then
    begin
      try
        Stopped := Rig.StopMorse;
        FLock.Enter;
        try
          if Stopped then
            FStatus.Stop := ssYes
          else
            FStatus.Stop := ssNo;
          { **止まったと言えるのは、無線機が止めを受けたときだけ**です。
            受けられない機種では、渡し済みの語が送り終わる見込みまで「送信中」
            のままにします（続けて送ると、その後ろに並んでしまうため）。
            **Only a rig that took the stop is called stopped.** On one that
            cannot, the state stays Sending until the words already handed over
            are expected to finish, so that a new text cannot queue behind
            them. }
          if Stopped then
          begin
            QueuedUntil := 0;
            FStatus.KeyedUntil := 0;
            if FStatus.State = ksSending then
              FStatus.State := ksReady;
          end;
        finally
          FLock.Leave;
        end;
      except
        on E: Exception do
          Fail(kfStop, E.Message);
      end;
    end;

    { 2. 切る。/ 2. Disconnect. }
    if DisconnectNow or ConnectNow then
    begin
      CloseRig;
      if DisconnectNow then
        SetState(ksOff);
    end;

    { 3. 繋ぐ。**開く試みは 1 度だけ**（口の開き直しで線が動くため）。
       3. Connect. **One attempt to open** (reopening moves the lines). }
    if ConnectNow then
    begin
      if not LoadHamlib(LibraryPath) then
      begin
        Fail(kfNoLibrary, HamlibLoadError);
        Continue;
      end;
      try
        Rig := THamlibRig.Create(Settings);
        Rig.Open;
      except
        on E: Exception do
        begin
          FailOpening(E);
          if Settings.PowerOnAtOpen then
            SetPower(prFailed);
          Continue;
        end;
      end;
      Wpm := 0;
      PaceWpm := 0;
      CanProbe := True;
      FLock.Enter;
      try
        FStatus.Stop := ssUnknown;
        FStatus.SpeedSet := False;
        FStatus.RigWpm := 0;
        FStatus.CanProbe := True;
        { 開けただけでは「待機」にしません。**応答を確かめてから**です。
          電源を入れさせて開いたのなら、起きるのを待ちます。
          Opening alone is not "ready": **the rig must answer first**. If the
          opening was to power it on, it is given time to wake. }
        if Settings.PowerOnAtOpen then
          FStatus.State := ksPoweringOn
        else
          FStatus.State := ksConnecting;
      finally
        FLock.Leave;
      end;
      NowMs := GetTickCount64;
      NextProbe := NowMs;
      WakeDeadline := NowMs + POWER_WAKE_LIMIT_MS;
    end;

    if Rig = nil then
      Continue;

    { 4. 電源を入れる（利用者が頼んだときだけ）。
       4. Power on (only when the operator asked). }
    if PowerNow and (CurrentState = ksNoAnswer) then
    begin
      Code := Rig.PowerOn;
      if Code = RIG_OK then
      begin
        SetState(ksPoweringOn);
        NowMs := GetTickCount64;
        WakeDeadline := NowMs + POWER_WAKE_LIMIT_MS;
        NextProbe := NowMs + PROBE_WAKING_MS;
      end
      else if (Code = -RIG_ENIMPL) or (Code = -RIG_ENAVAIL) then
        SetPower(prNotSupported)
      else if Code = -RIG_EIO then
      begin
        Fail(kfLink, Format('power on: %d', [Code]));
        Continue;
      end
      else
        SetPower(prFailed);
    end
    else if PowerNow then
      { 頼んだあいだに応答が戻った（など）。頼みは要らなくなりました。
        The rig answered again meanwhile (or similar): the request is moot. }
      SetPower(prNone);

    { 5. 応答を確かめる。**読むだけの命令です。**送っている間はしません。
       5. Check the rig answers, **with a read-only command**; never while
       sending. }
    State := CurrentState;
    if CanProbe and (State in [ksConnecting, ksReady, ksNoAnswer, ksPoweringOn]) and
       (GetTickCount64 >= NextProbe) then
    begin
      Code := Rig.Probe(FreqHz);
      NowMs := GetTickCount64;
      if Code = RIG_OK then
      begin
        { 答えた。周波数とモードを控えます（モードは読めなくても構わない）。
          It answered: note the frequency and mode (the mode may be unreadable). }
        ModeName := Rig.ReadMode;
        FLock.Enter;
        try
          FStatus.RigFreqHz := FreqHz;
          FStatus.RigMode := ModeName;
          FStatus.RigReadAt := GetTickCount64;
        finally
          FLock.Leave;
        end;
        if State <> ksReady then
        begin
          { 戻ってきた。**速度を合わせ直し、何も送らない。**
            It is back: **set the speed again, send nothing.** }
          Wpm := 0;
          FLock.Enter;
          try
            FStatus.State := ksReady;
            if State = ksPoweringOn then
              FStatus.Power := prAwake;
          finally
            FLock.Leave;
          end;
        end;
        NextProbe := NowMs + PROBE_READY_MS;
      end
      else if (Code = -RIG_ENIMPL) or (Code = -RIG_ENAVAIL) then
      begin
        { 確かめる手段が無い機種。確かめずに「待機」とし、その旨を見せます。
          The model has no way to check; ready without checking, and it says so. }
        CanProbe := False;
        FLock.Enter;
        try
          FStatus.CanProbe := False;
          FStatus.State := ksReady;
        finally
          FLock.Leave;
        end;
      end
      else if Code = -RIG_EIO then
      begin
        Fail(kfLink, Format('probe: %d', [Code]));
        Continue;
      end
      else
      begin
        { 応答が無い。口は開いたまま、訊き続けます。
          No answer: the port stays open and the rig keeps being asked. }
        if State = ksPoweringOn then
        begin
          if NowMs >= WakeDeadline then
          begin
            FLock.Enter;
            try
              FStatus.State := ksNoAnswer;
              FStatus.Power := prNoWake;
            finally
              FLock.Leave;
            end;
            NextProbe := NowMs + PROBE_SILENT_MS;
          end
          else
            NextProbe := NowMs + PROBE_WAKING_MS;
        end
        else
        begin
          SetState(ksNoAnswer);
          NextProbe := NowMs + PROBE_SILENT_MS;
        end;
      end;
    end;

    State := CurrentState;
    if not (State in [ksReady, ksSending]) then
      Continue;

    { 6. 速度を合わせる。**合わせられない機種もあります**（そのときは無線機の
       設定の速さで送られます）。
       6. Match the keyer speed. **Some models cannot** (the rig then sends at
       its own setting). }
    if (WantedWpm > 0) and (WantedWpm <> Wpm) then
    begin
      Wpm := WantedWpm;
      SpeedTaken := True;
      try
        Rig.SetKeyerWpm(Wpm);
      except
        SpeedTaken := False;
      end;
      { 合わせたあと、**無線機に訊き直します。**合わせられても範囲に丸める
        機種があり、合わせられなくても読める機種があります。読めなければ、
        合わせた速度（合わせられなければ望んだ速度）で計ります。
        After setting, **the rig is asked back**: some models clamp what they
        accept, some cannot be set but can be read. If it cannot be read, pacing
        uses the speed set (or wanted). }
      try
        PaceWpm := Rig.KeyerWpm;
        if (PaceWpm < HAMLIB_MIN_WPM) or (PaceWpm > HAMLIB_MAX_WPM) then
          PaceWpm := 0;
      except
        PaceWpm := 0;
      end;
      FLock.Enter;
      try
        FStatus.SpeedSet := SpeedTaken;
        FStatus.RigWpm := PaceWpm;
      finally
        FLock.Leave;
      end;
    end;

    { 7. 次の語を渡す。**取るのは錠の下**、渡すのは錠の外。
       7. Hand over the next word: **taken under the lock**, handed outside it. }
    Word_ := '';
    FLock.Enter;
    try
      if (FStatus.State = ksSending) and (FNextWord <= High(FWords)) and
         (Int64(QueuedUntil) - Int64(GetTickCount64) < KEYER_LEAD_MS) then
      begin
        Word_ := FWords[FNextWord];
        Inc(FNextWord);
      end
      else if (FStatus.State = ksSending) and (FNextWord > High(FWords)) and
              (GetTickCount64 >= QueuedUntil) then
      begin
        FStatus.State := ksReady;
        { 送り終えたらすぐ確かめます。送っている間は確かめないので、周波数が
          古いままにならないように（要件 FR-T.7）。
          Checked right after sending: no check runs while sending, so the
          frequency must not be left stale (FR-T.7). }
        NextProbe := GetTickCount64;
      end;
    finally
      FLock.Leave;
    end;
    if Word_ <> '' then
    begin
      try
        Rig.SendMorse(Word_);
      except
        on E: Exception do
        begin
          Fail(kfSend, E.Message);
          Continue;
        end;
      end;
      QueuedUntil := Max(QueuedUntil, GetTickCount64) +
        QWord(Round(1000 * KeyingSeconds(Word_,
          Max(IfThen(PaceWpm > 0, PaceWpm, Wpm), HAMLIB_MIN_WPM))));
      FLock.Enter;
      try
        Inc(FStatus.Handed, Length(Word_));
        FStatus.KeyedUntil := QueuedUntil;
      finally
        FLock.Leave;
      end;
      FWake.SetEvent;
    end;
  end;

  { 終わるときは、送りかけを止めて閉じます。/ On the way out: stop and close. }
  CloseRig;
end;

end.
