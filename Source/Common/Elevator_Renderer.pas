unit Elevator_Renderer;

// Copyright (c) 2026 VRAMの魔術師
// SPDX-License-Identifier: GPL-3.0-only
// Direct2D/WICの透過2D描画と、AviUtl2へ渡すRGBAの合成を管理する。

interface

uses System.SysUtils, Winapi.D2D1, Winapi.Wincodec, AviUtl2FilterTypes, Elevator_Canvas,
  Elevator_Settings, Elevator_Timeline, Elevator_Structure, Elevator_Framebuffer;

type
  TElevatorRenderer = class
  private
    FFactory: ID2D1Factory;
    FWic: IWICImagingFactory;
    FBitmap: IWICBitmap;
    FTarget: ID2D1RenderTarget;
    FCanvas: TElevatorCanvas;
    FFramebuffer: TElevatorFramebuffer;
    FFloorBitmap: ID2D1Bitmap;
    FFloorPixels: TBytes;
    FComCookie: Pointer;
    FWidth, FHeight: Integer;
    FRaw, FPixels: TArray<TPIXEL_RGBA>;
    procedure ResetTarget;
    procedure EnsureTarget(Width, Height: Integer);
    procedure RenderLayer(const S: TElevatorSettings; const Schedule: TElevatorSchedule;
      const F: TElevatorFrame; const Layout: TElevatorLayout; const View: TElevatorFloorView;
      Front: Boolean);
    function PrepareFloor(Video: PFILTER_PROC_VIDEO; const S: TElevatorSettings;
      const Schedule: TElevatorSchedule; const Layout: TElevatorLayout;
      Seconds: Double): TElevatorFloorView;
    procedure ReadLayer(Composite: Boolean);
  public
    destructor Destroy; override;
    // インスタンスを呼び出し側で直列化する。ホスト所有データは呼び出し中だけ借りる。
    procedure Render(const S: TElevatorSettings; const Schedule: TElevatorSchedule;
      const F: TElevatorFrame; Seconds: Double; Video: PFILTER_PROC_VIDEO);
  end;

implementation

uses System.Math, System.Win.ComObj, Winapi.Windows, Winapi.ActiveX,
  Winapi.DxgiFormat, Elevator_Controls;

function CoIncrementMTAUsage(out Cookie: Pointer): HRESULT; stdcall;
  external 'ole32.dll' name 'CoIncrementMTAUsage';
function CoDecrementMTAUsage(Cookie: Pointer): HRESULT; stdcall;
  external 'ole32.dll' name 'CoDecrementMTAUsage';

destructor TElevatorRenderer.Destroy;
begin
  ResetTarget;
  FFramebuffer.Free;
  FFactory := nil;
  FWic := nil;
  if FComCookie <> nil then CoDecrementMTAUsage(FComCookie);
  inherited;
end;

procedure TElevatorRenderer.ResetTarget;
begin
  FFloorBitmap := nil;
  FreeAndNil(FCanvas);
  FTarget := nil;
  FBitmap := nil;
  FWidth := 0;
  FHeight := 0;
end;

procedure TElevatorRenderer.EnsureTarget(Width, Height: Integer);
var
  Properties: TD2D1RenderTargetProperties;
begin
  if (FWidth = Width) and (FHeight = Height) then Exit;
  if FComCookie = nil then OleCheck(CoIncrementMTAUsage(FComCookie));
  if FFactory = nil then
    OleCheck(D2D1CreateFactory(D2D1_FACTORY_TYPE_MULTI_THREADED, ID2D1Factory, nil, FFactory));
  if FWic = nil then
    OleCheck(CoCreateInstance(CLSID_WICImagingFactory, nil, CLSCTX_INPROC_SERVER,
      IID_IWICImagingFactory, FWic));
  ResetTarget;
  OleCheck(FWic.CreateBitmap(Width, Height, @GUID_WICPixelFormat32bppPBGRA,
    WICBitmapCacheOnLoad, FBitmap));
  Properties := D2D1RenderTargetProperties(D2D1_RENDER_TARGET_TYPE_SOFTWARE,
    D2D1PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED), 96, 96);
  OleCheck(FFactory.CreateWicBitmapRenderTarget(FBitmap, Properties, FTarget));
  FCanvas := TElevatorCanvas.Create(FFactory, FTarget);
  FTarget.SetTransform(TD2D1Matrix3x2F.Scale(Width / DESIGN_W, Height / DESIGN_H, D2D1PointF(0, 0)));
  SetLength(FRaw, Width * Height);
  SetLength(FPixels, Width * Height);
  FWidth := Width;
  FHeight := Height;
