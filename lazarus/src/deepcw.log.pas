unit DeepCW.Log;

{ 交信の記録です。ADIF の読み書きと、「この局とは交信済みか」への答えを持ちます。

  この 1 つの記録が、これから 3 つの要件に使われます。

    FR-E.3  ADIF で書き出し、ハムログや CTESTWIN が読み込める
    FR-J.4  バンドマップで交信済みの局を区別する
    FR-K    呼出符号の確からしさの第 3 段（手元の交信記録との照合）

  **同じ問いに 3 か所が別々に答える形にはしません。**「JA1ABC と交信したか」の
  答えが画面と書き出しで食い違えば、どちらを信じてよいか分からなくなります。

  項目は名前と値の並びとして持ちます。決まった欄だけを持つ形にすると、読み込んだ
  記録の知らない欄が落ちます。**運用者が別のソフトで積み上げた記録を読み込んで
  書き戻したときに、黙って何かが消えるのは許されません。**この形なら、あとから
  必要になる欄（JCC/JCG、POTA の公園符号など。要件 FR-E.6・FR-E.7）も、単に
  項目が増えるだけで済みます。

  A log of contacts: reading and writing ADIF, and answering whether a station
  has been worked before.

  This one record serves three requirements: exporting ADIF that the common
  Japanese loggers can read (FR-E.3), marking worked stations on the band map
  (FR-J.4), and the third stage of a call sign's trustworthiness — checking it
  against the operator's own log (FR-K). **Three places must not answer the same
  question separately**: if the screen and the export disagree about whether
  JA1ABC was worked, neither can be believed.

  A record is a list of named values rather than a fixed set of columns. With
  fixed columns, fields this program does not know about are lost on the way
  through, and **silently dropping something from a log an operator has built up
  in another program is not acceptable.** It also means the fields that later
  requirements want — JCC/JCG, POTA park references (FR-E.6, FR-E.7) — are just
  more entries. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, StrUtils, Math, DeepCW.Types, DeepCW.Callsign;

const
  { 書き出す ADIF の版。読み手が解釈の基準にします。
    The ADIF version declared on export, which tells a reader how to read it. }
  ADIF_VERSION = '3.1.4';

type
  { 記録の 1 項目。名前は大文字で持ちます。ADIF の項目名は大文字小文字を
    区別しないためで、比べるたびに変換すると取りこぼしが出ます。
    One field of a record. The name is held upper case: ADIF field names are
    case-insensitive, and converting at each comparison is where a match gets
    missed. }
  TAdifField = record
    Name: string;
    Value: string;
  end;

  { 交信 1 件。/ One contact. }
  TAdifRecord = record
    Fields: array of TAdifField;
  end;
  TAdifRecords = array of TAdifRecord;

{ 項目を読み書きします。無い項目を読むと空文字が返ります。
  Reads and writes a field; reading one that is absent gives an empty string. }
function AdifValue(const Item: TAdifRecord; const Name: string): string;
procedure SetAdifValue(var Item: TAdifRecord; const Name, Value: string);

{ ADIF の文字列を記録の並びへ直します。

  読めない部分があっても例外は投げません。**運用者が長年積み上げた記録の
  1 行が壊れていたときに、全部を読まないのは損害が大きすぎます。**読める記録は
  読み、読めない部分は飛ばします。

  Turns ADIF text into records.

  Nothing is raised when part of it cannot be read: **refusing the whole of a log
  an operator has built over years because one line is damaged does more harm
  than good.** What can be read is read and the rest is skipped. }
function ParseAdif(const Text: string): TAdifRecords;

{ 記録 1 件を ADIF の 1 行にします。末尾に <EOR> が付きます。
  Formats one record as a line of ADIF, ending with <EOR>. }
function FormatAdifRecord(const Item: TAdifRecord): string;

{ 見出し付きの ADIF 全体を作ります。書き出し用です。
  Builds a whole ADIF file with a header, for export. }
function FormatAdif(const Items: TAdifRecords; const ProgramName: string): string;

type
  { 交信記録。

    追記は 1 件ごとにファイルを開いて書いて閉じます。開いたままにして終了時に
    まとめて書く作りは、強制終了したときに何も残りません。受信テキストの記録
    （DeepCW.Journal）と同じ考え方です（要件 FR-B.6 の理由がそのまま当てはまり
    ます）。

    UI スレッドからのみ呼んでください。排他は持ちません。交信を記録するのは
    運用者の操作であり、解析スレッドが触ることはありません。

    A contact log.

    Call it from the interface thread only; it holds no lock. Recording a contact
    is something the operator does, and the analysis thread never touches it.

    Each contact is appended by opening the file, writing and closing it. Holding
    it open and writing everything at exit leaves nothing behind when the exit is
    not clean — the same reasoning as the transcript journal (the argument behind
    requirement FR-B.6 applies unchanged). }
  TContactLog = class
  private
  type
    { 交信済みかどうかを引くための索引。呼出符号の**本体**（附加符号を除いた
      もの）で引きます。JA1ABC と JA1ABC/P は同じ局なので、別々に数えると
      「初めての局」と誤って示します。
      The index for the worked-before question, keyed on the **base** call sign
      with any appended designator removed. JA1ABC and JA1ABC/P are the same
      station, and counting them apart would show a worked station as new. }
    TWorkedEntry = record
      Base: string;
      Count: Integer;
      LastOn: string;
      LastAt: string;
    end;
  private
    FFileName: string;
    FRecords: TAdifRecords;
    FWorked: array of TWorkedEntry;
    FLastError: string;
    function IndexOfBase(const Base: string): Integer;
    { 交信 1 件を一意に指す文字列。局・日・時刻で足ります。同じ局と同じ秒に
      2 回交信することはありません。
      A string identifying one contact: station, date and time are enough, since
      the same station cannot be worked twice in the same second. }
    function IdentityOf(const Item: TAdifRecord): string;
    procedure Remember(const Item: TAdifRecord);
    procedure Reindex;
    function Append(const Text: string): Boolean;
  public
    constructor Create(const AFileName: string);

    { 保存してある記録を読み込みます。ファイルが無ければ空のまま始めます。
      Loads what is stored; with no file it simply starts empty. }
    procedure Load;

    { 交信を 1 件加え、その場でファイルへ書き足します。
      Adds one contact and appends it to the file there and then. }
    function Add(const Item: TAdifRecord): Boolean;

    { 別のファイルの ADIF を取り込みます。運用者が他のソフトで積み上げた記録を
      持ち込むための入口で、これが FR-K 第 3 段の材料になります。

      **既にある交信は取り込みません。**同じファイルをうっかり 2 回取り込んだ
      ときに記録が倍になると、交信数も「交信済み」の判定も狂います。同じ局・
      同じ日・同じ時刻なら同じ交信と見なします。飛ばした件数も返すので、
      黙って減ることはありません。

      Imports ADIF from another file — the way an operator brings in a log built
      elsewhere, and the material for the third stage of FR-K.

      **Contacts already held are not taken in.** Importing the same file twice
      by accident would double the log, and with it the contact count and every
      worked-before answer. The same station, date and time is the same contact.
      How many were skipped is returned too, so nothing goes quietly. }
    function ImportAdif(const FileName: string;
      out Added, Skipped: Integer): Boolean;

    { 見出し付きの ADIF として書き出します（要件 FR-E.3）。
      Exports as ADIF with a header (requirement FR-E.3). }
    function ExportAdif(const FileName: string): Boolean;

    { この呼出符号と交信した回数。附加符号は無視します。
      How many times this call sign was worked, ignoring any appended
      designator. }
    function WorkedCount(const Callsign: string): Integer;
    { 最後に交信した日付（YYYYMMDD）。無ければ空です。
      The date of the last contact as YYYYMMDD, or empty. }
    function LastWorkedOn(const Callsign: string): string;

    function Count: Integer;
    function Records: TAdifRecords;
    property FileName: string read FFileName;
    { 書けなかった・読めなかったときの理由。記録が使えなくても受信は続きます。
      Why a read or write failed. Reception continues even when the log cannot be
      used. }
    property LastError: string read FLastError;
  end;

{ 交信 1 件を組み立てます。時刻は**協定世界時**で渡してください。

  ADIF は QSO_DATE と TIME_ON を協定世界時と定めています。地方時で書くと、
  読み込んだログソフトが別の時刻として扱い、**交信の突き合わせが合わなくなります。**
  変換そのものは呼び出し側の仕事です（`LocalTimeToUniversal(Now)`）。ここで
  変換しないのは、変換済みの時刻を渡す経路――取り込んだ記録の作り直しなど――で
  二重に変換されないためです。

  Builds one contact. The moment must be given in **UTC**.

  ADIF defines QSO_DATE and TIME_ON as UTC. Written in local time, the logger
  that reads them treats them as a different moment and **contacts no longer
  match up.** The conversion itself belongs to the caller
  (`LocalTimeToUniversal(Now)`); doing it here would convert twice on any path
  that already holds a UTC moment, such as rebuilding an imported record. }
function BuildContact(const Callsign: string; MomentUtc: TDateTime;
  const Mode: string = 'CW'): TAdifRecord;

{ 呼出符号を索引に使う形へ直します。附加符号を落とし、大文字にします。
  形として成立しないものは、そのまま大文字にして返します。**記録は運用者のもので
  あり、こちらの規則に合わないという理由で捨ててよいものではありません。**

  Puts a call sign into the form used as an index key: the appended designator
  removed and upper case. Anything that does not fit the shape rule is returned
  upper-cased as it stands — **the log belongs to the operator and is not ours to
  discard for failing our rule.** }
function LogKeyOf(const Callsign: string): string;

implementation

function BuildContact(const Callsign: string; MomentUtc: TDateTime;
  const Mode: string): TAdifRecord;
begin
  Result := Default(TAdifRecord);
  SetAdifValue(Result, 'CALL', UpperCase(Trim(Callsign)));
  SetAdifValue(Result, 'QSO_DATE', FormatDateTime('yyyymmdd', MomentUtc));
  SetAdifValue(Result, 'TIME_ON', FormatDateTime('hhnnss', MomentUtc));
  SetAdifValue(Result, 'MODE', Mode);
end;

function LogKeyOf(const Callsign: string): string;
var
  Parsed: TCallsign;
begin
  Result := UpperCase(Trim(Callsign));
  if ParseCallsign(Result, Parsed) then
    Result := Parsed.Base;
end;

function AdifValue(const Item: TAdifRecord; const Name: string): string;
var
  I: Integer;
  Wanted: string;
begin
  Result := '';
  Wanted := UpperCase(Name);
  for I := 0 to High(Item.Fields) do
    if Item.Fields[I].Name = Wanted then
      Exit(Item.Fields[I].Value);
end;

procedure SetAdifValue(var Item: TAdifRecord; const Name, Value: string);
var
  I: Integer;
  Wanted: string;
begin
  Wanted := UpperCase(Name);
  for I := 0 to High(Item.Fields) do
    if Item.Fields[I].Name = Wanted then
    begin
      Item.Fields[I].Value := Value;
      Exit;
    end;
  SetLength(Item.Fields, Length(Item.Fields) + 1);
  Item.Fields[High(Item.Fields)].Name := Wanted;
  Item.Fields[High(Item.Fields)].Value := Value;
end;

function ParseAdif(const Text: string): TAdifRecords;
var
  Position, Closing, Colon, Length_, Total: Integer;
  Tag, Name, LengthText: string;
  Current: TAdifRecord;

  procedure PushRecord;
  begin
    if Length(Current.Fields) = 0 then
      Exit;
    if Total = Length(Result) then
      SetLength(Result, Max(16, Total * 2));
    Result[Total] := Current;
    Inc(Total);
    Current.Fields := nil;
  end;

begin
  Result := nil;
  Total := 0;
  Current.Fields := nil;
  Position := 1;
  while Position <= System.Length(Text) do
  begin
    { 括弧の外にある文字は、見出しの説明文や空白です。読み飛ばします。
      Anything outside the angle brackets is header prose or whitespace and is
      skipped. }
    if Text[Position] <> '<' then
    begin
      Inc(Position);
      Continue;
    end;
    Closing := PosEx('>', Text, Position + 1);
    if Closing = 0 then
      { 閉じない括弧。ここから先は読めません。
        An unclosed bracket: nothing beyond it can be read. }
      Break;
    Tag := Copy(Text, Position + 1, Closing - Position - 1);
    Position := Closing + 1;

    Colon := Pos(':', Tag);
    if Colon = 0 then
    begin
      Name := UpperCase(Trim(Tag));
      if Name = 'EOR' then
        PushRecord
      else if Name = 'EOH' then
        { 見出しの終わり。ここまでに拾った項目は見出しのものなので捨てます。
          The end of the header; anything gathered so far belonged to it. }
        Current.Fields := nil;
      Continue;
    end;

    Name := UpperCase(Trim(Copy(Tag, 1, Colon - 1)));
    LengthText := Copy(Tag, Colon + 1, System.Length(Tag));
    { 型の指定（<CALL:6:S> の S）が続くことがあります。長さだけを取ります。
      A type indicator may follow, as the S in <CALL:6:S>; only the length is
      taken. }
    Colon := Pos(':', LengthText);
    if Colon > 0 then
      LengthText := Copy(LengthText, 1, Colon - 1);
    Length_ := StrToIntDef(Trim(LengthText), -1);
    if Length_ < 0 then
      Continue;
    { 宣言された長さが残りより大きい場合は、残りだけを取ります。**壊れた 1 件の
      ために、そこまでに読めた記録まで失うほうが損です。**
      A length beyond what is left takes only what is left: **losing the records
      already read because one is damaged costs more than the damaged one.** }
    Length_ := Min(Length_, System.Length(Text) - Position + 1);
    if Name <> '' then
    begin
      SetLength(Current.Fields, System.Length(Current.Fields) + 1);
      Current.Fields[High(Current.Fields)].Name := Name;
      Current.Fields[High(Current.Fields)].Value := Copy(Text, Position, Length_);
    end;
    Inc(Position, Length_);
  end;
  { <EOR> で終わっていない最後の記録も拾います。追記の途中で落ちたファイルが
    これに当たります。
    A last record not closed by <EOR> is kept as well, which is what a file
    interrupted mid-append looks like. }
  PushRecord;
  SetLength(Result, Total);
end;

function FormatAdifRecord(const Item: TAdifRecord): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(Item.Fields) do
    if Item.Fields[I].Name <> '' then
      Result := Result + Format('<%s:%d>%s',
        [Item.Fields[I].Name, Length(Item.Fields[I].Value),
         Item.Fields[I].Value]);
  Result := Result + '<EOR>';
end;

function FormatAdif(const Items: TAdifRecords; const ProgramName: string): string;
var
  I: Integer;
begin
  Result := 'Exported by ' + ProgramName + LineEnding +
    Format('<ADIF_VER:%d>%s', [Length(ADIF_VERSION), ADIF_VERSION]) +
    Format('<PROGRAMID:%d>%s', [Length(ProgramName), ProgramName]) +
    '<EOH>' + LineEnding;
  for I := 0 to High(Items) do
    Result := Result + FormatAdifRecord(Items[I]) + LineEnding;
end;

constructor TContactLog.Create(const AFileName: string);
begin
  inherited Create;
  FFileName := AFileName;
end;

function TContactLog.IdentityOf(const Item: TAdifRecord): string;
begin
  Result := UpperCase(Trim(AdifValue(Item, 'CALL'))) + '|' +
    AdifValue(Item, 'QSO_DATE') + '|' + AdifValue(Item, 'TIME_ON');
end;

function TContactLog.IndexOfBase(const Base: string): Integer;
var
  Low_, High_, Middle: Integer;
begin
  Low_ := 0;
  High_ := System.Length(FWorked) - 1;
  while Low_ <= High_ do
  begin
    Middle := (Low_ + High_) div 2;
    if FWorked[Middle].Base = Base then
      Exit(Middle)
    else if FWorked[Middle].Base < Base then
      Low_ := Middle + 1
    else
      High_ := Middle - 1;
  end;
  { 見つからなかった位置に、負の値で挿入先を返します。
    Not found: the insertion point is returned as a negative value. }
  Result := -(Low_ + 1);
end;

procedure TContactLog.Remember(const Item: TAdifRecord);
var
  Base, On_, At_: string;
  Index, I: Integer;
begin
  Base := LogKeyOf(AdifValue(Item, 'CALL'));
  if Base = '' then
    Exit;
  On_ := AdifValue(Item, 'QSO_DATE');
  At_ := AdifValue(Item, 'TIME_ON');
  Index := IndexOfBase(Base);
  if Index >= 0 then
  begin
    Inc(FWorked[Index].Count);
    { 新しいほうを覚えます。取り込んだ記録は日付の順とはかぎりません。
      The later one is kept: an imported log is not necessarily in date order. }
    if (On_ > FWorked[Index].LastOn) or
       ((On_ = FWorked[Index].LastOn) and (At_ > FWorked[Index].LastAt)) then
    begin
      FWorked[Index].LastOn := On_;
      FWorked[Index].LastAt := At_;
    end;
    Exit;
  end;
  Index := -Index - 1;
  SetLength(FWorked, System.Length(FWorked) + 1);
  for I := System.Length(FWorked) - 1 downto Index + 1 do
    FWorked[I] := FWorked[I - 1];
  FWorked[Index].Base := Base;
  FWorked[Index].Count := 1;
  FWorked[Index].LastOn := On_;
  FWorked[Index].LastAt := At_;
end;

procedure TContactLog.Reindex;
var
  I: Integer;
begin
  FWorked := nil;
  for I := 0 to High(FRecords) do
    Remember(FRecords[I]);
end;

procedure TContactLog.Load;
var
  Stream: TFileStream;
  Text: string;
begin
  FRecords := nil;
  FWorked := nil;
  if (FFileName = '') or not FileExists(FFileName) then
    Exit;
  try
    Stream := TFileStream.Create(FFileName, fmOpenRead or fmShareDenyNone);
    try
      SetLength(Text, Stream.Size);
      if Stream.Size > 0 then
        Stream.ReadBuffer(Text[1], Stream.Size);
    finally
      Stream.Free;
    end;
  except
    on E: Exception do
    begin
      FLastError := '交信記録を読めません: ' + E.Message;
      Exit;
    end;
  end;
  FRecords := ParseAdif(Text);
  Reindex;
end;

function TContactLog.Append(const Text: string): Boolean;
var
  Stream: TFileStream;
  Mode: Word;
  Directory: string;
begin
  Result := False;
  if FFileName = '' then
    Exit;
  try
    Directory := ExtractFilePath(FFileName);
    if (Directory <> '') and not DirectoryExists(Directory) then
      if not ForceDirectories(Directory) then
      begin
        FLastError := '交信記録の保存先を作れません: ' + Directory;
        Exit;
      end;
    if FileExists(FFileName) then
      Mode := fmOpenWrite or fmShareDenyNone
    else
      Mode := fmCreate or fmShareDenyNone;
    Stream := TFileStream.Create(FFileName, Mode);
    try
      Stream.Seek(0, soEnd);
      Stream.WriteBuffer(Text[1], Length(Text));
    finally
      { 閉じることが書き込みの完了です。ここまで来ていれば、この 1 件は
        強制終了しても残ります。
        Closing is what completes the write: past this point the contact survives
        even a kill. }
      Stream.Free;
    end;
    FLastError := '';
    Result := True;
  except
    on E: Exception do
      FLastError := '交信記録を書けません: ' + E.Message;
  end;
end;

function TContactLog.Add(const Item: TAdifRecord): Boolean;
begin
  Result := Append(FormatAdifRecord(Item) + LineEnding);
  if not Result then
    Exit;
  SetLength(FRecords, System.Length(FRecords) + 1);
  FRecords[High(FRecords)] := Item;
  Remember(Item);
end;

function TContactLog.ImportAdif(const FileName: string;
  out Added, Skipped: Integer): Boolean;
var
  Stream: TFileStream;
  Text, Body: string;
  Incoming, Accepted: TAdifRecords;
  Known: TStringList;
  I: Integer;
begin
  Added := 0;
  Skipped := 0;
  Result := False;
  try
    Stream := TFileStream.Create(FileName, fmOpenRead or fmShareDenyNone);
    try
      SetLength(Text, Stream.Size);
      if Stream.Size > 0 then
        Stream.ReadBuffer(Text[1], Stream.Size);
    finally
      Stream.Free;
    end;
  except
    on E: Exception do
    begin
      FLastError := '取り込むファイルを読めません: ' + E.Message;
      Exit;
    end;
  end;

  Incoming := ParseAdif(Text);

  { 既にある交信を集めます。取り込みは滅多に行わないので、その場で作って
    その場で捨てます。
    The contacts already held are gathered. Importing is rare, so the set is
    built and discarded on the spot. }
  Known := TStringList.Create;
  try
    Known.Sorted := True;
    Known.Duplicates := dupIgnore;
    for I := 0 to High(FRecords) do
      Known.Add(IdentityOf(FRecords[I]));

    { 取り込んだものも自分の記録へ書き足します。**読んだだけで消えるなら、次に
      起動したときに「交信済み」が消えます。**
      What was imported is appended to our own file as well: **held only in
      memory it would be gone, and with it the worked-before answers, at the
      next start.** }
    Body := '';
    SetLength(Accepted, System.Length(Incoming));
    for I := 0 to High(Incoming) do
    begin
      if Known.IndexOf(IdentityOf(Incoming[I])) >= 0 then
      begin
        Inc(Skipped);
        Continue;
      end;
      Known.Add(IdentityOf(Incoming[I]));
      Body := Body + FormatAdifRecord(Incoming[I]) + LineEnding;
      Accepted[Added] := Incoming[I];
      Inc(Added);
    end;
    SetLength(Accepted, Added);
  finally
    Known.Free;
  end;

  { **ファイルへ書けてから、覚えます。**先に覚えると、書けなかったときに画面と
    ファイルが食い違い、次に起動したときに交信が消えます。
    **Written first, remembered second.** The other way round, a failed write
    leaves the screen and the file disagreeing, and the contacts are gone at the
    next start. }
  if Body <> '' then
    if not Append(Body) then
    begin
      Added := 0;
      Exit;
    end;
  for I := 0 to High(Accepted) do
  begin
    SetLength(FRecords, System.Length(FRecords) + 1);
    FRecords[High(FRecords)] := Accepted[I];
    Remember(Accepted[I]);
  end;
  Result := True;
end;

function TContactLog.ExportAdif(const FileName: string): Boolean;
var
  Stream: TFileStream;
  Text: string;
begin
  Result := False;
  Text := FormatAdif(FRecords, 'DeepCW Morse Station');
  try
    Stream := TFileStream.Create(FileName, fmCreate or fmShareDenyNone);
    try
      if Text <> '' then
        Stream.WriteBuffer(Text[1], Length(Text));
    finally
      Stream.Free;
    end;
    FLastError := '';
    Result := True;
  except
    on E: Exception do
      FLastError := '書き出せません: ' + E.Message;
  end;
end;

function TContactLog.WorkedCount(const Callsign: string): Integer;
var
  Index: Integer;
begin
  Index := IndexOfBase(LogKeyOf(Callsign));
  if Index >= 0 then
    Result := FWorked[Index].Count
  else
    Result := 0;
end;

function TContactLog.LastWorkedOn(const Callsign: string): string;
var
  Index: Integer;
begin
  Index := IndexOfBase(LogKeyOf(Callsign));
  if Index >= 0 then
    Result := FWorked[Index].LastOn
  else
    Result := '';
end;

function TContactLog.Count: Integer;
begin
  Result := System.Length(FRecords);
end;

function TContactLog.Records: TAdifRecords;
begin
  Result := Copy(FRecords, 0, System.Length(FRecords));
end;

end.
