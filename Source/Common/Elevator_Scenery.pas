unit Elevator_Scenery;

// Copyright (c) 2026 VRAMの魔術師
// SPDX-License-Identifier: GPL-3.0-only
// 窓・格子の透過部分に表示できる風景を、階位置から生成する。

interface

uses Elevator_Canvas, Elevator_Settings;

// 指定した矩形内だけに描画し、階位置が増えると建物を下方へ送る。
procedure DrawScenery(C: TElevatorCanvas; Style: TBackground; X, Y, W, H: Single;
  FloorPosition: Double);
// 縦窓用の簡易背景。呼び出し側で窓または開口部にクリップする。
procedure DrawShaft(C: TElevatorCanvas; X, Y, W, H: Single; FloorPosition: Double);
procedure DrawLandingView(C: TElevatorCanvas; X, Y, W, H: Single; FloorPosition: Double);

implementation

uses Winapi.D2D1, System.Math;

procedure DrawShaft(C: TElevatorCanvas; X, Y, W, H: Single; FloorPosition: Double);
var
  BeamY, Gap: Single;
  I: Integer;
begin
  C.Panel(X, Y, W, H, 0, $303D3E, $232D31, $151D21);
  C.Box(X + W * 0.19, Y, W * 0.07, H, 0, $263135);
  C.Box(X + W * 0.74, Y, W * 0.07, H, 0, $263135);
  C.Box(X + W * 0.24, Y, W * 0.007, H, 0, $657073, 0.55);
  C.Box(X + W * 0.76, Y, W * 0.007, H, 0, $657073, 0.55);
  Gap := H * 0.49;
  BeamY := Y + (FloorPosition - Floor(FloorPosition)) * Gap;
  for I := -1 to 2 do
  begin
    C.Box(X, BeamY + I * Gap, W, H * 0.031, 0, $10171A, 0.63);
    C.Box(X, BeamY + I * Gap + H * 0.031, W, H * 0.009, 0, $6D7778, 0.42);
  end;
end;

procedure Landing(C: TElevatorCanvas; X, Y, W, H: Single; FloorIndex: Integer);
var
  Wall, Dado, Base: Cardinal;
  I: Integer;
  PX: Single;
begin
  Wall := Mix($C3BDB0, $B1BCB2, ((FloorIndex mod 3 + 3) mod 3) * 0.25);
  Dado := $7B8984;
  Base := Shade(Wall, 0.72);
  C.Panel(X, Y, W, H, 0, Shade(Wall, 0.67), Wall, Base);
  C.Polygon([Pt(X, Y), Pt(X + W, Y), Pt(X + W * 0.81, Y + H * 0.14),
    Pt(X + W * 0.19, Y + H * 0.14)], Shade(Wall, 1.19));
  C.Glow(X + W * 0.49, Y + H * 0.17, W * 0.62, H * 0.29, $FFF0CF, 0.48);
  C.Panel(X + W * 0.15, Y + H * 0.14, W * 0.70, H * 0.014, 1, $EFE4CA, $FCF3DF, $CFC6AF);
  C.Box(X, Y + H * 0.37, W, H * 0.17, 0, Dado);
  C.Box(X, Y + H * 0.37, W, H * 0.01, 0, Shade(Wall, 0.78));
  for I := 1 to 4 do
  begin
    PX := X + W * (0.05 + I * 0.18);
    C.Line(PX, Y + H * 0.18, PX, Y + H * 0.36, 1.2, Base, 0.72);
  end;
  C.Panel(X + W * 0.35, Y + H * 0.20, W * 0.25, H * 0.32, 0, Shade(Wall, 0.55), Base, $66675F);
  C.Box(X + W * 0.38, Y + H * 0.23, W * 0.19, H * 0.105, 0, $818C86);
  C.Box(X + W * 0.65, Y + H * 0.24, W * 0.12, H * 0.054, 1, $635C50);
  C.Line(X + W * 0.68, Y + H * 0.268, X + W * 0.74, Y + H * 0.268, 1.8, $DED5BD);
  C.Panel(X, Y + H * 0.52, W, H * 0.48, 0, Shade(Dado, 0.70), $888379, $ADA89B);
  C.Line(X, Y + H * 0.52, X + W, Y + H * 0.52, 2, Shade(Dado, 0.62));
  for I := 0 to 4 do
    C.Line(X + W * I / 4, Y + H * 0.79, X + W * (0.30 + I * 0.10), Y + H * 0.52,
      0.8, Shade(Dado, 0.62), 0.7);