end;

function TElevatorRenderer.PrepareFloor(Video: PFILTER_PROC_VIDEO; const S: TElevatorSettings;
  const Schedule: TElevatorSchedule; const Layout: TElevatorLayout;
  Seconds: Double): TElevatorFloorView;
var
  Properties: TD2D1BitmapProperties;
  Bounds: TD2D1RectU;
begin
  Result := Default(TElevatorFloorView);
  if (S.Scene = esOutside) or not S.UseFloorImage then Exit;
  if not (Layout.Panorama or HasDoorWindow(S) or SeeThroughDoor(S.Door) or
    (S.Kind in [ekGlass, ekConstruction, ekMine])) then Exit;
  try
    if not HasFloorImage(Video) then Exit;
    Result.Motion := EvaluateFloorMotion(Schedule, Seconds);
    if (Result.Motion.Phase = fpLeaving) and (Result.Motion.Offset = 0) then
      Result.Motion.Phase := fpStill;
    Result.Active := True;
    if not (Result.Motion.Phase in [fpLeaving, fpArriving]) then Exit;

    if FFramebuffer = nil then FFramebuffer := TElevatorFramebuffer.Create;
    if not FFramebuffer.ReadAligned(Video, FWidth, FHeight, FFloorPixels) then
    begin
      Result.Active := False;
      Exit;
    end;
    if FFloorBitmap = nil then
    begin
      Properties := D2D1BitmapProperties(D2D1PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM,
        D2D1_ALPHA_MODE_PREMULTIPLIED), 96, 96);
      OleCheck(FTarget.CreateBitmap(D2D1SizeU(FWidth, FHeight), nil, 0, Properties, FFloorBitmap));
    end;
    Bounds.Left := 0;
    Bounds.Top := 0;
    Bounds.Right := FWidth;
    Bounds.Bottom := FHeight;
    OleCheck(FFloorBitmap.CopyFromMemory(Bounds, @FFloorPixels[0], FWidth * 4));
    Result.Bitmap := FFloorBitmap;
  except
    // 読み戻しが使えない環境でも既存の風景を描けるようにする。
    Result := Default(TElevatorFloorView);
  end;
end;

procedure TElevatorRenderer.RenderLayer(const S: TElevatorSettings; const Schedule: TElevatorSchedule;
  const F: TElevatorFrame; const Layout: TElevatorLayout; const View: TElevatorFloorView;
  Front: Boolean);
var
  Status: HRESULT;
begin
  FTarget.BeginDraw;
  try
    FTarget.Clear(D2D1ColorF(0, 0, 0, 0));
    if Front then
    begin
      DrawFront(FCanvas, S, F, Layout);
      if not Layout.Panorama then DrawControls(FCanvas, S, Schedule, F, Layout);
    end
    else DrawRear(FCanvas, S, Schedule, F, Layout, View);
  finally
    Status := FTarget.EndDraw;
    if Failed(Status) then
    begin
      ResetTarget;
      OleCheck(Status);
    end;
  end;
end;

function Straight(Value, Alpha: Integer): Byte; inline;
begin
  Result := (Value * 255 + Alpha div 2) div Alpha;
end;

