unit DeepCW.LicenseLookup;

{ 総務省の無線局等情報検索 Web-API で、日本の局が免許されているかを確かめます
  （要件 FR-K.3〜K.8、付録 CM）。

  **使うのは件数取得 API だけです。**一覧取得 API は免許人の名称や住所を返し
  ますが、件数取得 API が返すのは件数とデータ更新日だけです。だから個人情報を
  そもそも受け取りません（要件 FR-K.7）。

  **照会するのは完全な呼出符号だけです**（利用者の判断、付録 CM.10）。API の
  呼出符号の検索は部分一致しかなく、後置符字が 2 字の局（`JA1AB`）は他の局にも
  当たります。そこで、件数が 1 以上でも「確かめられない」と返します。

  **見つからないことを誤りとは言いません**（要件 FR-K.4）。データには更新日が
  あり、新しく免許された局はまだ載っていないことがあります。

  **通信そのものはここでは行いません。**`TLookupTransport` の向こうに置き、
  試験では記録した形の応答を返す偽の相手に差し替えます。照会できないとき
  （断られた・繋がらない・混み合っている）も受信は止めず、理由を返すだけです
  （要件 FR-K.10）。

  Checks with the Ministry of Internal Affairs and Communications' radio station
  search Web-API whether a Japanese station is licensed (requirements
  FR-K.3-K.8, appendix CM).

  **Only the count API is used.** The list API returns the licensee's name and
  address; the count API returns a count and the data date and nothing else, so
  no personal information is ever received (requirement FR-K.7).

  **Only complete call signs are queried** (the operator's decision, appendix
  CM.10). The API matches call signs by substring only, so a two-letter suffix
  (`JA1AB`) also hits other stations; such a call sign is reported as not
  verifiable even when the count is one or more.

  **Not found is never called an error** (requirement FR-K.4): the data has a
  date, and a newly licensed station may not be in it yet.

  **No traffic happens here.** It sits behind `TLookupTransport`, which tests
  replace with a fake answering in the recorded shape. When a query cannot be
  made -- refused, unreachable, busy -- reception carries on and only the reason
  comes back (requirement FR-K.10). }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, fpjson, jsonparser, DeepCW.Callsign, DeepCW.Https;

const
  { 件数取得 API（仕様書 Ver.1.6.0、条件一覧 Ver.1.3.0）。
    The count API (specification Ver.1.6.0, conditions Ver.1.3.0). }
  LOOKUP_COUNT_URL = 'https://www.tele.soumu.go.jp/musen/num';
  { 照会と照会のあいだの最短の間（秒）。規約は数値を定めず「短時間における
    大量アクセス」を禁じています（第 6 条）。
    The shortest gap between two queries, in seconds. The terms set no figure
    but prohibit heavy access in a short time (article 6). }
  LOOKUP_MIN_INTERVAL_SECONDS = 1.0;
  { 混み合っている（429）・繋がらないときに待つ時間。待つたびに倍にし、上限で
    止めます。
    How long to wait when busy (429) or unreachable, doubled each time up to the
    cap. }
  LOOKUP_BACKOFF_SECONDS = 60.0;
  LOOKUP_BACKOFF_MAX_SECONDS = 900.0;
  { 結果を使い回す時間。データ更新日は日ごとなので 1 日。
    How long a result is reused: a day, as the data is dated by the day. }
  LOOKUP_KEEP_SECONDS = 24 * 3600.0;
  { 覚えておく結果と、待たせておく照会の上限。照会はバンドマップを描くたびに
    求め直されるので、溢れた分は捨てても次に来ます。
    The most results remembered and queries kept waiting. Queries are asked
    for again every time the band map is drawn, so what overflows comes back. }
  LOOKUP_CACHE_LIMIT = 10000;
  LOOKUP_QUEUE_LIMIT = 32;
  { 第四級アマチュア無線技士の局の一括表示記号（コード値一覧 Ver.1.2.0）。
    電信は運用できません（未解決 #12、要件 FR-K.8）。
    The bundled-designation codes of fourth-class stations (code list
    Ver.1.2.0), which may not operate telegraphy (open question #12,
    requirement FR-K.8). }
  LOOKUP_FOURTH_CLASS_CODES: array[0..1] of string = ('4AF', '4AM');
  { 製品の版。**要件定義書の版と同じにします**（`dsp_check` が突き合わせます）。
    The product version: **the same as the requirements document's**
    (`dsp_check` compares them). }
  DEEPCW_VERSION = '2.100';
  { 照会に付ける User-Agent。2025-01 の刷新から、ブラウザらしい値でないと
    断られたという報告があり（付録 CM.8）、互換の印のあとに製品名と版を名乗り
    ます（利用者の判断、付録 CM.13）。
    The User-Agent sent with queries. Since the 2025-01 renewal non-browser
    values were reported refused (appendix CM.8), so the compatibility token is
    followed by the product's name and version (the operator's decision,
    appendix CM.13). }
  LOOKUP_USER_AGENT = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) DeepCW/' +
    DEEPCW_VERSION;
  { 1 回の照会を待つ上限（ミリ秒）。切ったり閉じたりするとき、作業スレッドの
    終わりを待つのはこの長さまでです。
    The longest one query may take, in milliseconds; switching off or closing
    waits for the worker no longer than this. }
  LOOKUP_TIMEOUT_MS = 5000;

