unit ViewColors;

{ 画面部品が共通で使う色の計算です。

  「地の色と文字の色を混ぜて薄くする」という操作は、受信テキストにも一覧にも
  出てきます。**部品ごとに写しを持つと、片方だけ直す日が来ます。**1 か所に置いて
  おきます（第 10 章 10.3）。

  Colour arithmetic shared by the view controls.

  Blending a foreground towards the background to fade it is wanted by the
  transcript and by the band map alike. **A copy in each control is one that will
  one day be fixed in only one of them**, so it lives in one place (chapter 10,
  rule 10.3). }

{$mode objfpc}{$H+}

interface

uses
  Graphics, DeepCW.Types;

{ 2 色を Amount(0..1) で混ぜます。0 で Background、1 で Foreground です。
  Blends two colours by Amount: zero gives Background, one gives Foreground. }
function BlendColor(Background, Foreground: TColor; Amount: Single): TColor;

implementation

function BlendColor(Background, Foreground: TColor; Amount: Single): TColor;
var
  BackRGB, ForeRGB: LongInt;
  R, G, B: Integer;
begin
  Amount := ClampDouble(Amount, 0, 1);
  BackRGB := ColorToRGB(Background);
  ForeRGB := ColorToRGB(Foreground);
  R := Round(Red(BackRGB) + (Red(ForeRGB) - Red(BackRGB)) * Amount);
  G := Round(Green(BackRGB) + (Green(ForeRGB) - Green(BackRGB)) * Amount);
  B := Round(Blue(BackRGB) + (Blue(ForeRGB) - Blue(BackRGB)) * Amount);
  Result := RGBToColor(ClampInt(R, 0, 255), ClampInt(G, 0, 255), ClampInt(B, 0, 255));
end;

end.
