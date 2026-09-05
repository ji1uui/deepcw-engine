unit DeepCW.BandMap;

{ 局ごとの文字列を、運用者が読める一覧の 1 行へ翻訳します（要件 FR-J）。

  多局同時受信（DeepCW.Multi）が出すのは**事実**です。「この音程から、この時刻に、
  この文字が出た」。運用者が知りたいのはその生の文字列ではなく、
  **「誰が」「どの周波数で」「いつ」「呼べる状態か」**の 4 つです。ここはその
  翻訳だけを行います。

  層を分けてあるのには理由があります。呼出符号の確からしさは四段構えで、
  第 1 段（形の検査）と第 2 段（複数回の一致）はここで完結しますが、第 3 段
  （手元の一覧との照合）と第 4 段（実在の確認）は外部の資料や通信を伴います
  （要件 FR-K）。**復号の機械にその知識を持たせると、後で通信まで抱え込みます。**

  Translates each station's characters into one readable row (requirement FR-J).

  Multi-station reception (DeepCW.Multi) produces **facts**: this pitch, at this
  time, gave these characters. What an operator wants is not that raw string but
  **who, on what frequency, when, and whether they can be called.** This unit
  does only that translation.

  The layers are separate for a reason. A call sign's trustworthiness is built in
  four stages: the first (the shape rule) and the second (agreement between
  sightings) are settled here, while the third (checking a list held locally) and
  the fourth (confirming the station exists) involve outside material and outside
  traffic (requirement FR-K). **Giving the decoding machine that knowledge would
  eventually give it the network traffic too.** }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Math, DeepCW.Types, DeepCW.Decoder, DeepCW.Callsign, DeepCW.Multi,
  DeepCW.Exchange;

const
  { CQ を出していると見なす、最後の根拠からの時間。要件は「根拠が消えたら区別も
    消す」なので、古い CQ をいつまでも根拠にはしません。
    How long a CQ counts as evidence. The requirement is that the distinction
    goes when its evidence goes, so an old CQ does not stand for ever. }
  BANDMAP_CALLING_SECONDS = 120.0;

  { 一覧の右端に添える、直近の文字数。全文は行を選んだときに出します。
    How many recent characters ride along at the end of a row; the whole
    transcript appears when the row is chosen. }
  BANDMAP_RECENT_CHARS = 28;

  { 同じ符号がこの回数出たら「複数回の一致」と見なします（要件 FR-J.7）。
    実運用では呼出符号を 2 回続けて送るのが普通で、付録 H では 40 回中、誤った
    まま一致した例は 0 件でした。
    How many sightings count as agreement (requirement FR-J.7). Sending a call
    sign twice is ordinary practice, and in appendix H no wrong reading ever
    agreed with itself across forty attempts. }
  BANDMAP_AGREEMENT = 2;

