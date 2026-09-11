unit DeepCW.FistLog;

{ 送信訓練の記録です（要件 FR-H.10・FR-H.12）。

  **素の測定値も残します。**基準や重みを後から見直したとき、過去の記録を
  採点し直せるようにするためです。点数だけを残すと、重みを変えた日から
  **その日より前と後を比べられなくなります。**

  形式は CSV です。表計算ソフトでそのまま開けること（要件 FR-H.12）と、
  壊れても人が読んで直せることの 2 つを満たします。1 行目は列の名前で、
  **読むときは名前で引きます。**列を足しても古い記録が読めるようにするためです
  （教訓: データ形式は足せるが、並びは変えられない）。

  The record of send practice (requirements FR-H.10, FR-H.12).

  **The raw figures are kept too**, so that a past session can be scored again
  after the basis or the weights are revised. Keeping the score alone would mean
  that from the day the weights change, **before and after cannot be compared.**

  The format is CSV: it opens in a spreadsheet as it is (FR-H.12), and it can be
  read and repaired by hand when something goes wrong. The first line names the
  columns and **reading goes by name**, so that a column added later does not
  make the older records unreadable. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, DeepCW.Types, DeepCW.Fist;

type
  TFistRecord = record
    When_: TDateTime;      { 記録した日時（地方時） }
    Seconds: Double;       { 送出にかかった時間 }
    Key: string;           { 鍵の種類 }
    Text_: string;         { 課題文 }
    Characters: Integer;
    Reference: Boolean;    { 課題文なし＝参考値 }
    Standard: TFistStandard;
    Score: TFistScore;
    Measurement: TFistMeasurement;  { Elements は持ちません / without the elements }
  end;
  TFistRecords = array of TFistRecord;

const
  { 列の名前。**並びではなく名前で読みます。**
    The column names. **Read by name, not by position.** }
  FISTLOG_HEADER =
    'datetime,seconds,key,standard,reference,text,characters,wpm,' +
    'speed,clarity,separation,spacing,copyability,overall,' +
    'dit_ms,dit_cv,ratio,intra_ratio,char_ratio,word_ratio,' +
    'tone_separation,gap_separation,drift';

{ 1 件を書き足します。ファイルが無ければ、列の名前から作ります。
  **書き足しは 1 行ずつです。**途中で落ちても、そこまでの記録は残ります
  （教訓 10.23 と同じ考え方）。
  Appends one record, creating the file with its header when it is not there.
  **One line at a time**: stopped in the middle, everything up to that point is
  still there (the same reasoning as lesson 10.23). }
procedure AppendFistRecord(const FileName: string; const Item: TFistRecord);

{ 読み出します。読めない行は**黙って飛ばさず**、読めた分だけを返します。
  Reads the file back, returning what could be read. }
function LoadFistRecords(const FileName: string): TFistRecords;

{ 表示用の 1 行。/ One line for display. }
function FistRecordCaption(const Item: TFistRecord): string;

implementation

{ CSV の 1 つぶんの値。**区切りと引用符と改行を含むものは引用します。**
  One CSV field: **quoted when it holds a comma, a quote or a line break.** }
function Escape(const Value: string): string;
begin
  Result := Value;
  if (Pos(',', Result) > 0) or (Pos('"', Result) > 0) or
     (Pos(#10, Result) > 0) or (Pos(#13, Result) > 0) then
    Result := '"' + StringReplace(Result, '"', '""', [rfReplaceAll]) + '"';
end;

{ 小数は**地域設定から切り離します。**`FormatFloat` は環境によって小数点を
  `,` にするため、CSV の区切りと衝突します（教訓 10.27 と同じ罠）。
  Numbers are kept out of the locale: `FormatFloat` would write the decimal
  point as a comma in some regions and collide with the separator itself (the
  same trap as lesson 10.27). }
function Num(Value: Double; Digits: Integer): string;
var
  Settings: TFormatSettings;
begin
  Settings := DefaultFormatSettings;
  Settings.DecimalSeparator := '.';
  Result := FloatToStrF(Value, ffFixed, 15, Digits, Settings);
end;

function ParseNum(const Value: string): Double;
var
  Settings: TFormatSettings;
begin
  Settings := DefaultFormatSettings;
  Settings.DecimalSeparator := '.';
  Result := StrToFloatDef(Trim(Value), 0, Settings);
end;

{ 日時は ISO 8601 の形で、**地域設定を通さずに**書きます。
  The date and time in ISO 8601, written without passing through the locale. }
function Stamp(When_: TDateTime): string;
begin
  Result := FormatDateTime('yyyy"-"mm"-"dd" "hh":"nn":"ss', When_);
end;

function ParseStamp(const Value: string): TDateTime;
var
  Y, Mo, D, H, Mi, S: Integer;
begin
  Result := 0;
  if Length(Value) < 19 then
    Exit;
  Y := StrToIntDef(Copy(Value, 1, 4), 0);
  Mo := StrToIntDef(Copy(Value, 6, 2), 0);
  D := StrToIntDef(Copy(Value, 9, 2), 0);
  H := StrToIntDef(Copy(Value, 12, 2), 0);
  Mi := StrToIntDef(Copy(Value, 15, 2), 0);
  S := StrToIntDef(Copy(Value, 18, 2), 0);
  if (Y = 0) or (Mo = 0) or (D = 0) then
    Exit;
  if not TryEncodeDate(Y, Mo, D, Result) then
    Exit;
  Result := Result + EncodeTime(H, Mi, S, 0);
end;

procedure SplitCsv(const Line: string; Fields: TStringList);
var
  I: Integer;
  Current: string;
  Quoted: Boolean;
begin
  Fields.Clear;
  Current := '';
  Quoted := False;
  I := 1;
  while I <= Length(Line) do
  begin
    if Quoted then
    begin
      if Line[I] = '"' then
      begin
        if (I < Length(Line)) and (Line[I + 1] = '"') then
        begin
          Current := Current + '"';
          Inc(I);
        end
        else
          Quoted := False;
      end
      else
        Current := Current + Line[I];
    end
    else if Line[I] = '"' then
      Quoted := True
    else if Line[I] = ',' then
    begin
      Fields.Add(Current);
      Current := '';
    end
    else
      Current := Current + Line[I];
    Inc(I);
  end;
  Fields.Add(Current);
end;

function RecordLine(const Item: TFistRecord): string;
begin
  Result :=
    Escape(Stamp(Item.When_)) + ',' +
    Num(Item.Seconds, 1) + ',' +
    Escape(Item.Key) + ',' +
    Escape(FIST_STANDARD_NAMES[Item.Standard]) + ',' +
    BoolToStr(Item.Reference, '1', '0') + ',' +
    Escape(Item.Text_) + ',' +
    IntToStr(Item.Characters) + ',' +
    Num(Item.Measurement.EffectiveWpm, 1) + ',' +
    Num(Item.Score.Speed, 0) + ',' +
    Num(Item.Score.Clarity, 0) + ',' +
    Num(Item.Score.Separation, 0) + ',' +
    Num(Item.Score.Spacing, 0) + ',' +
    Num(Item.Score.Copyability, 0) + ',' +
    Num(Item.Score.Overall, 0) + ',' +
    Num(Item.Measurement.DitSeconds * 1000, 2) + ',' +
    Num(Item.Measurement.Stats[ekDit].Cv, 4) + ',' +
    Num(Item.Measurement.Ratio, 3) + ',' +
    Num(Item.Measurement.IntraRatio, 3) + ',' +
    Num(Item.Measurement.CharRatio, 3) + ',' +
    Num(Item.Measurement.WordRatio, 3) + ',' +
    Num(Item.Measurement.ToneSeparation, 2) + ',' +
    Num(Item.Measurement.GapSeparation, 2) + ',' +
    Num(Item.Measurement.Drift, 4);
end;

procedure AppendFistRecord(const FileName: string; const Item: TFistRecord);
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
      Line := FISTLOG_HEADER + LineEnding;
    Line := Line + RecordLine(Item) + LineEnding;
    Stream.WriteBuffer(Line[1], Length(Line));
  finally
    Stream.Free;
  end;
end;

function LoadFistRecords(const FileName: string): TFistRecords;
var
  Lines, Names, Fields: TStringList;
  I, Count: Integer;

  function Field(const Name: string): string;
  var
    At_: Integer;
  begin
    Result := '';
    At_ := Names.IndexOf(Name);
    if (At_ >= 0) and (At_ < Fields.Count) then
      Result := Fields[At_];
  end;

  function Standard_(const Name: string): TFistStandard;
  var
    S: TFistStandard;
  begin
    Result := fsStandard;
    for S := Low(TFistStandard) to High(TFistStandard) do
      if FIST_STANDARD_NAMES[S] = Name then
        Exit(S);
  end;

begin
  Result := nil;
  if not FileExists(FileName) then
    Exit;
  Lines := TStringList.Create;
  Names := TStringList.Create;
  Fields := TStringList.Create;
  try
    try
      Lines.LoadFromFile(FileName);
    except
      Exit;
    end;
    if Lines.Count < 2 then
      Exit;
    SplitCsv(Lines[0], Names);
    SetLength(Result, Lines.Count - 1);
    Count := 0;
    for I := 1 to Lines.Count - 1 do
    begin
      if Trim(Lines[I]) = '' then
        Continue;
      SplitCsv(Lines[I], Fields);
      Result[Count] := Default(TFistRecord);
      Result[Count].When_ := ParseStamp(Field('datetime'));
      Result[Count].Seconds := ParseNum(Field('seconds'));
      Result[Count].Key := Field('key');
      Result[Count].Standard := Standard_(Field('standard'));
      Result[Count].Reference := Field('reference') = '1';
      Result[Count].Text_ := Field('text');
      Result[Count].Characters := StrToIntDef(Trim(Field('characters')), 0);
      Result[Count].Measurement.Ok := True;
      Result[Count].Measurement.EffectiveWpm := ParseNum(Field('wpm'));
      Result[Count].Score.Speed := ParseNum(Field('speed'));
      Result[Count].Score.Clarity := ParseNum(Field('clarity'));
      Result[Count].Score.Separation := ParseNum(Field('separation'));
      Result[Count].Score.Spacing := ParseNum(Field('spacing'));
      Result[Count].Score.Copyability := ParseNum(Field('copyability'));
      Result[Count].Score.Overall := ParseNum(Field('overall'));
      Result[Count].Measurement.DitSeconds := ParseNum(Field('dit_ms')) / 1000;
      Result[Count].Measurement.Stats[ekDit].Cv := ParseNum(Field('dit_cv'));
      Result[Count].Measurement.Ratio := ParseNum(Field('ratio'));
      Result[Count].Measurement.IntraRatio := ParseNum(Field('intra_ratio'));
      Result[Count].Measurement.CharRatio := ParseNum(Field('char_ratio'));
      Result[Count].Measurement.WordRatio := ParseNum(Field('word_ratio'));
      Result[Count].Measurement.ToneSeparation := ParseNum(Field('tone_separation'));
      Result[Count].Measurement.GapSeparation := ParseNum(Field('gap_separation'));
      Result[Count].Measurement.Drift := ParseNum(Field('drift'));
      Inc(Count);
    end;
    SetLength(Result, Count);
  finally
    Fields.Free;
    Names.Free;
    Lines.Free;
  end;
end;

function FistRecordCaption(const Item: TFistRecord): string;
begin
  Result := Format('%s  %s  総合 %.0f（速度 %.0f / 短長 %.0f / 区切り %.0f / 間隔 %.0f）  %.1f WPM  %s',
    [FormatDateTime('mm"/"dd" "hh":"nn', Item.When_), Item.Key,
     Item.Score.Overall, Item.Score.Speed, Item.Score.Clarity,
     Item.Score.Separation, Item.Score.Spacing,
     Item.Measurement.EffectiveWpm, FIST_STANDARD_NAMES[Item.Standard]]);
  if Item.Reference then
    Result := Result + '（参考値）';
end;

end.
