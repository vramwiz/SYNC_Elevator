unit Elevator_Structure;

// Copyright (c) 2026 VRAMの魔術師
// SPDX-License-Identifier: GPL-3.0-only
// 固定の車体と乗り場、扉の開閉、開口部の透過をレイヤー別に描画する。

interface

uses Winapi.D2D1, Elevator_Canvas, Elevator_Settings, Elevator_Timeline;

type
  TOpening = record
    X, Y, W, H: Single;
  end;
  TElevatorLayout = record
    Opening: TOpening;
    NearPlane, FarPlane: TOpening; // 客室の手前と突き当たり
    DepthScale: Single;
    Panorama: Boolean;
    IndicatorX, IndicatorY, PanelX, PanelY: Single;
  end;
  TElevatorFloorView = record
    Active: Boolean;
    Motion: TFloorMotion;
    Bitmap: ID2D1Bitmap;
  end;

const
  DESIGN_W = 960;
  DESIGN_H = 720;

function ElevatorLayout(Scene: TElevatorScene; Kind: TElevatorKind): TElevatorLayout;
procedure DrawRear(C: TElevatorCanvas; const S: TElevatorSettings; const Schedule: TElevatorSchedule;
  const F: TElevatorFrame; const Layout: TElevatorLayout; const View: TElevatorFloorView);
procedure DrawFront(C: TElevatorCanvas; const S: TElevatorSettings; const F: TElevatorFrame;
  const Layout: TElevatorLayout);

implementation

uses System.Math, Elevator_Scenery;

const
  CAR_HORIZON = 264;
  CAR_DEPTH_SCALE = 0.56;
  LANDING_JAMB_W = 51;
  LANDING_WING_W = 33;

function ElevatorLayout(Scene: TElevatorScene; Kind: TElevatorKind): TElevatorLayout;
begin
  Result := Default(TElevatorLayout);
  if Scene <> esInside then
  begin
    Result.Opening.Y := 165;
    Result.Opening.W := 434;
    Result.Opening.X := (DESIGN_W - Result.Opening.W) * 0.5;
    Result.Opening.H := 460;
    Result.IndicatorX := DESIGN_W * 0.5;
    Result.IndicatorY := 113;
    Result.PanelX := Result.Opening.X + Result.Opening.W + LANDING_JAMB_W + 2;
    Result.PanelY := 383;
  end
  else
  begin
    Result.Panorama := Kind = ekGlass;
    Result.DepthScale := CAR_DEPTH_SCALE;
    if Result.Panorama then Result.DepthScale := 0.82;
    Result.NearPlane.X := 202;
    Result.NearPlane.Y := 18;
    Result.NearPlane.W := DESIGN_W - 2 * Result.NearPlane.X;
    Result.NearPlane.H := DESIGN_H - 2 * Result.NearPlane.Y;
    Result.FarPlane.W := Result.NearPlane.W * Result.DepthScale;
    Result.FarPlane.H := Result.NearPlane.H * Result.DepthScale;
    Result.FarPlane.X := (DESIGN_W - Result.FarPlane.W) * 0.5;
    Result.FarPlane.Y := CAR_HORIZON + (Result.NearPlane.Y - CAR_HORIZON) * Result.DepthScale;
    if Result.Panorama then Exit;
    Result.Opening.W := 226;
    Result.Opening.X := (DESIGN_W - Result.Opening.W) * 0.5;
    Result.Opening.Y := Result.FarPlane.Y + 65;
    Result.Opening.H := Result.FarPlane.Y + Result.FarPlane.H - Result.Opening.Y;
    Result.IndicatorX := DESIGN_W * 0.5;
    Result.IndicatorY := Result.Opening.Y - 25;
    Result.PanelX := Result.Opening.X + Result.Opening.W + 21;
    Result.PanelY := Result.Opening.Y + Result.Opening.H * 0.45;
  end;
end;

type
  TSlidingLeaf = record
    Body, Window: TOpening; // 窓幅 0 は板戸
  end;
  TSlidingLeaves = record
    Items: array[0..3] of TSlidingLeaf;
    Count: Integer;
  end;

function SlidingLeaves(const S: TElevatorSettings; const F: TElevatorFrame;
  const O: TOpening): TSlidingLeaves;
var
  Half, Gap, Quarter, Overlap: Single;
  HasWindows: Boolean;
  procedure Append(X, W, WindowCenter: Single);
  var
    Leaf: ^TSlidingLeaf;
  begin
    Leaf := @Result.Items[Result.Count];
    Inc(Result.Count);
    Leaf^.Body.X := X;
    Leaf^.Body.Y := O.Y;
    Leaf^.Body.W := W;
    Leaf^.Body.H := O.H;
    if not HasWindows or (WindowCenter <= 0) then Exit;
    Leaf^.Window.W := Min(O.W * 0.105, W * 0.48);
    Leaf^.Window.H := O.H * 0.40;
    Leaf^.Window.X := X + W * WindowCenter - Leaf^.Window.W * 0.5;
    Leaf^.Window.Y := O.Y + O.H * 0.15;
  end;
begin
  Result := Default(TSlidingLeaves);
  if F.OpenAmount >= 1 then Exit;
  HasWindows := HasDoorWindow(S);
  Half := O.W / 2;
  Gap := Half * F.OpenAmount;
  case S.Door of
    dsCenter:
      begin
        Append(O.X - Gap, Half, 0.61);
        Append(O.X + Half + Gap, Half, 0.39);
      end;
    dsSingle: Append(O.X - O.W * F.OpenAmount, O.W, 0.57);
    dsMulti:
      begin
        Quarter := Half * 0.5;
        Overlap := 2 * (1 - F.OpenAmount);
        Append(O.X - Quarter * F.OpenAmount, Quarter + Overlap, 0);
        Append(O.X + O.W - Quarter + Quarter * F.OpenAmount - Overlap, Quarter + Overlap, 0);
        Append(O.X + Quarter - Gap, Quarter, 0.52);
        Append(O.X + Half + Gap, Quarter, 0.48);
      end;
  end;
end;

