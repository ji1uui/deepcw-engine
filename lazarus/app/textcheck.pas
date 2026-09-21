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
  SysUtils, Classes, Math, Graphics, FileUtil, Translations;

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

{ 見出しに使えない字が入っている訳を返します（要件 NFR-7.6）。

  **`&` は LCL では「次の字に下線を引く」印**として食われます。`Text & score` は
  画面に `Text_score` と出ます（付録 BE.6 で実際に出ました）。訳す人が知っている
  べき事情ではないので、**機械で見つけます。**

  Returns translations holding a character a caption cannot carry (NFR-7.6).

  **In the LCL an `&` is eaten as "underline the next letter"**: `Text & score`
  reaches the screen as `Text_score` (it did; appendix BE.6). That is not
  something a translator should have to know, so **it is found by machine.** }
function BadForCaption(const Items: TTextWidthList): TTextWidthList;

{ 差し込みが元と食い違っている訳を返します（要件 NFR-7.6）。

  **これは画面が崩れる話ではなく、落ちる話です。**`Format` は、文字列が求める
  引数と渡された引数が合わなければ例外を投げます。`未解析の音声: %.1f 秒` を
  `Audio %0:s` と訳せば、**その行が出ようとした瞬間に受信が止まります。**

  訳す人が Pascal の書式を知っている必要はありません。**機械で見つけます。**

  見るのは**差し込みの並びそのもの**です。番号を付けても、**LCL は並べ替えた訳を
  受け付けません。**`.po` を読み込むとき、LCL の `Translations` は元と訳の差し込みを
  順番どおりに突き合わせ、違えば `badformat` の印を付けて**その訳を黙って捨て、元の
  日本語を出します**（`translations.pas` の `CompareFormatArgs` と
  `TPOFile.Translate`。実測、付録 BH.9）。

  **黙って捨てられるのが厄介です。**訳は `.po` に入っていて、幅も通り、個数も合って
  いるのに、画面には日本語が出ます。だからここで落とします。

  Returns translations whose placeholders disagree with the original
  (requirement NFR-7.6).

  **This is not about the screen breaking but about the program stopping.**
  `Format` raises when the string asks for arguments the caller did not pass:
  translate `未解析の音声: %.1f 秒` as `Audio %0:s` and **reception halts the
  moment that line is due.**

  A translator need not know Pascal's format syntax. **It is found by machine.**

  What is compared is **the run of placeholders in order**. Indices do not buy
  reordering: on loading a `.po` the LCL compares the two runs and, when they
  differ, marks the entry `badformat` and **drops the translation in silence**,
  showing the original instead (`CompareFormatArgs` and `TPOFile.Translate` in
  `translations.pas`; measured, appendix BH.9). **Silence is what makes it
  costly** -- the translation is in the file, it fits, its counts match, and
  Japanese still reaches the screen -- so it fails here instead. }
function BadPlaceholders(const Items: TTextWidthList): TTextWidthList;

{ 置いてある `.po` をすべて読み、幅を報告します。広すぎるものが 1 件でもあれば
  0 以外を返します（呼ぶ側はそれを終了コードにします）。

  **訳が無ければ何も言わずに 0 を返します。**訳していないことは誤りではありません。

  Reads every `.po` beside the application, reports the widths, and returns
  non-zero when any translation is too wide (the caller uses it as an exit
  code).

  **With no translations it returns 0 in silence**: not having translated is
  not an error. }
{ LCL 自身の読み込み器が捨てる訳を数えます（要件 NFR-7.6）。

  **上の `BadPlaceholders` は規則を写したもの、こちらは本物です。**写した規則は
  いつか本物とずれます。ここでは `.po` を LCL の `TPOFile` に読ませ、`fuzzy` か
  `badformat` の印が付いた訳——つまり `TPOFile.Translate` が**使わずに捨てる**
  訳——をそのまま数えます。

  Counts the translations the LCL's own loader throws away (NFR-7.6).

  **`BadPlaceholders` above copies the rule; this one is the rule.** A copied
  rule drifts from the original in time. Here the `.po` is handed to the LCL's
  `TPOFile` and whatever comes back marked `fuzzy` or `badformat` -- what
  `TPOFile.Translate` **drops instead of using** -- is counted as it stands. }
