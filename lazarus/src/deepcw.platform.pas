unit DeepCW.Platform;

{ OS ごとに違うところを 1 か所に集めます。

  **OS 依存を無くすことはできません。できるのは、置き場所を決めることです。**
  同じ問いに答える処理が 2 つの実行ファイルに写されていると、片方だけを直した
  ことに気づけません（教訓 10.11）。実際、実メモリの読み取りは `cw_tune` と
  `gui_probe` に同じものが 2 つありました。

  いまのところ、ここに集めるのは**実メモリの読み取り**と**同梱した許諾条項の
  一覧**です。増えたら、ここに足してください。

  The places that differ by operating system, gathered here.

  **Dependence on the system cannot be removed; where it lives can be decided.**
  The same question answered in two executables is a thing that can be fixed in
  one and not the other without anyone noticing (lesson 10.11) -- and reading
  the resident memory was indeed written twice, in `cw_tune` and `gui_probe`.

  For now this holds the memory reading and the list of bundled licence texts.
  Anything else that differs by system belongs here too. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, DeepCW.Types;

type
  { 使っている記憶の量と、それをどうやって測ったか。

    **「測れなかった」と「0 だった」を分けます。**分けないと、測れない環境で
    「増えていない」という検査が黙って通ります（教訓 10.14）。

    How much memory is in use and how it was measured.

    **"Could not measure" is kept apart from "measured zero"**: without that
    distinction, a check for "it did not grow" passes in silence where nothing
    can be measured (lesson 10.14). }
  TMemoryKind = (
    mkNone,      { 測れない / not available }
    mkResident,  { OS が言う常駐メモリ（要件 NFR-1.8 はこれ） / resident set }
    mkHeap       { この処理系のヒープ使用量 / this runtime's heap }
  );

  TMemoryUse = record
    Kind: TMemoryKind;
    Kilobytes: Int64;
  end;

{ いま使っている記憶の量。

  常駐メモリが読めればそれを返します（要件 NFR-1.8 が言うのはこちらで、
  ONNX Runtime のように処理系の外で確保されたものも含みます）。読めない環境
  では、**代わりにこの処理系のヒープ使用量**を返します。外部ライブラリの分は
  見えませんが、**「増え続けていないか」という問いには答えられます。**

  どちらで測ったかは `Kind` に入ります。呼ぶ側は、それを表示してください。

  How much memory is in use.

  The resident set where it can be read -- that is what requirement NFR-1.8
  means, and it includes what was allocated outside this runtime, ONNX Runtime
  among it. Where it cannot be read, **this runtime's heap usage** is returned
  instead: it cannot see a library's own allocations, but **it can still answer
  whether something keeps growing.**

  Which of the two it is appears in `Kind`; show it. }
function MemoryUse: TMemoryUse;

{ 表示用の短い言葉。「常駐 139616 kB」「ヒープ 3204 kB」「測れません」。
  A short phrase for display. }
function MemoryUseCaption(const Use: TMemoryUse): string;

{ 同梱した許諾条項の一覧を返します（要件 NFR-8.4）。

  配布物では、実行ファイルの隣に `licences/` があり、同梱した各ライブラリの
  条項が入っています（`tools/make_bundle.sh` が置きます）。**開発の木から
  走らせているときは在りません。**そのときは空を返します——**無いものを
  「在る」と出すより、無いと分かるほうがよい。**

  返すのはファイル名と大きさだけで、中身は読みません。一覧に要るのは
  「何の条項が、どこに、同梱されているか」であって、全文ではありません。

  The bundled licence texts (requirement NFR-8.4).

  A distribution carries a `licences/` directory beside the executable, holding
  each bundled library's terms (put there by `tools/make_bundle.sh`). **Run from
  a build tree there is none**, and then this returns nothing: **better to show
  that there is none than to claim one that is not there.**

  Only the names and sizes come back, not the contents: a list needs to say what
  terms are bundled and where, not to quote them. }
function BundledLicences: TStringList;

{ 許諾条項の置き場所。無ければ空を返します。
  Where the licence texts are, or empty when there are none. }
function LicenceDirectory: string;

{ 訳せる文字列の改行（`#10`）を、この OS の改行へ直します（要件 NFR-7.6）。

  **訳の一覧に載る綴りは、どの OS でも同じでなければなりません。**`LineEnding`
  を文字列に埋めると、Linux は `#10`、Windows は `#13#10` になり、**Windows では
  訳が当たりません**（実測。付録 BH.1）。そこで文字列には `#10` だけを書き、
  画面に出す直前にここで直します。

  **何度通しても同じ結果になります。**版 2.62 まで、この関数は「1 度しか通しては
  いけない」ものでした——2 度通すと Windows で `#13#13#10` になるためで、それを
  註釈で守っていました。**註釈で守る決まりは、いつか破られます。**先に `#10` へ
  戻してから直すことで、決まりそのものを無くしました（付録 BK.3）。

  **置き場所をここにしたのは、OS で振る舞いが変わるからです。**`DeepCW.Platform`
  は OS 依存を集める場所であり、ここに在れば `dsp_check` から——つまり
  **Windows と macOS の CI から**——確かめられます。

  Turns the `#10` line breaks of a translatable string into this platform's line
  ending (requirement NFR-7.6).

  **The spelling in the translation list has to be the same on every
  platform.** With `LineEnding` embedded it would be `#10` on Linux and
  `#13#10` on Windows, and **the translations would not match on Windows**
  (measured; appendix BH.1). So only `#10` is written, and it is turned into the
  real line ending here.

  **It may be applied any number of times.** Up to version 2.62 this was a
  function that had to be applied exactly once -- twice would yield `#13#13#10`
  on Windows -- and a comment was what kept it so. **A rule kept by a comment
  gets broken.** Normalising back to `#10` first removed the rule itself
  (appendix BK.3).

  **It lives here because it behaves differently by platform.**
  `DeepCW.Platform` is where system dependence is gathered, and from here it can
  be checked by `dsp_check` -- that is, **from the Windows and macOS build
  matrix.** }
function AsLines(const Text_: string): string;

{ 訳した文言（`.po`）の置き場所。**最後に区切り記号が付きます。**

  同じ場所を 3 か所で組み立てていました（`UiLang`・`frmmain`・`TextCheck`）。
  `.app` の中では実行ファイルの隣ではなくなるので、**3 か所のうち 1 つを
  直し忘れれば、そこだけ訳が見つからなくなります**（教訓 10.11）。1 本にします。

  Where the translated `.po` files live, **with a trailing delimiter.**

  The same path was being built in three places (`UiLang`, `frmmain`,
  `TextCheck`). Inside a `.app` it is no longer beside the executable, so
  **forgetting one of the three would leave that one unable to find the
  translations** (lesson 10.11). One place now. }
function LanguageDirectory: string;

{ この実行ファイルの置き場所（UTF-8）。**`ParamStr(0)` の代わりに使います。**

  Windows の FPC 3.2.2 は `ParamStr(0)` を `GetModuleFileNameA`（ANSI）から
  作ります。一方この木は、画面のアプリ（LCL）でも命令行の道具（この単位の
  初期化）でも、文字列を UTF-8 として扱います。**ANSI のバイト列を UTF-8 と
  読むことになり、置き場所に ASCII 以外の文字（日本語の利用者名など）があると
  別の場所を指します。**モデル・ライブラリ・訳を探す起点がここなので、見つから
  なくなります（未解決 #24、付録 BQ）。Windows では `GetModuleFileNameW` から
  UTF-8 にします。他の OS では `ParamStr(0)` のままです（もともと UTF-8）。

  Where this executable is (UTF-8). **Use it instead of `ParamStr(0)`.**

  On Windows FPC 3.2.2 builds `ParamStr(0)` from `GetModuleFileNameA` (ANSI),
  while this tree treats strings as UTF-8 -- the GUI through the LCL, the
  command-line tools through this unit's initialization. **ANSI bytes read as
  UTF-8 point somewhere else when the location holds anything outside ASCII**
  (a Japanese user name, say), and this is where the model, the libraries and
  the translations are searched from (open question #24, appendix BQ). On
  Windows it comes from `GetModuleFileNameW`; elsewhere it is `ParamStr(0)`,
  which is UTF-8 already. }
function ExecutablePath: string;

{ 命令行の引数（UTF-8）と、その数。**`ParamStr`・`ParamCount` の代わりに
  使います。**Windows の `ParamStr` も ANSI（`GetCommandLineA`）なので、
  `ExecutablePath` と同じ理由で、日本語のファイル名を渡すと開けません。
  Windows では `GetCommandLineW` を `CommandLineToArgvW` で分けます。**数が
  `ParamCount` と食い違ったら、RTL の分け方に戻します**（LazUtils の
  `ParamStrUTF8` と同じ用心）。0 番は `ExecutablePath` です。

  A command-line argument (UTF-8), and how many there are. **Use them instead
  of `ParamStr` and `ParamCount`.** On Windows `ParamStr` is ANSI too
  (`GetCommandLineA`), so for the same reason as `ExecutablePath` a Japanese
  file name passed in cannot be opened. On Windows `GetCommandLineW` is split
  with `CommandLineToArgvW`; **should the count disagree with `ParamCount`, the
  RTL's split is used instead** (the same caution as LazUtils'
  `ParamStrUTF8`). Number 0 is `ExecutablePath`. }
function CommandLineArg(Index: Integer): string;
function CommandLineArgCount: Integer;

implementation

{$IFDEF WINDOWS}
uses
  Windows;

function CommandLineToArgvW(CmdLine: PWideChar; out NumArgs: LongInt): PPWideChar;
  stdcall; external 'shell32.dll' name 'CommandLineToArgvW';
{$ENDIF}

var
  { 起動のときに 1 度だけ読みます。/ Read once, at start-up. }
  GExecutablePath: string;
  GArgs: array of string;

resourcestring
  { 同梱の許諾条項の 1 行（要件 NFR-8.2・NFR-7.6）。
    One line of the bundled licences (NFR-8.2, NFR-7.6). }
  RsLicenceFile = '%0:s（%1:d バイト）';

{ 常駐メモリ（kB）。読めない環境では 0 を返します。

  Linux は `/proc/self/status` の `VmRSS:` に持っています。Windows は
  `GetProcessMemoryInfo`（psapi）、macOS は `task_info` で取れますが、**この
  容器では確かめられないため書いていません。**確かめられないものを書いて
  「対応した」と言うより、測れないと言うほうが正直です。

  The resident set in kilobytes, or zero where it cannot be read.

  Linux keeps it in `VmRSS:` of `/proc/self/status`. Windows has
  `GetProcessMemoryInfo` (psapi) and macOS has `task_info`, but **neither can be
  checked in this container, so neither is written here.** Saying it cannot be
  measured is more honest than writing what cannot be tried and calling the
  platform supported. }
function ResidentKb: Int64;
{$IFDEF LINUX}
var
  Lines: TStringList;
  I: Integer;
  Line: string;
begin
  Result := 0;
  Lines := TStringList.Create;
  try
    try
      Lines.LoadFromFile('/proc/self/status');
    except
      Exit;
    end;
    for I := 0 to Lines.Count - 1 do
    begin
      Line := Lines[I];
      if Copy(Line, 1, 6) = 'VmRSS:' then
      begin
        Line := Trim(Copy(Line, 7, Length(Line)));
        Result := StrToInt64Def(Trim(Copy(Line, 1, Pos(' ', Line + ' ') - 1)), 0);
        Exit;
      end;
    end;
  finally
    Lines.Free;
  end;
end;
{$ELSE}
begin
  Result := 0;
end;
{$ENDIF}

function MemoryUse: TMemoryUse;
var
  Kb: Int64;
begin
  Kb := ResidentKb;
  if Kb > 0 then
  begin
    Result.Kind := mkResident;
    Result.Kilobytes := Kb;
    Exit;
  end;
  { 常駐が読めなくても、処理系のヒープなら**どの OS でも**読めます。
    Where the resident set cannot be read, the runtime's heap can be, **on every
    system.** }
  Result.Kind := mkHeap;
  Result.Kilobytes := Int64(GetFPCHeapStatus.CurrHeapUsed) div 1024;
  if Result.Kilobytes <= 0 then
  begin
    Result.Kind := mkNone;
    Result.Kilobytes := 0;
  end;
end;

function LicenceDirectory: string;
var
  Base: string;
  Candidates: array[0..3] of string;
  I: Integer;
begin
  Base := IncludeTrailingPathDelimiter(ExtractFilePath(ExecutablePath));
  { 配布物では実行ファイルの隣（`.app` では `Contents/Resources/`）。
    開発の木では 1 つ上（`lazarus/app/` から
    `lazarus/`）も見ます。`LocateDataFile` と同じ考え方です。
    Beside the executable in a distribution; in a build tree one level up is
    looked at too (from `lazarus/app/` to `lazarus/`), the same way
    `LocateDataFile` works. }
  Candidates[0] := ResourceDirectory + 'licences';
  Candidates[1] := Base + 'licences';
  Candidates[2] := Base + '..' + PathDelim + 'licences';
  Candidates[3] := Base + '..' + PathDelim + '..' + PathDelim + 'licences';
  for I := Low(Candidates) to High(Candidates) do
    if DirectoryExists(Candidates[I]) then
      Exit(ExpandFileName(Candidates[I]));
  Result := '';
end;

function AsLines(const Text_: string): string;
begin
  { **まず `#10` へ戻します。**すでに直したものを渡されても同じ結果になります。
    First back to `#10`, so that something already turned stays the same. }
  Result := StringReplace(Text_, LineEnding, #10, [rfReplaceAll]);
  if LineEnding <> #10 then
    Result := StringReplace(Result, #10, LineEnding, [rfReplaceAll]);
end;

function LanguageDirectory: string;
begin
  Result := ResourceDirectory + 'languages' + PathDelim;
end;

function BundledLicences: TStringList;
var
  Folder: string;
  Search: TSearchRec;
begin
  Result := TStringList.Create;
  Folder := LicenceDirectory;
  if Folder = '' then
    Exit;
  Folder := IncludeTrailingPathDelimiter(Folder);
  if FindFirst(Folder + '*', faAnyFile, Search) <> 0 then
    Exit;
  try
    repeat
      if (Search.Attr and faDirectory) <> 0 then
        Continue;
      Result.Add(Format(RsLicenceFile, [Search.Name, Search.Size]));
    until FindNext(Search) <> 0;
  finally
    { **`SysUtils.` と書きます。**Windows では実装部で `Windows` を使うので、
      そちらの `FindClose(QWord)` が前に出て、組み立てが落ちます（CI で実測）。
      **Written `SysUtils.`**: on Windows the implementation uses `Windows`,
      whose `FindClose(QWord)` would take precedence and fail the build
      (seen in CI). }
    SysUtils.FindClose(Search);
  end;
  { 並びを決めておきます。**ファイルの並ぶ順は環境で変わるので、決めないと
    診断情報が実行のたびに違って見えます。**
    The order is fixed: **the order files come back in varies by system, and
    without fixing it the diagnostics would look different run to run.** }
  Result.Sort;
end;

function ExecutablePath: string;
begin
  Result := GExecutablePath;
end;

function CommandLineArgCount: Integer;
begin
  Result := ParamCount;
end;

function CommandLineArg(Index: Integer): string;
begin
  if Index = 0 then
    Exit(GExecutablePath);
  if (Index >= 1) and (Index < Length(GArgs)) then
    Result := GArgs[Index]
  else
    Result := ParamStr(Index);
end;

procedure ReadStartUp;
{$IFDEF WINDOWS}
var
  Buffer: array[0..32767] of WideChar;
  Length_: DWORD;
  Wide: UnicodeString;
  Argv: PPWideChar;
  Count, I: LongInt;
{$ENDIF}
begin
  GExecutablePath := ParamStr(0);
  GArgs := nil;
  {$IFDEF WINDOWS}
  Length_ := GetModuleFileNameW(0, @Buffer[0], Length(Buffer));
  if (Length_ > 0) and (Length_ < Length(Buffer)) then
  begin
    SetString(Wide, PWideChar(@Buffer[0]), Length_);
    GExecutablePath := UTF8Encode(Wide);
  end;
  Argv := CommandLineToArgvW(GetCommandLineW, Count);
  if Argv <> nil then
  try
    if Count - 1 = ParamCount then
    begin
      SetLength(GArgs, Count);
      for I := 0 to Count - 1 do
        GArgs[I] := UTF8Encode(UnicodeString(Argv[I]));
    end;
  finally
    LocalFree(HLOCAL(Argv));
  end;
  {$ENDIF}
end;

function MemoryUseCaption(const Use: TMemoryUse): string;
begin
  case Use.Kind of
    mkResident: Result := Format('常駐 %d kB', [Use.Kilobytes]);
    mkHeap: Result := Format('ヒープ %d kB', [Use.Kilobytes]);
  else
    Result := 'メモリは測れません';
  end;
end;

initialization
  { **Windows では、RTL の既定の符号系を UTF-8 にします**（未解決 #24、付録 BQ）。
    既定のままだと 1252 などの ANSI で、`Format` の結果が「1252 の文字列」と
    札を付けられます。中身は UTF-8 のバイト列なので、出力の段で 1252 → UTF-8 と
    変換されて化けていました（CI で実測）。画面のアプリは LCL（LazUtils の
    `fpcadds`）が同じことをしているので、命令行の道具だけが化けていました。
    ファイル名の符号系も揃えます。
    **On Windows the RTL's default code page becomes UTF-8** (open question #24,
    appendix BQ). Left at an ANSI page such as 1252, a `Format` result is
    labelled as 1252 while holding UTF-8 bytes, and the output stage converted
    it from 1252 to UTF-8 and garbled it (measured in CI). The GUI escaped this
    because the LCL (LazUtils' `fpcadds`) does the same; only the command-line
    tools were garbled. The file-name code page is set to match. }
  {$IFDEF WINDOWS}
  SetMultiByteConversionCodePage(CP_UTF8);
  SetMultiByteRTLFileSystemCodePage(CP_UTF8);
  {$ENDIF}
  ReadStartUp;
end.