procedure DrawTravelView(C: TElevatorCanvas; Style: TBackground; const View: TElevatorFloorView;
  X, Y, W, H: Single; Position: Double; CoverMissingBackground: Boolean); forward;

procedure Cabin(C: TElevatorCanvas; const S: TElevatorSettings; const F: TElevatorFrame;
  const O: TOpening; const View: TElevatorFloorView; Through: Boolean);
var
  X, Y, W, H, BackLeft, BackRight, BackTop, BackBottom, LampY, P: Single;
  I: Integer;
  Wall, FloorColor, Ceiling, Accent: Cardinal;
begin
  X := O.X;
  Y := O.Y;
  W := O.W;
  H := O.H;
  BackLeft := X + W * 0.19;
  BackRight := X + W * 0.81;
  if S.Kind = ekGlass then
  begin
    BackLeft := X + W * 0.08;
    BackRight := X + W * 0.92;
  end;
  BackTop := Y + H * 0.13;
  BackBottom := Y + H * 0.83;
  Wall := S.Colors[2];
  FloorColor := Shade(Wall, 0.60);
  Ceiling := Shade(S.Colors[1], 0.69);
  Accent := S.Colors[3];
  C.PushClip(X, Y, W, H);
  try
    if Through then
      DrawTravelView(C, S.Background, View, BackLeft, BackTop, BackRight - BackLeft,
        BackBottom - BackTop, F.FloorPosition, False)
    else
    begin
      C.Panel(BackLeft, BackTop, BackRight - BackLeft, BackBottom - BackTop, 0,
        Shade(Wall, 1.24), Wall, Shade(Wall, 0.52));
      for I := 1 to 3 do
      begin
        P := BackLeft + (BackRight - BackLeft) * I / 4;
        C.Line(P, BackTop + 5, P, BackBottom - 4, 1.2, Shade(Wall, 0.64));
        C.Line(P + 2, BackTop + 8, P + 2, BackBottom - 4, 1, Shade(Wall, 1.28), 0.53);
      end;
      if HasDoorWindow(S) then
      begin
        // 縦窓からも奥の内装が読めるよう、照明の映り込みと腰板の継ぎ目を出す。
        C.Glow(X + W * 0.5, Y + H * 0.24, W * 0.42, H * 0.16,
          Mix(Accent, $FFF7E6, 0.72), 0.31);
        C.Line(BackLeft, Y + H * 0.48, BackRight, Y + H * 0.48, 2.6, Shade(Wall, 0.59));
        C.Line(BackLeft, Y + H * 0.48 - 1.5, BackRight, Y + H * 0.48 - 1.5,
          1.3, Shade(Wall, 1.33), 0.72);
      end;
    end;
    C.Polygon([Pt(X, Y), Pt(BackLeft, BackTop), Pt(BackLeft, BackBottom),
      Pt(X, Y + H)], Shade(Wall, 0.74));
    C.Polygon([Pt(X + W, Y), Pt(BackRight, BackTop), Pt(BackRight, BackBottom),
      Pt(X + W, Y + H)], Shade(Wall, 0.58));
    C.Polygon([Pt(X, Y), Pt(X + W, Y), Pt(BackRight, BackTop), Pt(BackLeft, BackTop)], Ceiling);
    C.Polygon([Pt(X, Y + H), Pt(BackLeft, BackBottom), Pt(BackRight, BackBottom),
      Pt(X + W, Y + H)], FloorColor);
    for I := 0 to 6 do
      C.Line(X + W * I / 6, Y + H, BackLeft + (BackRight - BackLeft) * I / 6,
        BackBottom, 1, Shade(FloorColor, 1.14));
    C.Line(X + W * 0.12, Y + H * 0.91, X + W * 0.88, Y + H * 0.91, 1, Shade(FloorColor, 1.19));
    LampY := Y + H * 0.07;
    C.Glow(X + W * 0.5, LampY, W * 0.45, H * 0.17, Mix(Accent, $FFF8DC, 0.7), 0.42);
    C.Box(X + W * 0.29, LampY - 4, W * 0.42, 8, 4, Mix(Accent, $FFFFFF, 0.77));
    C.Line(X, Y + H * 0.68, BackLeft, Y + H * 0.64, 4, Shade(S.Colors[0], 1.24));
    C.Line(BackRight, Y + H * 0.64, X + W, Y + H * 0.68, 4, Shade(S.Colors[0], 1.24));
    C.Line(BackLeft, Y + H * 0.64, BackRight, Y + H * 0.64, 5, Shade(S.Colors[0], 0.46));
    C.Line(BackLeft, Y + H * 0.64 - 1.5, BackRight, Y + H * 0.64 - 1.5,
      2, Shade(S.Colors[0], 1.32));
    if Through then
      for I := 0 to 1 do
      begin
        P := BackLeft + (BackRight - BackLeft) * I;
        C.Line(P, BackTop, P, BackBottom, 5, Shade(S.Colors[1], 1.11));
      end;
  finally
    C.PopClip;
  end;
end;

type
  TPlane = array[0..3] of TD2D1Point2F;

function CabinProjection(const L: TElevatorLayout; Across, Depth, Height: Single): TD2D1Point2F;
var
  Scale: Single;
begin
  // 同じ消失点と縮尺を、壁、床、天井、手すり、設備のすべてで使う。
  // Depth は正方形の客室を手前から扉面まで進む距離の比率。
  Scale := 1 / (1 + Depth * (1 / L.DepthScale - 1));
  Result := Pt(L.NearPlane.X + L.NearPlane.W * Across, L.NearPlane.Y + L.NearPlane.H * Height);
  Result.X := DESIGN_W * 0.5 + (Result.X - DESIGN_W * 0.5) * Scale;
  Result.Y := CAR_HORIZON + (Result.Y - CAR_HORIZON) * Scale;
end;

function CabinColor(const S: TElevatorSettings): Cardinal;
begin
  Result := Mix(S.Colors[2], $D6D0C2, 0.61);
end;

function ShowingStationaryFloor(const View: TElevatorFloorView): Boolean;
begin
  Result := View.Active and (View.Motion.Phase = fpStill);
end;

procedure DrawMovingFloor(C: TElevatorCanvas; const View: TElevatorFloorView; X, Y, W, H: Single);
var
  Shift, VisibleH: Single;