type
  { 照会の結果。/ What a query found. }
  TLicenseVerdict = (
    { 照会しない（切っている・日本の局でない・形が違う）。
      Not queried: switched off, not Japanese, or not of the right form. }
    lvNotAsked,
    { 照会を待っている。/ Waiting to be queried. }
    lvPending,
    { 免許されている（データ更新日の時点で）。
      Licensed, as of the data date. }
    lvFound,
    { データ更新日の時点で見つからない。**誤りとは言いません。**
      Not found as of the data date. **Not called an error.** }
    lvNotFound,
    { 後置符字が短く、他の局にも当たるので確かめられない。
      The suffix is short and hits other stations too, so it cannot be told. }
    lvAmbiguous,
    { 照会できない（理由は Problem）。/ Could not be queried (see Problem). }
    lvUnavailable);

  TLicenseResult = record
    Verdict: TLicenseVerdict;
    { 当たった局が、すべて第四級（電信不可）か。lvFound のときだけ意味を持ち
      ます。/ Whether every station hit is fourth class (no telegraphy);
      meaningful only with lvFound. }
    FourthClass: Boolean;
    { データ更新日（YYYY-MM-DD）。読めなければ空。/ The data date, or empty. }
    DataDate: string;
    { 照会できなかった理由（HTTP の状態や API の誤りの番号）。応答の本文は
      入れません。/ Why a query failed: the HTTP status or the API's error
      code. Never the response body. }
    Problem: string;
  end;

  { 件数取得 API の 1 回の応答を読んだ結果。/ One count API answer, read. }
  TCountOutcome = (coCount, coBusy, coRejected, coFailed);

  { 通信の口。段 3 で HTTPS の実装を入れます。**どのスレッドから呼ばれても
    よいように作ってください**（照会は作業スレッドから呼びます）。
    The transport. The HTTPS implementation arrives in stage 3. **It must be
    safe to call from a worker thread**, which is where queries run. }
  TLookupTransport = class
  public
    { 成功すれば真と、HTTP の状態・本文を返します。繋がらなければ偽と、
      その理由を返します。/ True with the HTTP status and body on success;
      false with the reason when no answer came. }
    function Get(const Url, UserAgent: string; out Status: Integer;
      out Body, Failure: string): Boolean; virtual; abstract;
  end;

  { OS の HTTPS の仕組みで通信する口（`DeepCW.Https`、付録 CM.13）。
    The transport over the system's HTTPS client (`DeepCW.Https`, appendix
    CM.13). }
  THttpsTransport = class(TLookupTransport)
  public
    function Get(const Url, UserAgent: string; out Status: Integer;
      out Body, Failure: string): Boolean; override;
  end;

  { 照会の窓口。結果を覚え、間引き、混み合えば待ちます。

    `Lookup` はどのスレッドからでも呼べ、**待たずに**覚えている結果を返します
    （無ければ照会を待たせて lvPending）。通信は `Step` が 1 回ずつ行い、
    `TLicenseLookupThread` が作業スレッドで回します。**通信の間は排他を
    握りません。**

    The lookup desk: remembers results, spaces queries out and waits when busy.

    `Lookup` may be called from any thread and **never waits**: it returns
    what is remembered, or queues a query and says lvPending. The traffic is
    done one request at a time by `Step`, run on a worker by
    `TLicenseLookupThread`. **The lock is never held during traffic.** }
  TLicenseLookup = class
  private
    type
      TJob = record
        Key: string;
        Ambiguous: Boolean;
        { 0 = 総数、1 以降 = 第四級の記号ごとの件数。
          0 = the total; 1 onwards = one count per fourth-class code. }
        Stage: Integer;
        Total: Integer;
        Fourth: Integer;
        DataDate: string;
      end;
      TEntry = record
        Result: TLicenseResult;
        At: Double;
      end;
    var
      FLock: TRTLCriticalSection;
      FTransport: TLookupTransport;
      FOwnsTransport: Boolean;
      FEnabled: Boolean;
      FUserAgent: string;
      FKeys: TStringList;
      FEntries: array of TEntry;
      FQueue: array of TJob;
      FNextAt: Double;
      FBackoff: Double;
      FLastProblem: string;
      FRequests: Int64;
    procedure SetEnabled(Value: Boolean);
    function GetEnabled: Boolean;
    function GetLastProblem: string;
    function GetRequests: Int64;
    procedure SetUserAgent(const Value: string);
    function GetUserAgent: string;
    function Queued(const Key: string): Boolean;
    procedure Remember(const Key: string; const Value: TLicenseResult;
      NowSeconds: Double);
    procedure Finish(const Job: TJob; NowSeconds: Double);
    procedure Wait(NowSeconds: Double; const Problem: string);
  public
    constructor Create(ATransport: TLookupTransport; AOwnsTransport: Boolean);
    destructor Destroy; override;
    { 覚えている結果を返します。無ければ照会を待たせます。NowSeconds は単調に
      進む時計（秒）。/ Returns what is remembered, or queues a query.
      NowSeconds is a monotonic clock in seconds. }
    function Lookup(const Callsign: string; NowSeconds: Double): TLicenseResult;
    { 待っている照会を 1 回だけ進めます。通信したら真。
      Advances the waiting queries by one request; true if traffic happened. }
    function Step(NowSeconds: Double): Boolean;
    { **既定は切です**（要件 FR-K.3）。切れば待っている照会も捨てます。
      **Off by default** (requirement FR-K.3). Switching off drops the queue. }
    property Enabled: Boolean read GetEnabled write SetEnabled;
    property UserAgent: string read GetUserAgent write SetUserAgent;
    { 診断に出すもの（要件 FR-K.10）。/ For the diagnostics (FR-K.10). }
    property LastProblem: string read GetLastProblem;
    property Requests: Int64 read GetRequests;
  end;

  { `Step` を回す作業スレッド。/ The worker that runs `Step`. }
  TLicenseLookupThread = class(TThread)
  private
    FLookup: TLicenseLookup;
  protected
    procedure Execute; override;
  public
    constructor Create(ALookup: TLicenseLookup);
  end;

