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

  { ADIF の DXCC 列挙（仕様 III.B.8）で日本を表す番号。

    **`CNTY` を書くときは、必ずこれも書きます。**仕様 III.C.1.b は `CNTY` の型を
    「`DXCC` の値による列挙」と定めており、I.E は「依存する欄を書き出すなら、
    依存先の欄も書き出すこと」と述べている。`DXCC` が無ければ、読み手は
    `100101` を米国の郡名の形式（`MA,Middlesex`）として解釈しようとする。

    The DXCC entity code for Japan (specification III.B.8).

    **Whenever `CNTY` is written, this is written with it.** III.C.1.b defines
    `CNTY` as an enumeration that is a function of the `DXCC` field's value, and
    I.E says that if a dependent field is exported, so is the field it depends
    on. Without `DXCC`, a reader would try to read `100101` in the shape used
    for US counties (`MA,Middlesex`). }
  ADIF_DXCC_JAPAN = '339';

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
    { バンドごとの回数。**コンテストの重複判定はバンドごとです。**7 MHz で交信した
      局を 14 MHz で聞いたときに「交信済み」と出すと、有効な交信を見送らせます。
      Per-band counts. **A contest counts duplicates band by band**: marking a
      station worked on 7 MHz as worked when it turns up on 14 MHz would have the
      operator pass over a valid contact. }
    TBandTally = record
      Band: string;
      Count: Integer;
      { そのバンドで最後に交信した日と時刻。**日付を全バンドから採ると、
        バンドごとに答えているのに、別のバンドの日付を示すことになります。**
        The date and time of the last contact on that band. **Taking the date
        across all bands would answer band by band and then show a date from a
        different band.** }
      LastOn: string;
      LastAt: string;
    end;

    TWorkedEntry = record
      Base: string;
      Count: Integer;
      LastOn: string;
      LastAt: string;
      Bands: array of TBandTally;
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
    { バンドごとの回数を 1 つ増やします。バンドが空でも 1 つの区分として数えます。
      **空を捨てると、バンドを設定せずに残した交信が重複判定から消えます。**
      Adds one to a band's count, an empty band counted as a category of its own:
      **discarding it would drop from the duplicate check every contact recorded
      without a band set.** }
    procedure TallyBand(Index: Integer; const Band, On_, At_: string);
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

    { そのバンドで何回交信したか。**コンテストの重複判定はこちらです。**

      バンドを空で渡すと、全バンドの回数を返します。バンドが分からないときに
      **「交信済みでない」と答えるのは嘘**で、分かる範囲で答えるほうが正直です。

      How many times worked on that band. **This is the count a contest's
      duplicate check needs.**

      An empty band gives the count across all of them: with no band known,
      **answering "not worked" would be a lie**, and answering as far as is known
      is the honest alternative. }
    function WorkedCountOn(const Callsign, Band: string): Integer;

    { その時刻以降に記録した交信の数。コンテストの「時間あたり何局」を出すのに
      使います。時刻は協定世界時で、記録の欄と同じ形（yyyymmdd と hhnnss）で
      比べます。
      How many contacts were recorded at or after that moment, for a contest's
      contacts-per-hour. The time is UTC and is compared in the same shape the
      record's fields use. }
    function CountSince(MomentUtc: TDateTime): Integer;
    { 最後に交信した日付（YYYYMMDD）。無ければ空です。

      バンドを渡すと、そのバンドで最後に交信した日付を返します。**回数を
      バンドごとに答えるなら、日付も同じバンドで答えなければ、画面の 2 つの
      表示が食い違います。**空を渡せば全バンドから採ります。

      The date of the last contact as YYYYMMDD, or empty.

      Given a band, it is the date of the last contact on that band: **answering
      the count band by band and the date across all of them would have two
      statements on the same screen disagree.** An empty band takes the date
      across all of them. }
    function LastWorkedOn(const Callsign: string;
      const Band: string = ''): string;

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
{ Subdivision は手入力された JCC/JCG コードです（要件 FR-E.7）。読み取れた
  ときだけ `CNTY` と `DXCC` を書きます。**読み取れないものは書きません**——
  形式に合わない `CNTY` は、読み手にとって郡名の書き損じと区別が付きません。
  Subdivision is a hand-entered JCC/JCG code (requirement FR-E.7). `CNTY` and
  `DXCC` are written only when it reads: **what does not read is not written**,
  a malformed `CNTY` being indistinguishable to a reader from a mistyped county
  name. }
function BuildContact(const Callsign: string; MomentUtc: TDateTime;
  const Mode: string = 'CW'; const Band: string = '';
  const Subdivision: string = ''): TAdifRecord;

type
  { 日本の第 2 行政区分コードの種別（要件 FR-E.7）。

    ADIF 仕様 III.B.22 が DXCC 339（日本）について定める形式:

    | 種別 | 形式 | 例 |
    | --- | --- | --- |
    | 市（JCC） | 2 桁の都道府県＋2 桁または 4 桁の市 | `0101`＝札幌市、`100101`＝千代田区 |
    | 郡（JCG） | 2 桁の都道府県＋3 桁の郡 | `01001`＝阿寒郡 |
    | 区（WAKU） | 2 桁の都道府県＋2 桁の市＋2 桁の区 | `010101`＝札幌市中央区 |

    **6 桁は 2 通りに読める。**JCC の 4 桁市コードと、区コードが同じ長さになる。
    どちらであるかは JARL の一覧を引かなければ決まらず、この機械は一覧を持たない
    （同梱しない方針）。**決められないことを決めたふりはしない**ので、6 桁は
    「市または区」として扱う。ADIF へ書く値はどちらでも同じなので、記録の
    正しさは損なわれない。

    The kind of Japanese secondary administrative subdivision code
    (requirement FR-E.7), in the formats specification III.B.22 lays down for
    DXCC 339.

    **Six digits read two ways**: a JCC with a 4-digit city code and a ward code
    have the same length. Which one it is cannot be settled without JARL's
    lists, which this machine does not carry. **Rather than pretend to settle
    what cannot be settled**, six digits are treated as "city or ward"; the
    value written to ADIF is the same either way, so nothing in the record
    suffers. }
  TJapanSubdivision = (
    jsUnknown,      { 形式に合わない / does not fit the format }
    jsCity,         { 市（JCC、4 桁） / a city, 4 digits }
    jsGun,          { 郡（JCG、5 桁） / a gun, 5 digits }
    jsCityOrWard    { 市または区（6 桁） / a city or a ward, 6 digits }
  );

{ 手入力された JCC/JCG コードを読み取ります（要件 FR-E.7）。

  受け付けるのは、頭に `JCC` または `JCG` の語が付いていてもよい数字列です。
  空白は落とします。**語と桁数が食い違えば受け付けません**——`JCG 0101` は
  4 桁なので市のコードであり、打った本人の意図と食い違う。黙って市として
  書けば、賞の申請でその 1 行だけが通らない。

  都道府県は 01〜47 でなければなりません（仕様 III.B.12 の DXCC 339 の一覧）。

  読み取れたときは Code に数字だけを返します。読み取れなければ jsUnknown を
  返し、Code は空です。

  Reads a hand-entered JCC/JCG code (requirement FR-E.7).

  What is accepted is a run of digits, optionally headed by the word `JCC` or
  `JCG`; spaces are dropped. **A word that disagrees with the digit count is
  refused**: `JCG 0101` has four digits and is therefore a city code, against
  what the person typing meant. Written through in silence, it would be the one
  line that fails an award application.

  The prefecture must be 01 to 47 (the enumeration for DXCC 339 in III.B.12).

  On success Code holds the digits alone; otherwise jsUnknown is returned and
  Code is empty. }
function ParseJapanSubdivision(const Text_: string;
  out Code: string): TJapanSubdivision;

{ 画面に出す読み。/ What to call it on screen. }
function JapanSubdivisionCaption(Kind: TJapanSubdivision): string;

{ 呼出符号を索引に使う形へ直します。附加符号を落とし、大文字にします。
  形として成立しないものは、そのまま大文字にして返します。**記録は運用者のもので
  あり、こちらの規則に合わないという理由で捨ててよいものではありません。**

  Puts a call sign into the form used as an index key: the appended designator
  removed and upper case. Anything that does not fit the shape rule is returned
  upper-cased as it stands — **the log belongs to the operator and is not ours to
  discard for failing our rule.** }
function LogKeyOf(const Callsign: string): string;

implementation

resourcestring
  { 交信記録の札と知らせ（要件 FR-E.3・FR-K.10・NFR-7.6）。交信記録は画面の
    スレッドで読み書きします。**ADIF へ書く値は訳しません**（鍵のまま）。
    Labels and messages of the contact log (FR-E.3, FR-K.10, NFR-7.6); the log
    is read and written on the UI thread. **Values written to ADIF are not
    translated** (they stay keys). }
  RsSubdivisionCity = '市（JCC）';
  RsSubdivisionGun = '郡（JCG）';
  RsSubdivisionCityOrWard = '市または区（JCC／WAKU）';
  RsLogCannotRead = '交信記録を読めません: %s';
  RsLogNoDirectory = '交信記録の保存先を作れません: %s';
  RsLogCannotWrite = '交信記録を書けません: %s';
  RsLogCannotImport = '取り込むファイルを読めません: %s';
  RsLogCannotExport = '書き出せません: %s';

function JapanSubdivisionCaption(Kind: TJapanSubdivision): string;
begin
  case Kind of
    jsCity: Result := RsSubdivisionCity;
    jsGun: Result := RsSubdivisionGun;
    jsCityOrWard: Result := RsSubdivisionCityOrWard;
  else
    Result := '';
  end;
end;

function ParseJapanSubdivision(const Text_: string;
  out Code: string): TJapanSubdivision;
var
  Work, Label_: string;
  I, Prefecture: Integer;
begin
  Result := jsUnknown;
  Code := '';
  Work := UpperCase(Trim(Text_));
  if Work = '' then
    Exit;

  { 頭の語を外します。外したあとに何も残らなければ、語だけが打たれたということ
    で、コードではありません。
    A heading word is taken off; nothing left after it means a word was typed
    without a code. }
  Label_ := '';
  if (Copy(Work, 1, 3) = 'JCC') or (Copy(Work, 1, 3) = 'JCG') then
  begin
    Label_ := Copy(Work, 1, 3);
    Work := Trim(Copy(Work, 4, Length(Work)));
    { 語と数字のあいだの区切りを落とします。/ The separator after the word. }
    while (Work <> '') and ((Work[1] = ':') or (Work[1] = '-')) do
      Work := Trim(Copy(Work, 2, Length(Work)));
  end;

  { 残りは数字だけであること。**空白混じりは受け付けません。**打ち間違いと
    区切りの区別が付かず、`10 0101` を `100101` と読むのは推測になります。
    What is left must be digits alone. **Spaces inside are not accepted**: a
    mistype cannot be told from a separator, and reading `10 0101` as `100101`
    would be a guess. }
  if Work = '' then
    Exit;
  for I := 1 to Length(Work) do
    if not (Work[I] in ['0'..'9']) then
      Exit;

  { 桁数で種別が決まります（仕様 III.B.22）。
    The digit count decides the kind (specification III.B.22). }
  case Length(Work) of
    4: Result := jsCity;
    5: Result := jsGun;
    6: Result := jsCityOrWard;
  else
    Exit;
  end;

  { 打った人の言葉と桁数が食い違えば、受け付けません。
    A word that disagrees with the digit count is refused. }
  if (Label_ = 'JCC') and (Result = jsGun) then
    Exit(jsUnknown);
  if (Label_ = 'JCG') and (Result <> jsGun) then
    Exit(jsUnknown);

  { 都道府県は 01〜47（仕様 III.B.12、DXCC 339 の一覧）。
    The prefecture is 01 to 47 (III.B.12, the enumeration for DXCC 339). }
  Prefecture := StrToIntDef(Copy(Work, 1, 2), 0);
  if (Prefecture < 1) or (Prefecture > 47) then
    Exit(jsUnknown);

  Code := Work;
end;

function BuildContact(const Callsign: string; MomentUtc: TDateTime;
  const Mode: string; const Band: string;
  const Subdivision: string): TAdifRecord;
var
  Code: string;
begin
  Result := Default(TAdifRecord);
  SetAdifValue(Result, 'CALL', UpperCase(Trim(Callsign)));
  SetAdifValue(Result, 'QSO_DATE', FormatDateTime('yyyymmdd', MomentUtc));
  SetAdifValue(Result, 'TIME_ON', FormatDateTime('hhnnss', MomentUtc));
  SetAdifValue(Result, 'MODE', Mode);
  { バンドは分かるときだけ書きます。**この機械は電波の周波数を知りません**
    （受信機との連携は別仕様）。運用者が選んだものをそのまま残します。空欄を
    書くより、欄ごと無いほうがログソフトの扱いは素直です。
    The band is written only when it is known: **this machine does not know the
    radio's frequency** (the receiver link is a separate specification), so what
    the operator chose is what is kept. Leaving the field out entirely sits
    better with a logger than writing it empty. }
  if Trim(Band) <> '' then
    SetAdifValue(Result, 'BAND', UpperCase(Trim(Band)));
  { JCC/JCG（要件 FR-E.7）。**`CNTY` だけでは読めません。**形式が `DXCC` の値で
    変わるため、依存先の `DXCC` を添えます（仕様 I.E）。
    JCC/JCG (requirement FR-E.7). **`CNTY` alone cannot be read**: its format is
    a function of `DXCC`, so the field it depends on goes with it (I.E). }
  if ParseJapanSubdivision(Subdivision, Code) <> jsUnknown then
  begin
    SetAdifValue(Result, 'CNTY', Code);
    SetAdifValue(Result, 'DXCC', ADIF_DXCC_JAPAN);
  end;
end;

function LogKeyOf(const Callsign: string): string;
begin
  { 規則そのものは `DeepCW.Callsign` にあります。手元の一覧（要件 FR-K.9）も
    同じ鍵で引くので、**写しを 2 つ置くと、片方だけが当たる符号ができます。**
    The rule itself is in `DeepCW.Callsign`: a locally held roster (requirement
    FR-K.9) keys the same way, and **two copies would leave call signs that only
    one of them finds.** }
  Result := CallsignKey(Callsign);
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

procedure TContactLog.TallyBand(Index: Integer; const Band, On_, At_: string);
var
  I, Slot: Integer;
begin
  for I := 0 to System.Length(FWorked[Index].Bands) - 1 do
    if FWorked[Index].Bands[I].Band = Band then
    begin
      Inc(FWorked[Index].Bands[I].Count);
      { 新しいほうを覚えます。取り込んだ記録は日付の順とはかぎりません。
        The later one is kept: an imported log is not necessarily in date
        order. }
      if (On_ > FWorked[Index].Bands[I].LastOn) or
         ((On_ = FWorked[Index].Bands[I].LastOn) and
          (At_ > FWorked[Index].Bands[I].LastAt)) then
      begin
        FWorked[Index].Bands[I].LastOn := On_;
        FWorked[Index].Bands[I].LastAt := At_;
      end;
      Exit;
    end;
  Slot := System.Length(FWorked[Index].Bands);
  SetLength(FWorked[Index].Bands, Slot + 1);
  FWorked[Index].Bands[Slot].Band := Band;
  FWorked[Index].Bands[Slot].Count := 1;
  FWorked[Index].Bands[Slot].LastOn := On_;
  FWorked[Index].Bands[Slot].LastAt := At_;
end;

procedure TContactLog.Remember(const Item: TAdifRecord);
var
  Base, On_, At_, Band: string;
  Index, I: Integer;
begin
  Base := LogKeyOf(AdifValue(Item, 'CALL'));
  if Base = '' then
    Exit;
  On_ := AdifValue(Item, 'QSO_DATE');
  At_ := AdifValue(Item, 'TIME_ON');
  Band := UpperCase(AdifValue(Item, 'BAND'));
  Index := IndexOfBase(Base);
  if Index >= 0 then
  begin
    Inc(FWorked[Index].Count);
    TallyBand(Index, Band, On_, At_);
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
  FWorked[Index].Bands := nil;
  TallyBand(Index, Band, On_, At_);
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
      FLastError := Format(RsLogCannotRead, [E.Message]);
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
        FLastError := Format(RsLogNoDirectory, [Directory]);
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
      FLastError := Format(RsLogCannotWrite, [E.Message]);
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
      FLastError := Format(RsLogCannotImport, [E.Message]);
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
      FLastError := Format(RsLogCannotExport, [E.Message]);
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

function TContactLog.WorkedCountOn(const Callsign, Band: string): Integer;
var
  Index, I: Integer;
begin
  Result := 0;
  Index := IndexOfBase(LogKeyOf(Callsign));
  if Index < 0 then
    Exit;
  if Band = '' then
    Exit(FWorked[Index].Count);
  for I := 0 to System.Length(FWorked[Index].Bands) - 1 do
    if FWorked[Index].Bands[I].Band = Band then
      Exit(FWorked[Index].Bands[I].Count);
end;

function TContactLog.CountSince(MomentUtc: TDateTime): Integer;
var
  I: Integer;
  Since, On_, At_: string;
begin
  Result := 0;
  Since := FormatDateTime('yyyymmdd', MomentUtc) +
    FormatDateTime('hhnnss', MomentUtc);
  for I := 0 to System.Length(FRecords) - 1 do
  begin
    On_ := AdifValue(FRecords[I], 'QSO_DATE');
    At_ := AdifValue(FRecords[I], 'TIME_ON');
    { 日付も時刻も桁の揃った数字なので、文字列のまま比べられます。欄が無い
      記録は数えません。**「いつか分からない交信」を直近の 1 時間に入れると、
      速さを水増しします。**
      Both fields are fixed-width digits, so they compare as text. A record
      missing them is not counted: **putting a contact of unknown time into the
      last hour would inflate the rate.** }
    if (System.Length(On_) = 8) and (System.Length(At_) >= 6) and
       (On_ + Copy(At_, 1, 6) >= Since) then
      Inc(Result);
  end;
end;

function TContactLog.LastWorkedOn(const Callsign: string;
  const Band: string = ''): string;
var
  Index, I: Integer;
begin
  Result := '';
  Index := IndexOfBase(LogKeyOf(Callsign));
  if Index < 0 then
    Exit;
  if Band = '' then
    Exit(FWorked[Index].LastOn);
  for I := 0 to System.Length(FWorked[Index].Bands) - 1 do
    if FWorked[Index].Bands[I].Band = Band then
      Exit(FWorked[Index].Bands[I].LastOn);
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
