unit DeepCW.Diagnostics;

{ 不具合報告に添える診断情報の控えです（要件 FR-G.5）。

  **受入基準は「個人情報・音声内容を含まない」ことです。**そこで 2 つのことを
  します。

    1. **入れない。**受信した文章、交信記録の中身、待っている符号は、
       そもそも控えに入れません。入れてから消すのではなく、入れません。
    2. **家の場所は伏せる。**診断情報はファイルの場所を並べるので、
       `/home/hanako/.config/...` のように**利用者の名前**が残ります。
       先頭を `~` に置き換えます。

  控えの先頭には、**何が入っていないか**を書きます。受け取った側が
  「音は入っていないのか」と聞かずに済み、渡す側も安心して貼れます。

  A copy of the diagnostics to attach to a bug report (requirement FR-G.5).

  **The acceptance criterion is that it holds no personal data and no audio**,
  which is met two ways. What was received, what the contact log holds and which
  call signs are being waited for are **never put in** -- not put in and then
  removed. And the home directory, which the paths would otherwise carry along
  with **the account name in it**, is replaced by `~`.

  The copy says at the top **what it does not contain**, so that whoever
  receives it need not ask whether the audio is in there, and whoever sends it
  can paste it without worrying. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils;

const
  { 控えの先頭に置く断り書き。**これを読めば、貼ってよいかが分かります。**
    The note at the top: **it is what tells the sender it is safe to paste.** }
  DIAGNOSTIC_NOTE =
    'この控えには、受信した文章・交信記録の中身・待っている符号・音声は' +
    '入っていません。ファイルの場所のうち、利用者の場所は ~ に置き換えて' +
    'あります。';

{ 利用者の場所を `~` に置き換えます。末尾の区切りの有無は問いません。
  `HomeDir` が空なら何もしません。
  Replaces the user's own directory with `~`, with or without a trailing
  separator. An empty `HomeDir` changes nothing. }
function MaskHome(const Text, HomeDir: string): string;

{ 控えを組み立てます。`Body` は画面に出ている診断情報そのものです。
  Builds the copy. `Body` is the diagnostics exactly as the screen shows them. }
function BuildDiagnosticReport(const Body, HomeDir: string;
  When_: TDateTime): string;

implementation

function MaskHome(const Text, HomeDir: string): string;
var
  Home_: string;
begin
  Result := Text;
  Home_ := HomeDir;
  if Home_ = '' then
    Exit;
  { 末尾の区切りを外した形と、付けた形の両方を置き換えます。**外した形だけだと
    `/home/hanako/` が `~/` にならず、付けた形だけだと `/home/hanako` が残ります。**
    Both with and without the trailing separator: **only one of the two would
    leave the other untouched.** }
  Home_ := ExcludeTrailingPathDelimiter(Home_);
  if Home_ = '' then
    Exit;
  Result := StringReplace(Result, IncludeTrailingPathDelimiter(Home_), '~' +
    PathDelim, [rfReplaceAll]);
  Result := StringReplace(Result, Home_, '~', [rfReplaceAll]);
end;

function BuildDiagnosticReport(const Body, HomeDir: string;
  When_: TDateTime): string;
begin
  { 日時は地域設定を通さない形で書きます。受け取った側の環境で読めなければ
    意味がありません（教訓 10.27）。
    The date and time are written without passing through the locale: unreadable
    on the receiving side, they would serve nothing (lesson 10.27). }
  Result :=
    'DeepCW 診断情報の控え  ' +
    FormatDateTime('yyyy"-"mm"-"dd" "hh":"nn":"ss', When_) + LineEnding +
    DIAGNOSTIC_NOTE + LineEnding +
    StringOfChar('-', 60) + LineEnding +
    MaskHome(Body, HomeDir);
end;

end.