function DroppedByLcl(const FileName: string; Names: TStrings): Integer;

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
  Fuzzy: Boolean;
  Reading: (rNothing, rSource, rTarget);

  procedure Keep;
  begin
    { **訳が空の行は「まだ訳していない」**という意味で、誤りではありません。
      An empty translation means **not translated yet**, which is not an
      error. }
    if (Source = '') or (Target = '') then
      Exit;
    { **`#, fuzzy` の付いた行は、訳があっても実行時には使われません。**
      `updatepofiles` は同じ日本語の訳を新しい行へ写しますが、確認を求める印を
      付けます。ここで数えてしまうと、**幅の検査は「訳した」と言い、画面には
      日本語が出る**という食い違いが起きます（付録 BE.5）。

      **An entry marked `#, fuzzy` is not used at run time even though it holds
      a translation.** `updatepofiles` copies a translation across to a new
      entry with the same Japanese but marks it for review. Counted here, **the
      width check would say "translated" while the screen showed Japanese**
      (appendix BE.5). }
    if Fuzzy then
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
    Fuzzy := False;
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
        Fuzzy := False;
        Reading := rNothing;
      end
      else if Copy(Text_, 1, 2) = '#,' then
        { 印の行。`fuzzy` 以外の印（`c-format` など）もここに並びます。
          The flags line; other flags such as `c-format` appear here too. }
        Fuzzy := Fuzzy or (Pos('fuzzy', Text_) > 0)
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

{ 差し込みを、出てくる順に並べた綴りを返します。`%%` は差し込みではありません。

  **LCL の `ExtractFormatArgs` と同じ規則です**（`translations.pas`、Lazarus 3.0）。
  同じでなければ、この検査は LCL が捨てる訳を通してしまいます。`ArgError` は、
  途中で綴りが壊れている場合にその番号（1 から）を返します。

  Returns the placeholders spelled out in the order they appear; `%%` is not
  one.

  **The rule is the LCL's `ExtractFormatArgs`** (`translations.pas`, Lazarus
  3.0). Were it not the same, this check would pass translations the LCL throws
  away. `ArgError` is the number (from one) of the placeholder whose spelling
  breaks off. }
function PlaceholderRun(const Text_: string; out ArgError: Integer): string;
var
  At_, StartAt, Count: Integer;
  Started, Broken: Boolean;
begin
  Result := '';
  Count := 0;
  ArgError := 0;
  StartAt := 0;
  Started := False;
  Broken := False;
  At_ := 1;
  while (At_ <= Length(Text_)) and (not Broken) do
  begin
    if not Started then
    begin
      if Text_[At_] = '%' then
      begin
        Started := True;
        StartAt := At_;
      end;
    end
    else if (Text_[At_] = '%') and (Text_[At_] = Text_[At_ - 1]) then
      { `%%` は画面に出る `%` そのものです。/ `%%` is a literal `%`. }
      Started := False
    else
      case Text_[At_] of
        ':', '-', '.', '*', '0'..'9': ;
        'D', 'E', 'F', 'G', 'M', 'N', 'P', 'S', 'U', 'X',
        'd', 'e', 'f', 'g', 'm', 'n', 'p', 's', 'u', 'x':
          begin
            Started := False;
            Result := Result + Copy(Text_, StartAt + 1, At_ - StartAt);
            Inc(Count);
          end;
      else
        Broken := True;
      end;
    Inc(At_);
  end;
  if Started then
    ArgError := Count + 1;
  Result := LowerCase(Result);
end;

