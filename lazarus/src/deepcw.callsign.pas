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

  19.68A は、特別な機会に 4 字を超える呼出符号を認めている。本実装はこれを
  受け付けない（付録 H.10）。

  The call sign form of ITU Radio Regulations Article 19, Section III, checked
  against the source text (fxm-art19-sec3). The provisions are quoted above:
  19.68 gives the amateur form, 19.68.1 the three-character prefix used for
  half series, 19.50 constrains the first two characters, and **19.69 exempts
  amateur stations from the prohibition on the digits 0 and 1.** Missing that
  one sentence would reject JA1ABC, K1ABC and G0ABC alike, so every digit from
  0 to 9 is accepted. 19.68A permits longer call signs on special occasions;
  this implementation does not accept them (appendix H.10). }
function ParseCallsign(const Token: string; out Call: TCallsign): Boolean;

{ 日本に割り当てられた前置符字か。JA〜JS、7J〜7N、8J・8N を扱います。
  Whether the prefix is one allocated to Japan: JA-JS, 7J-7N, 8J and 8N. }
function IsJapanesePrefix(const Prefix: string): Boolean;

{ テキストからコールサインらしい語をすべて取り出します。
  Pulls every callsign-shaped word out of a piece of text. }
function ExtractCallsigns(const Text: string): TCallsigns;

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

function ParseCallsign(const Token: string; out Call: TCallsign): Boolean;
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

    { 日本の後置符字は英字 1〜3 字です。ITU の形は満たしていても、日本の前置符字に
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

end.
