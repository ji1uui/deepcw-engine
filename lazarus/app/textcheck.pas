unit TextCheck;

{ 訳した文言が、元の日本語より広くなっていないかを測る部品です（要件 NFR-7.6）。

  **画面の部品の大きさは、日本語の文言に合わせて決めてあります。**訳した文字列が
  それより広ければ、同じ枠には入りません。入らなければ端が切れるか、隣とぶつかるか、
  親からはみ出します。**どれも運用者には「壊れている」としか見えません。**

  ここで測るのは**文字数ではなく描画幅**です。日本語の全角 1 文字は、この画面の
  既定の書体で 14 画素あり、英字 1 文字は 7 画素あります。**文字数で揃えると英語は
  倍の幅になります。**「英字は日本語の 2 倍の文字数まで」が目安になるのは、
  そのためです。

  `.po` を読み、`msgid`（日本語）と `msgstr`（訳）の幅を同じ書体で測って突き合わせます。
  **画面を組む前に、文言だけで判じられます。**

  **ここは判定するだけで、直しません。**短くするのは訳す人の仕事です。

  Measures whether a translated string has grown wider than the Japanese it
  replaces (requirement NFR-7.6).

  **The controls were sized for the Japanese.** A translation wider than that
  does not fit the same box: it is clipped, it collides with its neighbour, or
  it leaves its parent. **To the operator all three look like breakage.**

  What is measured is **the drawn width, not the number of characters**. One
  full-width Japanese character is 14 pixels in this screen's default font and
  one Latin character is 7, so **matching the character count doubles the
  width.** That is why the working rule is "English may run to twice the
  Japanese character count".

  It reads the `.po`, measures `msgid` (the Japanese) and `msgstr` (the
  translation) in the same font, and compares them. **This can be judged from
  the text alone, before any screen is built.**

  **This unit only judges; it does not shorten.** Shortening is the translator's
  work. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Math, Graphics, FileUtil;

type
  { 1 件ぶんの突き合わせ。 / One string's worth of comparison. }
  TTextWidths = record
    Name_: string;      { `#:` 行の識別子 / the identifier on the `#:` line }
    Source: string;     { 日本語 / the Japanese }
    Target: string;     { 訳 / the translation }
    SourceWidth: Integer;
    TargetWidth: Integer;
  end;
  TTextWidthList = array of TTextWidths;

const
  { 訳がどれだけ広くなってよいか。**1 割**まで。

    「1 画素も広くしない」は厳しすぎます。`入力レベル` 70 画素に対して
    `Input level` は 74 画素で、**4 画素のために意味の通らない略語を選ぶのは
    本末転倒**です。一方で 2 割を許すと、`交信を記録` の幅に `Log this contact`
    が入らないことを見逃します。

    **この数は、部品の余地とは別のものです。**部品に入るかどうかは
    `LayoutCheck` が実物で数えます。ここは「元より目立って広くない」という、
    訳すときの目安です。

    How much wider a translation may be: **one tenth**.

    "Not one pixel wider" is too strict: `Input level` is 74 pixels against 70
    for `入力レベル`, and **choosing an opaque abbreviation over four pixels is
    the wrong trade.** Allowing a fifth, on the other hand, would let
    `Log this contact` past where `交信を記録` sits.

    **This number is not the room in the control.** Whether it fits is counted
    on the real screen by `LayoutCheck`. This is the translator's guide: "not
    noticeably wider than what it replaces". }
  TEXT_WIDTH_ALLOWANCE = 1.10;

  { この幅より狭い文言は、ここでは比率で判じません。**全角 6 文字**ぶんです。

    「停止」は 28 画素で、`Stop` は 32 画素あります。**4 画素で 114% になります。**
    「標準」に対する `Normal` は 186% ですが、それが入る選択肢の箱は「確実さ優先」
    に合わせて作ってあるので、余地は十分にあります。

    **短い文言の比率は、訳す人の節度ではなく、たまたまその意味の英単語が何画素
    あるかで決まります。**28 画素の英単語はありません。ここで落としても、直せるのは
    意味を削ることだけで、利用者の役には立ちません。

    短い文言が入るかどうかは `LayoutCheck` が**実物の部品に訊いて**数えます。
    そちらのほうが強い検査です——部品の大きさを知っているからです。

    ここが受け持つのは、**長い案内文が少しずつ膨らむこと**です。膨らみが積もるのは
    そちらで、しかも文の長さには訳す人の裁量があります。

    Below this width, nothing is judged by ratio here. It is **six full-width
    Japanese characters**.

    `停止` is 28 pixels and `Stop` is 32: **four pixels make 114%.** `Normal`
    against `標準` is 186%, yet the box it drops into was sized for
    `確実さ優先` and has room to spare.

    **At these lengths the ratio is decided not by the translator's restraint
    but by how many pixels the English word for that meaning happens to be.**
    There is no 28-pixel English word. Failing here could only be answered by
    cutting meaning, which does the operator no good.

    Whether a short string fits is counted by `LayoutCheck`, **which asks the
    real control** -- the stronger check of the two, because it knows how big
    the control is.

    What this unit holds is **the slow swelling of running text**, which is
    where the growth accumulates and where the translator does have a choice. }
  TEXT_WIDTH_SHORT_PIXELS = 84;

{ `.po` を読みます。訳が空の行（まだ訳していないもの）は返しません。

  **読めなければ空を返します。**`.po` が無いのは、訳が無い（＝日本語で動く）
  というだけのことで、異常ではありません（受信は fail-soft）。

  Reads a `.po`. Entries whose translation is empty -- not yet translated -- are
  not returned.

  **An unreadable file gives an empty list.** No `.po` simply means no
  translation, and the application runs in Japanese; that is not a fault
  (receive is fail-soft). }
function LoadPoPairs(const FileName: string): TTextWidthList;

{ 同じ書体で両方の幅を測って入れます。`Canvas` は画面のものを渡してください。
  Measures both widths in one font. Pass a screen canvas. }
procedure MeasureWidths(var Items: TTextWidthList; Canvas_: TCanvas);

{ 広すぎるものだけを返します。**測っていないもの（幅 0）は判じません。**
  Returns only the ones that are too wide. **Nothing is judged before it is
  measured** (a width of zero). }
function TooWide(const Items: TTextWidthList): TTextWidthList;

{ 1 行の報告。 / One line of report. }
function DescribeWidths(const Item: TTextWidths): string;

{ 置いてある `.po` をすべて読み、幅を報告します。広すぎるものが 1 件でもあれば
  0 以外を返します（呼ぶ側はそれを終了コードにします）。

  **訳が無ければ何も言わずに 0 を返します。**訳していないことは誤りではありません。

  Reads every `.po` beside the application, reports the widths, and returns
  non-zero when any translation is too wide (the caller uses it as an exit
  code).

  **With no translations it returns 0 in silence**: not having translated is
  not an error. }
function ReportTextWidths(Canvas_: TCanvas): Integer;

implementation

{ `.po` の 1 行から引用符の中身を取り出します。`msgid "..."` の形だけを見ます。
  **続きの行（複数行の文字列）にも対応します。**長い案内文は折り返して書かれます。
  Takes the quoted text out of one `.po` line, for the `msgid "..."` form.
  **Continuation lines are handled too**: long sentences are wrapped. }
function Quoted(const Line: string): string;
var
  First, Last_, I: Integer;
begin
  Result := '';
  First := Pos('"', Line);
  if First <= 0 then
    Exit;
  Last_ := Length(Line);
  while (Last_ > First) and (Line[Last_] <> '"') do
    Dec(Last_);
  if Last_ <= First then
    Exit;
  I := First + 1;
  while I < Last_ do
  begin
    { `.po` の逃がし字。**`\n` を字のまま数えると、幅が 2 文字ぶん増えます。**
      The escapes of a `.po`. **Counted literally, `\n` would add two
      characters' worth of width.** }
    if (Line[I] = '\') and (I + 1 < Last_) then
    begin
      Inc(I);
      case Line[I] of
        'n': Result := Result + ' ';
        't': Result := Result + ' ';
        '"': Result := Result + '"';
        '\': Result := Result + '\';
      else
        Result := Result + Line[I];
      end;
    end
    else
      Result := Result + Line[I];
    Inc(I);
  end;
end;

function LoadPoPairs(const FileName: string): TTextWidthList;
var
  Lines: TStringList;
  I, Count: Integer;
  Name_, Source, Target, Text_: string;
  Reading: (rNothing, rSource, rTarget);

  procedure Keep;
  begin
    { **訳が空の行は「まだ訳していない」**という意味で、誤りではありません。
      An empty translation means **not translated yet**, which is not an
      error. }
    if (Source = '') or (Target = '') then
      Exit;
    if Count > High(Result) then
      SetLength(Result, Count + 32);
    Result[Count] := Default(TTextWidths);
    Result[Count].Name_ := Name_;
    Result[Count].Source := Source;
    Result[Count].Target := Target;
    Inc(Count);
  end;

begin
  Result := nil;
  Count := 0;
  if not FileExists(FileName) then
    Exit;
  Lines := TStringList.Create;
  try
    try
      Lines.LoadFromFile(FileName);
    except
      Exit;
    end;
    Name_ := '';
    Source := '';
    Target := '';
    Reading := rNothing;
    for I := 0 to Lines.Count - 1 do
    begin
      Text_ := Trim(Lines[I]);
      if Copy(Text_, 1, 3) = '#: ' then
      begin
        Keep;
        Name_ := Trim(Copy(Text_, 4, Length(Text_)));
        Source := '';
        Target := '';
        Reading := rNothing;
      end
      else if Copy(Text_, 1, 6) = 'msgid ' then
      begin
        Source := Quoted(Text_);
        Reading := rSource;
      end
      else if Copy(Text_, 1, 7) = 'msgstr ' then
      begin
        Target := Quoted(Text_);
        Reading := rTarget;
      end
      else if (Text_ <> '') and (Text_[1] = '"') then
      begin
        { 折り返しの続き。 / A wrapped continuation. }
        case Reading of
          rSource: Source := Source + Quoted(Text_);
          rTarget: Target := Target + Quoted(Text_);
        end;
      end
      else if Text_ = '' then
        Reading := rNothing;
    end;
    Keep;
    SetLength(Result, Count);
  finally
    Lines.Free;
  end;
end;

procedure MeasureWidths(var Items: TTextWidthList; Canvas_: TCanvas);
var
  I: Integer;
begin
  if Canvas_ = nil then
    Exit;
  for I := 0 to High(Items) do
  begin
    Items[I].SourceWidth := Canvas_.TextWidth(Items[I].Source);
    Items[I].TargetWidth := Canvas_.TextWidth(Items[I].Target);
  end;
end;

function TooWide(const Items: TTextWidthList): TTextWidthList;
var
  I, Count: Integer;
begin
  SetLength(Result, Length(Items));
  Count := 0;
  for I := 0 to High(Items) do
  begin
    if Items[I].SourceWidth <= 0 then
      Continue;
    { 短い文言は `LayoutCheck` に任せます（上の TEXT_WIDTH_SHORT_PIXELS）。
      Short strings are left to `LayoutCheck` (see TEXT_WIDTH_SHORT_PIXELS). }
    if Items[I].SourceWidth < TEXT_WIDTH_SHORT_PIXELS then
      Continue;
    if Items[I].TargetWidth > Round(Items[I].SourceWidth * TEXT_WIDTH_ALLOWANCE) then
    begin
      Result[Count] := Items[I];
      Inc(Count);
    end;
  end;
  SetLength(Result, Count);
end;

function DescribeWidths(const Item: TTextWidths): string;
begin
  Result := Format('%s: 「%s」%d 画素 → 「%s」%d 画素（%.0f%%）',
    [Item.Name_, Item.Source, Item.SourceWidth, Item.Target, Item.TargetWidth,
     100 * Item.TargetWidth / Max(1, Item.SourceWidth)]);
end;

function ReportTextWidths(Canvas_: TCanvas): Integer;
var
  Found: TStringList;
  Items, Wide: TTextWidthList;
  I, J, Total: Integer;
  Dir: string;
begin
  Result := 0;
  Total := 0;
  Dir := IncludeTrailingPathDelimiter(
    ExtractFilePath(ParamStr(0))) + 'languages' + PathDelim;
  Found := FindAllFiles(Dir, '*.po', False);
  try
    if Found.Count = 0 then
    begin
      WriteLn('訳された文言はありません（', Dir, '）');
      Exit;
    end;
    Found.Sort;
    for I := 0 to Found.Count - 1 do
    begin
      Items := LoadPoPairs(Found[I]);
      MeasureWidths(Items, Canvas_);
      Wide := TooWide(Items);
      Inc(Total, Length(Wide));
      WriteLn(Format('%s: 訳 %d 件 / 広すぎるもの %d 件',
        [ExtractFileName(Found[I]), Length(Items), Length(Wide)]));
      for J := 0 to High(Wide) do
        WriteLn('  ', DescribeWidths(Wide[J]));
    end;
    WriteLn(Format('許す広がりは %.0f%% まで。%d 画素より狭い文言は LayoutCheck に任せる',
      [100 * TEXT_WIDTH_ALLOWANCE, TEXT_WIDTH_SHORT_PIXELS]));
    Flush(Output);
    Result := Ord(Total > 0);
  finally
    Found.Free;
  end;
end;

end.