{ 作業スレッドを止めます。**待つのは WaitMs まで**です。照会の最中なら、通信の
  待ち時間（`LOOKUP_TIMEOUT_MS`、OS によってはその数倍）まで終わらないことがあり、
  画面のスレッドがそれを待つと画面が止まります（付録 CM.15 で 3 秒を測った）。
  止まれば解放して真を返します。止まらなければ偽を返し、**スレッドも照会の窓口
  も手放しません**（スレッドがまだ使っているため）。閉じるときにだけ使い、
  偽なら、そのままプロセスの終わりに任せます。
  Stops the worker, **waiting no more than WaitMs**. Mid-query it may not end
  until the network timeout (`LOOKUP_TIMEOUT_MS`, several times that on some
  systems), and the UI thread waiting for it is a frozen screen (appendix CM.15
  measured 3 s). If it stops it is freed and true is returned; if not, false,
  and **neither the thread nor the lookup is released** (the thread still uses
  them). Only for closing: on false, the end of the process takes care of it. }
function StopLookupWorker(var Worker: TLicenseLookupThread;
  WaitMs: Integer): Boolean;

{ この版の通信の口と、それが実際に通信できるか。偽の間、画面は設定を選べなく
  します。
  This version's transport and whether it can actually talk; while false the
  screen does not offer the setting. }
function NewLookupTransport: TLookupTransport;
function LookupTransportBuilt: Boolean;