begin
  if View.Bitmap = nil then Exit;
  Shift := View.Motion.Offset * H;
  VisibleH := H - Abs(Shift);
  if VisibleH <= 0 then Exit;
  // 画像を窓の中で移動し、画像が抜けた範囲には先に描いた昇降路を残す。
  C.PushClip(X, Y + Max(0.0, Shift), W, VisibleH);
  try
    C.DrawBitmap(View.Bitmap, 0, Shift, DESIGN_W, DESIGN_H);
  finally
    C.PopClip;
  end;
end;

procedure DrawTravelView(C: TElevatorCanvas; Style: TBackground; const View: TElevatorFloorView;
  X, Y, W, H: Single; Position: Double; CoverMissingBackground: Boolean);
begin
  if ShowingStationaryFloor(View) then Exit;
  if CoverMissingBackground and View.Active and (Style = bgNone) and (Position >= 0) then
    DrawShaft(C, X, Y, W, H, Position)
  else DrawScenery(C, Style, X, Y, W, H, Position);
  DrawMovingFloor(C, View, X, Y, W, H);
end;

procedure CarSideWall(C: TElevatorCanvas; const S: TElevatorSettings; const F: TElevatorFrame;
  const L: TElevatorLayout; const View: TElevatorFloorView; Across: Single);
const
  WINDOW_NEAR = 0.16;
  WINDOW_FAR = 0.78;
  WINDOW_TOP = 0.16;
  WINDOW_BOTTOM = 0.46;
var
  Window: TPlane;
  NearPoint, FarPoint, Stock, FarStock: TD2D1Point2F;
  Wall, Rail: Cardinal;
  Left, Top, W, H: Single;
  function WallPatch(FromDepth, ToDepth, FromHeight, ToHeight: Single): TPlane;
  begin
    Result[0] := CabinProjection(L, Across, FromDepth, FromHeight);
    Result[1] := CabinProjection(L, Across, ToDepth, FromHeight);
    Result[2] := CabinProjection(L, Across, ToDepth, ToHeight);
    Result[3] := CabinProjection(L, Across, FromDepth, ToHeight);
  end;
  procedure FillWall(FromDepth, ToDepth, FromHeight, ToHeight: Single);
  begin
    C.GradientPolygon(WallPatch(FromDepth, ToDepth, FromHeight, ToHeight), NearPoint, FarPoint,
      Shade(Wall, 1.18), Wall, Shade(Wall, 0.78));
  end;
begin
  Wall := CabinColor(S);
  NearPoint := CabinProjection(L, Across, 0, 0.19);
  FarPoint := CabinProjection(L, Across, 1, 0.36);
  if (Across = 1) and (S.Kind in [ekGlass, ekConstruction, ekMine]) then
  begin
    FillWall(0, WINDOW_NEAR, 0, 1);
    FillWall(WINDOW_FAR, 1, 0, 1);
    FillWall(WINDOW_NEAR, WINDOW_FAR, 0, WINDOW_TOP);
    FillWall(WINDOW_NEAR, WINDOW_FAR, WINDOW_BOTTOM, 1);
    Window := WallPatch(WINDOW_NEAR, WINDOW_FAR, WINDOW_TOP, WINDOW_BOTTOM);
    if (S.Background <> bgNone) or (View.Active and not ShowingStationaryFloor(View)) then
    begin
      Left := Window[1].X;
      Top := Min(Window[0].Y, Window[1].Y);
      W := Window[0].X - Left;
      H := Max(Window[2].Y, Window[3].Y) - Top;
      C.PushShapeClip(Window, Left, Top, W, H);
      try
        DrawTravelView(C, S.Background, View, Left, Top, W, H, F.FloorPosition, True);
      finally
        C.PopShapeClip;
      end;
    end;
    C.StrokePath(Window, 3.2, Shade(Wall, 0.56), 1, True);
    if S.Kind <> ekGlass then
    begin
      Stock := CabinProjection(L, Across, 0.40, WINDOW_TOP);
      FarStock := CabinProjection(L, Across, 0.40, WINDOW_BOTTOM);
      C.Line(Stock.X, Stock.Y, FarStock.X, FarStock.Y, 2.8, Shade(Wall, 0.67));
    end;
  end
  else FillWall(0, 1, 0, 1);

  C.Polygon(WallPatch(0, 1, 0.974, 1), Shade(Wall, 0.60));
  Stock := CabinProjection(L, Across, 0.48, 0);
  FarStock := CabinProjection(L, Across, 0.48, 0.974);
  if (Across = 0) or not (S.Kind in [ekGlass, ekConstruction, ekMine]) then
    C.Line(Stock.X, Stock.Y, FarStock.X, FarStock.Y, 0.85, Shade(Wall, 0.77));

  NearPoint := CabinProjection(L, Across, 0.025, 0.65);
  FarPoint := CabinProjection(L, Across, 0.91, 0.65);
  // 取付金具と手すりも壁の奥行きに沿って細くなる。
  Rail := Mix(S.Colors[0], $B6B4AC, 0.60);
  Stock := CabinProjection(L, Across, 0.17, 0.65);
  FarStock := CabinProjection(L, Across, 0.76, 0.65);
  C.Oval(Stock.X, Stock.Y + 3, 3.5, 5, Shade(Rail, 0.70));
  C.Oval(FarStock.X, FarStock.Y + 2, 2.4, 3.5, Shade(Rail, 0.62));
  C.Polygon([Pt(NearPoint.X, NearPoint.Y + 5), Pt(FarPoint.X, FarPoint.Y + 1.5),
    Pt(FarPoint.X, FarPoint.Y + 5), Pt(NearPoint.X, NearPoint.Y + 11)], Shade(Wall, 0.62), 0.58);
  C.GradientPolygon([Pt(NearPoint.X, NearPoint.Y - 3.5), Pt(FarPoint.X, FarPoint.Y - 1.8),
    Pt(FarPoint.X, FarPoint.Y + 2.2), Pt(NearPoint.X, NearPoint.Y + 4.1)],
    Pt(NearPoint.X, NearPoint.Y - 3.5), Pt(NearPoint.X, NearPoint.Y + 4.1),
    Shade(Rail, 1.35), Rail, Shade(Rail, 0.55));
