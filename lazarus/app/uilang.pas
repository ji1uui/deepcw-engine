unit UiLang;

{ 画面の言語の選択です（要件 NFR-7.6）。

  **鍵と表示名を分けます**（版 2.54、付録 BB と同じ理由）。設定ファイルに書くのは
  `ja` `en` という鍵で、選択肢に出すのは「日本語」「English」です。番号で覚えると、
  言語を足した日に別の言語が選ばれます。

  日本語へ戻す道が、英語へ行く道と違うことに注意してください。

  - 英語へ: `SetDefaultLang('en')` が `.po` を読んで `resourcestring` を置き換える
  - 日本語へ: **`ja.po` はありません。**ソースに書いてあるものが日本語だからです。
    `ResetResourceTables` が `resourcestring` を既定値へ戻します（実測。付録 BD.1）

  `SetDefaultLang('ja')` では戻りません。読むものが無いので**何もせずに帰り**、
  画面は英語のままになります。**ここを取り違えると、一度英語にしたら戻れません。**

  The choice of language for the screen (requirement NFR-7.6).

  **The key and the name shown are kept apart** (version 2.54, appendix BB, for
  the same reason): `ja` and `en` go into the settings file while `日本語` and
  `English` go on screen. Remembering the choice by its number would select a
  different language the day one is added.

  Note that the way back to Japanese differs from the way out to English:

  - to English: `SetDefaultLang('en')` reads the `.po` over the resourcestrings
  - to Japanese: **there is no `ja.po`**, because what the source holds *is* the
    Japanese. `ResetResourceTables` puts the resourcestrings back to their
    default values (measured; appendix BD.1)

  `SetDefaultLang('ja')` does not do it: with nothing to read it **returns
  having done nothing**, leaving the screen in English. **Mistake this and the
  application cannot come back once it has gone to English.** }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes;

const
  { 設定ファイルに書く鍵。**訳しません。**
    The keys written into the settings file. **Never translated.** }
  UI_LANG_KEYS: array[0..1] of string = ('ja', 'en');

  { 既定は日本語です。**ソースに書いてあるものが日本語**なので、これは
    「訳を読まない」ことと同じです。
    The default is Japanese. **The source itself holds the Japanese**, so this
    is the same as reading no translation at all. }
  UI_LANG_DEFAULT = 0;

{ 選択肢に出す名前です。**それぞれの言語で、その言語の名前を書きます。**
  `English` を「英語」と出すと、英語しか読めない人には選べません。
  The names shown in the list. **Each language is named in its own language**:
  showing `English` as `英語` leaves someone who reads only English unable to
  find it. }
function UiLangCaption(Index_: Integer): string;

{ 鍵から並びの番号へ。読めない鍵は既定（日本語）にします。
  Turns a key into its position, falling back to the default. }
function UiLangIndexOf(const Key: string): Integer;

{ 起動のときに、どの言語で出すかを決めます（要件 NFR-7.6）。

  順に見ます。

    1. 命令行の `--lang`（試験と、1 度だけ試したいとき）
    2. 設定ファイルに覚えてある鍵
    3. OS の地域設定

  **3 つとも決め手が無ければ日本語**——ソースに書いてあるものが日本語だからです。

  **決め方を 1 か所にまとめてあります。**別々に決めると、選択肢は「日本語」を
  指しているのに画面は英語、という食い違いが起きます。

  Decides which language to start in (requirement NFR-7.6), looking at the
  command line's `--lang` (for tests and one-off runs), then the key remembered
  in the settings file, then the operating system's locale. **With none of
  those, Japanese**, because the Japanese is what the source holds.

  **The decision is made in one place.** Made separately, the list could say
  `日本語` while the screen is in English. }
function StartingUiLang(const Remembered: string): Integer;

{ 命令行で言語が指定されていれば、その鍵を返します。無ければ空です。

  **命令行の指定は 1 度きりのものです。**設定に書き戻すと、試しに `--lang en`
  で開いただけで、次からずっと英語で開くことになります。書き戻すかどうかを
  決めるために、呼ぶ側がこれを見ます（`TMainForm.SaveSettings`）。

  The key given on the command line, or empty.

  **A command-line choice is for one run.** Written back to the settings, a
  single trial with `--lang en` would open in English from then on. The caller
  looks at this to decide whether to write it back (`TMainForm.SaveSettings`). }
