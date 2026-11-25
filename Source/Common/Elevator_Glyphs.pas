unit Elevator_Glyphs;

// Copyright (c) 2026 VRAMの魔術師
// SPDX-License-Identifier: GPL-3.0-only
// 階数表示と操作パネルの文字をストローク、独立した7セグメント、LEDドットで描画する。

interface

uses Elevator_Canvas;

type
  TGlyphDisplay = (cdVector, cdSevenSegment, cdDots);

procedure Glyph(Canvas: TElevatorCanvas; Ch: Char; X, Y, W, H: Single;
  Color: Cardinal; Display: TGlyphDisplay; Unlit: Boolean = False);
procedure VectorText(Canvas: TElevatorCanvas; const Text: string; CenterX, CenterY,
  Height: Single; Color: Cardinal; AdvanceScale: Single = 1.24);

implementation

uses System.Math, System.SysUtils, Winapi.D2D1;

const
  // 各座標は 0～9 の格子上の XY。/ はペンを離す位置。
  DIGITS: array['0'..'9'] of string = (
    '30608193968869391806031130',
    '225059/2989',
    '0211306081938465370999',
    '013060819284644464859697793908',
    '79700696',
    '90100443749688693908',
    '8050210406183969889684633305',
    '009039',
    '44231221406081928364351607297998966444',
    '9466361503113060819396784919');
  MASKS: array['0'..'9'] of Byte = ($3F,$06,$5B,$4F,$66,$6D,$7D,$07,$7F,$6F);
  DOTS: array['0'..'9',0..6] of Byte = (
    (14,17,19,21,25,17,14), (4,12,4,4,4,4,14), (14,17,1,2,4,8,31),
    (30,1,1,14,1,1,30), (2,6,10,18,31,2,2), (31,16,16,30,1,1,30),
    (14,16,16,30,17,17,14), (31,1,2,4,8,8,8), (14,17,17,14,17,17,14),
    (14,17,17,15,1,1,14));

function StrokeData(Ch: Char): string;
begin
  if CharInSet(Ch, ['0'..'9']) then Exit(DIGITS[Ch]);
  case Ch of
    'B': Result := '0900507182654606/46668788896909';
    'F': Result := '090090/0595';
    else Result := '';
  end;
end;

procedure VectorGlyph(Canvas: TElevatorCanvas; Ch: Char; X, Y, W, H: Single; Color: Cardinal);
var
  Data: string;
  P: array[0..23] of TD2D1Point2F;
  Index, Count: Integer;
  Stroke: Single;
begin
  Stroke := W * 0.14;
  if Ch = ':' then
  begin
    Canvas.Oval(X + W * 0.5, Y + H * 0.32, Stroke, Stroke, Color);
    Canvas.Oval(X + W * 0.5, Y + H * 0.72, Stroke, Stroke, Color);
    Exit;
  end;
  if Ch = '.' then
  begin
    Canvas.Oval(X + W * 0.5, Y + H * 0.92, Stroke, Stroke, Color);
    Exit;
  end;
  Data := StrokeData(Ch);
  Count := 0;
  Index := 1;
  while Index < Length(Data) do
  begin
    if Data[Index] = '/' then
    begin
      Canvas.StrokePath(Slice(P, Count), Stroke, Color);
      Count := 0;
      Inc(Index);
      Continue;
    end;
    P[Count] := Pt(X + W * (0.1 + 0.8 * (Ord(Data[Index]) - Ord('0')) / 9),
      Y + H * (0.07 + 0.86 * (Ord(Data[Index + 1]) - Ord('0')) / 9));
    Inc(Count);
    Inc(Index, 2);
  end;
  Canvas.StrokePath(Slice(P, Count), Stroke, Color);
end;

procedure SegmentedGlyph(Canvas: TElevatorCanvas; Ch: Char; X, Y, W, H: Single;
  Color: Cardinal; Unlit: Boolean);
