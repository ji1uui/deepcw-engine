program deepcw_station;

{ DeepCW モールス通信ステーションです。送信では入力した文字を側音に変え、
  受信ではサウンドカードまたは WAV ファイルの音声を文字に変えます。いずれも
  DeepCW の ONNX モデルを用います。

  DeepCW Morse station: keyboard to sidetone on transmit, sound card or WAV
  file to text on receive, both driven by the DeepCW ONNX model. }

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  SysUtils, Classes, Interfaces, Forms, Graphics,
  FrmMain, TextCheck;

{$R *.res}

var
  Problems: TStringList;
  Line: Integer;
begin
  Application.Title := 'DeepCW Morse Station';
  RequireDerivedFormResource := False;
  Application.Scaled := True;
  Application.Initialize;

  { 文言は画面自身が選びます（要件 NFR-7.6）。

    設定タブの選択、命令行の `--lang`、OS の地域設定の順に見て、`TMainForm` が
    決めます（`UiLang.StartingUiLang`）。**ここで決めてしまうと、覚えてある
    選択と食い違います。**

    The screen chooses its own words (requirement NFR-7.6): `TMainForm` looks at
    the settings tab's choice, the command line's `--lang`, and the locale, in
    that order (`UiLang.StartingUiLang`). **Deciding it here would disagree with
    the remembered choice.** }
  Application.CreateForm(TMainForm, MainForm);
  { 訳の幅だけを調べて終える道です（要件 NFR-7.6）。回帰試験が走らせます。
    A path that inspects the width of the translations and exits (NFR-7.6);
    the regression suite runs it. }
  if GetEnvironmentVariable('DEEPCW_TEXT_CHECK') <> '' then
  begin
    Halt(ReportTextWidths(MainForm.Canvas));
  end;
  { 言語を往復させて、戻ってくるかを調べて終える道です（要件 NFR-7.6）。

    **日本語へ戻す道は、英語へ行く道と違います**（`UiLang` の頭書き）。取り違えると
    「一度英語にしたら戻れない」が起こり、しかも**画面を開いて押してみるまで
    分かりません。**回帰試験が毎回押します。

    A path that takes the language out and back, checks that it returned, and
    exits (NFR-7.6).

    **The way back to Japanese is not the way out to English** (see the head of
    `UiLang`). Mistake it and the application cannot return once it has gone,
    and **that shows only when someone opens the screen and tries it.** The
    regression tries it every time. }
  if GetEnvironmentVariable('DEEPCW_LANG_CHECK') <> '' then
  begin
    MainForm.Show;
    Application.ProcessMessages;
    Problems := MainForm.ReportLanguage;
    try
      for Line := 0 to Problems.Count - 1 do
        WriteLn('  ', Problems[Line]);
      Flush(Output);
      { 1 行目は数の報告です。**2 行目から先があれば異常です。**
        The first line is the counts; **anything past it is a fault.** }
      Halt(Ord(Problems.Count > 1));
    finally
      Problems.Free;
    end;
  end;
  { 画面の組み方だけを調べて終える道です（要件 NFR-5.1）。回帰試験が、
    画素密度の違う画面で 2 度走らせます。**普段の起動では通りません。**
    A path that inspects the layout and exits (requirement NFR-5.1); the
    regression suite runs it twice, on screens of different pixel density.
    **A normal start never takes it.** }
  if GetEnvironmentVariable('DEEPCW_LAYOUT_CHECK') <> '' then
  begin
    MainForm.Show;
    Application.ProcessMessages;
    Problems := MainForm.ReportLayout;
    try
      WriteLn(Format('画素密度 %d dpi / 窓 %d x %d',
        [Screen.PixelsPerInch, MainForm.Width, MainForm.Height]));
      for Line := 0 to Problems.Count - 1 do
        WriteLn('  ', Problems[Line]);
      WriteLn(Format('組み方の破綻 %d 件', [Problems.Count]));
      Flush(Output);
      Halt(Ord(Problems.Count > 0));
    finally
      Problems.Free;
    end;
  end;
  Application.Run;
end.