end;

procedure CarCeiling(C: TElevatorCanvas; const S: TElevatorSettings; const L: TElevatorLayout);
var
  A, B: TD2D1Point2F;
  Ceiling, Light: Cardinal;
  I: Integer;
  function Patch(X1, X2, D1, D2: Single): TPlane;
  begin
    Result[0] := CabinProjection(L, X1, D1, 0);
    Result[1] := CabinProjection(L, X2, D1, 0);
    Result[2] := CabinProjection(L, X2, D2, 0);
    Result[3] := CabinProjection(L, X1, D2, 0);
  end;
begin
  Ceiling := Mix(CabinColor(S), $F4EEE1, 0.45);
  C.GradientPolygon(Patch(0, 1, 0, 1), CabinProjection(L, 0.5, 0, 0),
    CabinProjection(L, 0.5, 1, 0), Shade(Ceiling, 1.12), Ceiling, Shade(Ceiling, 0.72));
  Light := Mix(S.Colors[3], $FFF7E6, 0.92);
  C.Polygon(Patch(0.125, 0.875, 0.08, 0.73), Shade(Ceiling, 0.62));
  C.GradientPolygon(Patch(0.14, 0.86, 0.10, 0.70), CabinProjection(L, 0.5, 0.10, 0),
    CabinProjection(L, 0.5, 0.70, 0), Shade(Light, 0.93), $FFFDF5, Shade(Light, 0.95));
  for I := 1 to 2 do
  begin
    A := CabinProjection(L, 0.14, 0.10 + I * 0.20, 0);
    B := CabinProjection(L, 0.86, 0.10 + I * 0.20, 0);
    C.Line(A.X, A.Y, B.X, B.Y, 1.5, Shade(Ceiling, 0.73));
  end;
  A := CabinProjection(L, 0.5, 0.10, 0);
  B := CabinProjection(L, 0.5, 0.70, 0);
  C.Line(A.X, A.Y, B.X, B.Y, 1.3, Shade(Ceiling, 0.73));
end;

procedure CarFloor(C: TElevatorCanvas; const S: TElevatorSettings; const L: TElevatorLayout);
const
  TILES = 5;
var
  A, B: TD2D1Point2F;
  Base, Grout: Cardinal;
  I, J: Integer;
  function Patch(X1, X2, D1, D2: Single): TPlane;
  begin
    Result[0] := CabinProjection(L, X1, D1, 1);
    Result[1] := CabinProjection(L, X2, D1, 1);
    Result[2] := CabinProjection(L, X2, D2, 1);
    Result[3] := CabinProjection(L, X1, D2, 1);
  end;
begin
  Base := Mix(S.Colors[2], $8B8174, 0.66);
  Grout := Shade(Base, 0.78);
  C.GradientPolygon(Patch(0, 1, 0, 1), CabinProjection(L, 0.5, 0, 1),
    CabinProjection(L, 0.5, 1, 1), Shade(Base, 0.84), Base, Shade(Base, 1.20));
  for I := 0 to TILES - 1 do
    for J := 0 to TILES - 1 do
      if Odd(I + J) then
        C.Polygon(Patch(I / TILES, (I + 1) / TILES, J / TILES, (J + 1) / TILES),
          Shade(Base, 1.55), 0.22);
  for I := 1 to TILES - 1 do
  begin
    A := CabinProjection(L, I / TILES, 0, 1);
    B := CabinProjection(L, I / TILES, 1, 1);
    C.Line(A.X, A.Y, B.X, B.Y, 0.8, Grout, 0.73);
    A := CabinProjection(L, 0, I / TILES, 1);
    B := CabinProjection(L, 1, I / TILES, 1);
    C.Line(A.X, A.Y, B.X, B.Y, 0.8, Grout, 0.73);
  end;
end;

procedure CarEndWall(C: TElevatorCanvas; const S: TElevatorSettings; const L: TElevatorLayout);
var
  FarWall, O: TOpening;
  Wall: Cardinal;
  EdgeW, HeadH: Single;
begin
  FarWall := L.FarPlane;
  O := L.Opening;
  Wall := CabinColor(S);
  EdgeW := O.X - FarWall.X;
  HeadH := O.Y - FarWall.Y;
  C.Panel(FarWall.X, FarWall.Y - 0.8, FarWall.W, HeadH + 0.8, 0,
    Shade(Wall, 0.85), Shade(Wall, 1.08), Shade(Wall, 1.13));
  C.Panel(FarWall.X, O.Y - 0.8, EdgeW + 0.4, O.H + 0.8, 0,
    Shade(Wall, 1.11), Wall, Shade(Wall, 0.79));
  C.Panel(O.X + O.W - 0.4, O.Y - 0.8, EdgeW + 0.4, O.H + 0.8, 0,
    Shade(Wall, 1.11), Wall, Shade(Wall, 0.79));
  C.Line(FarWall.X, FarWall.Y + 0.6, FarWall.X + FarWall.W, FarWall.Y + 0.6, 1.4, Shade(Wall, 0.52), 0.65);
end;

procedure Interior(C: TElevatorCanvas; const S: TElevatorSettings; const F: TElevatorFrame;
  const L: TElevatorLayout; const View: TElevatorFloorView);
var
  O: TOpening;
  StripWidth: Single;
  procedure DrawDoorBackground(X: Single);
  begin
    C.PushClip(X, O.Y, StripWidth, O.H);
    try
      DrawTravelView(C, S.Background, View, O.X, O.Y, O.W, O.H, F.FloorPosition, True);
    finally
      C.PopClip;
    end;
  end;
begin
  CarSideWall(C, S, F, L, View, 0);
  CarSideWall(C, S, F, L, View, 1);
  CarCeiling(C, S, L);
  CarFloor(C, S, L);
  CarEndWall(C, S, L);
  if not SeeThroughDoor(S.Door) or ShowingStationaryFloor(View) or
    ((S.Background = bgNone) and not View.Active) then Exit;
  O := L.Opening;
  // 開いた中央部は降車先の背景を通す。風景は閉じている戸の領域だけに描く。
  StripWidth := Floor(O.W * (1 - F.OpenAmount) * 0.5);
  if StripWidth <= 0 then Exit;
  DrawDoorBackground(O.X);
  DrawDoorBackground(O.X + O.W - StripWidth);
