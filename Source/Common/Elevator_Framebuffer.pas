unit Elevator_Framebuffer;

// Copyright (c) 2026 VRAMの魔術師
// SPDX-License-Identifier: GPL-3.0-only
// ホストの合成済みフレームを借用し、窓の合成に使う画像へ読み戻す。

interface

uses System.SysUtils, AviUtl2FilterTypes, Winapi.D3D11, Winapi.DxgiFormat;

type
  TElevatorFramebuffer = class
  private
    FDevice: ID3D11Device;
    FStaging: ID3D11Texture2D;
    FSourceDesc: D3D11_TEXTURE2D_DESC;
    function Prepare(const Texture: ID3D11Texture2D; const Desc: D3D11_TEXTURE2D_DESC): Boolean;
  public
    // コールバック内で直列に呼び出す。返すのはオブジェクト座標に整列した PBGRA。
    function ReadAligned(Video: PFILTER_PROC_VIDEO; Width, Height: Integer;
      var Pixels: TBytes): Boolean;
  end;

// 現在フレームで本体より奥側に映像オブジェクトがあるかを調べる。
function HasFloorImage(Video: PFILTER_PROC_VIDEO): Boolean;

implementation

uses System.Math;

type
  TChannels16 = array[0..3] of Word;
  PChannels16 = ^TChannels16;
  TChannels8 = array[0..3] of Byte;
  PChannels8 = ^TChannels8;

var
  HalfBytes: array[Word] of Byte;

function HasFloorImage(Video: PFILTER_PROC_VIDEO): Boolean;
var
  Layer: Integer;
begin
  Result := False;
  if not Assigned(Video^.GetFramebufferTexture2D) then Exit;
  if not Assigned(Video^.GetImageObject) then Exit(True);
  for Layer := Video^.Object_^.Layer - 1 downto 0 do
    if Video^.GetImageObject(Layer, 0) <> nil then Exit(True);
end;

function HalfToByte(Value: Word): Byte;
var
  Exponent, Mantissa: Integer;
begin
  Result := 0;
  if (Value and $8000) <> 0 then Exit;
  Exponent := (Value shr 10) and $1F;
  Mantissa := Value and $03FF;
  if (Exponent = 0) or ((Exponent = 31) and (Mantissa <> 0)) then Exit;
  if Exponent >= 15 then Exit(255);
  Result := Round(Ldexp(1 + Mantissa / 1024, Exponent - 15) * 255);
end;

procedure InitHalfBytes;
var
  I: Integer;
begin
  for I := Low(Word) to High(Word) do HalfBytes[I] := HalfToByte(Word(I));
end;

function BytesPerPixel(Format: DXGI_FORMAT): Integer;
begin
  case Format of
    DXGI_FORMAT_R8G8B8A8_UNORM, DXGI_FORMAT_R8G8B8A8_UNORM_SRGB,
    DXGI_FORMAT_B8G8R8A8_UNORM, DXGI_FORMAT_B8G8R8A8_UNORM_SRGB,
    DXGI_FORMAT_B8G8R8X8_UNORM, DXGI_FORMAT_B8G8R8X8_UNORM_SRGB: Result := 4;
    DXGI_FORMAT_R16G16B16A16_UNORM, DXGI_FORMAT_R16G16B16A16_FLOAT: Result := 8;
  else
    Result := 0;
  end;
end;

procedure WritePBGRA(From: PByte; ToPixel: PChannels8; Format: DXGI_FORMAT);
var
  Words: PChannels16;
  Alpha, R, G, B: Integer;
