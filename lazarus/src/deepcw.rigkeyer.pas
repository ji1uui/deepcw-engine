unit DeepCW.RigKeyer;

{ 無線機の鍵を、fail-safe に操作します（要件 FR-T.2・FR-T.3）。

  **Transmit は fail-safe**（`CLAUDE.md`）。ここがその約束の置き場所です。

  1. **送るのは `Send` を呼んだときだけ**です。繋がっていて、送っていない
     ときだけ受け付けます。**受け付けなかった文は溜めません**——あとで繋がった
     ときに、古い文が勝手に送られないためです。
  2. **無線機には語ずつ渡します**（`SplitForKeying`）。次の語は、前の語を
     送り終える見込みの少し前に渡します。**`Stop` は残りの語を錠の下で捨てる
     ので、`Stop` が戻ったあとは 1 語も渡しません。**`stop_morse` を持たない
     機種でも、止まるのは遅くとも「渡し済みの語」の終わりです。
  3. **誤りが起きたら**: 残りを捨て、止めを試み、無線機の口を閉じ、「失敗」に
     なります。**自動で送り直したり繋ぎ直したりしません**（同じ文が 2 度出る）。
     `Connect` をもう一度押すまで、何も送りません。
  4. **無線機の口は、このスレッドだけが触ります**（`DeepCW.Hamlib`）。画面は
     `Snapshot` で様子を読むだけです（録音と同じ形。画面をワーカーから触らない）。

  Operates the rig's key in a fail-safe way (requirements FR-T.2, FR-T.3).

  **Transmit is fail-safe** (`CLAUDE.md`); this is where that promise lives.

  1. **Nothing is sent except on `Send`**, accepted only while connected and
     idle. **A refused text is not kept**, so that no stale text goes out on
     its own after a later connection.
  2. **The rig is handed one word at a time** (`SplitForKeying`); the next
     word goes a little before the previous one is expected to finish. **`Stop`
     drops the remaining words under the lock, so after `Stop` returns not one
     more word is handed over.** Even on a model without `stop_morse`, sending
     ends at the latest with the words already handed over.
  3. **On any error** the rest is dropped, a stop is attempted, the rig is
     closed, and the state becomes Failed. **Nothing is resent or reconnected
     automatically** (the same text would go out twice); nothing is sent until
     `Connect` is pressed again.
  4. **Only this thread touches the rig handle** (`DeepCW.Hamlib`). The screen
     only reads `Snapshot` -- the recorder's pattern; no worker touches the
     screen. }

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

type
  TKeyerState = (ksOff, ksConnecting, ksReady, ksSending, ksFailed);
  { 失敗の種類。**言葉にするのは画面の側です。**
    The kind of failure; **the screen puts it into words.** }
  TKeyerFault = (kfNone, kfNoLibrary, kfConnect, kfSend, kfStop);
  { 止められる機種か。繋いだだけでは分かりません（止めて初めて分かる）。
    Whether the model can stop; unknown until a stop is tried. }
  TStopSupport = (ssUnknown, ssYes, ssNo);

  TKeyerStatus = record
    State: TKeyerState;
    Fault: TKeyerFault;
    { 技術的な原文（英語）。診断に残し、画面には種類から作った言葉を出します。
      The technical original (English): kept for diagnostics; the screen shows
      words made from the kind. }
    Detail: string;
    Text: string;
    { 渡し済みの文字数。/ Characters handed over so far. }
    Handed: Integer;
    Stop: TStopSupport;
    { キーヤーの速度を無線機に合わせられたか。/ Whether the rig took the speed. }
    SpeedSet: Boolean;
    Wpm: Integer;
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
    procedure Connect(const Settings: TRigSettings; Wpm: Integer;
      const LibraryPath: string = '');
    procedure Disconnect;
    { 送ります。**繋がっていて、送っていないときだけ True。**`Clean` は
      `CheckTransmitText` を通した文です。
      Sends. **True only while connected and idle.** `Clean` is text that has
      passed `CheckTransmitText`. }
    function Send(const Clean: string): Boolean;
    { 止めます。**いつでも呼べ、戻ったあとは 1 語も渡しません。**
      Stops. **Always callable; after it returns no further word is handed
      over.** }
    procedure Stop;
    procedure SetWpm(Wpm: Integer);
    function Snapshot: TKeyerStatus;
  end;

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
    FLibraryPath := LibraryPath;
    FWpmWanted := Wpm;
    FConnectWanted := True;
    FDisconnectWanted := False;
    FStatus.State := ksConnecting;
    FStatus.Fault := kfNone;
    FStatus.Detail := '';
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
  QueuedUntil: QWord;
  ConnectNow, DisconnectNow, StopNow: Boolean;
  Settings: TRigSettings;
  LibraryPath, Word_: string;
  Wpm, WantedWpm: Integer;
  Stopped: Boolean;

  procedure SetState(State: TKeyerState);
  begin
    FLock.Enter;
    try
      FStatus.State := State;
    finally
      FLock.Leave;
    end;
  end;

  { 誤りのあとの後始末。**送り直さず、繋ぎ直さず、止めを試みて閉じる。**
    After an error: **no resending, no reconnecting; try to stop, then close.** }
  procedure Fail(Fault: TKeyerFault; const Detail: string);
  begin
    FLock.Enter;
    try
      FWords := nil;
      FNextWord := 0;
      FStatus.State := ksFailed;
      FStatus.Fault := Fault;
      FStatus.Detail := Detail;
    finally
      FLock.Leave;
    end;
    if Rig <> nil then
    begin
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
  end;