end;

procedure PanoramaRear(C: TElevatorCanvas; const S: TElevatorSettings; const F: TElevatorFrame;
  const L: TElevatorLayout; const View: TElevatorFloorView);
var
  N, B: TOpening;
begin
  N := L.NearPlane;
  // 左右と正面奥は一続きの眺望。床と天井を後から重ねて視野を囲う。
  C.PushClip(N.X, N.Y, N.W, N.H);
  try
    DrawTravelView(C, S.Background, View, N.X, N.Y, N.W, N.H, F.FloorPosition, True);
  finally
    C.PopClip;
  end;
  if S.Background <> bgNone then
  begin
    B := L.FarPlane;
    C.Polygon([Pt(B.X + B.W * 0.18, B.Y), Pt(B.X + B.W * 0.30, B.Y),
      Pt(B.X + B.W * 0.13, B.Y + B.H), Pt(B.X + B.W * 0.05, B.Y + B.H)], $E7F5EF, 0.07);
  end;
  CarFloor(C, S, L);
  CarCeiling(C, S, L);
end;

procedure PanoramaFrame(C: TElevatorCanvas; const S: TElevatorSettings; const L: TElevatorLayout);
var
  N, B: TOpening;
  FarLeft, FarRight, NearLeft, NearRight: TD2D1Point2F;
  Frame, Rail: Cardinal;
begin
  N := L.NearPlane;
  B := L.FarPlane;
  Frame := Mix(S.Colors[1], $3F5154, 0.50);
  Rail := Mix(S.Colors[0], $CBD5D4, 0.52);
  C.Panel(B.X, B.Y - 3, B.W, 9, 0, Shade(Frame, 1.14), Frame, Shade(Frame, 0.65));
  C.Panel(B.X, B.Y + B.H - 8, B.W, 12, 0, Shade(Frame, 1.18), Frame, Shade(Frame, 0.66));
  C.Panel(B.X - 2, B.Y, 5, B.H, 0, Shade(Frame, 1.13), Frame, Shade(Frame, 0.72));
  C.Panel(B.X + B.W - 3, B.Y, 5, B.H, 0, Shade(Frame, 1.15), Frame, Shade(Frame, 0.72));
  C.Line(N.X, N.Y, N.X, N.Y + N.H, 6, Shade(Frame, 0.84));
  C.Line(N.X + N.W, N.Y, N.X + N.W, N.Y + N.H, 6, Shade(Frame, 0.84));
  C.Line(N.X, N.Y, B.X, B.Y, 3, Shade(Frame, 1.08));
  C.Line(N.X + N.W, N.Y, B.X + B.W, B.Y, 3, Shade(Frame, 1.08));
  C.Line(N.X, N.Y + N.H, B.X, B.Y + B.H, 4, Shade(Frame, 0.78));
  C.Line(N.X + N.W, N.Y + N.H, B.X + B.W, B.Y + B.H, 4, Shade(Frame, 0.78));

  NearLeft := CabinProjection(L, 0, 0.04, 0.65);
  NearRight := CabinProjection(L, 1, 0.04, 0.65);
  FarLeft := CabinProjection(L, 0, 1, 0.65);
  FarRight := CabinProjection(L, 1, 1, 0.65);
  C.StrokePath([NearLeft, FarLeft, FarRight, NearRight], 6, Shade(Rail, 0.57));
  C.StrokePath([Pt(NearLeft.X, NearLeft.Y - 1.4), Pt(FarLeft.X, FarLeft.Y - 1.4),
    Pt(FarRight.X, FarRight.Y - 1.4), Pt(NearRight.X, NearRight.Y - 1.4)], 2.0, Shade(Rail, 1.29));
end;

procedure DoorWindowLandings(C: TElevatorCanvas; const S: TElevatorSettings;
  const F: TElevatorFrame; const O: TOpening; const View: TElevatorFloorView);
var
  Leaves: TSlidingLeaves;
  V: TOpening;
  I: Integer;
begin
  if ShowingStationaryFloor(View) then Exit;
  Leaves := SlidingLeaves(S, F, O);
  C.PushClip(O.X, O.Y, O.W, O.H);
  try
    for I := 0 to Leaves.Count - 1 do
    begin
      V := Leaves.Items[I].Window;
      if (V.W = 0) or (V.X >= O.X + O.W) or (V.X + V.W <= O.X) then Continue;
      C.PushClip(V.X, V.Y, V.W, V.H);
      try
        DrawLandingView(C, O.X, O.Y, O.W, O.H, F.FloorPosition);
        DrawMovingFloor(C, View, V.X, V.Y, V.W, V.H);
      finally
        C.PopClip;
      end;
    end;
  finally
    C.PopClip;
  end;
end;

procedure DrawRear(C: TElevatorCanvas; const S: TElevatorSettings; const Schedule: TElevatorSchedule;
  const F: TElevatorFrame; const Layout: TElevatorLayout; const View: TElevatorFloorView);
var
  O: TOpening;
  Through: Boolean;
  ShaftOpacity: Single;
begin
  O := Layout.Opening;
  if Layout.Panorama then
  begin
    PanoramaRear(C, S, F, Layout, View);
    Exit;
  end;
  if S.Scene = esInside then
  begin
    Interior(C, S, F, Layout, View);
    if HasDoorWindow(S) then DoorWindowLandings(C, S, F, O, View);
    Exit;
  end;
  Through := (S.Door = dsGlass) or (S.Kind in [ekGlass, ekConstruction, ekMine]) or
    (SeeThroughDoor(S.Door) and (S.Background <> bgNone));
  if S.Scene = esCarFront then
    Through := Through or SeeThroughDoor(S.Door) or HasDoorWindow(S);
  ShaftOpacity := 0;
  if (S.Scene = esOutside) and HasDoorWindow(S) then
    ShaftOpacity := Ease(Abs(F.FloorPosition - Schedule.TargetFloor) / 0.45);
  if ShaftOpacity < 1 then Cabin(C, S, F, O, View, Through);
  if ShaftOpacity > 0 then
  begin
    C.PushOpacity(O.X, O.Y, O.W, O.H, ShaftOpacity);
    try
      DrawShaft(C, O.X, O.Y, O.W, O.H, F.FloorPosition);
    finally
      C.PopShapeClip;
    end;
  end;
