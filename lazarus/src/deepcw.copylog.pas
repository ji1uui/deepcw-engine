unit DeepCW.CopyLog;

{ 受信練習の記録です（要件 FR-F.5）。

  版 2.33 から、正答率と間違えやすかった符号は**その場で出して**いた。出すだけ
  では「傾向」にならない。**同じ符号をいつも間違えている**ことは、1 回の練習の
  中では分からず、何十回ぶんを並べて初めて見える。

  **残すのは、出題した文と写した文そのものである。**点数と間違いの数え上げも
  書くが、それは読みやすさのためで、**傾向は毎回この 2 つから数え直す。**
  採点のしかた（`ScoreCopy`）を将来直したとき、点数だけを残していると
  **直した日より前と後を比べられなくなる**（`DeepCW.FistLog` と同じ考え方）。

  形式は CSV。表計算ソフトでそのまま開けて、壊れても人が読んで直せる。1 行目は
  列の名前で、**読むときは名前で引く。**列を足しても古い記録が読めるように。

  **ここに入るのは、機械が出した課題文と、運用者自身が打った文だけである。**
  受信した通信の中身は入らない（要件 NFR-6.1）。

  The record of receive practice (requirement FR-F.5).

  Since version 2.33 the accuracy and the confusable characters were shown **on
  the spot**. Showing is not yet a tendency: **that the same character is always
  misread** cannot be seen within one exercise, only across dozens of them.

  **What is kept is the text sent and the text copied.** The score and the counts
  are written too, for legibility, but **the tendency is counted afresh from
  those two every time.** Were the score alone kept, revising the marking
  (`ScoreCopy`) later would mean **before and after the revision could no longer
  be compared** — the same reasoning as `DeepCW.FistLog`.

  The format is CSV: it opens in a spreadsheet as it is, and it can be read and
  repaired by hand. The first line names the columns and **reading goes by
  name**, so a column added later does not make older records unreadable.

  **What lands here is the exercise the machine produced and what the operator
  typed, and nothing else.** No received traffic (requirement NFR-6.1). }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, DateUtils, DeepCW.Practice;

type
  TCopyRecord = record
    When_: TDateTime;   { 記録した日時（地方時） / local time }
    { 出題の種類の鍵（`EXERCISE_KEYS`）。**表示名ではありません**（要件 NFR-7.6）。
      鍵を使う前の記録には日本語の名前が入っているため、読み戻しは
      `ExerciseKindByKey` を通します。
      The key of the kind of exercise (`EXERCISE_KEYS`), **not the name shown**
      (requirement NFR-7.6). Records written before the keys existed carry the
      Japanese name instead, so read it back through `ExerciseKindByKey`. }
    Kind: string;
    Groups: Integer;
    Wpm: Integer;
    Noise: Double;
    Total: Integer;
    Same: Integer;
    Wrong: Integer;
    Missed: Integer;
    Extra: Integer;
    Percent: Double;
    Truth: string;      { 出題した文 / what was sent }
    Typed: string;      { 写した文 / what was copied }
  end;
  TCopyRecords = array of TCopyRecord;

const
  { 列の名前。**並びではなく名前で読みます。**
    The column names. **Read by name, not by position.** }
  COPYLOG_HEADER =
    'datetime,kind,groups,wpm,noise,total,same,wrong,missed,extra,percent,' +
    'truth,typed';

  { 傾向を出すのに要る最小の回数。**1 回や 2 回を「傾向」と呼ばない。**
    たまたま 1 度読み違えた符号を「いつも間違える符号」として見せると、
    運用者はそこを直そうとして、実際には直すところが違う。
    The fewest sessions that make a tendency. **One or two is not a tendency**:
    showing a character misread once as one always misread sends the operator
    to practise the wrong thing. }
  COPYLOG_MIN_SESSIONS = 3;

{ 1 件を書き足します。ファイルが無ければ、列の名前から作ります。
  **書き足しは 1 行ずつ**なので、途中で落ちてもそこまでは残ります。
  Appends one record, creating the file with its header when absent. **One line
  at a time**, so an unclean exit still leaves everything up to that point. }
procedure AppendCopyRecord(const FileName: string; const Item: TCopyRecord);

{ 読み出します。読めない行は飛ばし、読めた分を返します。
  Reads back what can be read, skipping lines that cannot. }
function LoadCopyRecords(const FileName: string): TCopyRecords;

