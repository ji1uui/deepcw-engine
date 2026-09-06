unit DeepCW.Watch;

{ 待っている呼出符号を、聞こえた符号と突き合わせます（要件 FR-I.4）。

  待機モードの目的は「指定した呼出符号が呼ばれるのを待つ」ことです。受入基準は
  **「見逃さない。誤検知は確信度で抑える」**の 2 つで、この 2 つは逆を向きます。
  緩くすれば見逃さない代わりに誤って知らせ、厳しくすれば誤らない代わりに見逃します。

  **どちらへ倒すかは測って決めました**（付録 T.2）。1 文字違いまで知らせる規則も
  書いて測りましたが、見逃しを 1 件救う代わりに誤報を 9 件出しました。しかも救えた
  のは文字誤り率 0.25 の信号で、**知らせても交信は成立しません。**採りませんでした。

    採る    完全一致した符号だけ
    採らない  1 文字違い（誤報 9 件で見逃し 1 件を救う割に合わない）

  「誤検知は確信度で抑える」ほうは、**一覧に出せる確かさに達した行だけを知らせる**
  ことで満たします（`TCallsignTrust` が `ctAgreed` 以上、すなわち 2 回以上一致）。
  測定では、完全一致した 4 回すべてがこの確かさに達していたので、**見逃しは
  増えません。**一覧の表示規則（要件 FR-J.7）と同じ規則を使うため、画面に出ている
  符号と知らせる符号が食い違うこともありません。

  この単位が持つのは**照合だけ**です。確かさで絞るのは一覧の層、知らせ方は画面の
  層が受け持ちます。

  Matches the call signs being waited for against the ones heard
  (requirement FR-I.4).

  The waiting mode exists to wait for a named call sign to be called. Its two
  acceptance criteria -- **do not miss it, and hold false alarms down with
  confidence** -- pull in opposite directions: loose never misses but cries wolf,
  strict never cries wolf but misses.

  **Which way to lean was measured** (appendix T.2). A rule accepting anything
  one character out was written and measured too: it rescued one miss at the
  cost of nine false alarms, and what it rescued was a signal at a character
  error rate of 0.25, where **announcing it would not lead to a contact.** It was
  not adopted.

  The other half -- holding false alarms down with confidence -- is met by
  announcing only rows that reached the trust required to appear in the list at
  all (`TCallsignTrust` of `ctAgreed` or better, meaning agreed twice). In the
  measurement all four exact matches had reached it, so **nothing is missed by
  requiring it.** Using the same rule as the list's display (requirement FR-J.7)
  also keeps the call sign announced from disagreeing with the one on screen.

  This unit holds **the matching alone**: filtering by trust belongs to the list
  layer and announcing to the display layer. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Math, DeepCW.Types, DeepCW.Callsign;

type
  TWatchedCalls = array of string;

  { 一度知らせた局を覚えておき、同じ局で鳴り続けないようにします。

    局の番号は検出が続いている間ずっと同じで、消えて出直せば新しい番号になります
    （`DeepCW.Stations` の `TTrackedStation.Id`）。**番号で覚えれば、同じ呼び出しでは
    一度だけ、出直した局には改めて知らせる**という振る舞いがそのまま得られます。

    Remembers the stations already announced so the same one does not keep
    ringing.

    A station keeps its number for as long as it stays detected and takes a new
    one if it drops and returns (`TTrackedStation.Id` in `DeepCW.Stations`).
    **Remembering by number gives exactly the wanted behaviour**: once per call,
    and again for a station that came back. }
  TWatchAlerts = class
  private
    FSeen: array of Int64;
    FCount: Integer;
  public
    { まだ知らせていなければ True を返し、知らせたものとして覚えます。
      Returns True when this one has not been announced yet, and remembers it. }
    function Announce(Id: Int64): Boolean;
    { 受信をやり直したときに忘れます。局の番号も振り直されるためです。
      Forgets everything when reception restarts, since the numbers restart too. }
    procedure Reset;
    function Count: Integer;
  end;

{ 利用者が書いた一覧を符号の並びにします。空白・読点・改行のどれでも区切れます。
  綴りは大文字に揃え、形の検査に通らないものは落とします。**通らないものを黙って
  待ち続けると、いつまでも知らせが来ない理由が分かりません。**落とした数は
  呼ぶ側が数えられるよう、入力の語数と結果の数の差で分かるようにしてあります。

  Turns what the operator typed into a list of call signs. Spaces, commas and
  line breaks all separate. Spelling is folded to upper case and anything failing
  the shape check is dropped: **waiting silently on something that can never
  match leaves no way to tell why nothing is ever announced.** The count of what
  was dropped is recoverable by the caller as the difference between the words
  given and the entries returned. }
function ParseWatchList(const Text: string): TWatchedCalls;

{ 入力に含まれていた語の数。ParseWatchList の結果と比べると、いくつ落ちたかが
  分かります。
  How many words the input held; comparing with the result of ParseWatchList
  says how many were dropped. }
function CountWatchWords(const Text: string): Integer;

{ 2 つの符号が何文字違うか。3 を超えるところまでは数えず、3 を返します。

  **照合そのものには使いません。**採らなかった「1 文字違いまで知らせる」規則が
  どれだけの誤報と引き換えだったかを測るために、`cw_tune --tests watch` が使います。
  規則を後から緩めようとしたとき、その代償が数字で出るようにしてあります。

  How many characters apart two call signs are, stopping at three.

  **It is not used by the matching itself.** `cw_tune --tests watch` uses it to
  measure what the rejected "announce anything one character out" rule would have
  cost in false alarms, so that loosening the rule later shows its price in
  numbers. }
function CallsignDistance(const A, B: string): Integer;

{ 聞こえた符号が待っている符号のどれかに**完全一致**すれば、その符号を返します。
  当たらなければ空を返します。

  比べるのは**附加符号を除いた本体**です。JA1ABC を待っているとき JA1ABC/P が
  呼んできたら、待っていた局です。交信記録が同じ扱いをするのに合わせています。

  Returns the watched call sign **exactly** matched by one heard, or empty.

  The comparison is on the **body without the appended designator**: waiting for
  JA1ABC, a call from JA1ABC/P is the station waited for. This matches how the
  contact log treats them. }
function MatchedWatch(const Callsign: string;
  const Watched: TWatchedCalls): string;

implementation

{ 区切りとして扱う文字。/ The characters treated as separators. }
function IsSeparator(C: Char): Boolean;
begin
  Result := (C = ' ') or (C = ',') or (C = #9) or (C = #13) or (C = #10)
    or (C = ';');
end;

function SplitWatchWords(const Text: string): TStringList;
var
  I: Integer;
  Current: string;
begin
  Result := TStringList.Create;
  Current := '';
  for I := 1 to Length(Text) do
    if IsSeparator(Text[I]) then
    begin
      if Current <> '' then
      begin
        Result.Add(Current);
        Current := '';
      end;
    end
    else
      Current := Current + Text[I];
  if Current <> '' then
    Result.Add(Current);
end;

function CountWatchWords(const Text: string): Integer;
var
  Words: TStringList;
begin
  Words := SplitWatchWords(Text);
  try
    Result := Words.Count;
  finally
    Words.Free;
  end;
end;

function ParseWatchList(const Text: string): TWatchedCalls;
var
  Words: TStringList;
  I, J, Count: Integer;
  Call: TCallsign;
  Body: string;
  Duplicate: Boolean;
begin
  Result := nil;
  Words := SplitWatchWords(Text);
  try
    SetLength(Result, Words.Count);
    Count := 0;
    for I := 0 to Words.Count - 1 do
    begin
      if not ParseCallsign(UpperCase(Words[I]), Call) then
        Continue;
      { 覚えるのは本体だけです。待つ側が JA1ABC/P と書いても、待っているのは
        JA1ABC です。
        Only the body is kept: written as JA1ABC/P, what is waited for is still
        JA1ABC. }
      Body := Call.Base;
      Duplicate := False;
      for J := 0 to Count - 1 do
        if Result[J] = Body then
        begin
          Duplicate := True;
          Break;
        end;
      if Duplicate then
        Continue;
      Result[Count] := Body;
      Inc(Count);
    end;
    SetLength(Result, Count);
  finally
    Words.Free;
  end;
end;

function CallsignDistance(const A, B: string): Integer;
const
  ENOUGH = 3;
var
  Previous, Current: array of Integer;
  I, J, Cost, Best: Integer;
begin
  if A = B then
    Exit(0);
  { 長さが 2 文字以上違えば、置き換えても挿入しても 2 手では届きません。
    数える前に打ち切れます。
    Two or more characters apart in length cannot be bridged in fewer than two
    edits, so the count can be cut short before it starts. }
  if Abs(Length(A) - Length(B)) >= ENOUGH then
    Exit(ENOUGH);

  SetLength(Previous, Length(B) + 1);
  SetLength(Current, Length(B) + 1);
  for J := 0 to Length(B) do
    Previous[J] := J;

  for I := 1 to Length(A) do
  begin
    Current[0] := I;
    Best := Current[0];
    for J := 1 to Length(B) do
    begin
      if A[I] = B[J] then
        Cost := 0
      else
        Cost := 1;
      Current[J] := Min(Min(Current[J - 1] + 1, Previous[J] + 1),
        Previous[J - 1] + Cost);
      Best := Min(Best, Current[J]);
    end;
    { その行のどこも ENOUGH 以上なら、これ以上どう進んでも下がりません。
      With every cell in the row at ENOUGH or more, nothing further can bring it
      back down. }
    if Best >= ENOUGH then
      Exit(ENOUGH);
    Previous := Copy(Current);
  end;
  Result := Min(Previous[Length(B)], ENOUGH);
end;

{ 聞こえた符号の本体。形の検査に通らなければ、そのまま大文字にして返します。
  待つ側の一覧は検査済みなので、比べる相手として不足はありません。
  The body of a call sign heard, or simply the upper-cased text when it fails the
  shape check: the watched list is already checked, so it remains a sound thing
  to compare against. }
function BodyOf(const Callsign: string): string;
var
  Call: TCallsign;
begin
  if ParseCallsign(UpperCase(Callsign), Call) then
    Result := Call.Base
  else
    Result := UpperCase(Callsign);
end;

function MatchedWatch(const Callsign: string;
  const Watched: TWatchedCalls): string;
var
  I: Integer;
  Body: string;
begin
  Result := '';
  if (Callsign = '') or (Length(Watched) = 0) then
    Exit;
  Body := BodyOf(Callsign);
  for I := 0 to High(Watched) do
    if Body = Watched[I] then
      Exit(Watched[I]);
end;

function TWatchAlerts.Announce(Id: Int64): Boolean;
var
  I: Integer;
begin
  for I := 0 to FCount - 1 do
    if FSeen[I] = Id then
      Exit(False);
  if FCount = Length(FSeen) then
    SetLength(FSeen, Max(16, FCount * 2));
  FSeen[FCount] := Id;
  Inc(FCount);
  Result := True;
end;

procedure TWatchAlerts.Reset;
begin
  FSeen := nil;
  FCount := 0;
end;

function TWatchAlerts.Count: Integer;
begin
  Result := FCount;
end;

end.