var
  Mask: Byte;
  T, Mid: Single;
  procedure Segment(Index: Integer; X1, Y1, X2, Y2: Single);
  var
    Alpha: Single;
  begin
    Alpha := 1;
    if Mask and (1 shl Index) = 0 then
    begin
      if not Unlit then Exit;
      Alpha := 0.14;
    end;
    if X1 = X2 then
      Canvas.Polygon([Pt(X1, Y1), Pt(X1 + T, Y1 + T), Pt(X2 + T, Y2 - T), Pt(X2, Y2),
        Pt(X2 - T, Y2 - T), Pt(X1 - T, Y1 + T)], Color, Alpha)
    else
      Canvas.Polygon([Pt(X1, Y1), Pt(X1 + T, Y1 + T), Pt(X2 - T, Y2 + T), Pt(X2, Y2),
        Pt(X2 - T, Y2 - T), Pt(X1 + T, Y1 - T)], Color, Alpha);
  end;
begin
  if not CharInSet(Ch, ['0'..'9']) then
  begin
    VectorGlyph(Canvas, Ch, X, Y, W, H, Color);
    Exit;
  end;
  Mask := MASKS[Ch];
  T := Min(W * 0.092, H * 0.085);
  Mid := Y + H / 2;
  Segment(0, X + T * 2, Y + T, X + W - T * 2, Y + T);
  Segment(1, X + W - T, Y + T * 2, X + W - T, Mid - T);
  Segment(2, X + W - T, Mid + T, X + W - T, Y + H - T * 2);
  Segment(3, X + T * 2, Y + H - T, X + W - T * 2, Y + H - T);
  Segment(4, X + T, Mid + T, X + T, Y + H - T * 2);
  Segment(5, X + T, Y + T * 2, X + T, Mid - T);
  Segment(6, X + T * 2, Mid, X + W - T * 2, Mid);
end;

procedure DotGlyph(Canvas: TElevatorCanvas; Ch: Char; X, Y, W, H: Single;
  Color: Cardinal; Unlit: Boolean);
var
  Row, Col: Integer;
  DX, DY, PX, PY, Radius: Single;
begin
  if not CharInSet(Ch, ['0'..'9']) then
  begin
    VectorGlyph(Canvas, Ch, X, Y, W, H, Color);
    Exit;
  end;
  DX := W / 5;
  DY := H / 7;
  Radius := DX * 0.36;
  for Row := 0 to 6 do
    for Col := 0 to 4 do
    begin
      PX := X + (Col + 0.5) * DX;
      PY := Y + (Row + 0.5) * DY;
      if DOTS[Ch, Row] and (16 shr Col) <> 0 then
      begin
        Canvas.Oval(PX, PY, Radius * 1.45, Radius * 1.45, Color, 0.18);
        Canvas.Oval(PX, PY, Radius, Radius, Color);
        Canvas.Oval(PX - Radius * 0.16, PY - Radius * 0.16,
          Radius * 0.52, Radius * 0.52, Shade(Color, 1.55));
      end
      else if Unlit then
        Canvas.Oval(PX, PY, Radius * 0.76, Radius * 0.76, Color, 0.11);
    end;
end;

procedure Glyph(Canvas: TElevatorCanvas; Ch: Char; X, Y, W, H: Single;
  Color: Cardinal; Display: TGlyphDisplay; Unlit: Boolean);
begin
  case Display of
    cdVector: VectorGlyph(Canvas, Ch, X, Y, W, H, Color);
    cdSevenSegment: SegmentedGlyph(Canvas, Ch, X, Y, W, H, Color, Unlit);
    cdDots: DotGlyph(Canvas, Ch, X, Y, W, H, Color, Unlit);
  end;
end;

procedure VectorText(Canvas: TElevatorCanvas; const Text: string; CenterX, CenterY,
  Height: Single; Color: Cardinal; AdvanceScale: Single);
var
  Ch: Char;
  X, W: Single;
begin
  W := Height * 0.57;
  X := CenterX - W * Length(Text) * (AdvanceScale * 0.5);
  for Ch in Text do
  begin
    VectorGlyph(Canvas, Ch, X, CenterY - Height * 0.5, W, Height, Color);
    X := X + W * AdvanceScale;
  end;
end;

end.