type
  { 読み違えの 1 組。Typed が #0 なら「書き落とし」、Truth が #0 なら
    「書き足し」です。
    One confusion; a Typed of #0 means the character was missed and a Truth of
    #0 means one was written that was never sent. }
  TConfusion = record
    Truth: Char;
    Typed: Char;
    Count: Integer;
  end;
  TConfusions = array of TConfusion;

{ 記録ぜんぶから読み違えを数えます（要件 FR-F.5 の「傾向」）。多い順に並べ、
  上位 Top 件を返します。Top が 0 以下なら全部です。

  **数え直しです。**記録に書いてある間違いの数ではなく、出題と写しから
  `ScoreCopy` で採点し直して数えます。

  Counts the confusions across every record (the "tendency" of requirement
  FR-F.5), commonest first, the top few. **It is a re-count**: the marking is
  run again over the text sent and the text copied rather than read off the
  numbers stored. }
function TallyConfusions(const Items: TCopyRecords;
  Top: Integer = 3): TConfusions;

{ 傾向を短い言葉にします。空なら空文字です。
  Puts the tendency into a short phrase; empty when there is none. }
function ConfusionCaption(const List: TConfusions): string;

{ 直近 Recent 件の平均正答率。Recent が 0 以下なら全部。記録が無ければ 0。
  The mean accuracy over the last few records; all of them for 0 or less, and
  0 when there are none. }
function AveragePercent(const Items: TCopyRecords; Recent: Integer = 0): Double;

implementation

function Escape(const Value: string): string;
begin
  Result := Value;
  if (Pos(',', Result) > 0) or (Pos('"', Result) > 0) or
     (Pos(#10, Result) > 0) or (Pos(#13, Result) > 0) then
    Result := '"' + StringReplace(Result, '"', '""', [rfReplaceAll]) + '"';
end;

{ 小数は**地域設定から切り離します。**環境によって小数点が `,` になり、CSV の
  区切りと衝突します（教訓 10.27 と同じ罠）。
  Numbers are kept out of the locale: the decimal point becomes a comma in some
  regions and collides with the separator (the same trap as lesson 10.27). }
function Num(Value: Double; Digits: Integer): string;
var
  Settings: TFormatSettings;
begin
  Settings := DefaultFormatSettings;
  Settings.DecimalSeparator := '.';
  Result := FloatToStrF(Value, ffFixed, 15, Digits, Settings);
end;

function Stamp(When_: TDateTime): string;
begin
  { 区切りを引用符で囲みます。地域設定が `:` を別の字に置き換えるためです
    （教訓 10.27）。
    The separators are quoted: some regions replace `:` with another character
    (lesson 10.27). }
  Result := FormatDateTime('yyyy-mm-dd"T"hh":"nn":"ss', When_);
end;

function RecordLine(const Item: TCopyRecord): string;
begin
  Result :=
    Escape(Stamp(Item.When_)) + ',' +
    Escape(Item.Kind) + ',' +
    IntToStr(Item.Groups) + ',' +
    IntToStr(Item.Wpm) + ',' +
    Num(Item.Noise, 2) + ',' +
    IntToStr(Item.Total) + ',' +
    IntToStr(Item.Same) + ',' +
    IntToStr(Item.Wrong) + ',' +
    IntToStr(Item.Missed) + ',' +
    IntToStr(Item.Extra) + ',' +
    Num(Item.Percent, 1) + ',' +
    Escape(Item.Truth) + ',' +
    Escape(Item.Typed);
end;

procedure AppendCopyRecord(const FileName: string; const Item: TCopyRecord);
var
  Stream: TFileStream;
  Line: string;
  Existed: Boolean;
begin
  if FileName = '' then
    Exit;
  ForceDirectories(ExtractFileDir(FileName));
  Existed := FileExists(FileName);
  if Existed then
    Stream := TFileStream.Create(FileName, fmOpenReadWrite or fmShareDenyNone)
  else
    Stream := TFileStream.Create(FileName, fmCreate or fmShareDenyNone);
  try
    Stream.Seek(0, soEnd);
    Line := '';
    if not Existed then
      Line := COPYLOG_HEADER + LineEnding;
    Line := Line + RecordLine(Item) + LineEnding;
    Stream.WriteBuffer(Line[1], Length(Line));
  finally
    Stream.Free;
  end;
end;

{ CSV の 1 行を項目へ分けます。引用符の中の区切りと改行はそのままにします。
  Splits one CSV line into cells, leaving separators and newlines inside quotes
  where they are. }
procedure SplitCells(const Line: string; Cells: TStrings);
var
  I: Integer;
  Cell: string;
  InQuotes: Boolean;
begin
  Cells.Clear;
  Cell := '';
  InQuotes := False;
  I := 1;
  while I <= Length(Line) do
  begin
    if InQuotes then
    begin
      if Line[I] = '"' then
      begin
        if (I < Length(Line)) and (Line[I + 1] = '"') then
        begin
          Cell := Cell + '"';
          Inc(I);
        end
        else
          InQuotes := False;
      end
      else
        Cell := Cell + Line[I];
    end
    else if Line[I] = '"' then
      InQuotes := True
    else if Line[I] = ',' then
    begin
      Cells.Add(Cell);
      Cell := '';
    end
    else
      Cell := Cell + Line[I];
    Inc(I);
  end;
  Cells.Add(Cell);
end;

function CellByName(Names, Cells: TStrings; const Name: string): string;
var
  At: Integer;
begin
  At := Names.IndexOf(Name);
  if (At < 0) or (At >= Cells.Count) then
    Exit('');
  Result := Cells[At];
end;

{ 書いた形をそのまま読み戻します。**読めなければ 0**（日時の無い記録）として
  扱い、行そのものは捨てません。写した文が残っているほうが、日時より大事です。
  Reads back the stamp exactly as written. **What cannot be read becomes 0** --
  a record without a time -- and the line itself is kept: the text copied
  matters more than when it was. }
function ParseStamp(const Value: string): TDateTime;
var
  Text_: string;
begin
  Result := 0;
  Text_ := Trim(Value);
  if Length(Text_) < 19 then
    Exit;
  try
    Result := EncodeDate(StrToInt(Copy(Text_, 1, 4)),
        StrToInt(Copy(Text_, 6, 2)), StrToInt(Copy(Text_, 9, 2))) +
      EncodeTime(StrToInt(Copy(Text_, 12, 2)), StrToInt(Copy(Text_, 15, 2)),
        StrToInt(Copy(Text_, 18, 2)), 0);
  except
    Result := 0;
  end;
end;

function ToInt(const Value: string): Integer;
begin
  Result := StrToIntDef(Trim(Value), 0);
end;

function ToFloat(const Value: string): Double;
var
  Settings: TFormatSettings;
begin
  Settings := DefaultFormatSettings;
  Settings.DecimalSeparator := '.';
  Result := StrToFloatDef(Trim(Value), 0, Settings);
end;

function LoadCopyRecords(const FileName: string): TCopyRecords;
var
  Lines, Names, Cells: TStringList;
  I: Integer;
  Item: TCopyRecord;
begin
  Result := nil;
  if (FileName = '') or not FileExists(FileName) then
    Exit;
  Lines := TStringList.Create;
  Names := TStringList.Create;
  Cells := TStringList.Create;
  try
    try
      Lines.LoadFromFile(FileName);
    except
      { 読めないファイルは「記録が無い」と同じに扱います。練習は続けられます
        （受信は fail-soft）。
        A file that cannot be read is treated as no records at all; practice
        carries on (receive is fail-soft). }
      Exit;
    end;
    if Lines.Count < 2 then
      Exit;
    SplitCells(Lines[0], Names);
    for I := 1 to Lines.Count - 1 do
    begin
      if Trim(Lines[I]) = '' then
        Continue;
      SplitCells(Lines[I], Cells);
      { 出題も写しも無い行は、記録として意味がありません。
        A line with neither the text sent nor the text copied records nothing. }
      if (CellByName(Names, Cells, 'truth') = '') and
         (CellByName(Names, Cells, 'typed') = '') then
        Continue;
      Item := Default(TCopyRecord);
      Item.When_ := ParseStamp(CellByName(Names, Cells, 'datetime'));
      Item.Kind := CellByName(Names, Cells, 'kind');
      Item.Groups := ToInt(CellByName(Names, Cells, 'groups'));
      Item.Wpm := ToInt(CellByName(Names, Cells, 'wpm'));
      Item.Noise := ToFloat(CellByName(Names, Cells, 'noise'));
      Item.Total := ToInt(CellByName(Names, Cells, 'total'));
      Item.Same := ToInt(CellByName(Names, Cells, 'same'));
      Item.Wrong := ToInt(CellByName(Names, Cells, 'wrong'));
      Item.Missed := ToInt(CellByName(Names, Cells, 'missed'));
      Item.Extra := ToInt(CellByName(Names, Cells, 'extra'));
      Item.Percent := ToFloat(CellByName(Names, Cells, 'percent'));
      Item.Truth := CellByName(Names, Cells, 'truth');
      Item.Typed := CellByName(Names, Cells, 'typed');
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := Item;
    end;
  finally
    Cells.Free;
    Names.Free;
    Lines.Free;
  end;
end;

function TallyConfusions(const Items: TCopyRecords; Top: Integer): TConfusions;
var
  I, J, K, At: Integer;
  Score: TCopyScore;
  Best: TConfusion;
begin
  Result := nil;
  for I := 0 to High(Items) do
  begin
    Score := ScoreCopy(Items[I].Truth, Items[I].Typed);
    for J := 0 to High(Score.Steps) do
    begin
      if not (Score.Steps[J].Mark in [cmWrong, cmMissed, cmExtra]) then
        Continue;
      { 空白は数えません。**語の切れ目をどう書くかは写し方の癖**であって、
        符号を読めたかどうかとは別のことです（`ScoreCopy` と同じ規則。その場で
        出す `MistakeSummary` も同じにしています）。

        **画面で見つけました。**除いていなかったため、いちばん多い「間違い」が
        空白になり、`　（落とし 196 回）` という読めない行が先頭に出ました。

        Spaces are not counted: **how the breaks between words are written is a
        habit of copying**, not whether the code was read (the rule `ScoreCopy`
        uses, and `MistakeSummary` with it).

        **Found on screen.** Without this, the commonest "mistake" was the
        space, and the list led with an unreadable `　（落とし 196 回）`. }
      if (Score.Steps[J].Truth = ' ') or (Score.Steps[J].Typed = ' ') then
        Continue;
      At := -1;
      for K := 0 to High(Result) do
        if (Result[K].Truth = Score.Steps[J].Truth) and
           (Result[K].Typed = Score.Steps[J].Typed) then
        begin
          At := K;
          Break;
        end;
      if At < 0 then
      begin
        SetLength(Result, Length(Result) + 1);
        At := High(Result);
        Result[At].Truth := Score.Steps[J].Truth;
        Result[At].Typed := Score.Steps[J].Typed;
        Result[At].Count := 0;
      end;
      Inc(Result[At].Count);
    end;
  end;

  { 多い順。件数が少ないので、単純な選択並べ替えで足ります。
    Commonest first; there are few enough for a plain selection sort. }
  for I := 0 to High(Result) do
  begin
    At := I;
    for J := I + 1 to High(Result) do
      if Result[J].Count > Result[At].Count then
        At := J;
    if At <> I then
    begin
      Best := Result[I];
      Result[I] := Result[At];
      Result[At] := Best;
    end;
  end;

  if (Top > 0) and (Length(Result) > Top) then
    SetLength(Result, Top);
end;

function ConfusionCaption(const List: TConfusions): string;
var
  I: Integer;
  One: string;
begin
  Result := '';
  for I := 0 to High(List) do
  begin
    if List[I].Typed = #0 then
      One := Format('%0:s（落とし %1:d 回）', [List[I].Truth, List[I].Count])
    else if List[I].Truth = #0 then
      One := Format('%0:s（足し %1:d 回）', [List[I].Typed, List[I].Count])
    else
      One := Format('%0:s → %1:s（%2:d 回）',
        [List[I].Truth, List[I].Typed, List[I].Count]);
    if Result = '' then
      Result := One
    else
      Result := Result + '、' + One;
  end;
end;

function AveragePercent(const Items: TCopyRecords; Recent: Integer): Double;
var
  I, From_, Count_: Integer;
  Sum: Double;
begin
  Result := 0;
  if Length(Items) = 0 then
    Exit;
  From_ := 0;
  if (Recent > 0) and (Length(Items) > Recent) then
    From_ := Length(Items) - Recent;
  Sum := 0;
  Count_ := 0;
  for I := From_ to High(Items) do
  begin
    Sum := Sum + Items[I].Percent;
    Inc(Count_);
  end;
  if Count_ > 0 then
    Result := Sum / Count_;
end;

end.