end;

procedure Fastener(C: TElevatorCanvas; X, Y: Single; Color: Cardinal);
begin
  C.Disc(X, Y, 3.5, 3.5, Shade(Color, 1.47), Color, Shade(Color, 0.48));
  C.Line(X - 1.6, Y + 1.0, X + 1.6, Y - 1.0, 1, Shade(Color, 0.48));
end;

procedure Jamb(C: TElevatorCanvas; const S: TElevatorSettings; const O: TOpening);
var
  X, Y, W, H, Left, Right, Top, Side: Single;
  Trim, Edge, Accent: Cardinal;
  I: Integer;
begin
  X := O.X;
  Y := O.Y;
  W := O.W;
  H := O.H;
  Side := LANDING_JAMB_W;
  Top := Y - 79;
  Left := X - Side;
  Right := X + W + Side;
  Trim := S.Colors[1];
  Edge := Shade(Trim, 0.53);
  Accent := S.Colors[3];
  C.BoxEdge(Left - 1, Top, Right - Left + 2, Y + H - Top + 12, 3, 7, Edge, 0.64);
  C.Metal(Left, Y - 1, Side, H + 3, 1, Trim);
  C.Metal(X + W, Y - 1, Side, H + 3, 1, Trim);
  C.Panel(Left, Top, Right - Left, Y - Top, 2, Shade(Trim, 1.27), Trim, Shade(Trim, 0.56));

  // 呼び出し盤の背板と同じ幅を反対側にも設け、扉を中心に外形を揃える。
  C.Panel(Left - LANDING_WING_W, Y - 1, LANDING_WING_W + 5, H + 3, 1,
    Shade(Trim, 0.73), Trim, Shade(Trim, 0.67));
  C.Panel(Right - 5, Y - 1, LANDING_WING_W + 5, H + 3, 1,
    Shade(Trim, 0.73), Trim, Shade(Trim, 0.67));
  C.Line(Left - LANDING_WING_W + 1, Y + 1, Left - LANDING_WING_W + 1, Y + H - 6, 2, Shade(Trim, 0.44));
  C.Line(Right + LANDING_WING_W - 1, Y + 1, Right + LANDING_WING_W - 1, Y + H - 6, 2, Shade(Trim, 0.44));

  C.Line(Left + 2, Top + 3, Right - 2, Top + 3, 2, Shade(Trim, 1.53), 0.61);
  C.Line(Left + 3, Y + 6, Left + 3, Y + H - 4, 1.5, Shade(Trim, 1.43), 0.68);
  C.Line(X - 1, Y + 1, X - 1, Y + H, 3, Edge);
  C.Line(X + W + 1, Y + 1, X + W + 1, Y + H, 3, Edge);
  C.Box(X - 1, Y - 2, W + 2, 4, 0, Shade(Trim, 0.37));
  C.Panel(Left, Y + H, Right - Left, 12, 2, Shade(Trim, 1.26), Trim, Edge);
  for I := 0 to 4 do
    C.Line(X, Y + H + 1 + I * 1.5, X + W, Y + H + 1 + I * 1.5,
      0.8, Shade(Trim, 0.55 + I * 0.15));
  if S.Era in [eeMeiji, eeEarlyShowa] then
  begin
    for I := 0 to 2 do
    begin
      C.BoxEdge(Left + 5 + I * 3, Top + 8 + I * 3, Right - Left - 10 - I * 6,
        Y - Top - 17 - I * 6, 13 - I * 3, 1.1, Shade(Trim, 1.29 - I * 0.12));
      C.Line(Left + 10 + I * 4, Y + 11, Left + 10 + I * 4, Y + H - 10, 1.7, Shade(Trim, 1.26));
      C.Line(Right - 10 - I * 4, Y + 11, Right - 10 - I * 4, Y + H - 10, 1.7, Shade(Trim, 1.26));
    end;
  end;
  if S.Era >= eeReiwa then
  begin
    C.Line(Left + 11, Y + 12, Left + 11, Y + H - 10, 2.1, Accent, 0.68);
    C.Line(Right - 11, Y + 12, Right - 11, Y + H - 10, 2.1, Accent, 0.68);
  end;
  if S.Kind in [ekFreight, ekConstruction, ekMine] then
    for I := 0 to 3 do
    begin
      Fastener(C, Left + Side * 0.5, Y + 24 + (H - 48) * I / 3, Trim);
      Fastener(C, Right - Side * 0.5, Y + 24 + (H - 48) * I / 3, Trim);
    end;
end;

procedure CarJamb(C: TElevatorCanvas; const S: TElevatorSettings; const O: TOpening);
var
  Trim, Edge: Cardinal;
begin
  Trim := Mix(S.Colors[1], CabinColor(S), 0.66);
  Edge := Shade(Trim, 0.65);
  C.Box(O.X - 4, O.Y - 4, O.W + 8, 4.8, 0, Trim);
  C.Box(O.X - 4, O.Y, 4.7, O.H + 1, 0, Trim);
  C.Box(O.X + O.W - 0.7, O.Y, 4.7, O.H + 1, 0, Trim);
  C.Line(O.X, O.Y + 0.7, O.X + O.W, O.Y + 0.7, 1.3, Edge);
  C.Line(O.X - 0.2, O.Y, O.X - 0.2, O.Y + O.H, 1.1, Edge);
  C.Line(O.X + O.W + 0.2, O.Y, O.X + O.W + 0.2, O.Y + O.H, 1.1, Edge);
  C.Panel(O.X - 4, O.Y + O.H - 0.6, O.W + 8, 3.2, 0,
    Shade(Trim, 1.17), Trim, Edge);
end;

