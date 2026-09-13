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
  Math, Graphics, DeepCW.Types;

const
  { 高コントラスト表示のときの、混ぜる量の下限（要件 NFR-5.5）。

    この単位の混色はすべて「地の色から文字の色へ Amount だけ寄せる」形なので、
    **Amount が小さいほど薄く、読みにくくなります。**下限を置けば、薄くする
    箇所すべてが一度に読みやすくなります。

    0.65 は測って決めました。白地に黒文字のとき、混ぜる量ごとの対比
    （WCAG の相対輝度比）は次のとおりです。

      量 0.20 → 1.61    量 0.45 → 3.36    量 0.65 → **7.00**
      量 0.30 → 2.12    量 0.55 → 4.74    量 0.75 → 10.37

    対比 4.5 に届くのは量 0.535、対比 7.0 に届くのは量 0.651 です。**高コント
    ラストと名乗る以上、4.5（AA 相当）ではなく 7.0（AAA 相当）を採りました。**
    この製品が想定する利用者は老眼を抱える運用者だからです（NFR-5 の前提）。

    **代償も書いておきます。**確からしさの濃淡（要件 FR-C.2）は 0.65〜1.0 の
    範囲へ縮みます。灰色 89 と黒 0 の差は残るので見分けは付きますが、**薄さの
    幅は狭くなります。**読めることを先に採る、という判断です。

    The floor on the blend amount in high contrast (requirement NFR-5.5).

    Every blend in this unit moves from the background toward the foreground by
    Amount, so **a smaller Amount is fainter and harder to read.** A floor lifts
    everything that fades, all at once.

    0.65 was measured. Against white with black text, the contrast (WCAG
    relative luminance ratio) by amount runs:

      0.20 -> 1.61    0.45 -> 3.36    0.65 -> **7.00**
      0.30 -> 2.12    0.55 -> 4.74    0.75 -> 10.37

    4.5 is reached at 0.535 and 7.0 at 0.651. **Calling something high contrast,
    7.0 (the AAA level) is the one to take, not 4.5**: the operators this product
    is for have presbyopia (the premise of NFR-5).

    **The cost is written down too.** The confidence shading (requirement
    FR-C.2) compresses into 0.65 to 1.0. Grey 89 against black 0 is still told
    apart, but **the range of faintness narrows.** Being readable comes
    first. }
  HIGH_CONTRAST_FLOOR = 0.65;

{ 2 色を Amount(0..1) で混ぜます。0 で Background、1 で Foreground です。
  高コントラスト表示のあいだは、Amount を下限まで持ち上げます。
  Blends two colours by Amount: zero gives Background, one gives Foreground.
  While high contrast is on, Amount is lifted to the floor. }
function BlendColor(Background, Foreground: TColor; Amount: Single): TColor;

{ 高コントラスト表示の入切（要件 NFR-5.5）。**薄くする箇所は部品ごとに散って
  いますが、薄くする計算はここ 1 か所です。**だから入口もここに置きます。
  High contrast on or off (requirement NFR-5.5). **What fades is spread across
  the controls, but the arithmetic that fades it is here alone**, so the switch
  belongs here too. }
procedure SetHighContrast(Value: Boolean);
function HighContrast: Boolean;

{ 2 色の対比（WCAG の相対輝度比、1.0〜21.0）。**下限を決めた根拠を、試験でも
  同じ式で確かめるため**に公開します。
  The contrast between two colours (the WCAG relative luminance ratio, 1.0 to
  21.0), public **so that the tests weigh the floor by the same formula that
  chose it.** }
function ContrastRatio(A, B: TColor): Double;

implementation

var
  FHighContrast: Boolean = False;

procedure SetHighContrast(Value: Boolean);
begin
  FHighContrast := Value;
end;

function HighContrast: Boolean;
begin
  Result := FHighContrast;
end;

function Luminance(Value: TColor): Double;
var
  RGB_: LongInt;

  function Channel(Level: Integer): Double;
  begin
    Result := Level / 255;
    if Result <= 0.03928 then
      Result := Result / 12.92
    else
      Result := Exp(Ln((Result + 0.055) / 1.055) * 2.4);
  end;

begin
  RGB_ := ColorToRGB(Value);
  Result := 0.2126 * Channel(Red(RGB_)) + 0.7152 * Channel(Green(RGB_)) +
    0.0722 * Channel(Blue(RGB_));
end;

function ContrastRatio(A, B: TColor): Double;
var
  Light, Dark: Double;
begin
  Light := Luminance(A);
  Dark := Luminance(B);
  if Dark > Light then
  begin
    Result := Light;
    Light := Dark;
    Dark := Result;
  end;
  Result := (Light + 0.05) / (Dark + 0.05);
end;

function BlendColor(Background, Foreground: TColor; Amount: Single): TColor;
var
  BackRGB, ForeRGB: LongInt;
  R, G, B: Integer;
begin
  Amount := ClampDouble(Amount, 0, 1);
  { **持ち上げるだけで、下げません。**既に濃いものを薄くしたら、高コントラスト
    ではなくなります。
    **Lifted, never lowered**: fading something already strong would not be high
    contrast. }
  if FHighContrast and (Amount < HIGH_CONTRAST_FLOOR) then
    Amount := HIGH_CONTRAST_FLOOR;
  BackRGB := ColorToRGB(Background);
  ForeRGB := ColorToRGB(Foreground);
  R := Round(Red(BackRGB) + (Red(ForeRGB) - Red(BackRGB)) * Amount);
  G := Round(Green(BackRGB) + (Green(ForeRGB) - Green(BackRGB)) * Amount);
  B := Round(Blue(BackRGB) + (Blue(ForeRGB) - Blue(BackRGB)) * Amount);
  Result := RGBToColor(ClampInt(R, 0, 255), ClampInt(G, 0, 255), ClampInt(B, 0, 255));
end;

end.