end;

procedure DrawLandingView(C: TElevatorCanvas; X, Y, W, H: Single; FloorPosition: Double);
var
  FloorIndex: Integer;
  Offset, Spacing: Single;
begin
  FloorIndex := Floor(FloorPosition);
  Spacing := H * 1.42;
  Offset := (FloorPosition - FloorIndex) * Spacing;
  DrawShaft(C, X, Y, W, H, FloorPosition);
  if Offset < H then Landing(C, X, Y + Offset, W, H, FloorIndex);
  if Offset > Spacing - H then Landing(C, X, Y + Offset - Spacing, W, H, FloorIndex + 1);
end;

type
  TGroundView = record
    X, Y, W, H: Single;
    Eye, Horizon: Single;
    function Project(WorldX, Distance, Height: Single): TD2D1Point2F;
  end;

function TGroundView.Project(WorldX, Distance, Height: Single): TD2D1Point2F;
begin
  Result := Pt(X + W * (0.5 + 0.96 * WorldX / Distance),
    Y + H * (Horizon + 0.68 * (Eye - Height) / Distance));
end;

procedure DrawRoad(C: TElevatorCanvas; const V: TGroundView; Color: Cardinal);
var
  I: Integer;
  NearDepth, FarDepth: Single;
begin
  C.Polygon([V.Project(-2.8, 0.75, 0), V.Project(2.8, 0.75, 0),
    V.Project(2.8, 174, 0), V.Project(-2.8, 174, 0)], Shade(Color, 0.61));
  C.Polygon([V.Project(-2.2, 0.75, 0), V.Project(2.2, 0.75, 0),
    V.Project(2.2, 174, 0), V.Project(-2.2, 174, 0)], Color);
  for I := 0 to 12 do
  begin
    NearDepth := 4 + I * 10;
    FarDepth := NearDepth + 5;
    C.Polygon([V.Project(-0.075, NearDepth, 0), V.Project(0.075, NearDepth, 0),
      V.Project(0.075, FarDepth, 0), V.Project(-0.075, FarDepth, 0)], $ECE0B8, 0.76);
  end;
end;

procedure DrawBuilding(C: TElevatorCanvas; const V: TGroundView; Style: TBackground;
  WorldX, Distance, W, Depth, Height: Single; Color: Cardinal);
var
  A, B, Fa, Fb, GroundA, GroundB, FarGround, RidgeNear, RidgeFar: TD2D1Point2F;
  Side, FarSide: TD2D1Point2F;
  Left, Right, EdgeX, Tilt, FloorY, HeightPx, Inset: Single;
  I, Count: Integer;
  Roof, Pane: Cardinal;
begin
  Left := WorldX - W * 0.5;
  Right := WorldX + W * 0.5;
  A := V.Project(Left, Distance, Height);
  B := V.Project(Right, Distance, Height);
  Fa := V.Project(Left, Distance + Depth, Height);
  Fb := V.Project(Right, Distance + Depth, Height);
  GroundA := V.Project(Left, Distance, 0);
  GroundB := V.Project(Right, Distance, 0);

  if WorldX < 0 then EdgeX := Right else EdgeX := Left;
  Side := V.Project(EdgeX, Distance, Height);
  FarSide := V.Project(EdgeX, Distance + Depth, Height);
  FarGround := V.Project(EdgeX, Distance + Depth, 0);
  C.Polygon([Side, FarSide, FarGround, V.Project(EdgeX, Distance, 0)], Shade(Color, 0.67));

  C.Panel(A.X, A.Y, B.X - A.X, GroundA.Y - A.Y, 0,
    Shade(Color, 1.07), Color, Shade(Color, 0.80));
  Roof := Shade(Color, 1.27);
  if Style = bgResidential then
  begin
    Roof := Mix(Color, $693F39, 0.76);
    Tilt := Height * 0.43;
    RidgeNear := V.Project(WorldX, Distance, Height + Tilt);
    RidgeFar := V.Project(WorldX, Distance + Depth, Height + Tilt);
    C.Polygon([A, RidgeNear, B], Shade(Roof, 0.77));
    if V.Eye > Height then
    begin
      C.Polygon([Fa, RidgeFar, RidgeNear, A], Shade(Roof, 1.27));
      C.Polygon([Fb, RidgeFar, RidgeNear, B], Roof);
    end
    else if WorldX < 0 then C.Polygon([B, Fb, RidgeFar, RidgeNear], Roof)
    else C.Polygon([A, Fa, RidgeFar, RidgeNear], Shade(Roof, 1.09));
  end
  else if V.Eye > Height then
  begin
    C.Polygon([A, B, Fb, Fa], Roof);
    // 屋上の設備で上面の見える範囲が伝わる。
    C.Polygon([V.Project(WorldX - W * 0.18, Distance + Depth * 0.31, Height),
      V.Project(WorldX + W * 0.14, Distance + Depth * 0.31, Height),
      V.Project(WorldX + W * 0.14, Distance + Depth * 0.68, Height),
      V.Project(WorldX - W * 0.18, Distance + Depth * 0.68, Height)], Shade(Color, 0.80));
  end;

  Count := EnsureRange(Round(Height * 0.85), 1, 6);
  HeightPx := GroundB.Y - B.Y;
  Inset := (B.X - A.X) * 0.14;
  Pane := Mix(Color, $263F52, 0.54);
  for I := 0 to Count - 1 do
  begin
    FloorY := A.Y + HeightPx * (I + 0.37) / Count;
    C.Box(A.X + Inset, FloorY, B.X - A.X - Inset * 2, HeightPx * 0.27 / Count, 0, Pane);
    if (Style = bgMall) and (I = Count - 1) then
      C.Box(A.X + Inset, FloorY, (B.X - A.X) * 0.41, HeightPx * 0.27 / Count, 0, $E1B78B);
  end;
