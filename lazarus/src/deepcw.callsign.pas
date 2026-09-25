unit DeepCW.Callsign;

{ 復号したテキストから、コールサインらしい語を取り出して形を確かめます。

  復号の誤りは、コールサインの上でだけ性質が違います。本文なら 1 文字違っても
  読めますが、コールサインは 1 文字違えば別の局です。そこで、まず形で確かめ、
  形が壊れているものは表に出しません（要件 FR-E.1、FR-J.7）。

  ここで行うのは**形の検査だけ**です。実在するかどうかは別の話であり、
  この単位では扱いません。形が正しいことは、正しいことを意味しません。

  Pulls callsign-shaped words out of decoded text and checks their shape.

  An error behaves differently on a callsign than anywhere else: a message
  survives one wrong character, a callsign becomes a different station. So the
  shape is checked first and anything malformed is kept off the display
  (requirements FR-E.1, FR-J.7).

  **Only the shape is checked here.** Whether the station exists is a separate
  question this unit does not touch; a well-formed callsign is not a correct
  one. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, DeepCW.Types;

type
  { 分解したコールサイン。/ A callsign taken apart. }
  TCallsign = record
    Text: string;      { 附加符号を含む全体 / the whole thing, suffix included }
    Base: string;      { 附加符号を除いた本体 / without the appended designator }
    Prefix: string;    { 前置符字 / the prefix }
    Area: Char;        { 地域番号 / the area digit }
    Suffix: string;    { 後置符字 / the letters after the digit }
    Appended: string;  { 「/1」「/P」など / "/1", "/P" and the like }
    Japanese: Boolean; { 日本に割り当てられた前置符字か / a Japanese prefix }
    { 19.68A の特別な形として読んだか（`ParseSpecialCallsign`、付録 BX）。
      Whether it was read in the special form of 19.68A
      (`ParseSpecialCallsign`, appendix BX). }
    Special: Boolean;
  end;
  TCallsigns = array of TCallsign;

{ ITU 無線通信規則 第 19 条 第 III 節の呼出符号の構成を満たすかを調べ、
  満たすなら分解して返します。原文（fxm-art19-sec3）で確認した規定は次のとおりです。

  19.68 アマチュア局および実験局
    「1 字（ただし B・F・G・I・K・M・N・R・W のいずれかであること）と 1 桁の数字、
      そのあとに 4 字を超えない文字群（末尾は英字であること）、または
      2 字と 1 桁の数字、そのあとに 4 字を超えない文字群（末尾は英字であること）」
  19.68.1 半系列（最初の 2 字が複数の主管庁に割り当てられている場合）
    「3 字＋ 1 桁の数字＋ 3 字を超えない文字群（末尾は英字）」
  19.50 最初の 2 字は「英字＋英字」「英字＋数字」「数字＋英字」のいずれか
  19.69 「ただし数字 0 および 1 の使用禁止は、アマチュア局には適用しない」

  **19.68 の本文には「0 または 1 以外の 1 桁の数字」とあるが、19.69 がアマチュア局を
  明示的に除外している。**この 1 文を読み落とすと、JA1ABC も K1ABC も G0ABC も
  弾いてしまう。地域番号は 0〜9 のすべてを受け付ける。

  19.68A は、特別な機会に 4 字を超える呼出符号を認めている。**ここでは受け付け
  ません**。形の決まりが無く、一律に通せば復号の誤りまで通すためです。特別な
  形は `ParseSpecialCallsign` が別に見ます（付録 BX）。

  The call sign form of ITU Radio Regulations Article 19, Section III, checked
  against the source text (fxm-art19-sec3). The provisions are quoted above:
  19.68 gives the amateur form, 19.68.1 the three-character prefix used for
  half series, 19.50 constrains the first two characters, and **19.69 exempts
  amateur stations from the prohibition on the digits 0 and 1.** Missing that
  one sentence would reject JA1ABC, K1ABC and G0ABC alike, so every digit from
  0 to 9 is accepted. 19.68A permits longer call signs on special occasions;
  **they are not accepted here**: 19.68A gives no form, and passing them all
  would pass decoding errors too. `ParseSpecialCallsign` checks the special
  form separately (appendix BX). }
function ParseCallsign(const Token: string; out Call: TCallsign): Boolean;

{ 19.68A の特別な呼出符号（記念局など、`GB100RSGB`・`TM100TDF`）の形を見ます
  （未解決 #19、付録 BX）。**`ParseCallsign` が拒むものだけ**を対象にし、
  通常の形に合うものには偽を返します。

  19.68A は「特別な機会には 4 字を超えるものを認めうる」とだけ言い、形を
  定めていません。ここでは次のように絞ります。

  - 前置符字は 19.68 の 1 字（B・F・G・I・K・M・N・R・W）か、19.50 の 2 字
    （3 字の枝は使わない）
  - 続けて数字 1〜4 桁、そのあと**英字だけ**の後置符字 1〜7 字
  - **19.68 を超えるところがある**（数字が 2 桁以上か、後置符字が 5 字以上）
  - **日本の前置符字は対象にしない**（後置符字は英字 1〜3 字。要件 FR-K.1a）
  - 国別前置符字表（要件 FR-K.12）は、ほかと同じく締めるだけ

  **受信文から拾うときは、これだけで信じないでください。**`TU599K`（`TU 599 K`
  が繋がったもの）もこの形に合います。受信文では **DE の直後に出たときだけ**
  認めます（`DeepCW.Exchange`）。利用者が書いた一覧（待ち符号・手元の一覧）は、
  利用者の根拠があるのでそのまま受け付けます。

  Checks the form of a 19.68A special call sign (commemorative stations and
  the like: `GB100RSGB`, `TM100TDF`) (open question #19, appendix BX). **Only
  what `ParseCallsign` rejects** is considered; a token of the ordinary form
  returns false.

  19.68A says only that more than four characters may be allowed on special
  occasions and gives no form. It is narrowed here: a prefix of 19.68's one
  letter (B, F, G, I, K, M, N, R, W) or 19.50's two characters (the
  three-character branch is not used); then one to four digits and a suffix
  of one to seven **letters only**; **something beyond 19.68** (two or more
  digits, or a suffix of five or more); **no Japanese prefix** (a Japanese
  suffix is one to three letters, FR-K.1a); and the country prefix table
  (FR-K.12) only tightens, as elsewhere.

  **Do not believe this alone for text off the air**: `TU599K` (`TU 599 K` run
  together) fits it too. In received text it is accepted **only directly after
  DE** (`DeepCW.Exchange`). Lists the operator wrote (watched calls, roster)
  carry the operator's own grounds and are accepted as they are. }
function ParseSpecialCallsign(const Token: string; out Call: TCallsign): Boolean;

{ 通常の形か、19.68A の特別な形のどちらかに合うか。**利用者が書いた一覧を
  読むときだけ**使います（待ち符号・手元の一覧・記録の鍵）。受信文には使わない
  でください（`ParseSpecialCallsign` の注意）。
  Whether it fits the ordinary form or the special form of 19.68A. **Only for
  lists the operator wrote** (watched calls, roster, log keys); not for text
  off the air (see `ParseSpecialCallsign`). }
function ParseOperatorCallsign(const Token: string; out Call: TCallsign): Boolean;

{ **形だけ**を見ます。国別前置符字表（要件 FR-K.12）を通しません。

  受信文から符号を拾うときは `ParseCallsign` を使ってください。こちらは、
  **こちらが組み立てたものを確かめる**ときのものです。

  分けた理由は実測です。練習の出題は、組み立てた符号を規則に通したものだけを
  採ります（教訓 10.30）。ところが表を入れると `ParseCallsign` が締まるため、
  **出題の既定値 `JA1ABC` までが「規則に通らない符号」になりました。**
  利用者が狭い表を選んだだけで、練習に実在しない形が出ることになります。

  **表は「受信文に出てきた符号を信じてよいか」の道具であって、「こちらが作る
  符号が正しい形か」の道具ではありません。**用途が違うので、入口を分けます。

  Checks **the form alone**, without the country prefix table (requirement
  FR-K.12).

  Use `ParseCallsign` for call signs pulled out of received text; this one is
  for **checking what we built ourselves.**

  The split came from a measurement. Practice exercises take only what the rule
  accepts (lesson 10.30) -- but with a table loaded, `ParseCallsign` tightens
  and **even the fallback exercise `JA1ABC` became a call sign the rule
  rejects.** A narrow table chosen by the operator would put unreal forms into
  the practice.

  **The table answers "may a call sign seen on the air be believed", not "is a
  call sign we are building well formed."** Different questions, separate
  doors. }
function ParseCallsignShape(const Token: string; out Call: TCallsign): Boolean;

{ 日本に割り当てられた前置符字か。JA〜JS、7J〜7N、8J・8N を扱います。
  Whether the prefix is one allocated to Japan: JA-JS, 7J-7N, 8J and 8N. }
function IsJapanesePrefix(const Prefix: string): Boolean;

{ テキストからコールサインらしい語をすべて取り出します。
  Pulls every callsign-shaped word out of a piece of text. }
function ExtractCallsigns(const Text: string): TCallsigns;

{ 国別前置符字表を入れ替えます（要件 FR-K.12）。

  この単位が持っている前置符字の規則は、ITU 第 19 条の**形**だけを見ています。
  形は満たすがどの国にも割り当てられていない前置符字（`QZ`・`XQ9` など）は、
  表が無いかぎり通ります。とくに 3 字の枝は「どれが半系列かは国別の表がなければ
  分からない」という理由で**規定より緩く**してあります。

  **表は締めるだけで、緩めません。**形の規則が拒むものは、表に載っていても
  通りません。**一覧が壊れていても、読めない符号が読めるようにはならない**
  という保証です。

  **表が空のあいだは、何も変わりません。**「表に無い」と「表が無い」を同じ顔で
  扱ってはいけません（要件 FR-K.4 と同じ考え方）。

  UI スレッドから、利用者がファイルを選んだときに呼んでください。読み取りの
  途中で入れ替えないでください。排他は持ちません。

  Replaces the country prefix table (requirement FR-K.12).

  The prefix rule in this unit checks only **the form** of Article 19. A prefix
  that fits the form but is allocated to no country (`QZ`, `XQ9`) passes unless
  a table says otherwise; the three-character branch in particular is
  **deliberately looser than the provision**, since which prefixes are half
  series cannot be known without a country table.

  **The table only tightens, never loosens**: what the form rule rejects stays
  rejected however the table reads. That is the guarantee that **a damaged list
  can never make an unreadable call sign readable.**

  **An empty table changes nothing.** "Not in the table" and "there is no table"
  must not wear the same face (the reasoning of requirement FR-K.4).

  Call it from the interface thread when the operator picks a file, not while
  reading is under way; it holds no lock. }
procedure SetAllocatedPrefixes(const Items: array of string);

{ 表に入っている前置符字の数。0 なら表は使われていません。
  How many prefixes the table holds; zero means it is not in use. }
function AllocatedPrefixCount: Integer;

{ その前置符字が、どこかの国に割り当てられているか。**表が無ければ、いつでも
  真を返します**——知らないことを「割り当てられていない」の証拠にしません。
  Whether the prefix is allocated to some country. **With no table it is always
  true**: not knowing is not evidence of not being allocated. }
function PrefixAllocated(const Prefix: string): Boolean;

{ 呼出符号を、引き当ての鍵に使う形へ直します。附加符号（`/P`・`/1`）を落とし、
  大文字にします。形として成立しないものは、そのまま大文字にして返します。
  **その符号は運用者のものであり、こちらの規則に合わないという理由で捨ててよい
  ものではありません。**

  規則をここに置くのは、**引き当てる側が複数あるため**です。交信記録
  （`DeepCW.Log` の `LogKeyOf`）と、手元の一覧（`DeepCW.Roster`、要件 FR-K.9）が
  同じ鍵で引けなければ、**片方だけが当たる符号ができます。**形の規則はこの単位に
  あるので、そこから作る鍵もここに置きます。

  Puts a call sign into the form used as a lookup key: the appended designator
  (`/P`, `/1`) removed and upper case. Anything that does not fit the shape rule
  is returned upper-cased as it stands -- **that call sign belongs to the
  operator and is not ours to discard for failing our rule.**

  The rule lives here because **more than one thing looks call signs up**: the
  contact log (`LogKeyOf` in `DeepCW.Log`) and a locally held roster
  (`DeepCW.Roster`, requirement FR-K.9). Keyed differently, **a call sign would
  be found by one and missed by the other.** The shape rule is in this unit, so
  the key built from it belongs here too. }
function CallsignKey(const Token: string): string;

implementation

function IsLetter(Ch: Char): Boolean;
begin
  Result := (Ch >= 'A') and (Ch <= 'Z');
end;

function IsDigit(Ch: Char): Boolean;
begin
  Result := (Ch >= '0') and (Ch <= '9');
end;

function IsJapanesePrefix(const Prefix: string): Boolean;
begin
  Result := False;
  if Length(Prefix) <> 2 then
    Exit;
  { JA〜JS。JB と JC はアマチュアに割り当てられていませんが、ここでは形の
    検査に留め、実在の確認は行いません。
    JA to JS. JB and JC are not allocated to amateurs, but this is a shape
    check and does not confirm that a station exists. }
  if (Prefix[1] = 'J') and (Prefix[2] >= 'A') and (Prefix[2] <= 'S') then
    Exit(True);
  if (Prefix[1] = '7') and (Prefix[2] >= 'J') and (Prefix[2] <= 'N') then
    Exit(True);
  { 8J と 8N は記念局・特別局に使われます。
    8J and 8N are used for commemorative and special stations. }
  if (Prefix[1] = '8') and ((Prefix[2] = 'J') or (Prefix[2] = 'N')) then
    Exit(True);
end;

{ 19.68 が 1 字の前置符字として認める文字です。ここを無制限にすると、どの国の
  ものでもない `J1ADC` のような符号を通してしまいます。

  なお 19.50.1 の脚注は「B, F, G, I, K, M, N, R, W および 2」を挙げますが、
  こちらは**国籍識別に必要な文字数**の話であって、呼出符号の構成ではありません。
  19.68 の列挙に数字の 2 は含まれないため、ここでも含めません。

  The letters 19.68 accepts as a one-character prefix. Leaving this
  unrestricted admits call signs belonging to no country, such as `J1ADC`.
  Footnote 19.50.1 lists "B, F, G, I, K, M, N, R, W and 2", but that concerns
  how many characters identify nationality, not how a call sign is formed;
  19.68 does not include the digit 2, so neither does this. }
function AllocatedSingleLetter(Ch: Char): Boolean;
begin
  Result := Ch in ['B', 'F', 'G', 'I', 'K', 'M', 'N', 'R', 'W'];
end;

{ 19.50「最初の 2 字は、英字 2 字、英字＋数字、数字＋英字のいずれか」。
  19.50: the first two characters are two letters, a letter and a digit, or a
  digit and a letter. }
function ValidFirstTwo(const Prefix: string): Boolean;
begin
  Result := (IsLetter(Prefix[1]) and IsLetter(Prefix[2])) or
            (IsLetter(Prefix[1]) and IsDigit(Prefix[2])) or
            (IsDigit(Prefix[1]) and IsLetter(Prefix[2]));
end;

var
  { 割り当てのある前置符字。並べ替えて重複を除いてあります。
    The allocated prefixes, sorted and deduplicated. }
  AllocatedPrefixes: array of string;

procedure SetAllocatedPrefixes(const Items: array of string);
var
  I, J, Kept: Integer;
  Swap, Value: string;
begin
  AllocatedPrefixes := nil;
  Kept := 0;
  SetLength(AllocatedPrefixes, Length(Items));
  for I := Low(Items) to High(Items) do
  begin
    Value := UpperCase(Trim(Items[I]));
    if Value <> '' then
    begin
      AllocatedPrefixes[Kept] := Value;
      Inc(Kept);
    end;
  end;
  SetLength(AllocatedPrefixes, Kept);
  { 表は数百件なので、挿入法で足ります。呼出符号の一覧（数十万件）とは桁が
    違います（要件 FR-K.12 の「一覧より小さく、更新も稀」）。
    The table runs to hundreds, so an insertion sort is enough -- an order apart
    from the call sign roster's hundreds of thousands (requirement FR-K.12 says
    it is smaller and rarely updated). }
  for I := 1 to Kept - 1 do
  begin
    Swap := AllocatedPrefixes[I];
    J := I - 1;
    while (J >= 0) and (AllocatedPrefixes[J] > Swap) do
    begin
      AllocatedPrefixes[J + 1] := AllocatedPrefixes[J];
      Dec(J);
    end;
    AllocatedPrefixes[J + 1] := Swap;
  end;
  J := 0;
  for I := 0 to Kept - 1 do
    if (J = 0) or (AllocatedPrefixes[I] <> AllocatedPrefixes[J - 1]) then
    begin
      AllocatedPrefixes[J] := AllocatedPrefixes[I];
      Inc(J);
    end;
  SetLength(AllocatedPrefixes, J);
end;

function AllocatedPrefixCount: Integer;
begin
  Result := Length(AllocatedPrefixes);
end;

function PrefixAllocated(const Prefix: string): Boolean;
var
  Low_, High_, Middle: Integer;
  Key: string;
begin
  { **表が無ければ、いつでも真。**知らないことを根拠にしません。
    **No table, always true**: not knowing is not grounds for anything. }
  Result := True;
  if Length(AllocatedPrefixes) = 0 then
    Exit;
  Key := UpperCase(Trim(Prefix));
  Low_ := 0;
  High_ := High(AllocatedPrefixes);
  while Low_ <= High_ do
  begin
    Middle := (Low_ + High_) div 2;
    if AllocatedPrefixes[Middle] = Key then
      Exit(True)
    else if AllocatedPrefixes[Middle] < Key then
      Low_ := Middle + 1
    else
      High_ := Middle - 1;
  end;
  Result := False;
end;

function ValidPrefix(const Prefix: string): Boolean;
begin
  Result := False;
  case Length(Prefix) of
    1: Result := AllocatedSingleLetter(Prefix[1]);
    2: Result := ValidFirstTwo(Prefix);
    { 19.68.1 の半系列。3 字目は英字・数字のどちらでもよい（3DA0 など）。
      どの前置符字が半系列かは国別の表がなければ分からないため、この分岐は
      規定より緩い。表を持てば締められる（要件 FR-K.12）。

      The half series of 19.68.1. The third character may be a letter or a
      digit, as in 3DA0. Which prefixes are half series cannot be known without
      a country table, so this branch is looser than the provision; the table
      would tighten it (requirement FR-K.12). }
    3: Result := ValidFirstTwo(Copy(Prefix, 1, 2)) and
                 (IsLetter(Prefix[3]) or IsDigit(Prefix[3])) and
                 { 日本は半系列ではないので、日本の前置符字で始まるものに
                   3 字の分岐を許してはいけません。これを外していたために、
                   実測で `JM4GHI` が `JMG5I` と読まれて通ってしまいました。
                   知っている国が増えるほどここは締まります（要件 FR-K.12）。

                   Japan is not a half series, so a token starting with a
                   Japanese prefix must not take the three-character branch.
                   Without this, measurement had JM4GHI read as JMG5I and
                   accepted. Every country the table knows tightens this
                   further (requirement FR-K.12). }
                 (not IsJapanesePrefix(Copy(Prefix, 1, 2)));
  end;
end;

function ParseCallsignShape(const Token: string; out Call: TCallsign): Boolean;
var
  Base, Appended, Prefix, Suffix: string;
  Slash, I, PrefixLength, MaxSuffix: Integer;
begin
  Result := False;
  Call.Text := '';
  Call.Base := '';
  Call.Prefix := '';
  Call.Area := #0;
  Call.Suffix := '';
  Call.Appended := '';
  Call.Japanese := False;
  Call.Special := False;

  if (Length(Token) < 3) or (Length(Token) > 12) then
    Exit;

  { 「JA1ABC/1」「JH2XYZ/P」のような附加符号を切り離します。
    Split off an appended designator such as "/1" or "/P". }
  Slash := Pos('/', Token);
  if Slash > 0 then
  begin
    Base := Copy(Token, 1, Slash - 1);
    Appended := Copy(Token, Slash + 1, Length(Token) - Slash);
    if (Length(Appended) < 1) or (Length(Appended) > 3) then
      Exit;
    for I := 1 to Length(Appended) do
      if not (IsLetter(Appended[I]) or IsDigit(Appended[I])) then
        Exit;
  end
  else
  begin
    Base := Token;
    Appended := '';
  end;

  if (Length(Base) < 3) or (Length(Base) > 8) then
    Exit;
  for I := 1 to Length(Base) do
    if not (IsLetter(Base[I]) or IsDigit(Base[I])) then
      Exit;

  { 前置符字は短いほうから試します。1 字で成立するのは 19.68 が挙げる 9 文字
    だけなので、長いものと取り違えることはありません。
    The shorter prefix is tried first; only the nine letters 19.68 names can
    form a one-character prefix, so it cannot be confused with a longer one. }
  for PrefixLength := 1 to 3 do
  begin
    if Length(Base) < PrefixLength + 2 then
      Break;
    Prefix := Copy(Base, 1, PrefixLength);
    if not ValidPrefix(Prefix) then
      Continue;
    { 19.69 により、アマチュア局では地域番号に 0 と 1 も使えます。
      By 19.69, amateur stations may use 0 and 1 as the digit. }
    if not IsDigit(Base[PrefixLength + 1]) then
      Continue;

    Suffix := Copy(Base, PrefixLength + 2, Length(Base) - PrefixLength - 1);
    { 19.68 は 4 字まで、19.68.1（3 字の前置符字）は 3 字まで。
      19.68 allows four characters, 19.68.1 with its three-character prefix
      allows three. }
    if PrefixLength = 3 then
      MaxSuffix := 3
    else
      MaxSuffix := 4;
    if (Length(Suffix) < 1) or (Length(Suffix) > MaxSuffix) then
      Continue;
    { 末尾は必ず英字です。途中に数字が入るのは差し支えありません。
      The last character is always a letter; digits may appear before it. }
    if not IsLetter(Suffix[Length(Suffix)]) then
      Continue;

    Call.Text := Token;
    Call.Base := Base;
    Call.Prefix := Prefix;
    Call.Area := Base[PrefixLength + 1];
    Call.Suffix := Suffix;
    Call.Appended := Appended;
    Call.Japanese := IsJapanesePrefix(Prefix);

    { 日本の後置符字は英字 1〜3 字です（要件 FR-K.1a）。ITU の形は満たしていても、日本の前置符字に
      4 字の後置符字や数字入りの後置符字が続く組は使われていません。国が分かる
      場合にだけ効く、もう一段の絞り込みです（付録 H.5）。

      A Japanese suffix is one to three letters. Such a call would satisfy the
      ITU form, but a Japanese prefix is not paired with a four-character or
      digit-bearing suffix in practice. This narrowing applies only where the
      country is known (appendix H.5). }
    if Call.Japanese then
    begin
      if Length(Suffix) > 3 then
        Exit(False);
      for I := 1 to Length(Suffix) do
        if not IsLetter(Suffix[I]) then
          Exit(False);
    end;
    Exit(True);
  end;
end;

function ExtractCallsigns(const Text: string): TCallsigns;
var
  Words: TStringList;
  Call: TCallsign;
  Count, I: Integer;
begin
  Result := nil;
  Words := TStringList.Create;
  try
    Words.Delimiter := ' ';
    Words.StrictDelimiter := True;
    Words.DelimitedText := Text;
    SetLength(Result, Words.Count);
    Count := 0;
    for I := 0 to Words.Count - 1 do
      if ParseCallsign(Words[I], Call) then
      begin
        Result[Count] := Call;
        Inc(Count);
      end;
    SetLength(Result, Count);
  finally
    Words.Free;
  end;
end;


{ 形を見たうえで、**どの国にも割り当てられていない前置符字を弾きます**
  （要件 FR-K.12）。

  **表は締めるだけです。**`and` で足しているので、形が拒んだものが表で通ることは
  ありません。表が空なら `PrefixAllocated` は真を返すので、何も変わりません。

  Checks the form, then **rejects a prefix allocated to no country**
  (requirement FR-K.12).

  **The table only tightens**: added with `and`, it can never pass what the form
  rejected, and with an empty table `PrefixAllocated` is true, so nothing
  changes. }
function ParseCallsign(const Token: string; out Call: TCallsign): Boolean;
begin
  Result := ParseCallsignShape(Token, Call) and PrefixAllocated(Call.Prefix);
end;

function ParseSpecialCallsign(const Token: string; out Call: TCallsign): Boolean;
const
  MAX_DIGITS = 4;
  MAX_SUFFIX = 7;
var
  Base, Appended, Prefix, Suffix: string;
  Slash, I, PrefixLength, Digits: Integer;
  OnlyLetters, Pair: Boolean;
begin
  Result := False;
  Call.Special := False;
  { 特別な形は、数字が 2 つ続くか（2 桁以上）、7 字以上（1 字＋数字 1 桁＋
    後置符字 5 字）のどちらかです。どちらでもなければ、通常の形の検査より前に
    安く弾きます。受信文の DE の後ろの語はほとんどこれで済みます（付録 BX.4）。
    The special form has two digits in a row (two or more digits) or is seven
    characters or longer (one letter, one digit, a five-letter suffix). Anything
    else is turned away cheaply, before the ordinary check; most words after DE
    in received text end here (appendix BX.4). }
  Pair := False;
  for I := 2 to Length(Token) do
    if IsDigit(Token[I - 1]) and IsDigit(Token[I]) then
    begin
      Pair := True;
      Break;
    end;
  if (not Pair) and (Length(Token) < 7) then
  begin
    Call.Text := '';
    Call.Base := '';
    Call.Prefix := '';
    Call.Area := #0;
    Call.Suffix := '';
    Call.Appended := '';
    Call.Japanese := False;
    Exit;
  end;
  { 通常の形に合うものは特別ではありません。/ The ordinary form is not special. }
  if ParseCallsignShape(Token, Call) then
  begin
    Call.Text := '';
    Call.Base := '';
    Call.Prefix := '';
    Call.Area := #0;
    Call.Suffix := '';
    Call.Appended := '';
    Call.Japanese := False;
    Exit;
  end;

  Slash := Pos('/', Token);
  if Slash > 0 then
  begin
    Base := Copy(Token, 1, Slash - 1);
    Appended := Copy(Token, Slash + 1, Length(Token) - Slash);
    if (Length(Appended) < 1) or (Length(Appended) > 3) then
      Exit;
    for I := 1 to Length(Appended) do
      if not (IsLetter(Appended[I]) or IsDigit(Appended[I])) then
        Exit;
  end
  else
  begin
    Base := Token;
    Appended := '';
  end;
  if (Length(Base) < 5) or (Length(Base) > 2 + MAX_DIGITS + MAX_SUFFIX) then
    Exit;

  for PrefixLength := 1 to 2 do
  begin
    Prefix := Copy(Base, 1, PrefixLength);
    if not ValidPrefix(Prefix) then
      Continue;
    if IsJapanesePrefix(Prefix) then
      Continue;
    { 1 字の前置符字の直後に数字が続くなら、数字はそこから始まります。2 字目の
      数字を前置符字に取り込んで数え直すと、`G12345ABC`（数字 5 桁）が `G1` と
      4 桁として通ってしまいます（試験で見つけた穴）。
      When a one-letter prefix is followed by a digit, the digits start there.
      Re-reading with the second character folded into the prefix let
      `G12345ABC` (five digits) through as `G1` and four digits (a hole the
      test found). }
    if (PrefixLength = 2) and IsDigit(Base[2]) and
      ValidPrefix(Copy(Base, 1, 1)) then
      Continue;
    Digits := 0;
    while (PrefixLength + Digits + 1 <= Length(Base)) and
      IsDigit(Base[PrefixLength + Digits + 1]) do
      Inc(Digits);
    if (Digits < 1) or (Digits > MAX_DIGITS) then
      Continue;
    Suffix := Copy(Base, PrefixLength + Digits + 1, Length(Base));
    if (Length(Suffix) < 1) or (Length(Suffix) > MAX_SUFFIX) then
      Continue;
    OnlyLetters := True;
    for I := 1 to Length(Suffix) do
      if not IsLetter(Suffix[I]) then
        OnlyLetters := False;
    if not OnlyLetters then
      Continue;
    { 19.68 を超えるところが無ければ、特別な形ではありません（通常の形で
      拒まれた別の理由があるはずです）。
      Nothing beyond 19.68 means it is not the special form (the ordinary rule
      must have rejected it for some other reason). }
    if (Digits < 2) and (Length(Suffix) < 5) then
      Continue;
    if not PrefixAllocated(Prefix) then
      Continue;
    Call.Text := Token;
    Call.Base := Base;
    Call.Prefix := Prefix;
    Call.Area := Base[PrefixLength + 1];
    Call.Suffix := Suffix;
    Call.Appended := Appended;
    Call.Japanese := False;
    Call.Special := True;
    Exit(True);
  end;
end;

function ParseOperatorCallsign(const Token: string; out Call: TCallsign): Boolean;
begin
  Result := ParseCallsign(Token, Call) or ParseSpecialCallsign(Token, Call);
end;

function CallsignKey(const Token: string): string;
var
  Parsed: TCallsign;
begin
  Result := UpperCase(Trim(Token));
  { 特別な形も本体に直します。`GB100RSGB/P` と `GB100RSGB` を同じ局として
    引けるように（付録 BX）。
    The special form is reduced to its body too, so that `GB100RSGB/P` and
    `GB100RSGB` are looked up as one station (appendix BX). }
  if ParseOperatorCallsign(Result, Parsed) then
    Result := Parsed.Base;
end;

end.
