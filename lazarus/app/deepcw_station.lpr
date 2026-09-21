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
  SysUtils, Classes, Interfaces, Forms, Graphics, LCLTranslator,
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

  { 文言を選びます（要件 NFR-7.6）。**画面に切替は置いていません。**

    言語の切替そのものは「将来」の要件であり、こちらはその前提となる分離だけを
    担います。いまは `--lang en` と、OS の地域設定から決まります。`.po` が
    無ければ、ソースに書いた日本語のまま動きます。

    **画面を組む前に呼びます。**部品の文言は組むときに入るので、あとから
    呼んでも組み上がった画面は日本語のままです。

    Chooses the words (requirement NFR-7.6). **There is no switch on screen**:
    switching languages is a future requirement, and this change carries only
    the separation it rests on. For now the language comes from `--lang en` or
    the operating system's locale, and with no `.po` the application runs in the
    Japanese written in the source.

    **Called before the screen is built**, because the words go into the
    controls as they are built; called later, a built screen stays Japanese. }
  SetDefaultLang('', 'languages');

  Application.CreateForm(TMainForm, MainForm);
  { 訳の幅だけを調べて終える道です（要件 NFR-7.6）。回帰試験が走らせます。
    A path that inspects the width of the translations and exits (NFR-7.6);
    the regression suite runs it. }
  if GetEnvironmentVariable('DEEPCW_TEXT_CHECK') <> '' then
  begin
    Halt(ReportTextWidths(MainForm.Canvas));
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
