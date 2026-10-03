unit DeepCW.Https;

{ HTTPS で 1 回だけ GET します。**OS ごとの違いはこの単位の中に閉じ込めます**
  （計画の段 3、付録 CM.13）。

  - Windows: WinHTTP（OS の部品。証明書も代理サーバも OS の設定に従う）
  - macOS: Foundation の URL 読み込み（`NSURLConnection`。OS の部品で、
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
  - macOS: Foundation's URL loading (`NSURLConnection`), the system's own
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
function HttpsGet(const Url, UserAgent: string; TimeoutMs: Integer;
  out Status: Integer; out Body, Failure: string): Boolean;
var
  Pool: NSAutoreleasePool;
  Address: NSURL;
  Request: NSMutableURLRequest;
  Response: NSURLResponse;
  Error: NSError;
  Data: NSData;
  Host, Path: string;
  Port, Count: Integer;
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
    Request := NSMutableURLRequest.requestWithURL_cachePolicy_timeoutInterval(
      Address, NSURLRequestReloadIgnoringLocalCacheData, TimeoutMs / 1000);
    Request.setValue_forHTTPHeaderField(
      NSString.stringWithUTF8String(PChar(UserAgent)),
      NSString.stringWithUTF8String('User-Agent'));
    Response := nil;
    Error := nil;
    { `NSURLConnection` の同期の呼び出しは非推奨（macOS 10.11 から）ですが、
      今も OS に入っています。`NSURLSession` は完了を C の block で受けるため、
      macOS の実機で確かめられるまでこちらを使います（付録 CM.13）。
      The synchronous `NSURLConnection` call is deprecated (since macOS 10.11)
      but still ships with the system. `NSURLSession` reports completion
      through a C block, so this is used until that can be checked on a real
      Mac (appendix CM.13). }
    Data := NSURLConnection.sendSynchronousRequest_returningResponse_error(
      Request, @Response, @Error);
    if (Response = nil) or not Response.isKindOfClass(NSHTTPURLResponse.classClass) then
    begin
      if Error <> nil then
        Failure := string(Error.localizedDescription.UTF8String)
      else
        Failure := 'no answer';
      Exit;
    end;
    Status := NSHTTPURLResponse(Response).statusCode;
    if Data <> nil then
    begin
      Count := Data.length;
      if Count > HTTPS_MAX_BODY_BYTES then
        Count := HTTPS_MAX_BODY_BYTES;
      SetString(Body, PAnsiChar(Data.bytes), Count);
    end;
    Result := True;
  finally
    Pool.release;
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

end.
