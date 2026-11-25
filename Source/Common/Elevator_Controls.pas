unit Elevator_Controls;

// Copyright (c) 2026 VRAMの魔術師
// SPDX-License-Identifier: GPL-3.0-only
// フォントに依存しない階数表示器と、位置が固定された操作パネルを描画する。

interface

uses Elevator_Canvas, Elevator_Settings, Elevator_Timeline, Elevator_Structure;

procedure DrawControls(C: TElevatorCanvas; const S: TElevatorSettings;
  const Schedule: TElevatorSchedule; const F: TElevatorFrame; const Layout: TElevatorLayout);

implementation

uses Winapi.D2D1, System.Math, Elevator_Glyphs;

procedure Arrow(C: TElevatorCanvas; X, Y, Size: Single; Direction: Integer; Color: Cardinal);
var
  Tip, Base: Single;
begin
  Tip := Y - Direction * Size * 0.36;
  Base := Y + Direction * Size * 0.11;
  C.Polygon([Pt(X, Tip), Pt(X - Size * 0.40, Base), Pt(X - Size * 0.14, Base),
    Pt(X - Size * 0.14, Y + Direction * Size * 0.43),
    Pt(X + Size * 0.14, Y + Direction * Size * 0.43),
    Pt(X + Size * 0.14, Base), Pt(X + Size * 0.40, Base)], Color);
end;

procedure LabelAt(C: TElevatorCanvas; const Text: string; X, Y, Height: Single;
  Color: Cardinal; Style: TGlyphDisplay);
var
  Width, Advance, Left: Single;
  Ch: Char;
begin
  Width := Height * 0.60;
  Advance := Width * 1.24;
  Left := X - (Advance * (Length(Text) - 1) + Width) * 0.5;
  for Ch in Text do
  begin
    Glyph(C, Ch, Left, Y - Height * 0.5, Width, Height, Color, Style, True);
    Left := Left + Advance;
  end;
end;

procedure Dial(C: TElevatorCanvas; const S: TElevatorSettings; const Schedule: TElevatorSchedule;
  const F: TElevatorFrame; X, Y: Single);
var
  Angle, Progress, LX, LY: Single;
  I, Span, Divisions, Mark: Integer;
  Brass, Paper, Ink: Cardinal;
begin
  Brass := S.Colors[1];
  Paper := Mix(Brass, $FFF0C5, 0.86);
  Ink := Shade(Brass, 0.31);
  C.Disc(X, Y, 88, 32, Shade(Brass, 1.44), Brass, Shade(Brass, 0.48));
  C.Disc(X, Y, 79, 25, Shade(Paper, 1.18), Paper, Shade(Paper, 0.70));
  C.Ring(X, Y, 82, 28, 1, Shade(Brass, 0.44));
  Span := Schedule.LastFloor - Schedule.FirstFloor;
  Divisions := Min(Span, 6);
  for I := 0 to Divisions do
  begin
    Progress := 0.5;
    if Divisions > 0 then Progress := I / Divisions;
    Angle := (Progress - 0.5) * 2.16;
    Mark := Schedule.FirstFloor + Round(Span * Progress);
    LX := X + Sin(Angle) * 66;
    LY := Y + 18 - Cos(Angle) * 39;
    C.Line(LX, LY + 2, LX, LY + 5.8, 1.1, Ink);
    VectorText(C, FloorLabel(Mark), LX, LY + 10, 7, Ink);
  end;
  Progress := 0.5;
  if Span > 0 then Progress := (F.FloorPosition - Schedule.FirstFloor) / Span;
  Angle := (Progress - 0.5) * 2.16;
  C.Line(X, Y + 15, X + Sin(Angle) * 58, Y + 16 - Cos(Angle) * 34,
    2.4, Mix($922E26, Ink, 0.25));
  C.Disc(X, Y + 15, 4, 4, Shade(Brass, 1.36), Brass, Ink);
  // 目盛りの省略時も現在階を読める小窓を設ける。
  C.Box(X - 16, Y + 19, 32, 10, 2, Ink);
  VectorText(C, FloorLabel(F.FloorIndex), X, Y + 24, 7, Paper);
