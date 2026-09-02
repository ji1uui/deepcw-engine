unit DeepCW.Types;

{ Shared types for the DeepCW Lazarus example. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils;

type
  TSingleArray = array of Single;
  TDoubleArray = array of Double;
  TInt64Array = array of Int64;

  { Raised for every recoverable failure inside the DeepCW units so that the
    GUI can present one message box instead of guessing at exception classes. }
  EDeepCW = class(Exception);

  { A [Frames x Bins] row-major log-magnitude spectrogram. }
  TSpectrogram = record
    Frames: Integer;
    Bins: Integer;
    Data: TSingleArray;
  end;

function ClampInt(Value, Low, High: Integer): Integer;
function ClampDouble(Value, Low, High: Double): Double;

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

end.
