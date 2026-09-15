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
  SysUtils, Classes, Interfaces, Forms, FrmMain;

{$R *.res}

var
  Problems: TStringList;
  Line: Integer;
begin
  Application.Title := 'DeepCW Morse Station';
  RequireDerivedFormResource := False;
  Application.Scaled := True;
  Application.Initialize;
  Application.CreateForm(TMainForm, MainForm);
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