end;

procedure LampBank(C: TElevatorCanvas; const S: TElevatorSettings; const Schedule: TElevatorSchedule;
  const F: TElevatorFrame; X, Y: Single);
var
  Floors: TArray<Integer>;
  I, Slot: Integer;
  Left, W: Single;
  Lit, Listed: Boolean;
  Color: Cardinal;
begin
  Floors := FloorButtons(Schedule, 7);
  Listed := False;
  for I := 0 to High(Floors) do
    Listed := Listed or (Floors[I] = F.FloorIndex);
  if not Listed then
  begin
    // 省略階の間は中央の予備窓に現在階を表示する。
    Slot := Length(Floors) div 2;
    Floors[Slot] := F.FloorIndex;
    while (Slot > 0) and (Floors[Slot - 1] > Floors[Slot]) do
    begin
      Floors[Slot] := Floors[Slot - 1];
      Dec(Slot);
      Floors[Slot] := F.FloorIndex;
    end;
    while (Slot < High(Floors)) and (Floors[Slot + 1] < Floors[Slot]) do
    begin
      Floors[Slot] := Floors[Slot + 1];
      Inc(Slot);
      Floors[Slot] := F.FloorIndex;
    end;
  end;
  W := Min(40.0, 218 / Length(Floors));
  Left := X - W * Length(Floors) / 2;
  for I := 0 to High(Floors) do
  begin
    Lit := Floors[I] = F.FloorIndex;
    Color := S.Colors[3];
    if not Lit then Color := Shade(S.Colors[0], 0.81);
    C.Panel(Left + I * W + 2, Y - 16, W - 4, 31, 3, Shade(Color, 0.60),
      Shade(Color, 0.43), Shade(Color, 0.20));
    if Lit then C.Glow(Left + (I + 0.5) * W, Y, W * 0.6, 18, Color, 0.66);
    VectorText(C, FloorLabel(Floors[I]), Left + (I + 0.5) * W, Y, 10, Color);
  end;
end;

procedure Indicator(C: TElevatorCanvas; const S: TElevatorSettings; const Schedule: TElevatorSchedule;
  const F: TElevatorFrame; X, Y: Single);
var
  TextColor, Rim, Screen: Cardinal;
  Format: TGlyphDisplay;
begin
  TextColor := S.Colors[3];
  Rim := S.Colors[1];
  C.Metal(X - 158, Y - 32, 316, 65, 10, Rim);
  C.BoxEdge(X - 157, Y - 31, 314, 63, 9, 1.2, Shade(Rim, 0.55));
  Screen := $101B21;
  if S.Indicator = isNeedle then Screen := Shade(Rim, 0.48);
  if S.Indicator = isLCD then Screen := $14262E;
  C.Panel(X - 149, Y - 27, 298, 55, 7, Shade(Screen, 1.15), Screen, Shade(Screen, 0.79));
  case S.Indicator of
    isNeedle: Dial(C, S, Schedule, F, X, Y);
    isLamps: LampBank(C, S, Schedule, F, X, Y);
  else
    Format := cdVector;
    if S.Indicator = isSegment then Format := cdSevenSegment;
    if S.Indicator = isDots then Format := cdDots;
    C.Glow(X, Y, 89, 26, TextColor, 0.19);
    if S.Indicator = isLCD then
    begin
      C.BoxEdge(X - 77, Y - 21, 154, 42, 6, 1, TextColor, 0.26);
      C.Box(X - 73, Y + 16, 146, 1, 0, TextColor, 0.30);
    end
    else if S.Indicator = isFuture then
    begin
      C.StrokePath([Pt(X - 110, Y + 15), Pt(X - 91, Y - 14), Pt(X - 57, Y - 14)],
        2.6, TextColor, 0.69);
      C.StrokePath([Pt(X + 110, Y - 15), Pt(X + 91, Y + 14), Pt(X + 57, Y + 14)],
        2.6, TextColor, 0.69);
    end;
    LabelAt(C, FloorLabel(F.FloorIndex), X, Y, 25, TextColor, Format);
  end;
  if F.Direction = 1 then C.Glow(X + 127, Y, 18, 18, TextColor, 0.58);
  if F.Direction = -1 then C.Glow(X - 127, Y, 18, 18, TextColor, 0.58);
  Arrow(C, X + 127, Y, 15, 1, Mix(Shade(Rim, 1.10), TextColor, Ord(F.Direction = 1)));
  Arrow(C, X - 127, Y, 15, -1, Mix(Shade(Rim, 1.10), TextColor, Ord(F.Direction = -1)));