{ 照会してよい符号か。日本の前置符字で、通常の形（19.68A の特別な形でない）の
  ものだけ。Key は附加符号を除いた本体、Ambiguous は後置符字が 3 字に満たない
  （部分一致で他の局にも当たる）こと。
  Whether a call sign may be queried: a Japanese prefix in the ordinary form
  (not the special form of 19.68A). Key is the call without the appended
  designator; Ambiguous means a suffix shorter than three letters, which the
  substring match lets hit other stations. }
function LookupKey(const Callsign: string; out Key: string;
  out Ambiguous: Boolean): Boolean;

{ 件数取得 API の URL。ClassCode が空なら総数を数えます。
  The count API URL; an empty ClassCode counts the total. }
function LookupCountUrl(const Key, ClassCode: string): string;

{ 応答を読みます。**読むのは件数・データ更新日・誤りの番号だけで、本文は
  残しません。**
  Reads an answer. **Only the count, the data date and the error code are
  read; the body is not kept.** }
function ParseCountResponse(Status: Integer; const Body: string;
  out Count: Integer; out DataDate, Problem: string): TCountOutcome;

implementation

function THttpsTransport.Get(const Url, UserAgent: string;
  out Status: Integer; out Body, Failure: string): Boolean;
begin
  Result := HttpsGet(Url, UserAgent, LOOKUP_TIMEOUT_MS, Status, Body, Failure);
end;

function NewLookupTransport: TLookupTransport;
begin
  Result := THttpsTransport.Create;
end;

function LookupTransportBuilt: Boolean;
begin
  Result := True;
end;

function LookupKey(const Callsign: string; out Key: string;
  out Ambiguous: Boolean): Boolean;
var
  Call: TCallsign;
begin
  Key := '';
  Ambiguous := False;
  Result := ParseCallsignShape(UpperCase(Trim(Callsign)), Call) and
    Call.Japanese and not Call.Special;
  if not Result then
    Exit;
  Key := Call.Base;
  Ambiguous := Length(Call.Suffix) < 3;
end;

function LookupCountUrl(const Key, ClassCode: string): string;
begin
  { ST=1 免許情報、OF=2 JSON、OW=AT アマチュア局、MA 呼出符号（部分一致）、
    FC 一括表示記号。符号は英数字だけなので符号化は要りません。
    ST=1 licences, OF=2 JSON, OW=AT amateur, MA call sign (substring), FC the
    bundled designation. A call sign is letters and digits only, so nothing
    needs escaping. }
  Result := LOOKUP_COUNT_URL + '?ST=1&OF=2&OW=AT&MA=' + Key;
  if ClassCode <> '' then
    Result := Result + '&FC=' + ClassCode;
end;

{ 数か、数を表す文字列か。応答は文字列で返す例が多い（付録 CM.9）。
  A number, or a string holding one; answers usually carry strings
  (appendix CM.9). }
function JsonCount(Data: TJSONData; out Value: Integer): Boolean;
begin
  Result := False;
  Value := 0;
  if Data = nil then
    Exit;
  case Data.JSONType of
    jtNumber:
      if Data is TJSONIntegerNumber then
      begin
        Value := Data.AsInteger;
        Result := Value >= 0;
      end;
    jtString:
      Result := TryStrToInt(Trim(Data.AsString), Value) and (Value >= 0);
  end;
end;

{ YYYY-MM-DD の形のときだけ受け取ります。/ Accepted only as YYYY-MM-DD. }
function CleanDate(const Text: string): string;
var
  I: Integer;
begin
  Result := '';
  if Length(Text) <> 10 then
    Exit;
  for I := 1 to 10 do
    if I in [5, 8] then
    begin
      if Text[I] <> '-' then
        Exit;
    end
    else if not (Text[I] in ['0'..'9']) then
      Exit;
  Result := Text;
end;

{ 誤りの番号（EQ と数字だけ）。それ以外の形なら空。/ The error code (EQ and
  digits only), or empty for anything else. }
function CleanCode(const Text: string): string;
var
  I: Integer;
begin
  Result := '';
  if (Length(Text) < 3) or (Length(Text) > 12) or (Copy(Text, 1, 2) <> 'EQ') then
    Exit;
  for I := 3 to Length(Text) do
    if not (Text[I] in ['0'..'9']) then
      Exit;
  Result := Text;