begin
  case Format of
    DXGI_FORMAT_R8G8B8A8_UNORM, DXGI_FORMAT_R8G8B8A8_UNORM_SRGB:
      begin
        R := From[0]; G := From[1]; B := From[2]; Alpha := From[3];
      end;
    DXGI_FORMAT_B8G8R8A8_UNORM, DXGI_FORMAT_B8G8R8A8_UNORM_SRGB:
      begin
        B := From[0]; G := From[1]; R := From[2]; Alpha := From[3];
      end;
    DXGI_FORMAT_B8G8R8X8_UNORM, DXGI_FORMAT_B8G8R8X8_UNORM_SRGB:
      begin
        B := From[0]; G := From[1]; R := From[2]; Alpha := 255;
      end;
    DXGI_FORMAT_R16G16B16A16_UNORM:
      begin
        Words := PChannels16(From);
        R := Words^[0] div 257; G := Words^[1] div 257;
        B := Words^[2] div 257; Alpha := Words^[3] div 257;
      end;
  else // R16G16B16A16_FLOAT
    Words := PChannels16(From);
    R := HalfBytes[Words^[0]]; G := HalfBytes[Words^[1]];
    B := HalfBytes[Words^[2]]; Alpha := HalfBytes[Words^[3]];
  end;
  ToPixel^[0] := (B * Alpha + 127) div 255;
  ToPixel^[1] := (G * Alpha + 127) div 255;
  ToPixel^[2] := (R * Alpha + 127) div 255;
  ToPixel^[3] := Alpha;
end;

function TElevatorFramebuffer.Prepare(const Texture: ID3D11Texture2D;
  const Desc: D3D11_TEXTURE2D_DESC): Boolean;
var
  Device: ID3D11Device;
  StagingDesc: D3D11_TEXTURE2D_DESC;
begin
  Result := False;
  Texture.GetDevice(Device);
  if Device = nil then Exit;
  if (FStaging <> nil) and (FDevice = Device) and (FSourceDesc.Width = Desc.Width) and
    (FSourceDesc.Height = Desc.Height) and (FSourceDesc.Format = Desc.Format) then Exit(True);

  FStaging := nil;
  FDevice := nil;
  StagingDesc := Desc;
  StagingDesc.MipLevels := 1;
  StagingDesc.ArraySize := 1;
  StagingDesc.Usage := D3D11_USAGE_STAGING;
  StagingDesc.BindFlags := 0;
  StagingDesc.CPUAccessFlags := D3D11_CPU_ACCESS_READ;
  StagingDesc.MiscFlags := 0;
  if Device.CreateTexture2D(StagingDesc, nil, FStaging) < 0 then Exit;
  FSourceDesc := Desc;
  FDevice := Device;
  Result := True;
end;

function GetPlacement(Video: PFILTER_PROC_VIDEO; out P: TOBJECT_IMAGE_PARAM): Boolean;
begin
  Result := False;
  if (Video^.Object_^.Flag and OBJECT_FLAG_CAMERA_TARGET) <> 0 then Exit;
  P := Default(TOBJECT_IMAGE_PARAM);
  P.SX := 1;
  P.SY := 1;
  if Assigned(Video^.GetOutputImageParam) and
    not Video^.GetOutputImageParam(nil, 0, @P, SizeOf(P)) then Exit;
  if IsNan(P.X + P.Y + P.RZ + P.SX + P.SY) or IsInfinite(P.X + P.Y + P.RZ + P.SX + P.SY) then Exit;
  // 二次元の標準描画へ出す画像に合わせる。外部カメラや傾けた平面は従来の背景で描く。
  Result := (Abs(P.RX) < 0.01) and (Abs(P.RY) < 0.01) and
    (Abs(P.CX) < 0.01) and (Abs(P.CY) < 0.01) and (Abs(P.CZ) < 0.01) and
    (Abs(P.SX) >= 0.0001) and (Abs(P.SY) >= 0.0001) and
    (Abs(P.SX) <= 1000) and (Abs(P.SY) <= 1000) and
    (Abs(P.X) <= 1000000) and (Abs(P.Y) <= 1000000);
end;

function TElevatorFramebuffer.ReadAligned(Video: PFILTER_PROC_VIDEO; Width, Height: Integer;
  var Pixels: TBytes): Boolean;