end;

function ButtonFace(C: TElevatorCanvas; const S: TElevatorSettings;
  X, Y, Radius: Single; Lit: Boolean): Cardinal;
var
  Base, Accent: Cardinal;
begin
  Accent := S.Colors[3];
  Base := Mix(S.Colors[0], S.Colors[1], 0.40);
  if Lit then
  begin
    C.Glow(X, Y, Radius * 1.80, Radius * 1.80, Accent, 0.48);
    Result := Mix(Accent, $FFFFFF, 0.44);
  end
  else Result := Mix(Base, $EDF1EA, 0.65);
  case S.Panel of
    psMechanical:
      begin
        C.Disc(X, Y, Radius, Radius, Shade(Base, 1.41), Base, Shade(Base, 0.35));
        C.Disc(X, Y, Radius - 3, Radius - 3, Shade(Base, 0.89), Shade(Base, 0.62), Shade(Base, 0.32));
        if Lit then C.Ring(X, Y, Radius - 1.6, Radius - 1.6, 1.9, Accent);
      end;
    psMetal:
      begin
        C.Disc(X, Y, Radius, Radius, Shade(Base, 1.59), Base, Shade(Base, 0.3));
        C.Disc(X, Y, Radius - 2.7, Radius - 2.7, Shade(Base, 1.02), Shade(Base, 0.70), Shade(Base, 0.35));
        if Lit then C.Ring(X, Y, Radius - 2, Radius - 2, 2.0, Accent);
      end;
    psTouch:
      begin
        C.Box(X - Radius, Y - Radius, Radius * 2, Radius * 2, 4, $172830);
        C.BoxEdge(X - Radius, Y - Radius, Radius * 2, Radius * 2, 4, 1.2,
          Mix(Shade(Base, 0.68), Accent, Ord(Lit)));
      end;
  end;
end;

procedure HallPanel(C: TElevatorCanvas; const S: TElevatorSettings; const Schedule: TElevatorSchedule;
  const F: TElevatorFrame; X, Y: Single);
var
  Color: Cardinal;
begin
  C.Metal(X - 28, Y - 61, 56, 122, 8, S.Colors[1]);
  C.Panel(X - 23, Y - 54, 46, 108, 6, $293238, $192329, $121A20);
  Color := ButtonFace(C, S, X, Y - 26, 17, F.ButtonLit and (Schedule.CallDirection > 0));
  Arrow(C, X, Y - 26, 17, 1, Color);
  Color := ButtonFace(C, S, X, Y + 26, 17, F.ButtonLit and (Schedule.CallDirection < 0));
  Arrow(C, X, Y + 26, 17, -1, Color);
end;

procedure DoorSymbol(C: TElevatorCanvas; X, Y: Single; Opening: Boolean; Color: Cardinal);
var
  D: Single;
