unit DeepCW.Exchange;

{ 受信文から、交信に必要なものを読み取ります。

  交信で書き留めるのは、相手の呼出符号と、送られてきた RST の 2 つです。この
  単位は受信文をその 2 つへ翻訳し、**それぞれが受信文のどこにあったかも返します。**
  位置を返すのは、画面で下線を引くためです（要件 FR-E.1）。どの語を符号と見なした
  のかが見えなければ、利用者は機械の判断を確かめることも、直すこともできません。

  形の検査そのものは DeepCW.Callsign が持ちます。ここが足すのは「複数ある候補
  からどれを相手と見るか」という**解釈**です。この規則は待機モードの一覧
  （DeepCW.BandMap）と交信モードの記録で同じでなければなりません。同じ問いに
  別の答えを出す規則が 2 つあると、一覧に出た符号と記録した符号が食い違います。
  そのため、規則はここ 1 か所に置きます。

  Reads what a contact needs out of received text.

  What gets written down is the other station's call sign and the RST that was
  sent. This unit translates a transcript into those two, **and reports where in
  the transcript each was found.** The positions exist so the display can
  underline them (requirement FR-E.1): unless the operator can see which words
  the machine took for call signs, they can neither check its judgement nor
  correct it.

  The shape rule itself belongs to DeepCW.Callsign. What this unit adds is the
  **interpretation**: which of several candidates is the station being worked.
  That rule has to be the same one the band map uses (DeepCW.BandMap) and the
  one the contact log uses, or the call sign shown in the list and the call sign
  written to the log can disagree. So the rule lives here, once. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Math, DeepCW.Types, DeepCW.Decoder, DeepCW.Callsign,
  DeepCW.Reference;

type
  { 受信文を語に切ったときの 1 語。
    One word of a transcript. }
  TWord = record
    Text: string;
    { その語の文字のうち、いちばん低い確からしさ。1 文字でも怪しければ、その語は
      怪しい。
      The lowest character confidence in the word: one doubtful character makes
      the word doubtful. }
    Confidence: Single;
    Seconds: Double;
    { 文字配列上の位置。両端を含みます。画面はここへ下線を引きます。
      Where the word sits in the character array, both ends included; this is
      what the display underlines. }
    First: Integer;
    Last: Integer;
  end;
  TWords = array of TWord;

  { 受信文の中の、意味のあるひと続き。First が負なら「無い」を表します。
    A meaningful run inside the transcript; a negative First means none. }
  TExchangeSpan = record
    First: Integer;
    Last: Integer;
    Text: string;
  end;
  TExchangeSpans = array of TExchangeSpan;

  { 受信文から読み取ったもの。
    What was read out of a transcript. }
  TExchange = record
    { 形の合った符号すべて。画面はこれを下線で示します（要件 FR-E.1）。
      Every word fitting the call sign shape; the display underlines these
      (requirement FR-E.1). }
    Callsigns: TExchangeSpans;
    { 相手と見た符号が Callsigns の何番目か。無ければ負。
      Which of Callsigns is the station being worked, or negative for none. }
    Chosen: Integer;
    Callsign: string;
    { その符号が何回出たか、そのときの最も高い確からしさ。1 回きりのものを
      断定して見せないために要ります。
      How many times it appeared and the best confidence seen; needed so a
      call sign heard once is not presented as settled. }
    Sightings: Integer;
    Confidence: Single;
    { 送られてきた RST（要件 FR-E.2）。First が負なら聞こえていません。
      The RST that was sent (requirement FR-E.2); a negative First means it was
      not heard. }
    Rst: TExchangeSpan;
    { 見つかった参照番号（要件 FR-E.6）。位置は `Callsigns` と同じ数え方
      （復号文字の番号）です。
      The references found (requirement FR-E.6); the positions are counted as
      `Callsigns` counts, in decoded-character indices. }
    References: TReferences;
  end;

{ 受信文を語に切ります。空白が区切りです。
  Splits a transcript into words at the spaces. }
function SplitWords(const Chars: TDecodedChars): TWords;

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

{ 信号報告（RST）の形か。

  RST は 3 文字で、了解度 1〜5、信号強度 1〜9、音調 1〜9 です。短縮数字のうち
  受け付けるのは **N（9）だけ**にしてあります。599 を 5NN と送るのは日常ですが、
  T（0）や E（5）まで受け付けると、実際に送られる `EEE`（訂正の合図）を 555 と
  読み違えます。**読み違えるくらいなら読まないほうがよい**という判断です。

  Whether a token has the shape of a signal report.

  An RST is three characters: readability 1-5, strength 1-9, tone 1-9. Of the
  cut numbers only **N (nine)** is accepted. Sending 599 as 5NN is everyday
  practice, but accepting T (zero) or E (five) as well would read `EEE` -- the
  correction signal, actually sent on the air -- as 555. **Better to read
  nothing than to read it wrong.** }
function IsRst(const Token: string): Boolean;

{ 受信文をひととおり読み取ります。1 度の走査で済みます。
  Reads a transcript through in a single pass. }
function ReadExchange(const Chars: TDecodedChars): TExchange;

implementation

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
  Current.First := -1;
  Current.Last := -1;
  for I := 0 to High(Chars) do
    if Chars[I].Text = ' ' then
      Flush
    else
    begin
      if Current.Text = '' then
      begin
        Current.Confidence := 1;
        Current.Seconds := Chars[I].Seconds;
        Current.First := I;
      end;
      Current.Text := Current.Text + Chars[I].Text;
      Current.Confidence := Min(Current.Confidence, Chars[I].Confidence);
      { 1 文字が 1 要素なので、末尾はいま見ている番号です。多バイトの文字が
        来ても、文字列の桁ではなく配列の番号で数えているためずれません。
        One character is one element, so the end is simply the index in hand.
        Counting array positions rather than string offsets keeps this correct
        whatever the characters are. }
      Current.Last := I;
    end;
  Flush;
  SetLength(Result, Count);
end;

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

function IsRst(const Token: string): Boolean;

  { 短縮数字を数に直します。受け付けない文字は負を返します。
    Turns a cut number into its value, or a negative for anything not accepted. }
  function Value(C: Char): Integer;
  begin
    if (C >= '0') and (C <= '9') then
      Result := Ord(C) - Ord('0')
    else if C = 'N' then
      Result := 9
    else
      Result := -1;
  end;

begin
  Result := (Length(Token) = 3)
    and (Value(Token[1]) >= 1) and (Value(Token[1]) <= 5)
    and (Value(Token[2]) >= 1) and (Value(Token[2]) <= 9)
    and (Value(Token[3]) >= 1) and (Value(Token[3]) <= 9);
end;

function ReadExchange(const Chars: TDecodedChars): TExchange;
var
  Words: TWords;
  Named: TReferenceWords;
  I, Count, Taken, AfterUr, LastRst: Integer;
  Parsed: TCallsign;
begin
  Result.Callsigns := nil;
  Result.Chosen := -1;
  Result.Callsign := '';
  Result.Sightings := 0;
  Result.Confidence := 0;
  Result.Rst.First := -1;
  Result.Rst.Last := -1;
  Result.Rst.Text := '';
  Result.References := nil;

  Words := SplitWords(Chars);
  if Length(Words) = 0 then
    Exit;

  { 参照番号は、語をもう一度切り直さずに渡します。**切り直すと位置の数え方が
    変わり、画面の印がずれます。**
    The references are handed the words as already split: **splitting again
    would change what the positions count, and move the marks on screen.** }
  SetLength(Named, Length(Words));
  for I := 0 to High(Words) do
  begin
    Named[I].Text_ := Words[I].Text;
    Named[I].First := Words[I].First;
    Named[I].Last := Words[I].Last;
  end;
  Result.References := ExtractReferences(Named);

  ChooseCallsign(Words, Result.Callsign, Result.Sightings, Result.Confidence);

  SetLength(Result.Callsigns, Length(Words));
  Count := 0;
  AfterUr := -1;
  LastRst := -1;
  for I := 0 to High(Words) do
    if ParseCallsign(Words[I].Text, Parsed) then
    begin
      Result.Callsigns[Count].First := Words[I].First;
      Result.Callsigns[Count].Last := Words[I].Last;
      Result.Callsigns[Count].Text := Words[I].Text;
      { 選んだ符号は何度も出てきます。いちばん新しいものを指すことで、画面では
        直前に届いた 1 つが強く出ます。
        The chosen call sign appears several times; pointing at the most recent
        one puts the emphasis on the one that just arrived. }
      if Words[I].Text = Result.Callsign then
        Result.Chosen := Count;
      Inc(Count);
    end
    else if IsRst(Words[I].Text) then
    begin
      LastRst := I;
      if (I > 0) and ((Words[I - 1].Text = 'UR') or (Words[I - 1].Text = 'RST')) then
        AfterUr := I;
    end;
  SetLength(Result.Callsigns, Count);

  { どの RST を採るか。UR・RST の直後があればそれです。符号を DE の後ろから
    採るのと同じ考えで、送り手が「これがあなたの信号報告です」と明示した箇所を
    優先します。

    無ければ最後のものですが、**連なっている場合はその先頭へ戻ります。**
    コンテストでは `599 123` のように RST のあとへ連続番号が続き、番号のほうが
    RST の形に当てはまってしまうためです（要件 FR-I.5 で効きます）。

    Which RST to take. One directly after UR or RST wins, on the same reasoning
    as taking the call sign after DE: prefer the place where the sender said
    outright that this is your report.

    Otherwise the last one, **stepping back to the start of a run.** A contest
    exchange is sent as `599 123`, and the serial number fits the RST shape
    too (this matters for requirement FR-I.5). }
  Taken := AfterUr;
  if Taken < 0 then
  begin
    Taken := LastRst;
    while (Taken > 0) and IsRst(Words[Taken - 1].Text) do
      Dec(Taken);
  end;
  if Taken >= 0 then
  begin
    Result.Rst.First := Words[Taken].First;
    Result.Rst.Last := Words[Taken].Last;
    Result.Rst.Text := Words[Taken].Text;
  end;
end;

end.
