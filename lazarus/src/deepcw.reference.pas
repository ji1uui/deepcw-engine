unit DeepCW.Reference;

{ 受信文の中の参照番号（POTA の公園符号、SOTA の山岳符号）を見つけます
  （要件 FR-E.6）。

  **このエンジンはハイフンを読めません。**モデルの文字集合は
  `, . / 0-9 ? A-Z` と空白だけで、ハイフンはそこにありません。ところが
  POTA の公園符号は `JP-0123`、SOTA の山岳符号は `JA/NN-015` と、どちらも
  ハイフンを含みます。

  では何と読めるのか。**推測せず、電波に乗せて測りました**（付録 AN）。

  | 送った符号 | 読めた文字 |
  | --- | --- |
  | `JP-0123` | `JP6T0123` |
  | `JA/NN-015` | `JA/NN6T015` |

  ハイフン `-....-` は、**`6`（`-....`）と `T`（`-`）の 2 文字**として読まれます。
  符号内の間隔が文字の切れ目として読まれるためです。

  だから、この単位が探すのは `JP-0123` ではなく **`JP6T0123`** です。
  規則は実測に合わせます。合わせなければ、実際の受信文には当たりません。

  見つけたものは `JP-0123` の形に直して返しますが、**ハイフンはこちらが
  補ったものです。**そうと分かるように `Trust` を付けます。

  Finds the references in a transcript -- POTA parks and SOTA summits
  (requirement FR-E.6).

  **This engine cannot read a hyphen**: the model's alphabet is `, . / 0-9 ? A-Z`
  and space, and the hyphen is not in it -- while a POTA park is `JP-0123` and a
  SOTA summit `JA/NN-015`, both of which carry one.

  So what does one read as? **Not guessed: sent over the air and measured**
  (appendix AN). A hyphen `-....-` reads as the **two characters `6` and `T`**,
  the gaps inside it being read as breaks between characters.

  What this unit looks for is therefore not `JP-0123` but **`JP6T0123`**. The
  rule follows the measurement; anything else would not match what arrives.

  What is found is returned in the `JP-0123` form, but **the hyphen is ours**,
  and `Trust` says as much. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, DeepCW.Types;

type
  TReferenceKind = (
    rkPota,   { POTA の公園符号 / a POTA park }
    rkSota    { SOTA の山岳符号 / a SOTA summit }
  );

  { どれだけ確かか。**ハイフンが送られていたかどうか**で分かれます。
    How sure: it turns on **whether the hyphen was sent.** }
  TReferenceTrust = (
    { 区切りが送られていなかった（`JP0123`）。こちらがハイフンを入れた位置は
      推測です。
      No separator was sent (`JP0123`): where we put the hyphen is a guess. }
    rtLoose,
    { ハイフンが送られていた、または POTA・SOTA と添えられていた。
      A hyphen was sent, or POTA/SOTA introduced it. }
    rtMarked
  );

  TReference = record
    Kind: TReferenceKind;
    { `JP-0123` の形。**ハイフンはこちらが補ったもの**です。
      In the `JP-0123` form -- **the hyphen being ours.** }
    Text_: string;
    { 受信文に出ていたままの形。**補う前を残します。**
      As it stood in the transcript: **what it was before we filled anything
      in.** }
    Raw: string;
    Trust: TReferenceTrust;
    { 受信文の中の位置（0 起点、`SplitWords` と同じ数え方）。
      Where it sits in the transcript, zero-based, counted as `SplitWords`
      counts. }
    First: Integer;
    Last: Integer;
  end;
  TReferences = array of TReference;

  { 語ひとつ。**位置は呼ぶ側の数え方のまま返します。**

    受信文は既に `DeepCW.Exchange` が語へ切っており、呼出符号の下線もその位置で
    引かれています。ここで切り直すと、**語の切れ目を決める場所が 2 つになります。**
    2 つある規則は、いつか食い違います。そうなったとき、参照番号の印だけが
    呼出符号の下線とずれた場所に出ます。

    だから切り直さず、語を切った側が位置を持ち込み、この単位はそれをそのまま
    返します。同じ問いには 1 か所で答える、という単位全体の決め方
    （DeepCW.Exchange の冒頭）と同じです。

    One word: **the positions are whatever the caller counts in.**

    The transcript has already been split into words by `DeepCW.Exchange`, and
    the call sign underlines are drawn at those positions. Splitting again here
    would make **two places decide where a word begins**, and two rules
    eventually disagree -- at which point the reference marks alone would sit
    somewhere the underlines do not.

    So nothing is split again: the caller brings the positions and they are
    handed back untouched. It is the same choice the unit headers make (see the
    top of DeepCW.Exchange): one question, answered in one place. }
  TReferenceWord = record
    Text_: string;
    First: Integer;
    Last: Integer;
  end;
  TReferenceWords = array of TReferenceWord;

const
  { ハイフンが読めた形。**実測（付録 AN）**。
    What a hyphen reads as -- **measured** (appendix AN). }
  REFERENCE_HYPHEN_AS_READ = '6T';

  { 参照番号の前に置かれる語。**添えられていれば、空白だけの区切りでも確かと
    見ます。**
    The words that introduce a reference: **with one of them in front, even a
    space is enough to be sure.** }
  REFERENCE_KEYWORDS: array[0..4] of string = ('POTA', 'SOTA', 'PARK', 'SUMMIT', 'REF');

{ 受信文から参照番号を取り出します。語の区切りは空白です。位置は文字列の桁
  （0 起点）です。
  Pulls the references out of a transcript, words separated by spaces; the
  positions are zero-based offsets into the string. }
function ExtractReferences(const Text: string): TReferences; overload;

{ 既に語へ切ってあるものから取り出します。**位置は渡されたものをそのまま
  返します。**
  Pulls them from words already split, **handing back the positions given.** }
function ExtractReferences(const Words: TReferenceWords): TReferences; overload;

{ 画面に出す短い言葉。確かでないものには `?` を付けます。
  The few words shown; an uncertain one carries a `?`. }
function ReferenceCaption(const Ref: TReference): string;

implementation

function IsLetter(Ch: Char): Boolean;
begin
  Result := (Ch >= 'A') and (Ch <= 'Z');
end;

function IsDigit(Ch: Char): Boolean;
begin
  Result := (Ch >= '0') and (Ch <= '9');
end;

function AllDigits(const Value: string; Least, Most: Integer): Boolean;
var
  I: Integer;
begin
  Result := (Length(Value) >= Least) and (Length(Value) <= Most);
  if not Result then
    Exit;
  for I := 1 to Length(Value) do
    if not IsDigit(Value[I]) then
      Exit(False);
end;

{ 実体の前置符字らしいか（`JP`、`K`、`VE`、`4X` など）。**英字を 1 つは
  含むこと**を求めます。数字だけなら、それは信号報告か通し番号です。
  Whether it looks like an entity prefix -- `JP`, `K`, `VE`, `4X`. **At least one
  letter** is required: all digits would be a report or a serial. }
function LooksLikePrefix(const Value: string): Boolean;
var
  I: Integer;
  Letters: Integer;
begin
  Result := False;
  if (Length(Value) < 1) or (Length(Value) > 4) then
    Exit;
  Letters := 0;
  for I := 1 to Length(Value) do
  begin
    if IsLetter(Value[I]) then
      Inc(Letters)
    else if not IsDigit(Value[I]) then
      Exit;
  end;
  Result := Letters > 0;
end;

{ 山岳符号の前半（`JA/NN`）らしいか。/ Whether it looks like `JA/NN`. }
function LooksLikeSummitArea(const Value: string): Boolean;
var
  Slash: Integer;
  Region: string;
begin
  Result := False;
  Slash := Pos('/', Value);
  if (Slash < 2) or (Slash > 4) then
    Exit;
  if not LooksLikePrefix(Copy(Value, 1, Slash - 1)) then
    Exit;
  Region := Copy(Value, Slash + 1, Length(Value) - Slash);
  Result := (Length(Region) = 2) and IsLetter(Region[1]) and IsLetter(Region[2]);
end;

function SplitTokens(const Text: string): TReferenceWords;
var
  I, Start_, Count: Integer;
begin
  SetLength(Result, Length(Text) div 2 + 2);
  Count := 0;
  I := 1;
  while I <= Length(Text) do
  begin
    while (I <= Length(Text)) and (Text[I] = ' ') do
      Inc(I);
    if I > Length(Text) then
      Break;
    Start_ := I;
    while (I <= Length(Text)) and (Text[I] <> ' ') do
      Inc(I);
    if Count = Length(Result) then
      SetLength(Result, Count * 2);
    Result[Count].Text_ := Copy(Text, Start_, I - Start_);
    Result[Count].First := Start_ - 1;
    Result[Count].Last := I - 2;
    Inc(Count);
  end;
  SetLength(Result, Count);
end;

function IsKeyword(const Value: string): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := Low(REFERENCE_KEYWORDS) to High(REFERENCE_KEYWORDS) do
    if REFERENCE_KEYWORDS[I] = Value then
      Exit(True);
end;

function ExtractReferences(const Words: TReferenceWords): TReferences;
var
  Tokens: TReferenceWords;
  I, Count, At_: Integer;
  Body, Head, Tail: string;
  Introduced: Boolean;

  procedure Keep(Kind: TReferenceKind; const Canonical, Raw_: string;
    Trust: TReferenceTrust; First, Last: Integer);
  begin
    if Count = Length(Result) then
      SetLength(Result, Count + 4);
    Result[Count].Kind := Kind;
    Result[Count].Text_ := Canonical;
    Result[Count].Raw := Raw_;
    Result[Count].Trust := Trust;
    Result[Count].First := First;
    Result[Count].Last := Last;
    Inc(Count);
  end;

  { 区切りを取り除いた残りを返します。区切りが在ったかどうかを `Marked` で
    返します。
    The remainder with the separator removed; `Marked` says whether there was
    one. }
  function StripSeparator(const Value: string; out Marked: Boolean): string;
  begin
    Marked := False;
    Result := Value;
    At_ := Pos(REFERENCE_HYPHEN_AS_READ, Result);
    if At_ > 1 then
    begin
      Marked := True;
      Result := Copy(Result, 1, At_ - 1) +
        Copy(Result, At_ + Length(REFERENCE_HYPHEN_AS_READ),
          Length(Result));
      Exit;
    end;
    At_ := Pos('-', Result);
    if At_ > 1 then
    begin
      Marked := True;
      Result := Copy(Result, 1, At_ - 1) + Copy(Result, At_ + 1, Length(Result));
    end;
  end;

  { 1 語のなかに収まっている形を見ます。/ The forms that fit inside one word. }
  function TryOneWord(Index_: Integer): Boolean;
  var
    Marked: Boolean;
    Stripped, Digits_, Area: string;
    Cut: Integer;
  begin
    Result := False;
    Stripped := StripSeparator(Tokens[Index_].Text_, Marked);

    { 山岳符号 `JA/NN-015` / a summit }
    Cut := Pos('/', Stripped);
    if Cut > 0 then
    begin
      Area := Copy(Stripped, 1, Cut + 2);
      Digits_ := Copy(Stripped, Cut + 3, Length(Stripped));
      if LooksLikeSummitArea(Area) and AllDigits(Digits_, 3, 3) then
      begin
        Keep(rkSota, Area + '-' + Digits_, Tokens[Index_].Text_,
          TReferenceTrust(Ord(Marked or Introduced)),
          Tokens[Index_].First, Tokens[Index_].Last);
        Exit(True);
      end;
      Exit;
    end;

    { 公園符号 `JP-0123`。後ろから 4〜5 桁を切り出します。
      A park: four or five digits taken off the end. }
    for Cut := 4 to 5 do
    begin
      if Length(Stripped) <= Cut then
        Continue;
      Digits_ := Copy(Stripped, Length(Stripped) - Cut + 1, Cut);
      Head := Copy(Stripped, 1, Length(Stripped) - Cut);
      if AllDigits(Digits_, Cut, Cut) and LooksLikePrefix(Head) then
      begin
        Keep(rkPota, Head + '-' + Digits_, Tokens[Index_].Text_,
          TReferenceTrust(Ord(Marked or Introduced)),
          Tokens[Index_].First, Tokens[Index_].Last);
        Exit(True);
      end;
    end;
  end;

  { 2 語に分かれている形を見ます（`POTA JP 0123`）。**POTA・SOTA と添えられて
    いるときだけ**受け取ります。

    はじめは添え言葉なしでも受け取り、確かさを低いほうにしていました。
    **測ったら、それでは通らないと分かりました。**コンテストの交信文
    `UR RST 579 579 NR 0123 NR 0123 K` に当てると、通し番号 `NR 0123` が
    公園符号 `NR-0123` として 2 回出ます（付録 AN）。

    形だけを見れば、`JP 0123` と `NR 0123` は同じものです。ハイフンも添え言葉も
    無い以上、**区別する手がかりが受信文の中に無い。**受入基準は
    「誤検出率が実用範囲」（FR-E.6）なので、手がかりの無いものは取りません。

    The forms split over two words -- **taken only when POTA or SOTA introduces
    them.**

    At first these were taken without an introducing word, at the weaker trust.
    **Measurement said no:** against the contest exchange
    `UR RST 579 579 NR 0123 NR 0123 K` the serial `NR 0123` comes out twice as
    the park `NR-0123` (appendix AN).

    By shape alone `JP 0123` and `NR 0123` are the same thing. With neither a
    hyphen nor an introducing word, **the transcript holds nothing to tell them
    apart**, and the acceptance criterion is a practical false-positive rate
    (FR-E.6) -- so what carries no evidence is not taken. }
  function TryTwoWords(Index_: Integer): Boolean;
  begin
    Result := False;
    if (Index_ >= High(Tokens)) or (not Introduced) then
      Exit;
    Head := Tokens[Index_].Text_;
    Tail := Tokens[Index_ + 1].Text_;
    if LooksLikeSummitArea(Head) and AllDigits(Tail, 3, 3) then
    begin
      Keep(rkSota, Head + '-' + Tail, Head + ' ' + Tail, rtMarked,
        Tokens[Index_].First, Tokens[Index_ + 1].Last);
      Exit(True);
    end;
    if LooksLikePrefix(Head) and AllDigits(Tail, 4, 5) then
    begin
      Keep(rkPota, Head + '-' + Tail, Head + ' ' + Tail, rtMarked,
        Tokens[Index_].First, Tokens[Index_ + 1].Last);
      Exit(True);
    end;
  end;

begin
  Result := nil;
  Count := 0;
  Tokens := Words;
  I := 0;
  while I <= High(Tokens) do
  begin
    { 直前の語が POTA・SOTA なら、空白だけの区切りでも確かと見ます。
      With POTA or SOTA in front, even a space is enough. }
    Introduced := (I > 0) and IsKeyword(Tokens[I - 1].Text_);
    if TryOneWord(I) then
      Inc(I)
    else if TryTwoWords(I) then
      Inc(I, 2)
    else
      Inc(I);
  end;
  SetLength(Result, Count);
end;

function ExtractReferences(const Text: string): TReferences;
begin
  Result := ExtractReferences(SplitTokens(Text));
end;

function ReferenceCaption(const Ref: TReference): string;
begin
  case Ref.Kind of
    rkSota: Result := 'SOTA ' + Ref.Text_;
  else
    Result := 'POTA ' + Ref.Text_;
  end;
  { 確かでないものは、そうと分かる形で出します（要件 FR-J.7 と同じ考え方）。
    An uncertain one is shown as uncertain, as a call sign is (FR-J.7). }
  if Ref.Trust = rtLoose then
    Result := Result + ' ?';
end;

end.