begin
  D := 0.42;
  if not Opening then D := -D;
  C.StrokePath([Pt(X - 1.2 + D, Y - 0.85), Pt(X - 1.2 - D, Y),
    Pt(X - 1.2 + D, Y + 0.85)], 0.35, Color);
  C.StrokePath([Pt(X + 1.2 - D, Y - 0.85), Pt(X + 1.2 + D, Y),
    Pt(X + 1.2 - D, Y + 0.85)], 0.35, Color);
  C.Line(X, Y - 1.1, X, Y + 1.1, 0.36, Color);
end;

procedure CarPanel(C: TElevatorCanvas; const S: TElevatorSettings; const Schedule: TElevatorSchedule;
  const F: TElevatorFrame; X, Y: Single);
const
  COLUMNS = 2;
  BUTTON_RADIUS = 2.65;
var
  Floors: TArray<Integer>;
  I, Row: Integer;
  PX, PY, Top: Single;
  Plate, Idle, Engraving: Cardinal;
  procedure DrawButton(BX, BY: Single; Lit: Boolean);
  var
    Face: Cardinal;
  begin
    Face := Idle;
    if Lit then Face := Mix(Face, S.Colors[3], 0.75);
    if S.Panel = psTouch then
      C.Box(BX - BUTTON_RADIUS, BY - BUTTON_RADIUS, 2 * BUTTON_RADIUS,
        2 * BUTTON_RADIUS, 0.8, Face)
    else
      C.Disc(BX, BY, BUTTON_RADIUS, BUTTON_RADIUS, Shade(Face, 1.18),
        Face, Shade(Face, 0.68));
  end;
begin
  Floors := FloorButtons(Schedule, 12);
  Top := Y - 44;
  Plate := Mix(S.Colors[1], $A7A59D, 0.60);
  Idle := Shade(Plate, 0.68);
  Engraving := Shade(Plate, 1.40);
  C.Panel(X - 10.6, Top, 21.2, 88, 1.4, Shade(Plate, 1.16), Plate, Shade(Plate, 0.72));
  C.BoxEdge(X - 10.6, Top, 21.2, 88, 1.4, 0.85, Shade(Plate, 0.63));
  C.Box(X - 5.6, Top + 5, 11.2, 5, 0.7, Shade(Plate, 0.47));
  for I := 0 to High(Floors) do
  begin
    Row := I div COLUMNS;
    PX := X + (I mod COLUMNS - 0.5) * 8.1;
    PY := Top + 54 - Row * 7.2;
    DrawButton(PX, PY, F.ButtonLit and (Floors[I] = Schedule.Destination));
    VectorText(C, FloorLabel(Floors[I]), PX, PY, 1.8, Engraving);
  end;
  PY := Top + 66;
  DrawButton(X - 4.05, PY, False);
  DrawButton(X + 4.05, PY, False);
  DoorSymbol(C, X - 4.05, PY, True, Engraving);
  DoorSymbol(C, X + 4.05, PY, False, Engraving);
  C.Oval(X, Top + 78, 2.3, 2.3, Mix($723733, Idle, 0.40));
end;

procedure DrawControls(C: TElevatorCanvas; const S: TElevatorSettings;
  const Schedule: TElevatorSchedule; const F: TElevatorFrame; const Layout: TElevatorLayout);
var
  Transform: TD2D1Matrix3x2F;
begin
  if S.Scene = esCarFront then Exit;
  if S.Scene = esOutside then
  begin
    if S.DisplayVisible then Indicator(C, S, Schedule, F, Layout.IndicatorX, Layout.IndicatorY);
    if S.PanelVisible then HallPanel(C, S, Schedule, F, Layout.PanelX, Layout.PanelY);
    Exit;
  end;

  if S.DisplayVisible then
  begin
    Transform := C.ScaleAround(Layout.IndicatorX, Layout.IndicatorY, 0.26);
    try
      Indicator(C, S, Schedule, F, Layout.IndicatorX, Layout.IndicatorY);
    finally
      C.RestoreTransform(Transform);
    end;
  end;
  if S.PanelVisible then CarPanel(C, S, Schedule, F, Layout.PanelX, Layout.PanelY);
end;

end.