function UiLangFromCommandLine: string;

{ 言語を切り替えます。**画面の文言を入れ直すのは呼ぶ側の仕事です**
  （`UiText.ApplyTexts`）。ここは `resourcestring` の中身だけを入れ替えます。

  Switches the language. **Putting the words back into the controls is the
  caller's work** (`UiText.ApplyTexts`); this replaces only the contents of the
  resourcestrings. }
procedure UseUiLang(Index_: Integer);

implementation

uses
  LCLTranslator, GetText, DeepCW.Platform;

{ 命令行の `--lang`。無ければ空を返します。**`LCLTranslator` も同じものを
  見ますが、こちらは「指定があったかどうか」を知りたいので自分で読みます。**
  The `--lang` on the command line, or empty. **`LCLTranslator` reads the same
  thing, but here it matters whether one was given at all**, so it is read
  here. }
function FromCommandLine: string;
var
  I: Integer;
  Arg: string;
begin
  Result := '';
  for I := 1 to ParamCount do
  begin
    Arg := ParamStr(I);
    if ((Arg = '-l') or (LowerCase(Arg) = '--lang')) and (I < ParamCount) then
      Exit(ParamStr(I + 1));
    if Copy(LowerCase(Arg), 1, 7) = '--lang=' then
      Exit(Copy(Arg, 8, Length(Arg)));
  end;
end;

{ OS の地域設定から。`ja_JP.UTF-8` のような形で来るので、前の 2 文字だけを見ます。
  From the operating system's locale, which arrives as `ja_JP.UTF-8` or similar,
  so only the first two characters are taken. }
function FromSystem: string;
var
  Lang, Fallback: string;
begin
  Lang := '';
  Fallback := '';
  GetLanguageIDs(Lang, Fallback);
  if Fallback <> '' then
    Result := Copy(Fallback, 1, 2)
  else
    Result := Copy(Lang, 1, 2);
end;

function StartingUiLang(const Remembered: string): Integer;
var
  Wanted: string;
begin
  Wanted := FromCommandLine;
  if Wanted = '' then
    Wanted := Remembered;
  if Wanted = '' then
    Wanted := FromSystem;
  Result := UiLangIndexOf(Wanted);
end;

function UiLangFromCommandLine: string;
begin
  Result := FromCommandLine;
end;

function UiLangCaption(Index_: Integer): string;
begin
  case Index_ of
    1: Result := 'English';
  else
    Result := '日本語';
  end;
end;

function UiLangIndexOf(const Key: string): Integer;
var
  I: Integer;
begin
  Result := UI_LANG_DEFAULT;
  for I := Low(UI_LANG_KEYS) to High(UI_LANG_KEYS) do
    if UI_LANG_KEYS[I] = Key then
      Exit(I);
end;

procedure UseUiLang(Index_: Integer);
begin
  { **まず既定へ戻します。**英語から別の言語へ移るとき、前の訳が残らない
    ようにするためです。訳の無い文言は、戻した日本語のまま残ります。
    **Back to the defaults first**, so that moving from one translation to
    another leaves none of the previous one behind. Anything not translated
    stays as the Japanese it was restored to. }
  ResetResourceTables;
  if (Index_ <= UI_LANG_DEFAULT) or (Index_ > High(UI_LANG_KEYS)) then
    Exit;
  { **置き場所は 1 か所で決めます。**`.app` の中では実行ファイルの隣では
    ありません（`DeepCW.Platform.LanguageDirectory`）。絶対の道を渡せば
    `SetDefaultLang` はそのまま使います。
    **One place decides where they are**: inside a `.app` it is not beside the
    executable (`DeepCW.Platform.LanguageDirectory`). Handed an absolute path,
    `SetDefaultLang` uses it as given. }
  SetDefaultLang(UI_LANG_KEYS[Index_], LanguageDirectory);
end;

end.
