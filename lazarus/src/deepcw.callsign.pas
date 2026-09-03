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

{ コールサインとしての形を満たすかを調べ、満たすなら分解して返します。

  形は「前置符字 1〜2 字 ＋ 地域番号 1 字 ＋ 後置符字 1〜4 字」とします。
  3 字の前置符字（3DA0 など）はごく少数のため扱いません。

  Checks the callsign shape and takes it apart when it holds. The shape is a
  one or two character prefix, one area digit, and one to four letters. The
  handful of three-character prefixes such as 3DA0 are not handled. }
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

function ParseCallsign(const Token: string; out Call: TCallsign): Boolean;
var
  Base, Appended: string;
  Slash, I, J, PrefixLength: Integer;
  HasLetter: Boolean;
begin
  Result := False;
  FillChar(Call, SizeOf(Call), 0);
  Call.Text := '';
  Call.Base := '';
  Call.Prefix := '';
  Call.Suffix := '';
  Call.Appended := '';

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

  { 地域番号は、そのあとが英字だけで 1〜4 字になる位置の数字です。前から順に
    見て最初に条件を満たすところを採ります。JA1ABC なら 3 文字目です。

    The area digit is the digit after which only letters follow, one to four
    of them. The first position that satisfies this is taken; in JA1ABC that
    is the third character. }
  for I := 2 to 3 do
  begin
    if I > Length(Base) then
      Break;
    if not IsDigit(Base[I]) then
      Continue;
    PrefixLength := I - 1;
    HasLetter := False;
    for J := 1 to PrefixLength do
      if IsLetter(Base[J]) then
        HasLetter := True;
    { 前置符字には英字が要ります。数字だけの前置符字はありません。
      A prefix needs a letter; there is no all-digit prefix. }
    if not HasLetter then
      Continue;
    if Length(Base) - I < 1 then
      Continue;
    if Length(Base) - I > 4 then
      Continue;
    for J := I + 1 to Length(Base) do
      if not IsLetter(Base[J]) then
        Exit;

    Call.Text := Token;
    Call.Base := Base;
    Call.Prefix := Copy(Base, 1, PrefixLength);
    Call.Area := Base[I];
    Call.Suffix := Copy(Base, I + 1, Length(Base) - I);
    Call.Appended := Appended;
    Call.Japanese := IsJapanesePrefix(Call.Prefix);
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
