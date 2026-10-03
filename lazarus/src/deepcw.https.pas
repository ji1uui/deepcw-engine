unit DeepCW.Https;

{ HTTPS で 1 回だけ GET します。**OS ごとの違いはこの単位の中に閉じ込めます**
  （計画の段 3、付録 CM.13）。

  - Windows: WinHTTP（OS の部品。証明書も代理サーバも OS の設定に従う）
  - macOS: Foundation の URL 読み込み（`NSURLSession`。OS の部品で、
    証明書も代理サーバも OS の設定に従う）
  - Linux: Free Pascal の `fphttpclient` と、OS に入っている OpenSSL
    （Linux には HTTPS の OS の部品が無いため）

  **暗号の部品は同梱しません。**Windows と macOS は OS のものを使い、Linux は
  OS に入っている OpenSSL を使います（利用者の判断、付録 CM.13）。

  呼び出しは待ちます（作業スレッドから呼んでください）。待つ長さは TimeoutMs で
  抑えます。応答の本文は HTTPS_MAX_BODY_BYTES までしか読みません。

  Does one HTTPS GET. **The differences between systems are kept inside this
  unit** (stage 3 of the plan, appendix CM.13).

  - Windows: WinHTTP, the system's own client (certificates and proxies follow
    the system's settings)
  - macOS: Foundation's URL loading (`NSURLSession`), the system's own
    client (certificates and proxies follow the system's settings)
  - Linux: Free Pascal's `fphttpclient` with the system's OpenSSL (Linux has
    no system HTTPS client)

  **No cryptography is bundled**: Windows and macOS use the system's, Linux
  the OpenSSL already installed (the operator's decision, appendix CM.13).

  The call blocks, so call it from a worker thread; TimeoutMs bounds the wait.
  No more than HTTPS_MAX_BODY_BYTES of the body is read. }

{$mode objfpc}{$H+}
{$IFDEF DARWIN}
{$modeswitch objectivec1}
{$modeswitch cblocks}
{$ENDIF}

interface

uses
  SysUtils, Classes;

const
  { 読む本文の上限。件数取得 API の応答は数百バイトです。
    The most of a body read; the count API answers in a few hundred bytes. }
  HTTPS_MAX_BODY_BYTES = 64 * 1024;

{ `https://ホスト[:ポート]/道?問い` を分けます。https でなければ偽。
  Splits `https://host[:port]/path?query`; false unless it is https. }
function SplitHttpsUrl(const Url: string; out Host: string; out Port: Integer;
  out PathAndQuery: string): Boolean;

{ GET します。応答が来れば真と状態・本文を、来なければ偽と理由を返します。
  Sends a GET: true with the status and body when an answer came, false with
  the reason when none did. }
function HttpsGet(const Url, UserAgent: string; TimeoutMs: Integer;
  out Status: Integer; out Body, Failure: string): Boolean;

implementation

{$IF defined(WINDOWS)}
uses
  Windows, WinHttp;

{ FPC 3.2.2 の `WinHttp` 単位には無いので、ここで宣言します。
  Not in FPC 3.2.2's `WinHttp` unit, so declared here. }
function WinHttpSetTimeouts(hInternet: HINTERNET; nResolveTimeout,
  nConnectTimeout, nSendTimeout, nReceiveTimeout: Integer): WINBOOL; stdcall;
  external 'winhttp.dll';
{$ELSEIF defined(DARWIN)}
uses
  CocoaAll;
{$ELSE}
uses
  fphttpclient, opensslsockets;
{$ENDIF}

function SplitHttpsUrl(const Url: string; out Host: string; out Port: Integer;
  out PathAndQuery: string): Boolean;
var
  Rest, Authority: string;
  Slash, Colon: Integer;
begin
  Host := '';
  Port := 443;
  PathAndQuery := '/';
  Result := False;
  if LowerCase(Copy(Url, 1, 8)) <> 'https://' then
    Exit;
  Rest := Copy(Url, 9, MaxInt);
  Slash := Pos('/', Rest);
  if Slash > 0 then
  begin
    Authority := Copy(Rest, 1, Slash - 1);
    PathAndQuery := Copy(Rest, Slash, MaxInt);
  end
  else
    Authority := Rest;
  Colon := Pos(':', Authority);
  if Colon > 0 then
  begin
    if not TryStrToInt(Copy(Authority, Colon + 1, MaxInt), Port) or
       (Port <= 0) or (Port > 65535) then
      Exit;
    Authority := Copy(Authority, 1, Colon - 1);
  end;
  Host := Authority;
  Result := (Host <> '') and (Pos('@', Host) = 0);
end;

{$IF defined(WINDOWS)}
function HttpsGet(const Url, UserAgent: string; TimeoutMs: Integer;
  out Status: Integer; out Body, Failure: string): Boolean;
var
  Host, Path: string;
  Port: Integer;
  Session, Connection, Request: HINTERNET;
  Code, Size, Available, Got: DWORD;
  Buffer: array[0..8191] of Byte;
  Chunk: string;
begin
  Status := 0;
  Body := '';
  Failure := '';
  Result := False;
  if not SplitHttpsUrl(Url, Host, Port, Path) then
  begin
    Failure := 'not an https URL';
    Exit;
  end;
  Connection := nil;
  Request := nil;
  { Windows 8.1 からは OS の代理サーバ設定を自動で使えます。古い OS では
    既定の設定に戻ります。
    From Windows 8.1 the system proxy settings can be used automatically; older
    systems fall back to the default. }
  Session := WinHttpOpen(PWideChar(UnicodeString(UserAgent)),
    WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY, nil, nil, 0);
  if Session = nil then
    Session := WinHttpOpen(PWideChar(UnicodeString(UserAgent)),
      WINHTTP_ACCESS_TYPE_DEFAULT_PROXY, nil, nil, 0);
  if Session = nil then
  begin
    Failure := Format('WinHTTP error %d', [GetLastError]);
    Exit;
  end;
  try
    WinHttpSetTimeouts(Session, TimeoutMs, TimeoutMs, TimeoutMs, TimeoutMs);
    Connection := WinHttpConnect(Session, PWideChar(UnicodeString(Host)), Port, 0);
    if Connection <> nil then
      Request := WinHttpOpenRequest(Connection, 'GET',
        PWideChar(UnicodeString(Path)), nil, nil, nil, WINHTTP_FLAG_SECURE);
    if (Request = nil) or
       not WinHttpSendRequest(Request, nil, 0, nil, 0, 0, 0) or
       not WinHttpReceiveResponse(Request, nil) then
    begin
      Failure := Format('WinHTTP error %d', [GetLastError]);
      Exit;
    end;
    Code := 0;
    Size := SizeOf(Code);
    if not WinHttpQueryHeaders(Request,
       WINHTTP_QUERY_STATUS_CODE or WINHTTP_QUERY_FLAG_NUMBER, nil, @Code,
       @Size, nil) then
    begin
      Failure := Format('WinHTTP error %d', [GetLastError]);
      Exit;
    end;
    Status := Code;
    repeat
      Available := 0;
      if not WinHttpQueryDataAvailable(Request, @Available) then
      begin
        Failure := Format('WinHTTP error %d', [GetLastError]);
        Exit;
      end;
      if Available = 0 then
        Break;
      if Available > SizeOf(Buffer) then
        Available := SizeOf(Buffer);
      Got := 0;
      if not WinHttpReadData(Request, @Buffer[0], Available, @Got) then
      begin
        Failure := Format('WinHTTP error %d', [GetLastError]);
        Exit;
      end;
      SetString(Chunk, PAnsiChar(@Buffer[0]), Got);
      Body := Body + Chunk;
    until (Got = 0) or (Length(Body) >= HTTPS_MAX_BODY_BYTES);
    Result := True;
  finally
    if Request <> nil then
      WinHttpCloseHandle(Request);
    if Connection <> nil then
      WinHttpCloseHandle(Connection);
    WinHttpCloseHandle(Session);
  end;
end;

{$ELSEIF defined(DARWIN)}
type
  { 完了を受ける block。**大域の手続きから作ります**（Free Pascal 3.2.2 は、
    大域の手続きなら静的な block にでき、`NSURLSession` が写しても壊れません）。
    The block that receives completion. **It is made from a global procedure**:
    Free Pascal 3.2.2 turns one into a static block, which survives
    `NSURLSession` copying it. }
  TSessionCompletion = reference to procedure(data: NSData;
    response: NSURLResponse; error: NSError); cdecl; cblock;

var
  { 照会は一度に 1 つ。完了は `NSURLSession` の別のスレッドから届くので、
    結果をここに置き、出来事で知らせます。
    One request at a time. Completion arrives on another of `NSURLSession`'s
    threads, so the result is left here and an event announces it. }
  GLock: TRTLCriticalSection;
  GDone: PRTLEvent;
  GFinished, GAnswered, GLeftOver: Boolean;
  GStatus: Integer;
  GBody, GFailure: string;

procedure SessionDone(data: NSData; response: NSURLResponse; error: NSError);
var
  Count: Integer;
begin
  if (response <> nil) and response.isKindOfClass(NSHTTPURLResponse.classClass) then
  begin
    GAnswered := True;
    GStatus := NSHTTPURLResponse(response).statusCode;
    GBody := '';
    if data <> nil then
    begin
      Count := data.length;
      if Count > HTTPS_MAX_BODY_BYTES then
        Count := HTTPS_MAX_BODY_BYTES;
      SetString(GBody, PAnsiChar(data.bytes), Count);
    end;
  end
  else
  begin
    GAnswered := False;
    if error <> nil then
      GFailure := string(error.localizedDescription.UTF8String)
    else
      GFailure := 'no answer';
  end;
  GFinished := True;
  RTLEventSetEvent(GDone);
end;

function HttpsGet(const Url, UserAgent: string; TimeoutMs: Integer;
  out Status: Integer; out Body, Failure: string): Boolean;
const
  { 取り消したあと、完了が届くのを待つ長さ。/ How long to wait for completion
    after cancelling. }
  CANCEL_WAIT_MS = 5000;
var
  Pool: NSAutoreleasePool;
  Address: NSURL;
  Config: NSURLSessionConfiguration;
  Session: NSURLSession;
  Request: NSMutableURLRequest;
  Task: NSURLSessionDataTask;
  Handler: TSessionCompletion;
  Host, Path: string;
  Port: Integer;
begin
  Status := 0;
  Body := '';
  Failure := '';
  Result := False;
  if not SplitHttpsUrl(Url, Host, Port, Path) then
  begin
    Failure := 'not an https URL';
    Exit;
  end;
  EnterCriticalSection(GLock);
  try
    { 前の照会の完了がまだ届いていなければ、もう少し待ちます。届かないまま
      次を始めると、前の完了が次の結果を上書きします。
      If the previous request's completion has not arrived, wait a little
      more: starting the next one regardless would let the old completion
      overwrite the new result. }
    if GLeftOver then
    begin
      RTLEventWaitFor(GDone, CANCEL_WAIT_MS);
      if not GFinished then
      begin
        Failure := 'previous request still running';
        Exit;
      end;
      GLeftOver := False;
    end;
    RTLEventResetEvent(GDone);
    GFinished := False;
    GAnswered := False;
    GStatus := 0;
    GBody := '';
    GFailure := '';

    { 作業スレッドから呼ぶので、自動解放の池を自分で持ちます。
      Called from a worker thread, so it keeps its own autorelease pool. }
    Pool := NSAutoreleasePool.alloc.init;
    try
      Address := NSURL.URLWithString(NSString.stringWithUTF8String(PChar(Url)));
      if Address = nil then
      begin
        Failure := 'not an https URL';
        Exit;
      end;
      { 記録を残さない設定（キャッシュ・クッキーをディスクに書かない）。
        An ephemeral configuration: no cache or cookies written to disk. }
      Config := NSURLSessionConfiguration.ephemeralSessionConfiguration;
      Config.setTimeoutIntervalForRequest(TimeoutMs / 1000);
      Config.setTimeoutIntervalForResource(TimeoutMs / 1000);
      Session := NSURLSession.sessionWithConfiguration(Config);
      Request := NSMutableURLRequest.requestWithURL_cachePolicy_timeoutInterval(
        Address, NSURLRequestReloadIgnoringLocalCacheData, TimeoutMs / 1000);
      Request.setValue_forHTTPHeaderField(
        NSString.stringWithUTF8String(PChar(UserAgent)),
        NSString.stringWithUTF8String('User-Agent'));
      Handler := @SessionDone;
      Task := Session.dataTaskWithRequest_completionHandler(Request,
        OpaqueCBlock(Handler));
      Task.resume;
      { 上限まで待ち、来なければ取り消して完了を待ちます。
        Wait up to the limit; if nothing came, cancel and wait for completion. }
      RTLEventWaitFor(GDone, TimeoutMs + 1000);
      if not GFinished then
      begin
        Task.cancel;
        RTLEventWaitFor(GDone, CANCEL_WAIT_MS);
      end;
      Session.finishTasksAndInvalidate;
      if not GFinished then
      begin
        GLeftOver := True;
        Failure := 'timed out';
        Exit;
      end;
      Status := GStatus;
      Body := GBody;
      Failure := GFailure;
      Result := GAnswered;
    finally
      Pool.release;
    end;
  finally
    LeaveCriticalSection(GLock);
  end;
end;

{$ELSE}
function HttpsGet(const Url, UserAgent: string; TimeoutMs: Integer;
  out Status: Integer; out Body, Failure: string): Boolean;
var
  Client: TFPHTTPClient;
  Answer: TStringStream;
  Host, Path: string;
  Port: Integer;
begin
  Status := 0;
  Body := '';
  Failure := '';
  Result := False;
  if not SplitHttpsUrl(Url, Host, Port, Path) then
  begin
    Failure := 'not an https URL';
    Exit;
  end;
  Client := TFPHTTPClient.Create(nil);
  Answer := TStringStream.Create('');
  try
    try
      Client.ConnectTimeout := TimeoutMs;
      Client.IOTimeout := TimeoutMs;
      Client.AllowRedirect := True;
      Client.AddHeader('User-Agent', UserAgent);
      { どの状態でも例外にせず、そのまま返します（429 などは呼び出し側が
        判じます）。
        No status raises: every one is handed back, and the caller judges 429
        and the rest. }
      Client.HTTPMethod('GET', Url, Answer, []);
      Status := Client.ResponseStatusCode;
      Body := Copy(Answer.DataString, 1, HTTPS_MAX_BODY_BYTES);
      Result := True;
    except
      on E: Exception do
        Failure := E.Message;
    end;
  finally
    Answer.Free;
    Client.Free;
  end;
end;
{$ENDIF}

{$IFDEF DARWIN}
initialization
  InitCriticalSection(GLock);
  GDone := RTLEventCreate;

finalization
  RTLEventDestroy(GDone);
  DoneCriticalSection(GLock);
{$ENDIF}

end.