end;

procedure DrawAboveGround(C: TElevatorCanvas; Style: TBackground; X, Y, W, H: Single;
  Position: Double);
const
  DISTANCES: array[0..3] of Single = (115, 76, 48, 27);
  BUILDING_COLORS: array[TBackground] of Cardinal = (0, $B7A089, $718D9D, $B7A69C, $879497);
  GROUND_COLORS: array[TBackground] of Cardinal = (0, $747D63, $718280, $939080, $708575);
  LINEAR_FLOORS = 16;
  HIGH_RISE_RANGE = 30;
var
  V: TGroundView;
  Altitude, ExtraFloors, FarY, Distance, Center, Width, Depth, Tall, Fog, Shift: Single;
  Row, Col, Variant: Integer;
  Ground, Color: Cardinal;
begin
  V.X := X;
  V.Y := Y;
  V.W := W;
  V.H := H;
  Altitude := Max(0.0, Position);
  // 低層では階ごとの変化を一定にし、高層だけ窓から遠景が消えないよう緩やかに圧縮する。
  if Altitude > LINEAR_FLOORS then
  begin
    ExtraFloors := Altitude - LINEAR_FLOORS;
    Altitude := LINEAR_FLOORS + HIGH_RISE_RANGE * ExtraFloors / (HIGH_RISE_RANGE + ExtraFloors);
  end;
  V.Eye := 1.45 + 1.03 * Altitude;
  V.Horizon := 0.64 - 0.010 * Altitude;
  FarY := Y + H * V.Horizon;

  C.Panel(X, Y, W, H, 0, $477895, $83A7B7, $DDCDB4);
  C.Glow(X + W * 0.76, Y + H * 0.22, W * 0.56, H * 0.43, $FFF1CC, 0.46);
  Ground := GROUND_COLORS[Style];
  C.Panel(X, FarY, W, Y + H - FarY, 0, Mix(Ground, $C6CBBC, 0.58), Ground, Shade(Ground, 0.66));
  if Style = bgScenic then
  begin
    C.Oval(X + W * 0.76, Y + H * 0.19, W * 0.038, H * 0.046, $FFF0C5);
    Shift := H * (0.023 + Altitude * 0.0005);
    C.Polygon([Pt(X, FarY + Shift), Pt(X + W * 0.16, FarY - H * 0.15 + Shift),
      Pt(X + W * 0.35, FarY - H * 0.045 + Shift), Pt(X + W * 0.62, FarY - H * 0.18 + Shift),
      Pt(X + W * 0.85, FarY - H * 0.064 + Shift), Pt(X + W, FarY + Shift),
      Pt(X + W, FarY + H * 0.05), Pt(X, FarY + H * 0.05)], $729198);
    C.Polygon([Pt(X, FarY + H * 0.078), Pt(X + W * 0.23, FarY - H * 0.052 + Shift),
      Pt(X + W * 0.47, FarY + H * 0.016), Pt(X + W * 0.72, FarY - H * 0.079 + Shift),
      Pt(X + W, FarY + H * 0.063), Pt(X + W, FarY + H * 0.105),
      Pt(X, FarY + H * 0.105)], Mix(Ground, $8DA7A1, 0.34));
  end;
  DrawRoad(C, V, Mix($586262, Ground, 0.25));

  for Row := Low(DISTANCES) to High(DISTANCES) do
    for Col := -2 to 2 do
    begin
      if Col = 0 then Continue;
      Variant := (Row * 7 + (Col + 2) * 11) mod 5;
      Distance := DISTANCES[Row] + Variant * 1.6;
      Center := Col * Distance * 0.163 + (Variant - 2) * Distance * 0.013;
      Width := Distance * (0.106 + Variant * 0.009);
      Depth := Width * (0.92 + (Variant mod 2) * 0.34);
      case Style of
        bgResidential: Tall := 1.7 + Variant * 0.52;
        bgOffice: Tall := 4.9 + Variant * 1.65;
        bgMall: Tall := 2.6 + Variant * 0.62;
      else
        Tall := 2.3 + Variant * 0.82;
      end;
      Fog := (3 - Row) * 0.14;
      Color := Mix(BUILDING_COLORS[Style], $C7CEC3, Fog);
      Color := Shade(Color, 0.84 + Variant * 0.09);
      DrawBuilding(C, V, Style, Center, Distance, Width, Depth, Tall, Color);
    end;