begin
  Rig := nil;
  QueuedUntil := 0;
  Wpm := 0;
  while True do
  begin
    FLock.Enter;
    try
      if FQuit then
        Break;
    finally
      FLock.Leave;
    end;
    FWake.WaitFor(50);

    FLock.Enter;
    try
      ConnectNow := FConnectWanted;
      FConnectWanted := False;
      DisconnectNow := FDisconnectWanted;
      FDisconnectWanted := False;
      StopNow := FStopWanted;
      FStopWanted := False;
      Settings := FSettings;
      LibraryPath := FLibraryPath;
      WantedWpm := FWpmWanted;
    finally
      FLock.Leave;
    end;

    { 1. 止める。**何より先に。** / 1. Stop, **before anything else.** }
    if StopNow and (Rig <> nil) then
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
      if Rig <> nil then
      begin
        try
          Rig.StopMorse;
        except
        end;
        try
          Rig.Free;
        except
        end;
        Rig := nil;
      end;
      if DisconnectNow then
        SetState(ksOff);
    end;

    { 3. 繋ぐ。/ 3. Connect. }
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
          Fail(kfConnect, E.Message);
          Continue;
        end;
      end;
      Wpm := 0;
      FLock.Enter;
      try
        FStatus.State := ksReady;
        FStatus.Stop := ssUnknown;
        FStatus.SpeedSet := False;
      finally
        FLock.Leave;
      end;
    end;

    if Rig = nil then
      Continue;

    { 4. 速度を合わせる。**合わせられない機種もあります**（そのときは無線機の
       設定の速さで送られ、語を渡す間合いの見込みがずれます）。
       4. Match the keyer speed. **Some models cannot** (the rig then sends at
       its own setting and the pacing estimate drifts). }
    if (WantedWpm > 0) and (WantedWpm <> Wpm) then
    begin
      Wpm := WantedWpm;
      try
        Rig.SetKeyerWpm(Wpm);
        FLock.Enter;
        FStatus.SpeedSet := True;
        FLock.Leave;
      except
        FLock.Enter;
        FStatus.SpeedSet := False;
        FLock.Leave;
      end;
    end;

    { 5. 次の語を渡す。**取るのは錠の下**、渡すのは錠の外。
       5. Hand over the next word: **taken under the lock**, handed outside it. }
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
        FStatus.State := ksReady;
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
        QWord(Round(1000 * EstimateTransmitSeconds(Word_, Max(Wpm, HAMLIB_MIN_WPM))));
      FLock.Enter;
      try
        Inc(FStatus.Handed, Length(Word_));
      finally
        FLock.Leave;
      end;
      FWake.SetEvent;
    end;
  end;

  { 終わるときは、送りかけを止めて閉じます。/ On the way out: stop and close. }
  if Rig <> nil then
  begin
    try
      Rig.StopMorse;
    except
    end;
    Rig.Free;
  end;
end;

end.
