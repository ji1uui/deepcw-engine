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

implementation

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

function LocateDataFile(const FileName: string): string;
const
  RepositoryRootCandidate = 2;
var
  Base: string;
  Candidates: array[0..3] of string;
  I: Integer;
begin
  Base := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0)));
  Candidates[0] := Base + FileName;
  Candidates[1] := Base + '..' + PathDelim + FileName;
  Candidates[RepositoryRootCandidate] :=
    Base + '..' + PathDelim + '..' + PathDelim + FileName;
  Candidates[3] := FileName;
  for I := Low(Candidates) to High(Candidates) do
    if FileExists(Candidates[I]) then
      Exit(ExpandFileName(Candidates[I]));
  Result := Candidates[RepositoryRootCandidate];
end;

end.
