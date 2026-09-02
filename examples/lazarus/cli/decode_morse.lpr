program decode_morse;

{ Console counterpart of the Python and Node.js examples: decode one WAV file
  with the DeepCW model and print the result. }

{$mode objfpc}{$H+}

uses
  SysUtils, DeepCW.Types, DeepCW.Onnx, DeepCW.Decoder;

procedure WriteUsage;
begin
  WriteLn('Usage: decode_morse --wav <file> [--model model.onnx] ' +
    '[--metadata model.onnx.json] [--onnxruntime <library>] [--verbose]');
end;

var
  ModelPath: string = '../../model.onnx';
  MetadataPath: string = '../../model.onnx.json';
  WavPath: string = '';
  RuntimePath: string = '';
  Verbose: Boolean = False;
  Decoder: TDeepCWDecoder;
  Index: Integer;
  Key, Value: string;
  Started: TDateTime;
begin
  Index := 1;
  while Index <= ParamCount do
  begin
    Key := ParamStr(Index);
    if (Key = '--help') or (Key = '-h') then
    begin
      WriteUsage;
      Halt(0);
    end;
    if Key = '--verbose' then
    begin
      Verbose := True;
      Inc(Index);
      Continue;
    end;

    Value := '';
    if Index < ParamCount then
      Value := ParamStr(Index + 1);
    if Value = '' then
    begin
      WriteLn(StdErr, 'Missing value for ', Key);
      WriteUsage;
      Halt(2);
    end;

    case Key of
      '--model': ModelPath := Value;
      '--metadata': MetadataPath := Value;
      '--wav': WavPath := Value;
      '--onnxruntime': RuntimePath := Value;
    else
      begin
        WriteLn(StdErr, 'Unknown option: ', Key);
        WriteUsage;
        Halt(2);
      end;
    end;
    Inc(Index, 2);
  end;

  if WavPath = '' then
  begin
    WriteLn(StdErr, 'Missing required argument: --wav');
    WriteUsage;
    Halt(2);
  end;

  try
    LoadOnnxRuntime(RuntimePath);
    if Verbose then
      WriteLn(StdErr, 'ONNX Runtime ', OnnxRuntimeVersion, ' from ', OnnxRuntimeLibraryPath);

    Decoder := TDeepCWDecoder.Create(ModelPath, MetadataPath);
    try
      Started := Now;
      WriteLn(Decoder.DecodeWavFile(WavPath));
      if Verbose then
        WriteLn(StdErr, Format('%.2f s of audio, %d spectrogram frames, %.0f ms',
          [Decoder.LastSeconds, Decoder.LastSpectrogram.Frames,
           (Now - Started) * 86400000]));
    finally
      Decoder.Free;
    end;
  except
    on E: Exception do
    begin
      WriteLn(StdErr, E.Message);
      Halt(1);
    end;
  end;
end.
