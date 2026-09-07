unit DeepCW.Platform;

{ OS ごとに違うところを 1 か所に集めます。

  **OS 依存を無くすことはできません。できるのは、置き場所を決めることです。**
  同じ問いに答える処理が 2 つの実行ファイルに写されていると、片方だけを直した
  ことに気づけません（教訓 10.11）。実際、実メモリの読み取りは `cw_tune` と
  `gui_probe` に同じものが 2 つありました。

  いまのところ、ここに集めるのは**実メモリの読み取り**だけです。増えたら、
  ここに足してください。

  The places that differ by operating system, gathered here.

  **Dependence on the system cannot be removed; where it lives can be decided.**
  The same question answered in two executables is a thing that can be fixed in
  one and not the other without anyone noticing (lesson 10.11) -- and reading
  the resident memory was indeed written twice, in `cw_tune` and `gui_probe`.

  For now this holds only the memory reading. Anything else that differs by
  system belongs here too. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes;

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

implementation

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

function MemoryUseCaption(const Use: TMemoryUse): string;
begin
  case Use.Kind of
    mkResident: Result := Format('常駐 %d kB', [Use.Kilobytes]);
    mkHeap: Result := Format('ヒープ %d kB', [Use.Kilobytes]);
  else
    Result := 'メモリは測れません';
  end;
end;

end.
