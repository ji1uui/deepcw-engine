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
  Interfaces, Forms, FrmMain;

{$R *.res}

begin
  Application.Title := 'DeepCW Morse Station';
  RequireDerivedFormResource := False;
  Application.Scaled := True;
  Application.Initialize;
  Application.CreateForm(TMainForm, MainForm);
  Application.Run;
end.