end;

function ParseCountResponse(Status: Integer; const Body: string;
  out Count: Integer; out DataDate, Problem: string): TCountOutcome;
var
  Root, Info, Errors, First: TJSONData;
  Code: string;
begin
  Count := 0;
  DataDate := '';
  Problem := '';
  Root := nil;
  try
    try
      Root := GetJSON(Body);
    except
      Root := nil;
    end;

    { 混み合っている。本文の形によらず、状態で決めます。
      Busy, decided by the status whatever the body looks like. }
    if Status = 429 then
    begin
      Problem := 'HTTP 429';
      Exit(coBusy);
    end;

    { API の誤り（JSON の err[0].errCd）。番号だけを残します。
      An API error (err[0].errCd in JSON); only the code is kept. }
    Code := '';
    if Root is TJSONObject then
    begin
      Errors := TJSONObject(Root).Find('err');
      if (Errors is TJSONArray) and (TJSONArray(Errors).Count > 0) then
      begin
        First := TJSONArray(Errors).Items[0];
        if First is TJSONObject then
          Code := CleanCode(TJSONObject(First).Get('errCd', ''));
      end;
    end;
    if Code = 'EQ00429' then
    begin
      Problem := Code;
      Exit(coBusy);
    end;
    if (Status = 400) or ((Code <> '') and (Status <> 200)) then
    begin
      if Code <> '' then
        Problem := Code
      else
        Problem := 'HTTP 400';
      Exit(coRejected);
    end;
    if Status <> 200 then
    begin
      Problem := Format('HTTP %d', [Status]);
      if Code <> '' then
        Problem := Problem + ' ' + Code;
      Exit(coFailed);
    end;

    { 200 なら musenInformation.totalCount と lastUpdateDate。**JSON でない
      本文（断られたときのページなど）は読めないと言うだけです。**
      On 200, musenInformation.totalCount and lastUpdateDate. **A body that is
      not JSON -- a refusal page, say -- is only reported as unreadable.** }
    if Root is TJSONObject then
      Info := TJSONObject(Root).Find('musenInformation')
    else
      Info := nil;
    if (Info is TJSONObject) and
       JsonCount(TJSONObject(Info).Find('totalCount'), Count) then
    begin
      DataDate := CleanDate(TJSONObject(Info).Get('lastUpdateDate', ''));
      Exit(coCount);
    end;
    Count := 0;
    if Code <> '' then
      Problem := Code
    else
      Problem := 'unreadable answer';
    Result := coFailed;
  finally
    Root.Free;
  end;
end;

{ TLicenseLookup }

constructor TLicenseLookup.Create(ATransport: TLookupTransport;
  AOwnsTransport: Boolean);
begin
  inherited Create;
  InitCriticalSection(FLock);
  FTransport := ATransport;
  FOwnsTransport := AOwnsTransport;
  FKeys := TStringList.Create;
  FKeys.Sorted := True;
  FKeys.Duplicates := dupIgnore;
  FBackoff := LOOKUP_BACKOFF_SECONDS;
  FNextAt := -Infinity;
end;

destructor TLicenseLookup.Destroy;
begin
  FKeys.Free;
  if FOwnsTransport then
    FTransport.Free;
  DoneCriticalSection(FLock);
  inherited Destroy;
end;

procedure TLicenseLookup.SetEnabled(Value: Boolean);
begin
  EnterCriticalSection(FLock);
  try
    FEnabled := Value;
    { 切ったら、待っている照会はもう送りません（要件 FR-K.3）。
      Once off, nothing waiting is sent any more (requirement FR-K.3). }
    if not Value then
      FQueue := nil;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TLicenseLookup.GetEnabled: Boolean;
begin
  EnterCriticalSection(FLock);
  try
    Result := FEnabled;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TLicenseLookup.GetLastProblem: string;
begin
  EnterCriticalSection(FLock);
  try
    Result := FLastProblem;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TLicenseLookup.GetRequests: Int64;
begin
  EnterCriticalSection(FLock);
  try
    Result := FRequests;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

procedure TLicenseLookup.SetUserAgent(const Value: string);
begin
  EnterCriticalSection(FLock);
  try
    FUserAgent := Value;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TLicenseLookup.GetUserAgent: string;