type
  { 呼出符号をどこまで信じてよいか。要件 FR-K の四段に対応します。

    **第 3 段と第 4 段は、この版では設定されません。**手元の一覧との照合も実在の
    確認も、まだ実装がないためです。段を先に用意してあるのは、一覧の見せ方
    （どこまでを事実として出すか）が段に直結しており、あとから段を挿し込むと
    表示の決めごとを作り直すことになるからです。

    How far a call sign may be trusted, matching the four stages of requirement
    FR-K.

    **The third and fourth stages are never set in this version**, there being no
    implementation yet of the local list or of confirming existence. The stages
    exist already because how the list presents a call sign — how much of it is
    offered as fact — follows directly from them, and inserting a stage later
    would mean redoing those decisions. }
  TCallsignTrust = (
    ctNone,      { 候補が無い / no candidate }
    ctShape,     { 形が規則に合う。1 度きり / the shape fits, seen once }
    ctAgreed,    { 同じ符号が複数回出た / the same call sign came out repeatedly }
    ctInRoster,  { 手元の一覧にある（未実装）/ in a list held locally (not built) }
    ctVerified); { 実在を確認した（未実装）/ confirmed to exist (not built) }

  { 一覧の 1 行。/ One row of the list. }
  TBandEntry = record
    Id: Int64;
    Hz: Double;
    LevelDb: Double;
    HalfWidthHz: Double;
    FirstSeconds: Double;
    LastSeconds: Double;
    { 読み取れた呼出符号と、その確からしさ。Trust が ctShape どまりのものは
      「まだ確かでない」と分かる形で見せてください（要件 FR-J.7）。
      The call sign read and how far it is trusted. Anything no further than
      ctShape must be shown as not yet certain (requirement FR-J.7). }
    Callsign: string;
    Trust: TCallsignTrust;
    { 同じ符号が出た回数と、いちばん良かったときの文字の確からしさ。
      How many times the same call sign came out, and the character confidence of
      the best of those sightings. }
    Sightings: Integer;
    Confidence: Single;
    { CQ を出しているか（要件 FR-J.2）。根拠は受信文の中の CQ です。
      Whether the station is calling CQ (requirement FR-J.2), on the evidence of a
      CQ in its transcript. }
    Calling: Boolean;
    { いま聞こえているか。/ Whether it is audible now. }
    Heard: Boolean;
    { いま解析の対象になっているか（要件 FR-I.7）。
      Whether it is being analysed (requirement FR-I.7). }
    Analysed: Boolean;
    { 能力の都合で読んでいない局か。**聞こえているのに読んでいない**場合だけ
      真です。送信を止めただけの局と混同しないための区別で、混同すると、
      止めただけの局を「切り捨てた」と見せることになります（要件 FR-I.7）。
      Whether it was cut for want of capacity: true only when it is **audible and
      not being read.** The distinction keeps it apart from a station that simply
      stopped, which would otherwise be shown as one that was cut
      (requirement FR-I.7). }
    Cut: Boolean;
    { この音程に畳み込まれた別の峰の数（要件 FR-J.6）。0 より大きい行は、
      1 局として読んだふりをせず「密集」と示してください。
      How many peaks were folded into this pitch (requirement FR-J.6). A row
      greater than zero must be shown as crowded rather than pretending to have
      read one station. }
    Crowded: Integer;
    { 直近の文字。一覧の中で「いま何を送っているか」の気配を伝えます。
      The most recent characters, giving a sense of what is being sent now. }
    Recent: string;
    { この局と交信したことがあるか（要件 FR-J.4）。記録が無ければ区別しません。

      **呼出符号が確かでないうちは、交信済みとは言いません。**1 文字違いの別人を
      「交信済み」と示すのは、示さないより悪いためです。判定は BuildBandEntries
      に渡された引き当ての手続きが行い、この層は記録の中身を知りません
      （要件 FR-K の段を足す先が同じ場所になります）。

      Whether this station has been worked before (requirement FR-J.4); with no
      log there is no distinction to draw.

      **Nothing is called worked while the call sign is not certain**: showing a
      station one letter away as already worked is worse than showing nothing.
      The lookup is done by the procedure handed to BuildBandEntries, and this
      layer knows nothing of the log's contents — which is where the further
      stages of FR-K will attach. }
    Worked: Boolean;
  end;
  TBandEntries = array of TBandEntry;

type
  { 交信済みかを引く手続き。記録そのものはここでは持ちません。**復号の側に
    記録の知識を持たせないためです**（要件 FR-K の第 3・4 段は外部の資料と通信を
    伴います）。nil を渡せば、交信済みの区別を付けません。
    The lookup for whether a station has been worked. The log itself is not held
    here, **so that the decoding side carries no knowledge of it** (the third and
    fourth stages of FR-K involve outside material and outside traffic). Passing
    nil draws no such distinction. }
  TWorkedLookup = function(const Callsign: string): Boolean of object;