end;

procedure DrawUnderground(C: TElevatorCanvas; X, Y, W, H: Single; Position: Double);
var
  Offset, Gap, BeamY: Single;
  I: Integer;
begin
  C.Panel(X, Y, W, H, 0, $111619, $07090C, $030407);
  C.Box(X + W * 0.15, Y, W * 0.062, H, 0, $171A1C);
  C.Box(X + W * 0.788, Y, W * 0.062, H, 0, $171A1C);
  C.Line(X + W * 0.17, Y, X + W * 0.17, Y + H, 1.35, $35393D, 0.63);
  C.Line(X + W * 0.83, Y, X + W * 0.83, Y + H, 1.35, $35393D, 0.63);

  Gap := H * 0.55;
  Offset := Position * 0.82;
  Offset := (Offset - Floor(Offset)) * Gap;
  for I := -1 to 2 do
  begin
    BeamY := Y + Offset + I * Gap;
    C.Box(X, BeamY, W, H * 0.041, 0, $171C20);
    C.Line(X, BeamY + H * 0.008, X + W, BeamY + H * 0.008, 0.85, $34383E, 0.66);
    C.Box(X + W * 0.142, BeamY - H * 0.014, W * 0.080, H * 0.085, 0.9, $21262A);
    C.Box(X + W * 0.778, BeamY - H * 0.014, W * 0.080, H * 0.085, 0.9, $21262A);
  end;
end;

procedure DrawScenery(C: TElevatorCanvas; Style: TBackground; X, Y, W, H: Single;
  FloorPosition: Double);
const
  SURFACE_SPAN = 0.32;
var
  SlabH, Boundary: Single;
begin
  if (Style = bgNone) or (W <= 0) or (H <= 0) then Exit;
  C.PushClip(X, Y, W, H);
  try
    if FloorPosition >= 0 then
      DrawAboveGround(C, Style, X, Y, W, H, FloorPosition)
    else if FloorPosition <= -SURFACE_SPAN then
      DrawUnderground(C, X, Y, W, H, FloorPosition)
    else
    begin
      // 地上への開口が窓を横切る。梁は昇降路と同じ向きに流れて画面外へ抜ける。
      SlabH := H * 0.085;
      Boundary := Y - SlabH + (H + SlabH) * (1 + FloorPosition / SURFACE_SPAN);
      if Boundary > Y then
      begin
        C.PushClip(X, Y, W, Boundary - Y);
        try
          DrawAboveGround(C, Style, X, Y, W, H, 0);
        finally
          C.PopClip;
        end;
      end;
      C.PushClip(X, Max(Y, Boundary), W, Y + H - Max(Y, Boundary));
      try
        DrawUnderground(C, X, Y, W, H, FloorPosition);
        C.Panel(X, Boundary, W, SlabH, 0, $65625B, $393939, $111417);
        C.Box(X, Boundary + SlabH * 0.77, W, SlabH * 0.23, 0, $121518);
      finally
        C.PopClip;
      end;
    end;
  finally
    C.PopClip;
  end;
end;

end.