var
  Raw: Pointer;
  Texture: ID3D11Texture2D;
  Context: ID3D11DeviceContext;
  Desc: D3D11_TEXTURE2D_DESC;
  Mapped: D3D11_MAPPED_SUBRESOURCE;
  P: TOBJECT_IMAGE_PARAM;
  X, Y, SrcX, SrcY, Stride, SceneWidth, SceneHeight: Integer;
  Angle, XX, XY, YX, YY, OriginX, OriginY, SampleX, SampleY, ScaleX, ScaleY: Double;
  Dest: PChannels8;
  Source: PByte;
begin
  Result := False;
  if not Assigned(Video^.GetFramebufferTexture2D) or not GetPlacement(Video, P) then Exit;
  Raw := Video^.GetFramebufferTexture2D();
  if Raw = nil then Exit;
  Texture := ID3D11Texture2D(Raw);
  Texture.GetDesc(Desc);
  if (Desc.Width < 1) or (Desc.Height < 1) or (Desc.Width > 8192) or (Desc.Height > 8192) or
    (Int64(Desc.Width) * Desc.Height > 33554432) or (Desc.SampleDesc.Count <> 1) or
    (Desc.MipLevels <> 1) or (Desc.ArraySize <> 1) then Exit;

  Stride := BytesPerPixel(Desc.Format);
  if (Stride = 0) or not Prepare(Texture, Desc) then Exit;
  FDevice.GetImmediateContext(Context);
  if Context = nil then Exit;

  SceneWidth := Desc.Width;
  SceneHeight := Desc.Height;
  if (Video^.Scene <> nil) and (Video^.Scene^.Width > 0) and (Video^.Scene^.Height > 0) then
  begin
    SceneWidth := Video^.Scene^.Width;
    SceneHeight := Video^.Scene^.Height;
  end;
  ScaleX := Desc.Width / SceneWidth;
  ScaleY := Desc.Height / SceneHeight;
  Angle := DegToRad(P.RZ);
  XX := ScaleX * Cos(Angle) * P.SX;
  XY := ScaleX * -Sin(Angle) * P.SY;
  YX := ScaleY * Sin(Angle) * P.SX;
  YY := ScaleY * Cos(Angle) * P.SY;
  OriginX := Desc.Width * 0.5 + P.X * ScaleX - (XX * (Width - 1) + XY * (Height - 1)) * 0.5;
  OriginY := Desc.Height * 0.5 + P.Y * ScaleY - (YX * (Width - 1) + YY * (Height - 1)) * 0.5;

  SetLength(Pixels, Width * Height * 4);
  Context.CopyResource(FStaging, Texture);
  Mapped := Default(D3D11_MAPPED_SUBRESOURCE);
  if Context.Map(FStaging, 0, D3D11_MAP_READ, 0, Mapped) < 0 then Exit;
  try
    if (Mapped.pData = nil) or (Mapped.RowPitch < Desc.Width * Cardinal(Stride)) then Exit;
    Dest := PChannels8(@Pixels[0]);
    for Y := 0 to Height - 1 do
    begin
      SampleX := OriginX + Y * XY;
      SampleY := OriginY + Y * YY;
      for X := 0 to Width - 1 do
      begin
        if (SampleX >= 0) and (SampleY >= 0) and (SampleX < Desc.Width) and (SampleY < Desc.Height) then
        begin
          SrcX := Trunc(SampleX);
          SrcY := Trunc(SampleY);
          Source := PByte(Mapped.pData) + NativeInt(SrcY) * Mapped.RowPitch + SrcX * Stride;
          WritePBGRA(Source, Dest, Desc.Format);
        end
        else PCardinal(Dest)^ := 0;
        Inc(Dest);
        SampleX := SampleX + XX;
        SampleY := SampleY + YX;
      end;
    end;
    Result := True;
  finally
    Context.Unmap(FStaging, 0);
  end;
end;

initialization
  InitHalfBytes;

end.