{ 局ごとの読み取り結果を、一覧の行へ翻訳します。渡された引き当て以外に状態を
  持たず、同じ入力からは必ず同じ行が出ます。

  Translates the per-station results into rows. Beyond the lookup it is handed it
  holds no state, and the same input always gives the same rows. }
function BuildBandEntries(const Logs: TStationLogs; NowSeconds: Double;
  Worked: TWorkedLookup = nil): TBandEntries;

{ 確からしさを、運用者に見せる短い言葉にします。
  Puts the trust into the few words shown to the operator. }
function TrustCaption(Trust: TCallsignTrust): string;

implementation

{ 語に切る規則と、相手の符号を選ぶ規則は DeepCW.Exchange が持ちます。交信モードの
  記録も同じ規則で選ぶ必要があり、写しを 2 つ置くと食い違うためです。
  Splitting into words and choosing the station's call sign live in
  DeepCW.Exchange: the contact log has to choose by the same rule, and two
  copies would drift apart. }

{ 最後に CQ を送った時刻。無ければ負の値を返します。
  When CQ was last sent, or a negative value if never. }
function LastCallingSeconds(const Words: TWords): Double;
var
  I: Integer;
begin
  Result := -1;
  for I := 0 to High(Words) do
    if Words[I].Text = 'CQ' then
      Result := Words[I].Seconds;
end;

function BuildBandEntries(const Logs: TStationLogs; NowSeconds: Double;
  Worked: TWorkedLookup): TBandEntries;
var
  I: Integer;
  Words: TWords;
  Text: string;
  Calling: Double;
begin
  SetLength(Result, Length(Logs));
  for I := 0 to High(Logs) do
  begin
    Result[I].Id := Logs[I].Id;
    Result[I].Hz := Logs[I].Hz;
    Result[I].LevelDb := Logs[I].LevelDb;
    Result[I].HalfWidthHz := Logs[I].HalfWidthHz;
    Result[I].FirstSeconds := Logs[I].FirstSeconds;
    Result[I].LastSeconds := Logs[I].LastSeconds;
    Result[I].Heard := Logs[I].Heard;
    Result[I].Analysed := Logs[I].Analysed;
    Result[I].Cut := Logs[I].Heard and not Logs[I].Analysed;
    Result[I].Crowded := Logs[I].Crowded;

    Words := SplitWords(Logs[I].Chars);
    ChooseCallsign(Words, Result[I].Callsign, Result[I].Sightings,
      Result[I].Confidence);
    if Result[I].Callsign = '' then
      Result[I].Trust := ctNone
    else if Result[I].Sightings >= BANDMAP_AGREEMENT then
      Result[I].Trust := ctAgreed
    else
      Result[I].Trust := ctShape;

    Calling := LastCallingSeconds(Words);
    Result[I].Calling := (Calling >= 0) and
      (NowSeconds - Calling <= BANDMAP_CALLING_SECONDS);

    { 交信済みの区別は、呼出符号が確かなときだけ付けます。**確かでない符号で
      「交信済み」と示すのは、1 文字違いの別人をそう示すことです。**
      The worked distinction is drawn only for a certain call sign: **drawing it
      on an uncertain one draws it on whoever is one letter away.** }
    Result[I].Worked := Assigned(Worked) and
      (Result[I].Trust >= ctAgreed) and Worked(Result[I].Callsign);

    Text := DecodedText(Logs[I].Chars);
    if Length(Text) > BANDMAP_RECENT_CHARS then
      Text := Copy(Text, Length(Text) - BANDMAP_RECENT_CHARS + 1,
        BANDMAP_RECENT_CHARS);
    Result[I].Recent := Trim(Text);
  end;
end;

function TrustCaption(Trust: TCallsignTrust): string;
begin
  case Trust of
    ctShape: Result := '確認中';
    ctAgreed: Result := '一致';
    ctInRoster: Result := '一覧にあり';
    ctVerified: Result := '実在確認';
  else
    Result := '';
  end;
end;

end.