procedure SolidLeaf(C: TElevatorCanvas; const S: TElevatorSettings; X, Y, W, H: Single);
var
  I: Integer;
  Color, Hi, Low: Cardinal;
  P: Single;
begin
  Color := S.Colors[0];
  if S.Scene = esInside then
  begin
    Color := Mix(Color, $B4B3AE, 0.46);
    C.Panel(X, Y, W, H, 0, Shade(Color, 0.96), Shade(Color, 1.10), Shade(Color, 0.83));
    C.Box(X, Y, 0.9, H, 0, Shade(Color, 0.60));
    C.Box(X + W - 0.9, Y, 0.9, H, 0, Shade(Color, 0.68));
    C.Box(X + 1.1, Y + 1, 0.55, H - 2, 0, Shade(Color, 1.20), 0.52);
    Exit;
  end;
  Hi := Shade(Color, 1.33);
  Low := Shade(Color, 0.56);
  if S.Era <= eeMidShowa then
    C.Panel(X, Y, W, H, 0, Shade(Color, 1.18), Color, Low)
  else
    C.Metal(X, Y, W, H, 0, Color);
  C.Box(X, Y, 2, H, 0, Low);
  C.Box(X + W - 2, Y, 2, H, 0, Low);
  C.Box(X + 3, Y + 3, 1.2, H - 6, 0, Hi, 0.72);
  C.Box(X + W - 5, Y + 3, 1.1, H - 6, 0, Hi, 0.52);
  if S.Era <= eeEarlyShowa then
    for I := 0 to 1 do
    begin
      P := Y + 34 + I * (H * 0.51);
      C.BoxEdge(X + W * 0.10, P, W * 0.80, H * 0.36, 8, 3, Shade(S.Colors[1], 1.08));
      C.BoxEdge(X + W * 0.13, P + 5, W * 0.74, H * 0.36 - 10, 5, 1, Hi);
    end
  else if S.Era = eeFuture then
  begin
    C.Glow(X + 10, Y + H * 0.48, 23, H * 0.52, S.Colors[3], 0.24);
    C.Box(X + 8, Y + 17, 2, H - 34, 1, S.Colors[3], 0.78);
  end
  else
    for I := 1 to 17 do
    begin
      P := X + W * I / 18;
      C.Line(P, Y + 9, P, Y + H - 9, 0.7, Hi, 0.10 + (I mod 3) * 0.043);
    end;
end;

procedure SlidingLeaf(C: TElevatorCanvas; const S: TElevatorSettings; const Leaf: TSlidingLeaf);
var
  B, V: TOpening;
  Opacity, Pitch, PX: Single;
  Frame, Tint: Cardinal;
  I: Integer;
begin
  B := Leaf.Body;
  V := Leaf.Window;
  if V.W <= 0 then
  begin
    SolidLeaf(C, S, B.X, B.Y, B.W, B.H);
    Exit;
  end;

  C.PushRectCutout(D2D1RectF(B.X - 2, B.Y - 2, B.X + B.W + 2, B.Y + B.H + 2),
    D2D1RectF(V.X, V.Y, V.X + V.W, V.Y + V.H));
  try
    SolidLeaf(C, S, B.X, B.Y, B.W, B.H);
  finally
    C.PopShapeClip;
  end;

  Opacity := 1 - S.Values[etWindowTransparency] / 100;
  if Opacity > 0 then
  begin
    Tint := Mix($172025, Shade(S.Colors[0], 0.40), 0.36);
    C.Box(V.X, V.Y, V.W, V.H, 0, Tint, Opacity);
    C.PushClip(V.X, V.Y, V.W, V.H);
    try
      // 控えめな網入りガラス。透明度100では枠だけを残す。
      Pitch := EnsureRange(V.W / 3.6, 6.0, 14.0);
      for I := -Ceil(V.H / Pitch) to Ceil(V.W / Pitch) do
      begin
        PX := I * Pitch;
        C.Line(V.X + PX, V.Y, V.X + PX + V.H, V.Y + V.H, 0.65, $A4AAA3, 0.25 * Opacity);
        C.Line(V.X + V.W - PX, V.Y, V.X + V.W - PX - V.H, V.Y + V.H, 0.65,
          $A4AAA3, 0.25 * Opacity);
      end;
    finally
      C.PopClip;
    end;
  end;
  Frame := Mix(Shade(S.Colors[1], 0.55), $282C2C, 0.53);
  C.BoxEdge(V.X - 0.65, V.Y - 0.65, V.W + 1.3, V.H + 1.3, 0, 2.2, Frame);
  C.Line(V.X + V.W + 1.5, V.Y + 0.5, V.X + V.W + 1.5, V.Y + V.H + 1.5,
    0.8, Shade(S.Colors[0], 1.29), 0.67);
end;

procedure GlassLeaf(C: TElevatorCanvas; const S: TElevatorSettings; X, Y, W, H: Single);
var
  Color, Shimmer: Cardinal;
begin
  Color := S.Colors[0];
  Shimmer := Mix(S.Colors[3], $FFFFFF, 0.54);
  if S.Scene = esInside then
  begin
    Color := Mix(Color, $9C9C96, 0.52);
    C.Panel(X, Y, 6, H, 0, Color, Shade(Color, 1.07), Shade(Color, 0.72));
    C.Panel(X + W - 6, Y, 6, H, 0, Color, Shade(Color, 1.07), Shade(Color, 0.72));
    C.Box(X, Y, W, 9, 0, Shade(Color, 0.89));
    C.Box(X + 5, Y + H - 13, W - 10, 13, 0, Color);
    if S.Background <> bgNone then
      C.Polygon([Pt(X + 6, Y + H * 0.38), Pt(X + W - 6, Y + H * 0.25),
        Pt(X + W - 6, Y + H * 0.29), Pt(X + 6, Y + H * 0.45)], Shimmer, 0.13);
    Exit;
  end;
  C.Metal(X, Y, 10, H, 0, Color);
  C.Metal(X + W - 10, Y, 10, H, 0, Color);
  C.Panel(X, Y, W, 15, 0, Shade(Color, 1.39), Color, Shade(Color, 0.52));
  C.Panel(X + 9, Y + H - 31, W - 18, 31, 0, Shade(Color, 1.23), Color, Shade(Color, 0.56));
  C.Line(X + 12, Y + 16, X + 12, Y + H - 31, 1.1, Shimmer, 0.73);
  C.Line(X + W - 13, Y + 16, X + W - 13, Y + H - 31, 1, Shimmer, 0.50);
  if S.Background <> bgNone then
  begin
    C.Polygon([Pt(X + 11, Y + H * 0.42), Pt(X + W - 11, Y + H * 0.27),
      Pt(X + W - 11, Y + H * 0.31), Pt(X + 11, Y + H * 0.50)], Shimmer, 0.15);
    C.Polygon([Pt(X + 11, Y + H * 0.52), Pt(X + W - 11, Y + H * 0.35),
      Pt(X + W - 11, Y + H * 0.37), Pt(X + 11, Y + H * 0.54)], Shimmer, 0.27);
  end;