{ 元と訳の差し込みが同じ並びかどうか。**LCL の `CompareFormatArgs` と同じです。**
  Whether the two runs agree. **The same as the LCL's `CompareFormatArgs`.** }
function SameFormatArgs(const Source, Target: string): Boolean;
var
  RunA, RunB: string;
  ErrA, ErrB: Integer;
begin
  Result := True;
  if Source = Target then
    Exit;
  RunA := PlaceholderRun(Source, ErrA);
  { 元に差し込みが無ければ、訳は自由です。/ No placeholders in the original
    leaves the translation free. }
  if (ErrA = 0) and (RunA = '') then
    Exit;
  RunB := PlaceholderRun(Target, ErrB);
  if (ErrA = 0) and (ErrB <> 0) then
    Result := False
  else
    Result := RunA = RunB;
end;

function BadPlaceholders(const Items: TTextWidthList): TTextWidthList;
var
  I, Count: Integer;
begin
  SetLength(Result, Length(Items));
  Count := 0;
  for I := 0 to High(Items) do
    if not SameFormatArgs(Items[I].Source, Items[I].Target) then
    begin
      Result[Count] := Items[I];
      Inc(Count);
    end;
  SetLength(Result, Count);
end;

function BadForCaption(const Items: TTextWidthList): TTextWidthList;
var
  I, Count, At_: Integer;
  Text_: string;
  Lone: Boolean;
begin
  SetLength(Result, Length(Items));
  Count := 0;
  for I := 0 to High(Items) do
  begin
    Text_ := Items[I].Target;
    { `&&` と書けば字として出ますが、1 つだけの `&` は食われます。
      Written `&&` it shows as itself; a lone `&` is eaten. }
    Lone := False;
    At_ := 1;
    while At_ <= Length(Text_) do
    begin
      if Text_[At_] = '&' then
      begin
        if (At_ < Length(Text_)) and (Text_[At_ + 1] = '&') then
          Inc(At_)
        else
          Lone := True;
      end;
      Inc(At_);
    end;
    if Lone then
    begin
      Result[Count] := Items[I];
      Inc(Count);
    end;
  end;
  SetLength(Result, Count);
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

function DroppedByLcl(const FileName: string; Names: TStrings): Integer;
var
  Po: TPOFile;
  Item: TPOFileItem;
  I: Integer;
begin
  Result := 0;
  Po := TPOFile.Create(FileName);
  try
    for I := 0 to Po.Count - 1 do
    begin
      Item := Po.PoItems[I];
      if Item = nil then
        Continue;
      if Item.Translation = '' then
        Continue;
      { 印は読み込みのときに付きます（`TPOFile.FillItem`）。この 2 つが付いて
        いると、`TPOFile.Translate` は訳ではなく元を返します。
        The flags are set while loading (`TPOFile.FillItem`); with either of
        these, `TPOFile.Translate` hands back the original, not the
        translation. }
      if (Pos('fuzzy', Item.Flags) > 0) or (Pos('badformat', Item.Flags) > 0) then
      begin
        if Names <> nil then
          Names.Add(Format('%0:s（%1:s）: 「%2:s」', [Item.IdentifierLow, Item.Flags,
            Item.Translation]));
        Inc(Result);
      end;
    end;
  finally
    Po.Free;
  end;
end;

function ReportTextWidths(Canvas_: TCanvas): Integer;
var
  Found: TStringList;
  Items, Wide, Bad, Broken: TTextWidthList;
  Dropped: TStringList;
  I, J, Total, Gone: Integer;
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
      Bad := BadForCaption(Items);
      Broken := BadPlaceholders(Items);
      Dropped := TStringList.Create;
      try
        Gone := DroppedByLcl(Found[I], Dropped);
        Inc(Total, Length(Wide) + Length(Bad) + Length(Broken) + Gone);
        WriteLn(Format('%0:s: 訳 %1:d 件 / 広すぎる %2:d / 見出しに使えない字 %3:d / 差し込み違い %4:d / LCL が捨てる %5:d',
          [ExtractFileName(Found[I]), Length(Items), Length(Wide), Length(Bad),
           Length(Broken), Gone]));
        for J := 0 to Dropped.Count - 1 do
          WriteLn('  捨てられます: ', Dropped[J]);
      finally
        Dropped.Free;
      end;
      for J := 0 to High(Broken) do
        WriteLn(Format('  %s: 差し込みが元と違います。「%s」→「%s」',
          [Broken[J].Name_, Broken[J].Source, Broken[J].Target]));
      for J := 0 to High(Wide) do
        WriteLn('  ', DescribeWidths(Wide[J]));
      for J := 0 to High(Bad) do
        WriteLn(Format('  %s: 「%s」に & があります。LCL は下線の印として食います',
          [Bad[J].Name_, Bad[J].Target]));
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