begin
  EnterCriticalSection(FLock);
  try
    Result := FUserAgent;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TLicenseLookup.Queued(const Key: string): Boolean;
var
  I: Integer;
begin
  for I := 0 to High(FQueue) do
    if FQueue[I].Key = Key then
      Exit(True);
  Result := False;
end;

procedure TLicenseLookup.Remember(const Key: string;
  const Value: TLicenseResult; NowSeconds: Double);
var
  Index: Integer;
begin
  { 上限を超えたら覚えたものを捨てて始め直します。求め直されれば戻ります。
    Past the limit, what is remembered is dropped and started afresh; it comes
    back when asked for again. }
  if FKeys.Count >= LOOKUP_CACHE_LIMIT then
  begin
    FKeys.Clear;
    FEntries := nil;
  end;
  Index := FKeys.IndexOf(Key);
  if Index < 0 then
  begin
    SetLength(FEntries, Length(FEntries) + 1);
    FKeys.AddObject(Key, TObject(PtrInt(High(FEntries))));
    Index := FKeys.IndexOf(Key);
  end;
  with FEntries[PtrInt(FKeys.Objects[Index])] do
  begin
    Result := Value;
    At := NowSeconds;
  end;
end;

procedure TLicenseLookup.Finish(const Job: TJob; NowSeconds: Double);
var
  Value: TLicenseResult;
begin
  Value := Default(TLicenseResult);
  Value.DataDate := Job.DataDate;
  if Job.Total = 0 then
    Value.Verdict := lvNotFound
  else if Job.Ambiguous then
    Value.Verdict := lvAmbiguous
  else
  begin
    Value.Verdict := lvFound;
    Value.FourthClass := Job.Fourth >= Job.Total;
  end;
  Remember(Job.Key, Value, NowSeconds);
end;

procedure TLicenseLookup.Wait(NowSeconds: Double; const Problem: string);
begin
  FLastProblem := Problem;
  FNextAt := NowSeconds + FBackoff;
  FBackoff := Min(FBackoff * 2, LOOKUP_BACKOFF_MAX_SECONDS);
end;

function TLicenseLookup.Lookup(const Callsign: string;
  NowSeconds: Double): TLicenseResult;
var
  Key: string;
  Ambiguous: Boolean;
  Index: Integer;
  Job: TJob;
begin
  Result := Default(TLicenseResult);
  if not LookupKey(Callsign, Key, Ambiguous) then
    Exit;
  EnterCriticalSection(FLock);
  try
    if not FEnabled then
      Exit;
    Index := FKeys.IndexOf(Key);
    if (Index >= 0) and
       (NowSeconds - FEntries[PtrInt(FKeys.Objects[Index])].At < LOOKUP_KEEP_SECONDS) then
      Exit(FEntries[PtrInt(FKeys.Objects[Index])].Result);
    { 照会を待たせます。同じ符号は 1 つだけ（要件 FR-K.6）。
      Queue a query; one per call sign (requirement FR-K.6). }
    if not Queued(Key) and (Length(FQueue) < LOOKUP_QUEUE_LIMIT) then
    begin
      Job := Default(TJob);
      Job.Key := Key;
      Job.Ambiguous := Ambiguous;
      SetLength(FQueue, Length(FQueue) + 1);
      FQueue[High(FQueue)] := Job;
    end;
    { 照会できない状態が続いているなら、そう言います（要件 FR-K.10）。
      If queries keep failing, say so (requirement FR-K.10). }
    if FLastProblem <> '' then
    begin
      Result.Verdict := lvUnavailable;
      Result.Problem := FLastProblem;
    end
    else
      Result.Verdict := lvPending;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TLicenseLookup.Step(NowSeconds: Double): Boolean;
var
  Job: TJob;
  Url, Agent, Body, Failure, DataDate, Problem: string;
  Status, Count: Integer;
  Answered: Boolean;
  Outcome: TCountOutcome;
  Rejected: TLicenseResult;