end;

procedure Lattice(C: TElevatorCanvas; const S: TElevatorSettings; X, Y, W, H: Single);
var
  Col, Row: Integer;
  CellW, CellH, Stroke, A, B, Top: Single;
  Color, Highlight: Cardinal;
begin
  if W <= 0.2 then Exit;
  C.PushClip(X, Y, W, H);
  try
    Color := Shade(S.Colors[0], 0.70);
    Highlight := Shade(S.Colors[0], 1.27);
    if S.Scene = esInside then
    begin
      Color := Mix(Color, $635E58, 0.55);
      Highlight := Shade(Color, 1.12);
    end;
    CellW := W / 5;
    CellH := H / 6;
    Stroke := Min(5.25, CellW * 0.58);
    for Col := 0 to 4 do
    begin
      A := X + Col * CellW;
      B := A + CellW;
      C.Line(A, Y, A, Y + H, Stroke * 0.85, Color);
      for Row := 0 to 5 do
      begin
        Top := Y + Row * CellH;
        C.Line(A, Top, B, Top + CellH, Stroke, Color);
        C.Line(B, Top, A, Top + CellH, Stroke, Color);
        C.Line(A, Top, B, Top + CellH, Stroke * 0.30, Highlight, 0.78);
        C.Oval((A + B) * 0.5, Top + CellH * 0.5, Stroke * 0.50, Stroke * 0.50, Highlight);
      end;
    end;
    C.Metal(X, Y, W, 7, 0, Color);
    C.Metal(X, Y + H - 8, W, 8, 0, Color);
    C.Metal(X, Y, Min(7.0, W), H, 0, Color);
    C.Metal(X + W - Min(7.0, W), Y, Min(7.0, W), H, 0, Color);
  finally
    C.PopClip;
  end;
end;

procedure FreightLeaf(C: TElevatorCanvas; const S: TElevatorSettings; X, Y, W, H: Single;
  TopLeaf: Boolean);
var
  I: Integer;
  P, EdgeY: Single;
  Color, Dark, Stripe: Cardinal;
begin
  Color := S.Colors[0];
  Dark := Shade(Color, 0.41);
  Stripe := Mix(S.Colors[3], $F7AC2A, 0.72);
  if S.Scene = esInside then
  begin
    Stripe := Mix(Stripe, Color, 0.62);
    C.Panel(X, Y, W, H, 0, Color, Shade(Color, 1.11), Shade(Color, 0.82));
  end
  else C.Metal(X, Y, W, H, 0, Color);
  for I := 1 to 9 do
  begin
    P := Y + H * I / 10;
    C.Box(X, P - 2, W, 5, 0, Shade(Color, 0.66));
    C.Box(X, P - 2, W, 1.5, 0, Shade(Color, 1.20));
  end;
  EdgeY := Y + 2;
  if TopLeaf then EdgeY := Y + H - 17;
  C.Box(X, EdgeY, W, 15, 0, Dark);
  C.PushClip(X, EdgeY, W, 15);
  try
    for I := 0 to Ceil(W / 35) do
    begin
      P := X + I * 35;
      C.Polygon([Pt(P, EdgeY + 15), Pt(P + 16, EdgeY + 15),
        Pt(P + 30, EdgeY), Pt(P + 14, EdgeY)], Stripe);
    end;
  finally
    C.PopClip;
  end;
end;

procedure Door(C: TElevatorCanvas; const S: TElevatorSettings; const F: TElevatorFrame;
  const O: TOpening);
var
  X, Y, W, H, Half, Gap: Single;
  Leaves: TSlidingLeaves;
  I: Integer;
begin
  if F.OpenAmount >= 1 then Exit;
  X := O.X;
  Y := O.Y;
  W := O.W;
  H := O.H;
  Half := W / 2;
  Gap := Half * F.OpenAmount;
  C.PushClip(X, Y, W, H);
  try
    case S.Door of
      dsCenter, dsSingle, dsMulti:
        begin
          Leaves := SlidingLeaves(S, F, O);
          for I := 0 to Leaves.Count - 1 do SlidingLeaf(C, S, Leaves.Items[I]);
        end;
      dsLattice:
        begin
          Lattice(C, S, X, Y, Half - Gap, H);
          Lattice(C, S, X + Half + Gap, Y, Half - Gap, H);
        end;
      dsGlass:
        begin
          GlassLeaf(C, S, X - Gap, Y, Half, H);
          GlassLeaf(C, S, X + Half + Gap, Y, Half, H);
        end;
      dsFreight:
        begin
          FreightLeaf(C, S, X, Y - H * F.OpenAmount / 2, W, H / 2, True);
          FreightLeaf(C, S, X, Y + H * (1 + F.OpenAmount) / 2, W, H / 2, False);
        end;
    end;
  finally
    C.PopClip;
  end;
end;

procedure DrawFront(C: TElevatorCanvas; const S: TElevatorSettings; const F: TElevatorFrame;
  const Layout: TElevatorLayout);
begin
  if Layout.Panorama then
  begin
    PanoramaFrame(C, S, Layout);
    Exit;
  end;
  Door(C, S, F, Layout.Opening);
  if S.Scene = esOutside then Jamb(C, S, Layout.Opening)
  else CarJamb(C, S, Layout.Opening);
end;

end.

