unit DeepCW.Types;

{ DeepCW Lazarus サンプル全体で共有する型と補助関数です。

  Shared types and small helpers for the DeepCW Lazarus example. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils;

type
  TSingleArray = array of Single;
  TDoubleArray = array of Double;
  TInt64Array = array of Int64;

  { DeepCW の各ユニットが回復可能な失敗を報告するための例外です。
    GUI 側は例外クラスを判別せずに 1 つのメッセージとして扱えます。

    Raised for every recoverable failure inside the DeepCW units so that the
    GUI can present one message box instead of guessing at exception classes. }
  EDeepCW = class(Exception);

  { [フレーム数 x ビン数] の行優先で格納した対数振幅スペクトログラムです。

    A [Frames x Bins] row-major log-magnitude spectrogram. }
  TSpectrogram = record
    Frames: Integer;
    Bins: Integer;
    Data: TSingleArray;
  end;

function ClampInt(Value, Low, High: Integer): Integer;
function ClampDouble(Value, Low, High: Double): Double;

{ model.onnx などの同梱データファイルを探索します。

  カレントディレクトリではなく実行ファイルの位置を起点とするため、どこから
  起動しても同じ動作になります。配布時は実行ファイルと同じ場所に、本リポジトリ
  では lazarus/app および lazarus/cli の 2 階層上に置かれています。見つからない
  場合はリポジトリ直下の候補を返し、エラーメッセージに有用なパスを残します。

  Finds a bundled data file such as model.onnx.

  The search starts at the executable rather than the working directory, so the
  tools behave the same however they are launched. A deployed copy usually sits
  next to the binary; in this repository the model is two directories above
  lazarus/app and lazarus/cli. When nothing is found the repository-root
  candidate is returned, which makes the resulting error name a useful path. }
function LocateDataFile(const FileName: string): string;

{ 持ち物（model.onnx、訳、許諾条項）を置く場所。

  ふつうは**実行ファイルの隣**です。**macOS の `.app` では違います。**実行
  ファイルは `Contents/MacOS/` に居て、持ち物は Apple の決まりで
  `Contents/Resources/` に置きます。`Contents/MacOS/` に実行ファイル以外を
  置くと、署名のときに「入れ物の形が違う」と言われるためです（未解決 #22）。

  **形で見分けます。**`$IFDEF DARWIN` にしていません。そうすると Linux では
  一度も通らない道になり、**確かめられなくなります。**見ているのは
  「実行ファイルの居る所の名前が `MacOS` で、1 つ上に `Info.plist` がある」
  という**並び方**だけで、この並びは `.app` にしか現れません。

  Where the application's belongings live: `model.onnx`, the translations, the
  licence texts.

  Normally **beside the executable**. **Inside a macOS `.app` it is not**: the
  executable sits in `Contents/MacOS/` and, by Apple's convention, what it
  carries goes in `Contents/Resources/` -- anything but executables in
  `Contents/MacOS/` makes the signing step reject the bundle's shape (open
  question #22).

  **It is recognised by shape, not by `$IFDEF DARWIN`.** Guarded by the
  define, this would be a path never taken on Linux and therefore **never
  checked.** What is looked at is only the arrangement -- the executable's
  directory is named `MacOS` and one level up holds `Info.plist` -- and that
  arrangement occurs nowhere but in a `.app`. }
function ResourceDirectory: string;

implementation

uses
  { 実行ファイルの置き場所は、OS の境界（`DeepCW.Platform`）から受け取ります
    （Windows で UTF-8 にするため。付録 BQ）。
    Where the executable is comes from the platform boundary
    (`DeepCW.Platform`), which makes it UTF-8 on Windows (appendix BQ). }
  DeepCW.Platform;

function ClampInt(Value, Low, High: Integer): Integer;
begin
  if Value < Low then Result := Low
  else if Value > High then Result := High
  else Result := Value;
end;

function ClampDouble(Value, Low, High: Double): Double;
begin
  if Value < Low then Result := Low
  else if Value > High then Result := High
  else Result := Value;
end;

function ResourceDirectory: string;
var
  Base, Contents: string;
begin
  Base := IncludeTrailingPathDelimiter(ExtractFilePath(ExecutablePath));
  Contents := ExtractFilePath(ExcludeTrailingPathDelimiter(Base));
  if (ExtractFileName(ExcludeTrailingPathDelimiter(Base)) = 'MacOS') and
     FileExists(Contents + 'Info.plist') then
    Result := IncludeTrailingPathDelimiter(Contents + 'Resources')
  else
    Result := Base;
end;

function LocateDataFile(const FileName: string): string;
const
  RepositoryRootCandidate = 3;
var
  Base: string;
  Candidates: array[0..4] of string;
  I: Integer;
begin
  Base := IncludeTrailingPathDelimiter(ExtractFilePath(ExecutablePath));
  { `.app` の中では、実行ファイルの隣ではなく `Contents/Resources/` に在ります。
    入れ物の外ではここは実行ファイルの隣と同じなので、候補が 1 つ増えるだけです。
    Inside a `.app` these live in `Contents/Resources/`, not beside the
    executable. Outside one this is the same directory, so it merely adds a
    candidate. }
  Candidates[0] := ResourceDirectory + FileName;
  Candidates[1] := Base + FileName;
  Candidates[2] := Base + '..' + PathDelim + FileName;
  Candidates[RepositoryRootCandidate] :=
    Base + '..' + PathDelim + '..' + PathDelim + FileName;
  Candidates[4] := FileName;
  for I := Low(Candidates) to High(Candidates) do
    if FileExists(Candidates[I]) then
      Exit(ExpandFileName(Candidates[I]));
  Result := Candidates[RepositoryRootCandidate];
end;

end.
