unit DeepCW.Roster;

{ 利用者が用意した呼出符号の一覧を読み、通信せずに照合します（要件 FR-K.9）。

  **同梱はしません。**配られている一覧の再配布可否は分かりません（未解決 #15）。
  読むのは利用者が自分で置いたファイルだけです。

  **通信もしません。**照合は手元のファイルとの突き合わせで完結します。だから
  相手先の都合にも、回線の有無にも左右されません（要件 FR-K.10）。

  **符号のほかは何も残しません。**配られている一覧には名前や常置場所が並んで
  いることがあります。読むのは各行の最初の語だけで、**残りはその場で捨てます**
  （要件 FR-K.7）。

  読めなくても受信は止めません。開けない、壊れている、空である——どれも
  「照合できない」であって、「受信できない」ではありません。**無いことを誤りの
  根拠にもしません**（要件 FR-K.4 と同じ考え方）。

  Reads a call sign roster the operator supplied, and matches against it without
  any traffic (requirement FR-K.9).

  **Nothing is bundled**: whether the distributed rosters may be redistributed
  is not known (open question #15), so the only file read is one the operator
  put there.

  **Nothing is sent.** Matching is done entirely against the local file, so it
  depends on neither a remote service nor a connection (requirement FR-K.10).

  **Nothing but the call sign is kept.** A distributed roster may carry names
  and addresses; only the first word of each line is read and **the rest is
  dropped where it stands** (requirement FR-K.7).

  A file that cannot be read does not stop reception. Missing, damaged or
  empty -- each of those means "cannot match", not "cannot receive". **Nor is
  absence taken as evidence of error** (the reasoning of requirement FR-K.4). }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, DeepCW.Callsign;

type
  TStringArray = array of string;

const
  { 読み込む上限。**上限を超えたら、超えたと言います。**黙って途中で止めると、
    一覧に在る符号が「無い」と出て、しかもなぜかが分かりません。

    5000 万バイトは、1 行 10 バイトとして 500 万件にあたります。配られている
    一覧（数万〜数十万件）には十分で、誤って巨大なファイルを選んだときには
    止まります。

    The cap on what is read. **Passing it is said out loud**: stopping quietly
    partway would report call signs that are in the roster as absent, with
    nothing to say why.

    Fifty million bytes is five million entries at ten bytes a line -- ample for
    the distributed rosters, which run to tens or hundreds of thousands, and a
    stop for a file chosen by mistake. }
  ROSTER_MAX_BYTES = 50 * 1000 * 1000;

type
  { 手元の呼出符号一覧。

    UI スレッドから読み込み、どのスレッドからでも引けます。読み込みのあいだは
    引かないでください。排他は持ちません——**読み込むのは利用者がファイルを
    選んだときだけ**で、受信中に入れ替わるものではありません。

    A locally held call sign roster.

    Loaded from the interface thread and read from any thread; do not read it
    while it loads, as it holds no lock -- **loading happens only when the
    operator picks a file**, not while receiving. }
  TCallsignRoster = class
  private
    { 並べ替えて重複を除いた鍵の列。二分探索で引きます。**引くのは 1 行ごとで
      はなく、画面を描くたびに何度もなので、線形に探すと一覧が重くなります。**
      The keys, sorted and deduplicated, searched by halving. **A lookup happens
      many times per repaint rather than once per line, and a linear scan would
      make the list heavy.** }
    FKeys: array of string;
    FCount: Integer;
    FName: string;
    FLastError: string;
    FSkipped: Integer;
    FTruncated: Boolean;
    procedure Take(const Text: string);
  public
    { ファイルを読みます。**例外は投げません。**読めなければ `LastError` に
      理由が入り、件数は 0 になります（要件 FR-K.10）。
      Reads the file. **Nothing is raised**: what went wrong goes into
      `LastError` and the count is zero (requirement FR-K.10). }
    procedure LoadFromFile(const FileName: string;
      MaxBytes: Int64 = ROSTER_MAX_BYTES);
    { 読み込んだものを捨てます。/ Drops what was loaded. }
    procedure Clear;
    { その符号が一覧に在るか。**空の一覧は、いつも「無い」ではなく「引けない」
      です。**呼ぶ側は `Count` が 0 なら照合そのものを行いません。
      Whether the call sign is in the roster. **An empty roster means "cannot
      look up", not "not there"**: the caller does no matching at all when
      `Count` is zero. }
    function Contains(const Callsign: string): Boolean;
    { 読み込んだ符号の数（重複を除いたあと）。
      How many call signs were loaded, duplicates removed. }
    property Count: Integer read FCount;
    { 画面に出す一覧の名前。**path ではなくファイル名だけ**を持ちます。
      作業場所の path には利用者の名前が入ることがあります（要件 FR-K.7）。
      The roster's name as shown. **The file name alone, never the path**: a
      path can carry the operator's own name (requirement FR-K.7). }
    property Name: string read FName;
    property LastError: string read FLastError;
    { 呼出符号として読めなかった行の数。**捨てた数は数えます。**
      How many lines held nothing that reads as a call sign. **What is dropped
      is counted.** }
    property Skipped: Integer read FSkipped;
    { 上限で打ち切ったか（要件 FR-K.9 の「読み込める」を偽らないため）。
      Whether the cap cut it short, so that "can be read" is not claimed
      falsely. }
    property Truncated: Boolean read FTruncated;
  end;

  { 国別前置符字表（要件 FR-K.12）。**読むだけの器**で、規則そのものは
    `DeepCW.Callsign` が持ちます。

    読み終えたら、呼ぶ側が `SetAllocatedPrefixes(Table.Items)` で入れ替えます。
    **この単位が勝手に入れ替えません。**いつ効き始めるかは呼ぶ側が決めるべき
    ことで、ファイルを読んだ副作用で形の規則が変わるのは分かりにくいためです。

    呼出符号の一覧（`TCallsignRoster`）と同じ形のファイルを、同じ規則で読みます
    ——行の最初の語だけ。**読み方を 2 つ持たないためです。**

    The country prefix table (requirement FR-K.12). **A reader only**; the rule
    itself belongs to `DeepCW.Callsign`.

    Once read, the caller swaps it in with `SetAllocatedPrefixes(Table.Items)`.
    **This unit never swaps it in by itself**: when it takes effect is the
    caller's to decide, and having the form rule change as a side effect of
    reading a file would be hard to follow.

    The file is read exactly as a call sign roster is -- the first word of each
    line -- **so that there are not two ways of reading one.** }
  TPrefixTable = class
  private
    FItems: array of string;
    FName: string;
    FLastError: string;
    FSkipped: Integer;
  public
    procedure LoadFromFile(const FileName: string);
    procedure Clear;
    { 読み込んだ前置符字。`SetAllocatedPrefixes` へ渡します。
      The prefixes read, to be handed to `SetAllocatedPrefixes`. }
    function Items: TStringArray;
    function Count: Integer;
    property Name: string read FName;
    property LastError: string read FLastError;
    { 前置符字として読めなかった行の数。**捨てた数は数えます。**
      How many lines held nothing that reads as a prefix. **What is dropped is
      counted.** }
    property Skipped: Integer read FSkipped;
  end;

{ 前置符字らしいか。英数字 1〜4 字で、**英字を 1 つは含むこと**を求めます。
  数字だけの語は、表の見出しや件数です。
  Whether it looks like a prefix: one to four letters or digits with **at least
  one letter**, an all-digit word being a heading or a count in the table. }
function LooksLikePrefixToken(const Value: string): Boolean;

{ 1 行から呼出符号を取り出します。行の**最初の語だけ**を見ます。

  配られている一覧の形はまちまちです。1 行 1 符号のものもあれば、`,` や `\t` で
  名前や常置場所が続くものもあります。**どれも最初の列が符号**なので、そこだけを
  取ります。`#` と `;` で始まる行は注記として飛ばします。

  Pulls the call sign out of one line, looking at **the first word only.**

  The distributed rosters are not all shaped alike: one call sign to a line in
  some, a name and address after a comma or tab in others. **The first column is
  the call sign in all of them**, so that is what is taken. Lines beginning `#`
  or `;` are skipped as notes. }
function RosterToken(const Line: string): string;

implementation

function RosterToken(const Line: string): string;
var
  I, Start_: Integer;
begin
  Result := '';
  I := 1;
  while (I <= Length(Line)) and (Line[I] in [' ', #9, #13, #10]) do
    Inc(I);
  if I > Length(Line) then
    Exit;
  { 注記の行を飛ばします。`;` を並べていないのは、**`;` が区切りでもあるため
    です。**`; note` の最初の語は、区切りに当たって空になります。ここへ書いても
    通る道が無く、**通らない枝は「効いている」ように見えるだけです**
    （教訓 10.38 と同じ）。壊して確かめようとして分かりました。
    Notes are skipped. `;` is not listed **because `;` is also a separator**: the
    first word of `; note` ends at it and comes out empty. Listed here it would
    have no reachable path, and **an unreachable branch only looks as though it
    works** (the reasoning of lesson 10.38). Trying to break it is what showed
    this. }
  if Line[I] = '#' then
    Exit;
  Start_ := I;
  { 区切りは空白・タブ・コンマ・セミコロンのいずれでも受けます。**どれか 1 つに
    決めると、その区切りの一覧しか読めません。**
    A space, tab, comma or semicolon all end the word: **fixing on one of them
    would read only the rosters that use it.** }
  while (I <= Length(Line)) and not (Line[I] in [' ', #9, ',', ';', #13, #10]) do
    Inc(I);
  Result := Copy(Line, Start_, I - Start_);
end;

{ **前回の結果を残しません。**件数も誤りも残すと、2 度目に読み込んだあとの
  画面が、1 度目のファイルのことを言い続けます。
  **Nothing from the last load survives**: a count or an error left behind would
  have the display go on describing the first file after a second was read. }
function LooksLikePrefixToken(const Value: string): Boolean;
var
  I, Letters: Integer;
begin
  Result := False;
  if (Length(Value) < 1) or (Length(Value) > 4) then
    Exit;
  Letters := 0;
  for I := 1 to Length(Value) do
    if (Value[I] >= 'A') and (Value[I] <= 'Z') then
      Inc(Letters)
    else if not ((Value[I] >= '0') and (Value[I] <= '9')) then
      Exit;
  Result := Letters > 0;
end;

procedure TPrefixTable.Clear;
begin
  FItems := nil;
  FName := '';
  FLastError := '';
  FSkipped := 0;
end;

function TPrefixTable.Items: TStringArray;
begin
  Result := FItems;
end;

function TPrefixTable.Count: Integer;
begin
  Result := Length(FItems);
end;

procedure TPrefixTable.LoadFromFile(const FileName: string);
var
  Lines: TStringList;
  I, Kept: Integer;
  Token: string;
begin
  Clear;
  if Trim(FileName) = '' then
    Exit;
  { 名前は**ファイル名だけ**です（要件 FR-K.7 と同じ扱い）。
    The file name alone (handled as requirement FR-K.7 asks). }
  FName := ExtractFileName(FileName);
  Lines := TStringList.Create;
  try
    try
      Lines.LoadFromFile(FileName);
    except
      on E: Exception do
      begin
        { 読めないのは「締められない」であって「受信できない」ではありません
          （要件 FR-K.10）。
          Unreadable means "cannot tighten", not "cannot receive" (requirement
          FR-K.10). }
        FLastError := E.Message;
        FName := '';
        Exit;
      end;
    end;
    SetLength(FItems, Lines.Count);
    Kept := 0;
    for I := 0 to Lines.Count - 1 do
    begin
      Token := UpperCase(RosterToken(Lines[I]));
      if Token = '' then
        Continue;
      { 前置符字として読めない行は、数えて飛ばします。**表に見出しや国名が
        混ざっていることがあり、それを前置符字として持つと、表は締まらずに
        散らかります。**
        A line that does not read as a prefix is counted and skipped: **a table
        can carry a heading or a country name, and keeping one would clutter the
        table instead of tightening it.** }
      if not LooksLikePrefixToken(Token) then
      begin
        Inc(FSkipped);
        Continue;
      end;
      FItems[Kept] := Token;
      Inc(Kept);
    end;
    SetLength(FItems, Kept);
  finally
    Lines.Free;
  end;
end;

procedure TCallsignRoster.Clear;
begin
  FKeys := nil;
  FCount := 0;
  FName := '';
  FLastError := '';
  FSkipped := 0;
  FTruncated := False;
end;

{ 並べ替えます。件数が多い（数十万）ので、挿入法では終わりません。
  Sorted by halving the range: with hundreds of thousands of entries an
  insertion sort would not finish. }
procedure SortKeys(var Keys: array of string; Low_, High_: Integer);
var
  I, J: Integer;
  Pivot, Swap: string;
begin
  while Low_ < High_ do
  begin
    Pivot := Keys[(Low_ + High_) div 2];
    I := Low_;
    J := High_;
    repeat
      while Keys[I] < Pivot do Inc(I);
      while Keys[J] > Pivot do Dec(J);
      if I <= J then
      begin
        Swap := Keys[I];
        Keys[I] := Keys[J];
        Keys[J] := Swap;
        Inc(I);
        Dec(J);
      end;
    until I > J;
    { 短いほうを再帰に、長いほうを繰り返しに回します。**そうしないと、既に
      並んでいるファイルで再帰が深くなりすぎます。**
      The shorter side recurses and the longer one loops: **otherwise an
      already-sorted file drives the recursion too deep.** }
    if J - Low_ < High_ - I then
    begin
      SortKeys(Keys, Low_, J);
      Low_ := I;
    end
    else
    begin
      SortKeys(Keys, I, High_);
      High_ := J;
    end;
  end;
end;

procedure TCallsignRoster.Take(const Text: string);
var
  I, Start_, Kept: Integer;
  Token: string;
  Parsed: TCallsign;

  procedure Add(const Value: string);
  begin
    if Kept = Length(FKeys) then
      SetLength(FKeys, 1024 + Kept * 2);
    FKeys[Kept] := Value;
    Inc(Kept);
  end;

  procedure Flush(From, Upto: Integer);
  begin
    if Upto < From then
      Exit;
    Token := RosterToken(Copy(Text, From, Upto - From + 1));
    if Token = '' then
      Exit;
    { **形に合わないものは数えて飛ばします。**一覧には見出し行や注記が混ざって
      いることがあり、それを符号として持つと、当たるはずのない語に当たります。
      **What does not fit the shape is counted and skipped**: a roster can carry
      a heading or a note, and keeping one as a call sign would match words that
      should never match. }
    if not ParseCallsign(Token, Parsed) then
    begin
      Inc(FSkipped);
      Exit;
    end;
    Add(CallsignKey(Token));
  end;

begin
  Kept := 0;
  Start_ := 1;
  for I := 1 to Length(Text) do
    if (Text[I] = #10) or (Text[I] = #13) then
    begin
      Flush(Start_, I - 1);
      Start_ := I + 1;
    end;
  Flush(Start_, Length(Text));
  SetLength(FKeys, Kept);

  if Kept > 1 then
    SortKeys(FKeys, 0, Kept - 1);
  { 重複を除きます。同じ符号が何度出ていても、引いた答えは変わりません。
    Duplicates are dropped: however often a call sign appears, the answer to a
    lookup is the same. }
  FCount := 0;
  for I := 0 to Kept - 1 do
    if (FCount = 0) or (FKeys[I] <> FKeys[FCount - 1]) then
    begin
      FKeys[FCount] := FKeys[I];
      Inc(FCount);
    end;
  SetLength(FKeys, FCount);
end;

{ `MaxBytes` を引数にしてあるのは**試験のため**です。50 MB のファイルを試験の
  たびに作るのは、確かめたいことに対して高すぎます。既定は `ROSTER_MAX_BYTES`
  なので、呼ぶ側の意味は変わりません。
  `MaxBytes` is a parameter **so that it can be tested**: building a 50 MB file
  for every run costs far more than what it checks. The default is
  `ROSTER_MAX_BYTES`, so nothing changes for the callers. }
procedure TCallsignRoster.LoadFromFile(const FileName: string; MaxBytes: Int64);
var
  Stream: TFileStream;
  Text: string;
  Length_: Int64;
begin
  Clear;
  if Trim(FileName) = '' then
    Exit;
  { 名前は**ファイル名だけ**を持ちます（要件 FR-K.7）。
    The name kept is **the file name alone** (requirement FR-K.7). }
  FName := ExtractFileName(FileName);
  try
    Stream := TFileStream.Create(FileName, fmOpenRead or fmShareDenyNone);
    try
      Length_ := Stream.Size;
      if Length_ > MaxBytes then
      begin
        Length_ := MaxBytes;
        FTruncated := True;
      end;
      SetLength(Text, Length_);
      if Length_ > 0 then
        Stream.ReadBuffer(Text[1], Length_);
    finally
      Stream.Free;
    end;
  except
    on E: Exception do
    begin
      { 読めないのは「照合できない」であって「受信できない」ではありません
        （要件 FR-K.10）。理由だけ残して戻ります。
        Unreadable means "cannot match", not "cannot receive" (requirement
        FR-K.10): the reason is kept and that is all. }
      FLastError := E.Message;
      FName := '';
      Exit;
    end;
  end;
  { 打ち切った場合、最後の行は途中で切れています。**切れた行を符号として持つと、
    在りもしない符号が一覧に入ります。**行として読めなければ、飛ばした数に
    入ります。
    When cut short the last line is incomplete. **Kept as a call sign it would
    put one that does not exist into the roster**; failing to read as a line, it
    joins the skipped count. }
  Take(Text);
end;

function TCallsignRoster.Contains(const Callsign: string): Boolean;
var
  Low_, High_, Middle: Integer;
  Key: string;
begin
  Result := False;
  if FCount = 0 then
    Exit;
  { 引く側も同じ鍵に直します。**片方だけを直すと、`JA1ABC/P` が一覧の
    `JA1ABC` に当たりません。**
    The looked-up side is keyed the same way: **keying only one of them would
    leave `JA1ABC/P` missing the roster's `JA1ABC`.** }
  Key := CallsignKey(Callsign);
  if Key = '' then
    Exit;
  Low_ := 0;
  High_ := FCount - 1;
  while Low_ <= High_ do
  begin
    Middle := (Low_ + High_) div 2;
    if FKeys[Middle] = Key then
      Exit(True)
    else if FKeys[Middle] < Key then
      Low_ := Middle + 1
    else
      High_ := Middle - 1;
  end;
end;

end.
