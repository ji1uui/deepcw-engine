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
  満たすなら分解して返します。

  前置符字は次のいずれかです。
    ・1 字。ただし ITU が 1 字で割り当てている B・F・G・I・K・M・N・R・W に限る
    ・2 字。英字＋英字／英字＋数字／数字＋英字（数字 2 つの組は存在しない）
  そのあとに地域番号 1 桁が続き、最後に 1〜4 字の後置符字が来ます。
  **後置符字には数字が入ってよく、末尾だけが英字でなければなりません。**

  3 字の前置符字（3DA0 など）はこの形に収まらないため扱いません。

  Checks the call sign form of ITU Radio Regulations Article 19, Section III,
  and takes it apart when it holds.

  The prefix is either one character, restricted to the letters ITU allocates
  singly (B, F, G, I, K, M, N, R, W), or two characters as letter-letter,
  letter-digit or digit-letter; a pair of digits does not occur. One area digit
  follows, then a suffix of one to four characters. **The suffix may contain
  digits; only its last character must be a letter.**

  The three-character prefixes such as 3DA0 do not fit this form and are not
  handled. }
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

{ ITU が 1 字だけで割り当てている前置符字です。ここを無制限にすると、
  どの国のものでもない `J1ADC` のような符号を通してしまいます。
  The prefixes ITU allocates as a single character. Leaving this unrestricted
  admits call signs belonging to no country, such as `J1ADC`. }
function AllocatedSingleLetter(Ch: Char): Boolean;
begin
  Result := Ch in ['B', 'F', 'G', 'I', 'K', 'M', 'N', 'R', 'W'];
end;

function ValidPrefix(const Prefix: string): Boolean;
begin
  Result := False;
  case Length(Prefix) of
    1: Result := AllocatedSingleLetter(Prefix[1]);
    { 数字 2 つの組は前置符字になりません。
      A pair of digits is never a prefix. }
    2: Result := (IsLetter(Prefix[1]) and IsLetter(Prefix[2])) or
                 (IsLetter(Prefix[1]) and IsDigit(Prefix[2])) or
                 (IsDigit(Prefix[1]) and IsLetter(Prefix[2]));
  end;
end;

function ParseCallsign(const Token: string; out Call: TCallsign): Boolean;
var
  Base, Appended, Prefix, Suffix: string;
  Slash, I, PrefixLength: Integer;
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

  if (Length(Base) < 3) or (Length(Base) > 7) then
    Exit;
  for I := 1 to Length(Base) do
    if not (IsLetter(Base[I]) or IsDigit(Base[I])) then
      Exit;

  { 前置符字は短いほうから試します。1 字で成立するのは割り当てのある 9 文字
    だけなので、2 字のものと取り違えることはありません。
    The shorter prefix is tried first; only the nine singly allocated letters
    can form one, so it cannot be confused with a two-character prefix. }
  for PrefixLength := 1 to 2 do
  begin
    if Length(Base) < PrefixLength + 2 then
      Break;
    Prefix := Copy(Base, 1, PrefixLength);
    if not ValidPrefix(Prefix) then
      Continue;
    if not IsDigit(Base[PrefixLength + 1]) then
      Continue;

    Suffix := Copy(Base, PrefixLength + 2, Length(Base) - PrefixLength - 1);
    if (Length(Suffix) < 1) or (Length(Suffix) > 4) then
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
