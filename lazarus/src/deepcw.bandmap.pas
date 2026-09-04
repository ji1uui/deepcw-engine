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
  SysUtils, Math, DeepCW.Types, DeepCW.Decoder, DeepCW.Callsign, DeepCW.Multi;

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
    { いま解析の対象になっているか（要件 FR-I.7）。False の行は、局が消えたのでは
      なく能力の都合で読んでいません。
      Whether it is being analysed (requirement FR-I.7). A row that is false is
      not a station that stopped but one there was no capacity to read. }
    Analysed: Boolean;
    { この音程に畳み込まれた別の峰の数（要件 FR-J.6）。0 より大きい行は、
      1 局として読んだふりをせず「密集」と示してください。
      How many peaks were folded into this pitch (requirement FR-J.6). A row
      greater than zero must be shown as crowded rather than pretending to have
      read one station. }
    Crowded: Integer;
    { 直近の文字。一覧の中で「いま何を送っているか」の気配を伝えます。
      The most recent characters, giving a sense of what is being sent now. }
    Recent: string;
  end;
  TBandEntries = array of TBandEntry;

{ 局ごとの読み取り結果を、一覧の行へ翻訳します。純粋な変換で、状態を持ちません。
  同じ入力からは必ず同じ行が出ます。

  Translates the per-station results into rows. It is a pure transformation with
  no state: the same input always gives the same rows. }
function BuildBandEntries(const Logs: TStationLogs;
  NowSeconds: Double): TBandEntries;

{ 確からしさを、運用者に見せる短い言葉にします。
  Puts the trust into the few words shown to the operator. }
function TrustCaption(Trust: TCallsignTrust): string;

implementation

type
  { 受信文を語に切ったときの 1 語。/ One word of a transcript. }
  TWord = record
    Text: string;
    { その語の文字のうち、いちばん低い確からしさ。1 文字でも怪しければ、その語は
      怪しい。
      The lowest character confidence in the word: one doubtful character makes
      the word doubtful. }
    Confidence: Single;
    Seconds: Double;
  end;
  TWords = array of TWord;

{ 受信文を語に切ります。空白が区切りです。
  Splits a transcript into words at the spaces. }
function SplitWords(const Chars: TDecodedChars): TWords;
var
  I, Count: Integer;
  Current: TWord;

  procedure Flush;
  begin
    if Current.Text = '' then
      Exit;
    if Count = Length(Result) then
      SetLength(Result, Max(16, Count * 2));
    Result[Count] := Current;
    Inc(Count);
    Current.Text := '';
  end;

begin
  Result := nil;
  Count := 0;
  Current.Text := '';
  Current.Confidence := 1;
  Current.Seconds := 0;
  for I := 0 to High(Chars) do
    if Chars[I].Text = ' ' then
      Flush
    else
    begin
      if Current.Text = '' then
      begin
        Current.Confidence := 1;
        Current.Seconds := Chars[I].Seconds;
      end;
      Current.Text := Current.Text + Chars[I].Text;
      Current.Confidence := Min(Current.Confidence, Chars[I].Confidence);
    end;
  Flush;
  SetLength(Result, Count);
end;

{ その局の呼出符号を選びます。

  候補は、形の規則（要件 FR-K 第 1 段、ITU 無線通信規則 第 19 条）に合う語です。
  複数あるときは **DE の直後を優先します。**交信では「相手 DE 自分」と送るのが
  決まりなので、DE の後ろが送信している局です。DE が無ければ、いちばん多く出た
  ものを採ります。

  Chooses the station's call sign.

  A candidate is a word fitting the shape rule (requirement FR-K, first stage;
  ITU Radio Regulations Article 19). Where there are several, **the one after DE
  wins**: a contact is sent as "them DE us", so what follows DE is the station
  transmitting. With no DE, the most frequent candidate is taken. }
procedure ChooseCallsign(const Words: TWords; out Callsign: string;
  out Sightings: Integer; out Confidence: Single);
type
  { 候補ごとの集計。候補の種類は少数なので、これで足ります。
    The tally for one candidate; there are only ever a few kinds. }
  TCandidate = record
    Text: string;
    Count: Integer;
    Best: Single;
  end;
var
  Tally: array of TCandidate;
  I, J, Found, Total: Integer;
  Parsed: TCallsign;
  AfterDe: string;
begin
  Callsign := '';
  Sightings := 0;
  Confidence := 0;
  AfterDe := '';
  Total := 0;

  { 語を 1 度だけ走査して、形の合うものを数え上げます。候補ごとに数えるやり方
    （候補の数 × 語の数）にすると、長い受信文で目に見えて遅くなります。
    A single pass over the words tallies those that fit the shape. Counting each
    candidate against every word instead would be visibly slow on a long
    transcript. }
  for I := 0 to High(Words) do
  begin
    if not ParseCallsign(Words[I].Text, Parsed) then
      Continue;
    Found := -1;
    for J := 0 to Total - 1 do
      if Tally[J].Text = Words[I].Text then
      begin
        Found := J;
        Break;
      end;
    if Found < 0 then
    begin
      if Total = Length(Tally) then
        SetLength(Tally, Max(8, Total * 2));
      Tally[Total].Text := Words[I].Text;
      Tally[Total].Count := 0;
      Tally[Total].Best := 0;
      Found := Total;
      Inc(Total);
    end;
    Inc(Tally[Found].Count);
    Tally[Found].Best := Max(Tally[Found].Best, Words[I].Confidence);
    { DE の直後なら、送信している局の符号です。いちばん新しいものを覚えます。
      Directly after a DE it is the transmitting station's own call sign; the most
      recent one is remembered. }
    if (I > 0) and (Words[I - 1].Text = 'DE') then
      AfterDe := Words[I].Text;
  end;

  if Total = 0 then
    Exit;

  if AfterDe <> '' then
    Callsign := AfterDe
  else
  begin
    { DE が無ければ、いちばん多く出たもの。同数なら後から見つかったほう。
      With no DE, the most frequent; the later one on a tie. }
    Found := 0;
    for J := 1 to Total - 1 do
      if Tally[J].Count >= Tally[Found].Count then
        Found := J;
    Callsign := Tally[Found].Text;
  end;

  for J := 0 to Total - 1 do
    if Tally[J].Text = Callsign then
    begin
      Sightings := Tally[J].Count;
      Confidence := Tally[J].Best;
      Break;
    end;
end;

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

function BuildBandEntries(const Logs: TStationLogs;
  NowSeconds: Double): TBandEntries;
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
    Result[I].Analysed := Logs[I].Analysed;
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