begin
  Result := False;
  EnterCriticalSection(FLock);
  try
    if (not FEnabled) or (Length(FQueue) = 0) or (NowSeconds < FNextAt) then
      Exit;
    Job := FQueue[0];
    Agent := FUserAgent;
    if Job.Stage = 0 then
      Url := LookupCountUrl(Job.Key, '')
    else
      Url := LookupCountUrl(Job.Key, LOOKUP_FOURTH_CLASS_CODES[Job.Stage - 1]);
    FNextAt := NowSeconds + LOOKUP_MIN_INTERVAL_SECONDS;
    Inc(FRequests);
  finally
    LeaveCriticalSection(FLock);
  end;

  { **通信の間は排他を握りません。**/ **No lock is held during traffic.** }
  Answered := FTransport.Get(Url, Agent, Status, Body, Failure);
  if Answered then
    Outcome := ParseCountResponse(Status, Body, Count, DataDate, Problem)
  else
  begin
    Outcome := coFailed;
    { 通信の部品の理由には URL が入ることがあります。理由は設定の脇と診断に
      出るので、URL と呼出符号は伏せます（要件 NFR-6.3）。
      A transport's reason may contain the URL. Reasons reach the settings
      label and the diagnostics, so the URL and the call sign are masked
      (requirement NFR-6.3). }
    Problem := StringReplace(Failure, Url, '(URL)', [rfReplaceAll, rfIgnoreCase]);
    Problem := StringReplace(Problem, Job.Key, '***', [rfReplaceAll, rfIgnoreCase]);
    if Problem = '' then
      Problem := 'no answer';
  end;
  Body := '';
  Result := True;

  EnterCriticalSection(FLock);
  try
    { 照会の間に切られたか、片付けられていれば、結果は使いません。
      Switched off or cleared meanwhile: the result is not used. }
    if (not FEnabled) or (Length(FQueue) = 0) or (FQueue[0].Key <> Job.Key) then
      Exit;
    case Outcome of
      coCount:
        begin
          FLastProblem := '';
          FBackoff := LOOKUP_BACKOFF_SECONDS;
          if Job.Stage = 0 then
          begin
            Job.Total := Count;
            Job.DataDate := DataDate;
          end
          else
            Inc(Job.Fourth, Count);
          Inc(Job.Stage);
          { 総数が 0・確かめられない・すでに全部が第四級・記号を数え終えた、の
            どれかなら終わりです。
            Done when the total is zero, the call cannot be told, every hit is
            already fourth class, or every code has been counted. }
          if (Job.Total = 0) or Job.Ambiguous or (Job.Fourth >= Job.Total) or
             (Job.Stage > Length(LOOKUP_FOURTH_CLASS_CODES)) then
          begin
            Finish(Job, NowSeconds);
            Delete(FQueue, 0, 1);
          end
          else
            FQueue[0] := Job;
        end;
      coRejected:
        begin
          { 断られた照会は、その符号については繰り返しません。総数が分かって
            いれば、第四級かどうかは分からないまま lvFound で終えます。
            A refused query is not repeated for that call sign. If the total is
            known, it ends as lvFound with the class unknown. }
          if Job.Stage > 0 then
          begin
            Job.Fourth := 0;
            Finish(Job, NowSeconds);
          end
          else
          begin
            Rejected := Default(TLicenseResult);
            Rejected.Verdict := lvUnavailable;
            Rejected.Problem := Problem;
            Remember(Job.Key, Rejected, NowSeconds);
          end;
          Delete(FQueue, 0, 1);
        end;
    else
      { 混み合っている・繋がらない・読めない。照会は残して待ちます。
        Busy, unreachable or unreadable: the query stays and we wait. }
      Wait(NowSeconds, Problem);
    end;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

{ TLicenseLookupThread }

constructor TLicenseLookupThread.Create(ALookup: TLicenseLookup);
begin
  FLookup := ALookup;
  FreeOnTerminate := False;
  inherited Create(False);
end;

function StopLookupWorker(var Worker: TLicenseLookupThread;
  WaitMs: Integer): Boolean;
var
  Started: QWord;
begin
  Result := True;
  if Worker = nil then
    Exit;
  Worker.Terminate;
  Started := GetTickCount64;
  while not Worker.Finished and (GetTickCount64 - Started < QWord(WaitMs)) do
    Sleep(10);
  if not Worker.Finished then
    Exit(False);
  Worker.WaitFor;
  FreeAndNil(Worker);
end;

procedure TLicenseLookupThread.Execute;
begin
  while not Terminated do
    if not FLookup.Step(GetTickCount64 / 1000) then
      Sleep(100);
end;

end.