function FromPBGRA(const Pixel: TPIXEL_RGBA): TPIXEL_RGBA; inline;
begin
  Result.A := Pixel.A;
  case Result.A of
    0: Result := Default(TPIXEL_RGBA);
    255:
      begin
        Result.R := Pixel.B;
        Result.G := Pixel.G;
        Result.B := Pixel.R;
      end;
  else
    Result.R := Straight(Pixel.B, Result.A);
    Result.G := Straight(Pixel.G, Result.A);
    Result.B := Straight(Pixel.R, Result.A);
  end;
end;

procedure Over(var Back: TPIXEL_RGBA; const Front: TPIXEL_RGBA);
var
  FrontWeight, BackWeight, Weight: Integer;
  function Component(F, B: Byte): Byte;
  begin
    Result := (Integer(F) * FrontWeight + Integer(B) * BackWeight + Weight div 2) div Weight;
  end;
begin
  if Front.A = 0 then Exit;
  if (Front.A = 255) or (Back.A = 0) then
  begin
    Back := Front;
    Exit;
  end;
  FrontWeight := Integer(Front.A) * 255;
  BackWeight := Integer(Back.A) * (255 - Front.A);
  Weight := FrontWeight + BackWeight;
  Back.R := Component(Front.R, Back.R);
  Back.G := Component(Front.G, Back.G);
  Back.B := Component(Front.B, Back.B);
  Back.A := (Weight + 127) div 255;
end;

procedure TElevatorRenderer.ReadLayer(Composite: Boolean);
var
  I: Integer;
begin
  OleCheck(FBitmap.CopyPixels(nil, FWidth * 4, Length(FRaw) * 4, @FRaw[0]));
  if Composite then
  begin
    // 両方ONの場合も、単独出力と同じストレートRGBAをsource-overで重ねる。
    for I := 0 to High(FPixels) do
      if FRaw[I].A <> 0 then Over(FPixels[I], FromPBGRA(FRaw[I]));
  end
  else
    for I := 0 to High(FPixels) do
      FPixels[I] := FromPBGRA(FRaw[I]);
end;

procedure TElevatorRenderer.Render(const S: TElevatorSettings; const Schedule: TElevatorSchedule;
  const F: TElevatorFrame; Seconds: Double; Video: PFILTER_PROC_VIDEO);
var
  Layout: TElevatorLayout;
  View: TElevatorFloorView;
  Scene: PSCENE_INFO;
  SizeScale: Double;
  Width, Height: Integer;
begin
  Scene := Video^.Scene;
  SizeScale := 1;
  if (Scene <> nil) and (Scene^.Width > 0) and (Scene^.Height > 0) then
    SizeScale := Min(2.0, Min(Scene^.Width / DESIGN_W, Scene^.Height / DESIGN_H));
  Width := Max(1, Round(DESIGN_W * SizeScale));
  Height := Max(1, Round(DESIGN_H * SizeScale));
  if not (S.RearLayer or S.FrontLayer) then
  begin
    // レイヤーを両方消しても、同じキャンバス寸法・原点をホストに渡す。
    SetLength(FPixels, Width * Height);
    FillChar(FPixels[0], Length(FPixels) * SizeOf(TPIXEL_RGBA), 0);
  end
  else
  begin
    EnsureTarget(Width, Height);
    // 両方OFFの呼び出しはターゲットを作らないため、出力バッファだけ寸法を再確認する。
    SetLength(FPixels, Width * Height);
    Layout := ElevatorLayout(S.Scene, S.Kind);
    if S.RearLayer then
    begin
      View := PrepareFloor(Video, S, Schedule, Layout, Seconds);
      RenderLayer(S, Schedule, F, Layout, View, False);
      ReadLayer(False);
    end;
    if S.FrontLayer then
    begin
      RenderLayer(S, Schedule, F, Layout, View, True);
      ReadLayer(S.RearLayer);
    end;
  end;
  Video^.SetImageData(@FPixels[0], Width, Height);
end;

end.

