program ElevatorVerification;

// 本番 AUF2 を読み込み、AviUtl2 のコールバックを模擬して設定・映像・音声を検査する。

{$APPTYPE CONSOLE}
{$RANGECHECKS ON}
{$OVERFLOWCHECKS ON}

uses
  System.SysUtils, System.Classes, System.Math, System.Hash, System.Generics.Collections, Winapi.Windows,
  Winapi.D3D11, Winapi.D3DCommon, Winapi.DxgiFormat,
  AviUtl2FilterTypes in '..\Source\Lib\AviUtl2FilterTypes.pas',
  Elevator_Settings in '..\Source\Common\Elevator_Settings.pas',
  Elevator_Timeline in '..\Source\Common\Elevator_Timeline.pas';

type
  TInitialize = function(Version: Cardinal): Byte; cdecl;
  TRequired = function: Cardinal; cdecl;
  TUninitialize = procedure; cdecl;
  TGetTable = function: PFILTER_PLUGIN_TABLE; cdecl;
  POption = ^TFILTER_ITEM_SELECT_ITEM;
  TItemHeader = record ItemType, Name: PWideChar; end;
  PItem = ^TItemHeader;
  PPItem = ^PItem;
  TBitmapHeader = packed record
    Magic: Word;
    FileSize, Reserved, PixelOffset, HeaderSize: Cardinal;
    W, H: Integer;
    Planes, BPP: Word;
    Compression, ImageSize, XPPM, YPPM, ColorsUsed, Important: Cardinal;
  end;

var
  DLL: HMODULE;
  Table: PFILTER_PLUGIN_TABLE;
  Video: TFILTER_PROC_VIDEO;
  Audio: TFILTER_PROC_AUDIO;
  Edit: TEDIT_SECTION;
  Obj: TOBJECT_INFO;
  Scene: TSCENE_INFO;
  Pixels: TArray<TPIXEL_RGBA>;
  Samples: array[0..1] of TArray<Single>;
  W, H, Checks, Writes: Integer;
  PresetValues: array[0..2] of UTF8String;
  Digest: TStringList;
  DepartureTexture, ArrivalTexture: ID3D11Texture2D;
  HasMockFloor: Boolean;
  FloorReads: Integer;
  FloorPlacement: TOBJECT_IMAGE_PARAM;

procedure Require(Condition: Boolean; const MessageText: string);
begin
  if not Condition then raise Exception.Create(MessageText);
  Inc(Checks);
end;

function FindItem(const Name: string): Pointer;
var
  Current: PPItem;
begin
  Current := PPItem(Table^.Items);
  while Current^ <> nil do
  begin
    if string(Current^^.Name) = Name then Exit(Current^);
    Inc(Current);
  end;
  raise Exception.Create('missing item: ' + Name);
end;

procedure Select(const Name: string; Value: Integer);
begin
  PFILTER_ITEM_SELECT(FindItem(Name))^.Value := Value;
end;

procedure Track(Kind: TElevatorTrack; Value: Double);
begin
  PFILTER_ITEM_TRACK(FindItem(ELEVATOR_TRACKS[Kind].Name))^.Value := Value;
end;

procedure Check(const Name: string; Value: Boolean);
begin
  PFILTER_ITEM_CHECK(FindItem(Name))^.Value := Ord(Value);
end;

function ReadItem(Handle: OBJECT_HANDLE; Effect, Name: PWideChar): PAnsiChar; cdecl;
begin
  Result := nil;
  if (Handle <> @Obj) or (string(Effect) <> 'エレベーター演出:1') then Exit;
  if string(Name) = 'プリセット場面' then Result := PAnsiChar(PresetValues[0]);
  if string(Name) = 'プリセット年代' then Result := PAnsiChar(PresetValues[1]);
  if string(Name) = 'プリセット種類' then Result := PAnsiChar(PresetValues[2]);
end;

function StoreItem(Handle: OBJECT_HANDLE; Effect, Name: PWideChar; Value: PAnsiChar): Boolean; cdecl;
var
  Field: PItem;
  Text: string;
  Option: POption;
  Color: Integer;
begin
  Result := False;
  if (Handle <> @Obj) or (string(Effect) <> 'エレベーター演出:1') then Exit;
  Field := FindItem(Name);
  Text := string(UTF8String(Value));
  if string(Field^.ItemType) = 'select' then
  begin
    Option := POption(PFILTER_ITEM_SELECT(Field)^.List);
    while (Option^.Name <> nil) and (Text <> string(Option^.Name)) do Inc(Option);
    if Option^.Name = nil then Exit;
    PFILTER_ITEM_SELECT(Field)^.Value := Option^.Value;
  end
  else if string(Field^.ItemType) = 'color' then
  begin
    Color := StrToInt('$' + Text);
    PFILTER_ITEM_COLOR(Field)^.R := (Color shr 16) and 255;
    PFILTER_ITEM_COLOR(Field)^.G := (Color shr 8) and 255;
    PFILTER_ITEM_COLOR(Field)^.B := Color and 255;
  end
  else Exit;
  Inc(Writes);
  Result := True;
end;

procedure Preset(A: TElevatorScene; E: TElevatorEra; K: TElevatorKind);
var
  Button: PFILTER_ITEM_BUTTON;
begin
  PresetValues[0] := UTF8String(string(SCENE_NAMES[A]));
  PresetValues[1] := UTF8String(string(ERA_NAMES[E]));
  PresetValues[2] := UTF8String(string(KIND_NAMES[K]));
  Button := FindItem('設定を反映');
  Writes := 0;
  Button^.Callback2(@Edit, @Obj, 'エレベーター演出:1', Button^.Name);
  Require(Writes = 11, 'preset writes');
  Require(PFILTER_ITEM_SELECT(FindItem('場面'))^.Value = Ord(A), 'preset scene');
  Require(PFILTER_ITEM_SELECT(FindItem('年代'))^.Value = Ord(E), 'preset era');
  Require(PFILTER_ITEM_SELECT(FindItem('種類'))^.Value = Ord(K), 'preset kind');
end;

procedure PublishImage(Buffer: PPIXEL_RGBA; Width, Height: Integer); cdecl;
begin
  W := Width;
  H := Height;
  SetLength(Pixels, W * H);
  Move(Buffer^, Pixels[0], Length(Pixels) * SizeOf(TPIXEL_RGBA));
end;

procedure PublishSamples(Buffer: System.PSingle; Channel: Integer); cdecl;
begin
  SetLength(Samples[Channel], Obj.SampleNum);
  Move(Buffer^, Samples[Channel][0], Obj.SampleNum * SizeOf(Single));
end;

function HashBytes: string;
var Hash: THashSHA2;
begin
  Hash := THashSHA2.Create;
  Hash.Update(Pixels[0], Length(Pixels) * SizeOf(TPIXEL_RGBA));
  Result := Hash.HashAsString;
end;

function RegionHash(X1, Y1, X2, Y2: Integer): string;
var
  Hash: THashSHA2;
  Row, Left, Right: Integer;
begin
  Hash := THashSHA2.Create;
  Left := W * X1 div 960;
  Right := W * X2 div 960;
  for Row := H * Y1 div 720 to H * Y2 div 720 do
    Hash.Update(Pixels[Row * W + Left], (Right - Left) * SizeOf(TPIXEL_RGBA));
  Result := Hash.HashAsString;
end;

function PixelAt(DesignX, DesignY: Integer): TPIXEL_RGBA;
begin
  Result := Pixels[(H * DesignY div 720) * W + W * DesignX div 960];
end;

function AlphaAt(DesignX, DesignY: Integer): Byte;
begin
  Result := PixelAt(DesignX, DesignY).A;
end;

procedure DrawFrame(Frame: Integer);
begin
  Obj.Frame := Frame;
  Require(Table^.Func_Proc_Video(@Video) = 1, Format('video frame %d', [Frame]));
  Require((W > 0) and (H > 0), 'image dimensions');
end;

function ReferenceOver(const Back, Front: TPIXEL_RGBA): TPIXEL_RGBA;
var
  A, B, D: Double;
begin
  if Front.A = 0 then Exit(Back);
  if (Back.A = 0) or (Front.A = 255) then Exit(Front);
  A := Front.A / 255;
  B := Back.A / 255 * (1 - A);
  D := A + B;
  Result.R := Trunc((Front.R * A + Back.R * B) / D + 0.500000001);
  Result.G := Trunc((Front.G * A + Back.G * B) / D + 0.500000001);
  Result.B := Trunc((Front.B * A + Back.B * B) / D + 0.500000001);
  Result.A := Trunc(D * 255 + 0.500000001);
end;

procedure AssertComposite(Frame: Integer);
var
  Back, Front, Both: TArray<TPIXEL_RGBA>;
  Expected: TPIXEL_RGBA;
  I: Integer;
begin
  Check('奥側の構造物', True);
  Check('手前側の構造物', False);
  DrawFrame(Frame);
  Back := Copy(Pixels);
  Check('奥側の構造物', False);
  Check('手前側の構造物', True);
  DrawFrame(Frame);
  Front := Copy(Pixels);
  Check('奥側の構造物', True);
  DrawFrame(Frame);
  Both := Copy(Pixels);
  Require((Length(Both) = Length(Back)) and (Length(Both) = Length(Front)), 'layer sizes');
  for I := 0 to High(Both) do
  begin
    Expected := ReferenceOver(Back[I], Front[I]);
    if not CompareMem(@Expected, @Both[I], 4) then
      raise Exception.CreateFmt('layer composition at %d frame %d', [I, Frame]);
  end;
  Inc(Checks);
  Check('奥側の構造物', False);
  Check('手前側の構造物', False);
  DrawFrame(Frame);
  for I := 0 to High(Pixels) do
    if PCardinal(@Pixels[I])^ <> 0 then raise Exception.Create('transparent layers');
  Inc(Checks);
  Check('奥側の構造物', True);
  Check('手前側の構造物', True);
end;

procedure SavePreview(const Name: string);
var
  Header: TBitmapHeader;
  FileOut: TFileStream;
  X, Y, Bg, A, Offset: Integer;
  BGR: TBytes;
  P: TPIXEL_RGBA;
begin
  if ParamCount < 2 then Exit;
  SetLength(BGR, (W * 3 + 3) and not 3);
  Header := Default(TBitmapHeader);
  Header.Magic := $4D42;
  Header.FileSize := SizeOf(Header) + Length(BGR) * H;
  Header.PixelOffset := SizeOf(Header);
  Header.HeaderSize := 40;
  Header.W := W;
  Header.H := -H;
  Header.Planes := 1;
  Header.BPP := 24;
  FileOut := TFileStream.Create(IncludeTrailingPathDelimiter(ParamStr(2)) + Name + '.bmp', fmCreate);
  try
    FileOut.WriteBuffer(Header, SizeOf(Header));
    for Y := 0 to H - 1 do
    begin
      for X := 0 to W - 1 do
      begin
        Bg := 223 + ((X div 16 + Y div 16) mod 2) * 17;
        P := Pixels[Y * W + X];
        A := P.A;
        Offset := X * 3;
        BGR[Offset] := (A * P.B + (255 - A) * Bg + 127) div 255;
        BGR[Offset + 1] := (A * P.G + (255 - A) * Bg + 127) div 255;
        BGR[Offset + 2] := (A * P.R + (255 - A) * Bg + 127) div 255;
      end;
      FileOut.WriteBuffer(BGR[0], Length(BGR));
    end;
  finally
    FileOut.Free;
  end;
end;

procedure TestTimeline;
var
  S: TElevatorSettings;
  T: TElevatorSchedule;
  F: TElevatorFrame;
  Floors: TArray<Integer>;
begin
  S := PresetSettings(esOutside, eeReiwa, ekStandard);
  S.Values[etMinFloor] := 99;
  S.Values[etMaxFloor] := -99;
  S.Values[etOwnFloor] := 0;
  S.Values[etInitialFloor] := -2;
  S.Values[etDestination] := 97;
  T := MakeSchedule(S);
  Require((T.FirstFloor = -99) and (T.LastFloor = 98) and (T.OwnFloor = 0), 'floor bounds and zero');
  Require(FloorLabel(T.StartFloor) = 'B2', 'initial floor');
  F := EvaluateFrame(T, T.PressAt + (T.ArriveAt - T.PressAt) * 0.53);
  Require((FloorLabel(F.FloorIndex) = 'B1') and (F.Direction = 1) and F.ButtonLit, 'travel through basement');
  Require((FloorLabel(EvaluateFrame(T, T.ArriveAt).FloorIndex) = '1F') and
    (EvaluateFrame(T, T.CloseEnd).OpenAmount = 0), 'arrival and final door');
  Require(EvaluateFrame(T, (T.CloseAt + T.CloseEnd) * 0.5).OpenAmount > 0.49, 'door closing');
  S.Scene := esInside;
  T := MakeSchedule(S);
  Require((T.StartFloor = 0) and (T.TargetFloor = 96), 'interior floor mapping');
  Floors := FloorButtons(T, 12);
  Require((Length(Floors) = 12) and (TArray.BinarySearch<Integer>(Floors, 0, F.FloorIndex)) and
    (TArray.BinarySearch<Integer>(Floors, 96, F.FloorIndex)), 'large-floor panel');
  S.Values[etTravel] := 0;
  S.Values[etOpen] := 0;
  S.Values[etHold] := 0;
  S.Values[etClose] := 0;
  T := MakeSchedule(S);
  F := EvaluateFrame(T, T.PressAt);
  Require(F.Arrived and (F.Direction = 0) and (F.OpenAmount = 0) and (F.FloorIndex = 96), 'zero durations');
  S.Values[etMinFloor] := -12;
  S.Values[etMaxFloor] := -3;
  T := MakeSchedule(S);
  Require((T.StartFloor = -3) and (T.TargetFloor = -3) and (T.ArriveAt = T.PressAt), 'clamping to basement building');
end;

function Energy(FromSeconds: Double): Double;
var
  I: Integer;
begin
  Obj.SampleIndex := Round(FromSeconds * Scene.SampleRate);
  Obj.SampleNum := 2048;
  Require(Table^.Func_Proc_Audio(@Audio) = 1, 'audio callback');
  Require(CompareMem(@Samples[0][0], @Samples[1][0], Obj.SampleNum * 4), 'stereo');
  Result := 0;
  for I := 0 to High(Samples[0]) do
  begin
    if Abs(Samples[0][I]) > 1 then raise Exception.Create('PCM amplitude');
    Result := Result + Sqr(Samples[0][I]);
  end;
end;

procedure TestAudio;
var
  FullVolume, First: Double;
  Whole, Chunk: TArray<Single>;
begin
  Preset(esOutside, eeReiwa, ekStandard);
  Track(etOwnFloor, 1);
  Track(etInitialFloor, 5);
  Track(etDestination, 6);
  Track(etWait, 0.5);
  Track(etTravel, 2.5);
  Track(etOpen, 0.85);
  Track(etHold, 2.0);
  Track(etClose, 0.9);
  Require(Energy(0.2) = 0, 'waiting audio silence');
  First := Energy(0.5);
  Require(First > 0.5, 'call tone');
  Require(Energy(1.5) > 0.1, 'running motor');
  Require(Energy(3.02) > 0.3, 'arrival');
  Require(Energy(3.62) > 0.1, 'opening motor');
  Require(Energy(5.1) = 0, 'held still');
  Require(Energy(6.0) > 0.1, 'closing motor');
  Require(Energy(7.0) > 0.1, 'onward motor after closing');
  Require(Energy(9.5) = 0, 'finished silence');
  Track(etDestination, 1);
  Require(Energy(7.0) = 0, 'no onward motor when staying on the boarding floor');
  Track(etDestination, 6);
  Track(etVolume, 100);
  FullVolume := Energy(0.5);
  Require(Abs(FullVolume / First - 4) < 0.00001, 'linear volume');
  Whole := Copy(Samples[0]);
  Obj.SampleIndex := Obj.SampleIndex + 500;
  Obj.SampleNum := 1000;
  Require(Table^.Func_Proc_Audio(@Audio) = 1, 'partial audio callback');
  Chunk := Copy(Samples[0]);
  Require(CompareMem(@Whole[500], @Chunk[0], 1000 * 4), 'arbitrary block segmentation');
  Check('音声出力', False);
  Require(Energy(0.5) = 0, 'mute');
  Check('音声出力', True);
  Track(etVolume, 50);
  Preset(esInside, eeReiwa, ekStandard);
  Require(Energy(0.5) > 0.5, 'destination tone');
end;

procedure TestCarPanel;
var
  WithPanel: TArray<TPIXEL_RGBA>;
  X, Y, Index, Changed: Integer;
begin
  DrawFrame(52);
  WithPanel := Copy(Pixels);
  Check('操作パネル表示', False);
  DrawFrame(52);
  Changed := 0;
  for Index := 0 to High(Pixels) do
    if not CompareMem(@Pixels[Index], @WithPanel[Index], SizeOf(TPIXEL_RGBA)) then
    begin
      X := (Index mod W) * 960 div W;
      Y := (Index div W) * 720 div H;
      if (X < 600) or (X > 628) or (Y < 284) or (Y > 383) then
        raise Exception.CreateFmt('car panel exceeds its footprint at %d,%d', [X, Y]);
      Inc(Changed);
    end;
  Require(Changed > 10, 'compact panel appears');
  Check('操作パネル表示', True);
end;

procedure TestDoorWindows;
var
  A: TElevatorScene;
  X: Integer;
  BeforeArrival: string;
begin
  for A := esOutside to esInside do
  begin
    Preset(A, eeLateShowa, ekStandard);
    X := 395;
    if A = esInside then X := 436;
    Check('奥側の構造物', False);
    Track(etWindowTransparency, 0);
    DrawFrame(90);
    Require(AlphaAt(X, 300) = 255, 'opaque window setting');
    Track(etWindowTransparency, 50);
    DrawFrame(90);
    Require((AlphaAt(X, 300) >= 125) and (AlphaAt(X, 300) < 170), 'half-transparent window');
    Track(etWindowTransparency, 100);
    DrawFrame(90);
    Require(AlphaAt(X, 300) = 0, 'clear window setting');
    Select('扉の縦窓', Ord(wmOff));
    DrawFrame(90);
    Require(AlphaAt(X, 300) = 255, 'window override off');
    Select('扉の縦窓', Ord(wmByEra));
    Check('奥側の構造物', True);
    DrawFrame(51);
    BeforeArrival := RegionHash(X - 7, 260, X + 7, 335);
    DrawFrame(90);
    Require(AlphaAt(X, 300) = 255, 'window view is composited');
    Require(BeforeArrival <> RegionHash(X - 7, 260, X + 7, 335), 'window view follows arrival');
    AssertComposite(90);
    AssertComposite(96);
    Track(etWindowTransparency, 50);
    DrawFrame(90);
    if A = esOutside then SavePreview('05-window-exterior')
    else SavePreview('06-window-interior');
  end;
  DrawFrame(126);
  Require(AlphaAt(436, 300) = 0, 'open door releases the landing view');
  Check('手前側の構造物', False);
  DrawFrame(96);
  Require((AlphaAt(420, 300) = 255) and (AlphaAt(436, 300) = 0), 'landing follows the sliding window');
  Check('手前側の構造物', True);

  Preset(esInside, eeReiwa, ekStandard);
  Check('奥側の構造物', False);
  Track(etWindowTransparency, 100);
  DrawFrame(90);
  Require(AlphaAt(436, 300) = 255, 'other eras have solid doors in automatic mode');
  Select('扉の縦窓', Ord(wmOn));
  DrawFrame(90);
  Require(AlphaAt(436, 300) = 0, 'window override on');
  Select('扉の縦窓', Ord(wmByEra));
  Track(etWindowTransparency, 50);
  Check('奥側の構造物', True);
end;

procedure TestVideo;
const
  Frames: array[0..4] of Integer = (0, 52, 102, 126, 240);
var
  A: TElevatorScene;
  E: TElevatorEra;
  K: TElevatorKind;
  B: TBackground;
  Frame: Integer;
  Hold, Closed, Prior: string;
begin
  Track(etOwnFloor, 3);
  Select('プリセット場面', Ord(esInside));
  Select('プリセット年代', Ord(eeFuture));
  Select('プリセット種類', Ord(ekMine));
  Require(PFILTER_ITEM_SELECT(FindItem('場面'))^.Value = Ord(esOutside), 'selection is deferred');
  Require(PFILTER_ITEM_SELECT(FindItem('年代'))^.Value = Ord(eeReiwa), 'default era');
  for A := Low(TElevatorScene) to High(TElevatorScene) do
    for E := Low(TElevatorEra) to High(TElevatorEra) do
      for K := Low(TElevatorKind) to High(TElevatorKind) do
      begin
        Preset(A, E, K);
        Require(PFILTER_ITEM_TRACK(FindItem('自分の階'))^.Value = 3, 'floors retained by preset');
        for Frame in Frames do
        begin
          DrawFrame(Frame);
          Digest.Add(Format('%d-%d-%d-%d %s', [Ord(A), Ord(E), Ord(K), Frame, HashBytes]));
        end;
      end;
  Preset(esInside, eeReiwa, ekStandard);
  DrawFrame(126);
  Hold := HashBytes;
  Require(AlphaAt(480, 330) = 0, 'inside open doorway');
  Require((AlphaAt(480, 600) = 255) and (AlphaAt(480, 70) = 255), 'cabin floor and ceiling');
  Require((AlphaAt(250, 350) = 255) and (AlphaAt(710, 350) = 255), 'symmetric sidewalls');
  Require((AlphaAt(165, 350) = 0) and (AlphaAt(795, 350) = 0), 'compact cabin framing');
  DrawFrame(240);
  Closed := HashBytes;
  Require(AlphaAt(480, 330) = 255, 'inside closed doorway');
  SavePreview('01-interior-closed');
  Require(Closed <> Hold, 'door animation');
  DrawFrame(126);
  Require(Hold = HashBytes, 'backward seek');
  AssertComposite(105);
  DrawFrame(126);
  SavePreview('01-interior-open');
  TestCarPanel;
  Preset(esOutside, eeReiwa, ekStandard);
  DrawFrame(126);
  Require(Pixels[(H * 330 div 720) * W + W * 451 div 960].A = 255, 'outside reveals cabin');
  Require(Pixels[(H * 300 div 720) * W + W * 100 div 960].A = 0, 'outside transparent surround');
  SavePreview('00-exterior');
  AssertComposite(101);
  Preset(esOutside, eeMeiji, ekStandard);
  Check('奥側の構造物', False);
  DrawFrame(52);
  Require(AlphaAt(302, 285) = 0, 'lattice gap transparent');
  Check('奥側の構造物', True);
  DrawFrame(102);
  SavePreview('02-lattice');
  Preset(esOutside, eeMidShowa, ekFreight);
  DrawFrame(103);
  SavePreview('03-freight');
  Preset(esInside, eeFuture, ekGlass);
  Select('背景', Ord(bgNone));
  DrawFrame(52);
  Require(AlphaAt(480, 300) = 0, 'clear rear glass without scene');
  Require((AlphaAt(214, 300) = 0) and (AlphaAt(746, 300) = 0), 'clear glass at both sides');
  Hold := HashBytes;
  Check('操作パネル表示', False);
  Check('階数・方向表示', False);
  DrawFrame(52);
  Require(HashBytes = Hold, 'controls face away from the panoramic view');
  DrawFrame(126);
  Require(HashBytes = Hold, 'opening the front door does not change the clear rear glass');
  Check('操作パネル表示', True);
  Check('階数・方向表示', True);
  for B := bgResidential to bgScenic do
  begin
    Select('背景', Ord(B));
    DrawFrame(48);
    Prior := RegionHash(350, 222, 550, 570);
    DrawFrame(66);
    Require(Prior <> RegionHash(350, 222, 550, 570), 'panoramic scenery moves');
    Require((AlphaAt(385, 300) = 255) and (AlphaAt(480, 300) = 255) and
      (AlphaAt(575, 300) = 255), 'one uninterrupted rear view');
    Require((AlphaAt(214, 300) = 255) and (AlphaAt(746, 300) = 255), 'small side views');
    DrawFrame(126);
    Require(AlphaAt(480, 300) = 255, 'rear scenery stays behind the glass at arrival');
    AssertComposite(102);
    DrawFrame(56);
    SavePreview('04-glass-' + IntToStr(Ord(B)));
  end;
  Scene.Width := 1920;
  Scene.Height := 1080;
  DrawFrame(98);
  Require((W = 1440) and (H = 1080), '1080p canvas');
  AssertComposite(98);
  Scene.Width := 1;
  Scene.Height := 1;
  DrawFrame(105);
  Require((W = 1) and (H = 1), 'small canvas');
  Scene.Width := 480;
  Scene.Height := 360;
  TestDoorWindows;
end;

function MockFloorTexture: Pointer; cdecl;
begin
  Inc(FloorReads);
  if Obj.Frame < 75 then Result := Pointer(DepartureTexture)
  else Result := Pointer(ArrivalTexture);
end;

function MockFloorObject(Layer: Integer; Offset: Double): OBJECT_HANDLE; cdecl;
begin
  Result := nil;
  if HasMockFloor and (Layer = 0) then Result := Pointer(1);
end;

function MockFloorPlacement(Handle: OBJECT_HANDLE; Offset: Double;
  Param: POBJECT_IMAGE_PARAM; ParamSize: Integer): Boolean; cdecl;
begin
  Result := (Handle = nil) and (Offset = 0) and (ParamSize = SizeOf(FloorPlacement));
  if Result then Param^ := FloorPlacement;
end;

procedure MakeFloorFixtures;
var
  Device: ID3D11Device;
  Context: ID3D11DeviceContext;
  Level: D3D_FEATURE_LEVEL;
  Desc: D3D11_TEXTURE2D_DESC;
  Data: D3D11_SUBRESOURCE_DATA;
  RGBA: TArray<TPIXEL_RGBA>;
  Half: TArray<Word>;
  X, Y, Index: Integer;
begin
  Require(D3D11CreateDevice(nil, D3D_DRIVER_TYPE_WARP, 0, 0, nil, 0, D3D11_SDK_VERSION,
    Device, Level, Context) >= 0, 'create test D3D device');
  Desc := Default(D3D11_TEXTURE2D_DESC);
  Desc.Width := Scene.Width;
  Desc.Height := Scene.Height;
  Desc.MipLevels := 1;
  Desc.ArraySize := 1;
  Desc.SampleDesc.Count := 1;
  Desc.Usage := D3D11_USAGE_DEFAULT;
  Data := Default(D3D11_SUBRESOURCE_DATA);
  SetLength(RGBA, Scene.Width * Scene.Height);
  SetLength(Half, Length(RGBA) * 4);
  for Y := 0 to Scene.Height - 1 do
    for X := 0 to Scene.Width - 1 do
    begin
      Index := Y * Scene.Width + X;
      RGBA[Index].R := 243;
      RGBA[Index].G := X div 4;
      RGBA[Index].B := Y div 2;
      RGBA[Index].A := 255;
      Half[Index * 4 + 1] := $3C00; // 緑の到着画像
      if Y >= 150 then Half[Index * 4 + 2] := $3A00;
      Half[Index * 4 + 3] := $3C00;
    end;
  Desc.Format := DXGI_FORMAT_R8G8B8A8_UNORM;
  Data.pSysMem := @RGBA[0];
  Data.SysMemPitch := Scene.Width * 4;
  Require(Device.CreateTexture2D(Desc, @Data, DepartureTexture) >= 0, 'departure RGBA fixture');
  Desc.Format := DXGI_FORMAT_R16G16B16A16_FLOAT;
  Data.pSysMem := @Half[0];
  Data.SysMemPitch := Scene.Width * 8;
  Require(Device.CreateTexture2D(Desc, @Data, ArrivalTexture) >= 0, 'arrival FP16 fixture');
end;

procedure TestFloorTransit;
var
  P: TPIXEL_RGBA;
  Prior, NoFloor: string;
begin
  Preset(esInside, eeLateShowa, ekStandard);
  Track(etOwnFloor, 1);
  Track(etDestination, 4);
  Track(etWindowTransparency, 100);
  DrawFrame(52);
  Prior := HashBytes;
  DrawFrame(22);
  NoFloor := HashBytes;
  Scene.Width := 640;
  MakeFloorFixtures;
  try
    Obj.Layer := 1;
    FloorPlacement := Default(TOBJECT_IMAGE_PARAM);
    FloorPlacement.SX := 1;
    FloorPlacement.SY := 1;
    Video.GetFramebufferTexture2D := MockFloorTexture;
    Video.GetImageObject := MockFloorObject;
    Video.GetOutputImageParam := MockFloorPlacement;
    HasMockFloor := False;
    DrawFrame(22);
    Require(HashBytes = NoFloor, 'no lower layer preserves the existing window');
    Require(FloorReads = 0, 'no readback without a lower layer');
    HasMockFloor := True;
    DrawFrame(10);
    Require(AlphaAt(436, 300) = 0, 'departure floor shows through while waiting');
    Require(FloorReads = 0, 'waiting requires no D3D readback');

    DrawFrame(22);
    P := PixelAt(436, 332);
    Require((P.R > 235) and (P.B >= 65) and (P.B <= 72) and (P.G >= 72) and (P.G <= 77),
      'upward departure samples the current background with a downward offset');
    Require(PixelAt(436, 257).R <> 243, 'travel texture replaces the vacated upper edge');
    SavePreview('07-floor-leaving');
    AssertComposite(22);
    DrawFrame(52);
    Require(HashBytes = Prior, 'existing window animation retained at mid-travel');
    SavePreview('08-floor-travel');

    DrawFrame(82);
    P := PixelAt(436, 266);
    Require((P.G >= 250) and (P.B >= 185), 'destination appears from above, with FP16 color intact');
    Require(PixelAt(436, 342).G < 230, 'lower edge still shows the shaft before arrival');
    SavePreview('09-floor-arriving');
    DrawFrame(90);
    Require(AlphaAt(436, 300) = 0, 'destination floor becomes the stationary lower layer');
    DrawFrame(126);
    Require(AlphaAt(480, 330) = 0, 'open doorway still shows the lower layer');

    FloorPlacement.X := 32;
    FloorPlacement.Y := 22;
    DrawFrame(22);
    P := PixelAt(436, 332);
    Require((P.R > 235) and (P.G >= 80) and (P.G <= 85) and (P.B >= 76) and (P.B <= 83),
      'readback stays aligned with standard XY placement');
    FloorPlacement.X := 0;
    FloorPlacement.Y := 0;

    Track(etOwnFloor, 4);
    Track(etDestination, 1);
    DrawFrame(22);
    Require((PixelAt(436, 256).R > 235) and (PixelAt(436, 340).R <> 243),
      'downward departure moves the view upwards');
    DrawFrame(82);
    Require((PixelAt(436, 341).G >= 250) and (PixelAt(436, 256).G < 230),
      'downward arrival brings the destination in from below');
    Track(etOwnFloor, 1);
    Track(etDestination, 4);

    Check('奥のフロア画像を使う', False);
    DrawFrame(22);
    Require(HashBytes = NoFloor, 'floor image option restores the original window');
    Check('奥のフロア画像を使う', True);
    Preset(esInside, eeReiwa, ekGlass);
    Select('背景', Ord(bgNone));
    DrawFrame(10);
    Require(AlphaAt(480, 300) = 0, 'panoramic glass lets the real floor show when stationary');
    DrawFrame(52);
    Require(AlphaAt(480, 300) = 255, 'panoramic glass shows a shaft during travel');
    DrawFrame(82);
    Require(PixelAt(480, 260).G >= 250, 'arrival spans the panoramic glass');

    Preset(esCarFront, eeReiwa, ekGlass);
    Check('手前側の構造物', False);
    DrawFrame(10);
    Require(AlphaAt(450, 320) = 0, 'front view waits with original departure floor visible');
    DrawFrame(22);
    Require(PixelAt(450, 418).R >= 235, 'front view samples the departing floor');
    DrawFrame(82);
    Require(PixelAt(450, 320).G >= 250, 'front view samples the arrival floor');
    Check('手前側の構造物', True);
    AssertComposite(82);
  finally
    Video.GetFramebufferTexture2D := nil;
    Video.GetImageObject := nil;
    Video.GetOutputImageParam := nil;
    DepartureTexture := nil;
    ArrivalTexture := nil;
    Obj.Layer := 0;
    Scene.Width := 480;
    Track(etWindowTransparency, 50);
  end;
end;


procedure TestStartDoor;
var
  S: TElevatorSettings;
  T: TElevatorSchedule;
  F: TElevatorFrame;
  Header: PPItem;
  Rule: PFILTER_ITEM_HIDE_RULE;
  ClosedHash, ClosingHash: string;
  ClosedStartAudio: TArray<Single>;
begin
  Require(PFILTER_ITEM_SELECT(FindItem('開始時の扉'))^.Value = Ord(sdClosed), 'closed by default');
  Rule := nil;
  Header := PPItem(Table^.Items);
  while Header^ <> nil do
  begin
    if (string(Header^^.ItemType) = 'hiderule') and (string(Header^^.Name) = '開始時の扉') then
      Rule := PFILTER_ITEM_HIDE_RULE(Header^);
    Inc(Header);
  end;
  Require((Rule <> nil) and (string(Rule^.ConditionName) = '場面') and
    (Rule^.ConditionOperator = HIDE_RULE_EQUAL) and (Rule^.ConditionValue = Ord(esOutside)),
    'outside hides the start door setting');

  S := PresetSettings(esInside, eeReiwa, ekStandard);
  S.StartDoor := sdCloseFromOpen;
  T := MakeSchedule(S);
  Require(T.StartsOpen and SameValue(T.DepartAt, 1.4) and SameValue(T.ArriveAt, 3.9),
    'close period precedes the full travel duration');
  F := EvaluateFrame(T, 0.25);
  Require((F.OpenAmount = 1) and not F.ButtonLit and (F.Direction = 0), 'wait with door open');
  F := EvaluateFrame(T, 0.95);
  Require(SameValue(F.OpenAmount, 0.5, 1E-6) and F.ButtonLit and (F.Direction = 0) and
    SameValue(F.FloorPosition, T.StartFloor), 'close in place after lighting destination button');
  Require(EvaluateFloorMotion(T, 1.39).Phase = fpStill, 'departure floor stays put while closing');
  F := EvaluateFrame(T, T.DepartAt);
  Require((F.OpenAmount = 0) and (F.Direction = 1), 'travel begins fully closed');
  Require(EvaluateFloorMotion(T, 1.60).Phase = fpLeaving, 'departure floor moves after closing');
  Require(EvaluateFloorMotion(T, 3.65).Phase = fpArriving, 'arrival view follows the new arrival');
  Require(EvaluateFrame(T, 4.84).OpenAmount = 1, 'door opens normally at destination');
  S.Values[etClose] := 0;
  T := MakeSchedule(S);
  Require(T.DepartAt = T.PressAt, 'zero closing duration departs immediately');
  Require((EvaluateFrame(T, 0.49).OpenAmount = 1) and
    (EvaluateFrame(T, T.DepartAt).OpenAmount = 0), 'immediate close at departure');
  S.Scene := esOutside;
  T := MakeSchedule(S);
  Require(not T.StartsOpen and (T.DepartAt = T.PressAt), 'outside ignores the hidden value');

  Preset(esInside, eeReiwa, ekStandard);
  Track(etOwnFloor, 1);
  Track(etDestination, 4);
  DrawFrame(0);
  Require(AlphaAt(480, 330) = 255, 'closed default video');
  Require(Energy(0.95) > 0, 'closed default is travelling by 0.95 seconds');
  ClosedStartAudio := Copy(Samples[0]);

  Select('開始時の扉', Ord(sdCloseFromOpen));
  DrawFrame(0);
  Require(AlphaAt(480, 330) = 0, 'open initial video');
  DrawFrame(28);
  Require((AlphaAt(401, 330) = 255) and (AlphaAt(480, 330) = 0), 'closing video');
  ClosingHash := HashBytes;
  DrawFrame(42);
  Require(AlphaAt(480, 330) = 255, 'closed at the departure frame');
  DrawFrame(28);
  Require(ClosingHash = HashBytes, 'closing is deterministic on backward seek');
  Require(Energy(0.95) > 0, 'boarding door motor is audible');
  Require(not CompareMem(@ClosedStartAudio[0], @Samples[0][0], Length(ClosedStartAudio) * 4),
    'boarding motor differs from drive sound');
  Require(Energy(1.75) > 0, 'drive is audible after boarding');

  Preset(esOutside, eeReiwa, ekStandard);
  DrawFrame(28);
  ClosedHash := HashBytes;
  Select('開始時の扉', Ord(sdClosed));
  DrawFrame(28);
  Require(ClosedHash = HashBytes, 'hidden outside setting does not affect the video');
end;


procedure TestDoorWaits;
var
  S: TElevatorSettings;
  T: TElevatorSchedule;
  F: TElevatorFrame;
  BeforeDeparture, BeforeOpening: string;
begin
  Require(PFILTER_ITEM_TRACK(FindItem('閉扉後待機時間'))^.Value = 0, 'default departure wait');
  Require(PFILTER_ITEM_TRACK(FindItem('到着後待機時間'))^.Value = 0, 'default arrival wait');
  S := PresetSettings(esInside, eeReiwa, ekStandard);
  S.StartDoor := sdCloseFromOpen;
  S.Values[etClosedWait] := 0.8;
  S.Values[etArrivalWait] := 1.5;
  T := MakeSchedule(S);
  Require(SameValue(T.EntryClosedAt, 1.4) and SameValue(T.DepartAt, 2.2), 'wait after the door closes');
  Require(SameValue(T.ArriveAt, 4.7) and SameValue(T.OpenAt, 6.2), 'wait after arrival');
  F := EvaluateFrame(T, 0.95);
  Require(SameValue(F.OpenAmount, 0.5, 1E-6), 'departure wait does not stretch the closing');
  F := EvaluateFrame(T, 1.8);
  Require((F.OpenAmount = 0) and (F.Direction = 0) and (F.FloorIndex = T.StartFloor) and F.ButtonLit,
    'closed and stationary through the departure wait');
  Require(EvaluateFloorMotion(T, 2.15).Phase = fpStill, 'scene image does not move during the wait');
  Require(EvaluateFloorMotion(T, 2.26).Phase = fpLeaving, 'scene image starts after the wait');
  F := EvaluateFrame(T, 5.2);
  Require(F.Arrived and (F.FloorIndex = T.TargetFloor) and (F.Direction = 0) and
    (F.OpenAmount = 0) and not F.ButtonLit, 'closed and stopped while waiting to open');
  F := EvaluateFrame(T, 6.48);
  Require(F.Arrived and (F.OpenAmount > 0) and (F.OpenAmount < 1), 'opening follows the arrival wait');
  S.StartDoor := sdClosed;
  T := MakeSchedule(S);
  Require(SameValue(T.EntryClosedAt, T.PressAt) and SameValue(T.DepartAt, 1.3),
    'closed start waits after the destination button is pressed');
  S.Scene := esOutside;
  T := MakeSchedule(S);
  Require((T.DepartAt = T.PressAt) and SameValue(T.OpenAt - T.ArriveAt, 1.5),
    'outside supports only the arrival wait');

  Preset(esInside, eeReiwa, ekStandard);
  Select('開始時の扉', Ord(sdCloseFromOpen));
  Track(etOwnFloor, 1);
  Track(etDestination, 4);
  Track(etClosedWait, 0.8);
  Track(etArrivalWait, 1.5);
  DrawFrame(51);
  Require(AlphaAt(480, 330) = 255, 'door closed while waiting to depart');
  BeforeDeparture := HashBytes;
  DrawFrame(63);
  Require(HashBytes = BeforeDeparture, 'view holds on the departure floor');
  DrawFrame(146);
  Require(AlphaAt(480, 330) = 255, 'door closed while waiting at the destination');
  BeforeOpening := HashBytes;
  DrawFrame(173);
  Require(HashBytes = BeforeOpening, 'view holds at the destination');
  DrawFrame(201);
  Require(AlphaAt(480, 330) = 0, 'door opens after the destination wait');

  Require(Energy(0.85) > 0.1, 'boarding closure has sound');
  Require(Energy(1.415) > 0.1, 'strike sounds as the boarding door closes');
  Require(Energy(1.8) = 0, 'drive is silent during the departure wait');
  Require(Energy(2.47) > 0.1, 'motor starts after the departure wait');
  Require(Energy(4.73) > 0.1, 'chime sounds immediately on arrival');
  Require(Energy(5.96) = 0, 'door has not started opening during the arrival wait');
  Require(Energy(6.40) > 0.1, 'opening motor starts after the arrival wait');
  Track(etClosedWait, 0);
  Track(etArrivalWait, 0);
  Select('開始時の扉', Ord(sdClosed));
end;


procedure TestDoorCenter;
var
  A: TElevatorScene;
  Span, WithButtons: TPoint;
  Offset: Integer;
  function OpeningSpan: TPoint;
  begin
    Result.X := W div 2;
    Result.Y := W div 2;
    while (Result.X > 0) and (Pixels[Offset + Result.X - 1].A = 0) do Dec(Result.X);
    while (Result.Y < W - 1) and (Pixels[Offset + Result.Y + 1].A = 0) do Inc(Result.Y);
  end;
  function StructureSpan: TPoint;
  begin
    Result.X := 0;
    Result.Y := W - 1;
    while (Result.X < Result.Y) and (Pixels[Offset + Result.X].A = 0) do Inc(Result.X);
    while (Result.Y > Result.X) and (Pixels[Offset + Result.Y].A = 0) do Dec(Result.Y);
  end;
begin
  for A := Low(TElevatorScene) to High(TElevatorScene) do
  begin
    Preset(A, eeReiwa, ekStandard);
    Check('奥側の構造物', False);
    DrawFrame(126);
    Offset := (H * 383 div 720) * W;
    Require(Pixels[Offset + W div 2].A = 0, 'the origin lies in the opening');
    Span := OpeningSpan;
    Require((Span.Y - Span.X >= W div 5) and (Abs(Span.X + Span.Y - (W - 1)) <= 1),
      'the door opening is centered on the object origin');

    if A = esOutside then
    begin
      WithButtons := StructureSpan;
      Require(Abs(WithButtons.X + WithButtons.Y - (W - 1)) <= 1, 'equal exterior wall widths');
      Check('操作パネル表示', False);
      DrawFrame(126);
      Span := StructureSpan;
      Require((Span.X = WithButtons.X) and (Span.Y = WithButtons.Y), 'the frame keeps its width when buttons are hidden');
      Check('操作パネル表示', True);
    end;

    Check('奥側の構造物', True);
    DrawFrame(0);
    case A of
      esOutside: SavePreview('10-centered-exterior');
      esInside: SavePreview('11-centered-interior');
    end;
  end;
end;


procedure TestCarFrontScenery;
var
  S: TElevatorSettings;
  T: TElevatorSchedule;
  LowView, HighView, Shaft: string;
  LowSample, HighSample, Dark: TPIXEL_RGBA;
begin
  S := PresetSettings(esCarFront, eeReiwa, ekStandard);
  S.Values[etMinFloor] := -8;
  S.Values[etMaxFloor] := 50;
  S.Values[etOwnFloor] := -3;
  S.Values[etInitialFloor] := 22;
  S.Values[etDestination] := 18;
  S.StartDoor := sdCloseFromOpen;
  S.Values[etClosedWait] := 0.3;
  S.Values[etArrivalWait] := 0.6;
  T := MakeSchedule(S);
  Require((T.StartFloor = -3) and (T.TargetFloor = 17), 'front view uses the ride floors');
  Require(T.StartsOpen and SameValue(T.DepartAt, 1.7) and SameValue(T.OpenAt, 4.8),
    'front view keeps all ride timings');

  Preset(esCarFront, eeReiwa, ekStandard);
  Select('開始時の扉', Ord(sdCloseFromOpen));
  Check('奥側の構造物', False);
  DrawFrame(5);
  Require(AlphaAt(480, 330) = 0, 'front view begins with the door open');
  DrawFrame(42);
  Require((AlphaAt(480, 330) = 255) and (AlphaAt(750, 383) = 0), 'only the cabin and door, without landing panel');
  Check('奥側の構造物', True);
  Select('開始時の扉', Ord(sdClosed));

  Preset(esCarFront, eeReiwa, ekGlass);
  Track(etMinFloor, -8);
  Track(etMaxFloor, 50);
  Track(etOwnFloor, 1);
  Track(etDestination, 1);
  DrawFrame(0);
  LowView := RegionHash(365, 295, 595, 430);
  LowSample := PixelAt(450, 405);
  SavePreview('12-carfront-1f');
  Track(etOwnFloor, 32);
  Track(etDestination, 32);
  DrawFrame(0);
  HighView := RegionHash(365, 295, 595, 430);
  HighSample := PixelAt(450, 405);
  Require((LowView <> HighView) and (LowSample.B > LowSample.G) and
    (HighSample.G >= HighSample.B), 'high view places the ground higher in the same window');
  SavePreview('13-carfront-32f');

  Track(etOwnFloor, -2);
  Track(etDestination, -5);
  DrawFrame(31);
  Shaft := RegionHash(365, 295, 595, 430);
  Dark := PixelAt(450, 388);
  Require((Dark.A = 255) and (Dark.R < 45) and (Dark.G < 45) and (Dark.B < 45),
    'underground has a dark shaft');
  DrawFrame(57);
  Require(RegionHash(365, 295, 595, 430) <> Shaft, 'shaft beams move while descending');
  SavePreview('14-carfront-underground');

  Track(etOwnFloor, -1);
  Track(etDestination, 1);
  DrawFrame(42);
  Dark := PixelAt(450, 340);
  DrawFrame(80);
  Require(PixelAt(450, 340).B > Dark.B + 30, 'the view brightens as it passes ground level');

  Select('背景', Ord(bgNone));
  DrawFrame(42);
  Require(AlphaAt(450, 340) = 0, 'no background also leaves the underground transparent');
  DrawFrame(90);
  Require(AlphaAt(450, 340) = 0, 'no background stays transparent above ground');
  SavePreview('15-carfront-transparent');
  AssertComposite(42);
end;


procedure TestGroundTransition;
var
  GroundSky, GroundStreet, Current: TPIXEL_RGBA;
  First, Second, Ninth, Tenth: Integer;
  function HorizonAt(Floor: Integer): Integer;
  var
    Y: Integer;
    P, Previous: TPIXEL_RGBA;
  begin
    Track(etOwnFloor, Floor);
    Track(etDestination, Floor);
    DrawFrame(0);
    Previous := PixelAt(480, 376);
    for Y := 378 to 448 do
    begin
      P := PixelAt(480, Y);
      if P.B + 8 < Previous.B then Exit(Y);
      Previous := P;
    end;
    raise Exception.Create('Ground horizon is outside the expected window region');
  end;
begin
  Preset(esCarFront, eeReiwa, ekGlass);
  Track(etMinFloor, -8);
  Track(etMaxFloor, 50);
  Track(etOwnFloor, -1);
  Track(etDestination, 1);
  Check('手前側の構造物', False);
  DrawFrame(90);
  GroundSky := PixelAt(450, 303);
  GroundStreet := PixelAt(450, 422);
  DrawFrame(60);
  Current := PixelAt(450, 303);
  Require(Current.B < 45, 'shaft fills the window before crossing');
  DrawFrame(70);
  Current := PixelAt(450, 303);
  Require(CompareMem(@Current, @GroundSky, SizeOf(TPIXEL_RGBA)), 'the revealed strip shows unblended daylight');
  Current := PixelAt(450, 422);
  Require(Current.B < 45, 'shaft still covers the bottom of the window at the boundary');
  DrawFrame(76);
  Current := PixelAt(450, 422);
  Require(CompareMem(@Current, @GroundStreet, SizeOf(TPIXEL_RGBA)), 'boundary continues down through the window');

  Check('手前側の構造物', True);
  DrawFrame(60);
  SavePreview('16-surface-shaft');
  DrawFrame(70);
  SavePreview('17-surface-boundary');
  DrawFrame(90);
  SavePreview('18-surface-1f');

  Track(etOwnFloor, 1);
  Track(etDestination, -1);
  Check('手前側の構造物', False);
  DrawFrame(35);
  Current := PixelAt(450, 303);
  Require(CompareMem(@Current, @GroundSky, SizeOf(TPIXEL_RGBA)) and (PixelAt(450, 422).B < 45),
    'descending through the same boundary reverses the wipe');
  DrawFrame(48);
  Require(PixelAt(450, 303).B < 45, 'the descending shaft clears the daylight');

  Select('背景', Ord(bgOffice));
  First := HorizonAt(1);
  Second := HorizonAt(2);
  Ninth := HorizonAt(9);
  Tenth := HorizonAt(10);
  Require((First - Second >= 2) and (First - Second <= 4) and
    (Abs((First - Second) - (Ninth - Tenth)) <= 2) and (First - Tenth >= 26) and (First - Tenth <= 32),
    Format('the horizon moves steadily on the first ten floors (%d, %d, %d, %d)', [First, Second, Ninth, Tenth]));

  Check('手前側の構造物', True);
  Select('背景', Ord(bgScenic));
  DrawFrame(0);
  SavePreview('19-surface-10f');
end;


procedure TestNearScenery;
var
  B: TBackground;
  P, OpenSky: TPIXEL_RGBA;
  NearStrip, Sky: string;
begin
  Preset(esCarFront, eeReiwa, ekGlass);
  Track(etMinFloor, -8);
  Track(etMaxFloor, 50);
  Track(etOwnFloor, 1);
  Track(etDestination, 1);
  for B := bgResidential to bgScenic do
  begin
    Select('背景', Ord(B));
    DrawFrame(0);
    SavePreview('20-near-' + IntToStr(Ord(B)));
  end;

  Select('背景', Ord(bgOffice));
  Check('手前側の構造物', False);
  DrawFrame(0);
  P := PixelAt(360, 345);
  OpenSky := PixelAt(480, 345);
  Require(P.B + 12 < OpenSky.B, 'a near office building fills the side of the lower-floor view');
  Track(etOwnFloor, 32);
  Track(etDestination, 32);
  DrawFrame(0);
  P := PixelAt(360, 300);
  OpenSky := PixelAt(480, 300);
  Require(Abs(Integer(P.B) - OpenSky.B) < 18, 'the close building drops below the upper-floor view');
  Check('手前側の構造物', True);
  DrawFrame(0);
  SavePreview('21-near-high');

  Check('手前側の構造物', False);
  Track(etOwnFloor, 1);
  Track(etDestination, 8);
  DrawFrame(29);
  NearStrip := RegionHash(311, 276, 350, 364);
  Sky := RegionHash(452, 285, 508, 335);
  DrawFrame(45);
  Require(RegionHash(311, 276, 350, 364) <> NearStrip, 'the near ledges and columns move past the window');
  Require(RegionHash(452, 285, 508, 335) = Sky, 'the distant sky stays visible behind the near motion');

  Track(etOwnFloor, -2);
  Track(etDestination, -6);
  DrawFrame(49);
  NearStrip := RegionHash(310, 294, 342, 428);
  DrawFrame(70);
  Require(RegionHash(310, 294, 342, 428) <> NearStrip, 'near supports move in the underground section');
  Check('手前側の構造物', True);
  DrawFrame(70);
  SavePreview('22-near-shaft');

  Select('背景', Ord(bgNone));
  Check('手前側の構造物', False);
  DrawFrame(70);
  Require(AlphaAt(332, 343) = 0, 'no near scenery when the background is disabled');
  Check('手前側の構造物', True);
  AssertComposite(70);
end;


procedure TestExteriorApproach;
var
  E: TElevatorEra;
  K: TElevatorKind;
  ShaftUpper, ShaftLower, Parked, OpaqueDoor: string;
  function Upper: string;
  begin
    Result := RegionHash(272, 235, 290, 286);
  end;
  function Lower: string;
  begin
    Result := RegionHash(272, 505, 290, 560);
  end;
begin
  Track(etMinFloor, -8);
  Track(etMaxFloor, 16);
  Track(etOwnFloor, 5);
  Check('手前側の構造物', False);
  for E := Low(TElevatorEra) to High(TElevatorEra) do
    for K := Low(TElevatorKind) to High(TElevatorKind) do
    begin
      Preset(esOutside, E, K);
      Track(etInitialFloor, 8);
      DrawFrame(0);
      ShaftUpper := Upper;
      ShaftLower := Lower;
      DrawFrame(40);
      Require((Upper = ShaftUpper) and (Lower = ShaftLower), 'the shaft is stationary before the car reaches the opening');
      DrawFrame(72);
      Require((Upper <> ShaftUpper) and (Lower = ShaftLower), 'a descending car enters from the top');
      DrawFrame(90);
      Parked := HashBytes;
      Track(etInitialFloor, 2);
      DrawFrame(72);
      Require((Upper = ShaftUpper) and (Lower <> ShaftLower), 'an ascending car enters from the bottom');
      DrawFrame(90);
      Require(HashBytes = Parked, 'the car lands in the same position from either direction');
      Track(etInitialFloor, 5);
      DrawFrame(0);
      Require(HashBytes = Parked, 'a car already on the current floor remains parked');
    end;
  Check('手前側の構造物', True);

  Preset(esOutside, eeReiwa, ekStandard);
  Track(etInitialFloor, 8);
  DrawFrame(0);
  OpaqueDoor := RegionHash(440, 235, 520, 560);
  DrawFrame(72);
  Require(RegionHash(440, 235, 520, 560) = OpaqueDoor, 'the solid landing door covers the moving car');
  AssertComposite(72);

  Preset(esOutside, eeReiwa, ekGlass);
  Track(etInitialFloor, 8);
  DrawFrame(40);
  SavePreview('23-approach-shaft');
  DrawFrame(72);
  SavePreview('24-approach-descending');
  Track(etInitialFloor, 2);
  DrawFrame(72);
  SavePreview('25-approach-ascending');
  DrawFrame(134);
  SavePreview('26-approach-parked');
end;

procedure TestExteriorOnward;
const
  Directions: array[0..1] of Integer = (-1, 1);
var
  S: TElevatorSettings;
  T: TElevatorSchedule;
  F: TElevatorFrame;
  E: TElevatorEra;
  K: TElevatorKind;
  Direction: Integer;
  ShaftUpper, ShaftLower, BoardingDisplay, DestinationDisplay, DepartureFrame: string;

  function Upper: string;
  begin
    Result := RegionHash(272, 235, 290, 286);
  end;

  function Lower: string;
  begin
    Result := RegionHash(272, 505, 290, 560);
  end;

  function Display: string;
  begin
    Result := RegionHash(450, 103, 510, 123);
  end;

begin
  S := PresetSettings(esOutside, eeReiwa, ekGlass);
  S.Values[etOwnFloor] := 5;
  S.Values[etInitialFloor] := 8;
  for Direction in Directions do
  begin
    S.Values[etDestination] := 5 + Direction * 3;
    T := MakeSchedule(S);
    Require((T.TargetFloor = T.OwnFloor) and (T.OnwardDirection = Direction) and
      (Abs(T.DestinationAt - T.CloseEnd - S.Values[etTravel]) < 0.00001), 'onward schedule after boarding');
    F := EvaluateFrame(T, (T.CloseAt + T.CloseEnd) * 0.5);
    Require(F.Arrived and (F.FloorPosition = T.OwnFloor) and (F.Direction = 0) and
      (F.OpenAmount > 0.49), 'the car stays level until the doors close');
    F := EvaluateFrame(T, T.CloseEnd);
    Require((F.FloorPosition = T.OwnFloor) and (F.Direction = Direction) and
      (F.OpenAmount = 0) and not F.ButtonLit, 'onward travel starts with closed doors');
    F := EvaluateFrame(T, (T.CloseEnd + T.DestinationAt) * 0.5);
    Require((F.FloorIndex = T.OwnFloor + Direction) and (F.Direction = Direction) and
      not F.Arrived and (F.OpenAmount = 0), 'floor display and direction advance during onward travel');
    F := EvaluateFrame(T, T.DestinationAt);
    Require(F.Arrived and (F.FloorIndex = T.Destination) and (F.FloorPosition = T.Destination) and
      (F.Direction = 0) and (F.OpenAmount = 0), 'destination displayed while boarding doors stay shut');
  end;
  S.Values[etDestination] := 5;
  T := MakeSchedule(S);
  F := EvaluateFrame(T, T.CloseEnd + 1);
  Require((T.DestinationAt = T.CloseEnd) and (F.FloorPosition = T.OwnFloor) and
    (F.Direction = 0), 'same-floor destination leaves the car parked');
  S.Values[etDestination] := 8;
  S.Values[etTravel] := 0;
  T := MakeSchedule(S);
  F := EvaluateFrame(T, T.CloseEnd);
  Require((T.DestinationAt = T.CloseEnd) and (F.FloorPosition = T.Destination) and
    (F.Direction = 0) and (F.OpenAmount = 0), 'zero-duration onward movement is instantaneous');

  Track(etOwnFloor, 5);
  Track(etInitialFloor, 8);
  Track(etWait, 0.5);
  Track(etTravel, 2.5);
  Track(etArrivalWait, 0);
  Track(etOpen, 0.85);
  Track(etHold, 2);
  Track(etClose, 0.9);
  Check('手前側の構造物', False);
  for E := Low(TElevatorEra) to High(TElevatorEra) do
    for K := Low(TElevatorKind) to High(TElevatorKind) do
    begin
      Preset(esOutside, E, K);
      Track(etDestination, 8);
      DrawFrame(0);
      ShaftUpper := Upper;
      ShaftLower := Lower;
      DrawFrame(203);
      Require((Upper <> ShaftUpper) and (Lower <> ShaftLower), 'the closed car still fills the opening at departure');
      DrawFrame(226);
      Require((Upper <> ShaftUpper) and (Lower = ShaftLower), 'an ascending car leaves through the top');
      DrawFrame(279);
      Require((Upper = ShaftUpper) and (Lower = ShaftLower), 'the shaft stays visible after onward arrival');
      Track(etDestination, 2);
      DrawFrame(226);
      Require((Upper = ShaftUpper) and (Lower <> ShaftLower), 'a descending car leaves through the bottom');
    end;
  Check('手前側の構造物', True);

  Preset(esOutside, eeReiwa, ekGlass);
  Track(etDestination, 8);
  DrawFrame(200);
  BoardingDisplay := Display;
  SavePreview('27-onward-closing');
  DrawFrame(226);
  DepartureFrame := HashBytes;
  SavePreview('28-onward-ascending');
  DrawFrame(248);
  Require(Display <> BoardingDisplay, 'the landing display updates after departure');
  DrawFrame(279);
  DestinationDisplay := Display;
  SavePreview('29-onward-destination');
  DrawFrame(315);
  Require((Display = DestinationDisplay) and (Display <> BoardingDisplay), 'the landing display holds the destination');
  DrawFrame(226);
  Require(HashBytes = DepartureFrame, 'onward travel can be sought independently of earlier frames');
  Track(etDestination, 2);
  DrawFrame(226);
  SavePreview('30-onward-descending');
end;

procedure TestExteriorLandingBackground;
var
  Background: TBackground;
  Landing: string;

  function Landscape: string;
  begin
    // かごが動いても照明や手すりに隠れない範囲で、背後の風景そのものを比較する。
    Result := RegionHash(390, 362, 555, 375);
  end;

begin
  Preset(esOutside, eeReiwa, ekGlass);
  Track(etOwnFloor, 5);
  Check('手前側の構造物', False);
  for Background := bgResidential to bgScenic do
  begin
    Select('背景', Ord(Background));
    Track(etInitialFloor, 8);
    Track(etDestination, 8);
    DrawFrame(0);
    Landing := Landscape;
    DrawFrame(80);
    Require(Landscape = Landing, 'descending approach reveals the fixed landing background');
    DrawFrame(134);
    Require(Landscape = Landing, 'the parked car shows the same landing background');
    DrawFrame(210);
    Require(Landscape = Landing, 'upward departure leaves the background in place');
    DrawFrame(279);
    Require(Landscape = Landing, 'the destination does not replace the landing background');

    Track(etInitialFloor, 2);
    Track(etDestination, 2);
    DrawFrame(80);
    Require(Landscape = Landing, 'ascending approach reveals the same background');
    DrawFrame(210);
    Require(Landscape = Landing, 'downward departure leaves the background in place');
    DrawFrame(279);
    Require(Landscape = Landing, 'arriving below the landing keeps its background');
  end;
  DrawFrame(0);
  Landing := RegionHash(300, 180, 660, 600);
  Track(etOwnFloor, 14);
  DrawFrame(0);
  Require(RegionHash(300, 180, 660, 600) <> Landing, 'the configured landing floor sets the viewpoint');
  Track(etOwnFloor, 5);
  Select('背景', Ord(bgNone));
  DrawFrame(0);
  Require(AlphaAt(480, 350) = 0, 'an empty landing is transparent with no background');
  DrawFrame(134);
  Require(AlphaAt(480, 350) = 0, 'the rear glass stays transparent with no background');
  Check('手前側の構造物', True);

  Select('背景', Ord(bgScenic));
  Track(etInitialFloor, 8);
  Track(etDestination, 8);
  DrawFrame(80);
  SavePreview('31-fixed-background-approach');
  DrawFrame(203);
  SavePreview('32-fixed-background-boarding');
  DrawFrame(210);
  SavePreview('33-fixed-background-departure');
  DrawFrame(279);
  SavePreview('34-fixed-background-away');
end;


procedure TestMotionPatterns;
var
  S: TElevatorSettings;
  T: TElevatorSchedule;
  F: TElevatorFrame;
  A: TElevatorScene;
  Motion: TElevatorMotion;
  Item: PFILTER_ITEM_SELECT;
  Option: POption;
  OpenHash, DefaultHash: string;
begin
  Item := FindItem('動作パターン');
  Require(Item^.Value = Ord(emAutomatic), 'legacy motion is the default');
  Option := POption(Item^.List);
  for Motion := Low(TElevatorMotion) to High(TElevatorMotion) do
  begin
    Require((Option^.Value = Ord(Motion)) and (string(Option^.Name) = string(MOTION_NAMES[Motion])),
      'registered motion option');
    Inc(Option);
  end;
  Require(Option^.Name = nil, 'motion list terminator');

  for A := Low(TElevatorScene) to High(TElevatorScene) do
  begin
    S := PresetSettings(A, eeReiwa, ekStandard);
    S.StartDoor := sdCloseFromOpen;
    S.Values[etArrivalWait] := 0.75;
    S.Values[etClosedWait] := 0.25;

    S.Motion := emArriveAndOpen;
    T := MakeSchedule(S);
    Require(not T.StartsOpen and (T.Direction = 2 * Ord(A <> esOutside) - 1) and
      (T.OnwardDirection = 0) and (T.OpenAt - T.ArriveAt = 0.75), 'arrival-only route and wait');
    F := EvaluateFrame(T, T.ArriveAt);
    Require(F.Arrived and (F.FloorIndex = T.TargetFloor) and (F.OpenAmount = 0),
      'doors stay closed during the arrival wait');
    Require((EvaluateFrame(T, T.OpenAt + 0.1).OpenAmount > 0) and
      (EvaluateFrame(T, T.OpenEnd + 60).OpenAmount = 1), 'arrival opens and holds');

    S.Motion := emCloseAndDepart;
    T := MakeSchedule(S);
    Require((T.StartFloor = T.OwnFloor) and (T.TargetFloor = T.Destination) and
      (T.DepartAt - T.EntryClosedAt = 0.25 * Ord(A <> esOutside)), 'departure route and wait');
    Require(EvaluateFrame(T, 0).OpenAmount = 1, 'departure starts open');
    F := EvaluateFrame(T, (T.PressAt + T.EntryClosedAt) * 0.5);
    Require(SameValue(F.OpenAmount, 0.5, 1E-6) and (F.Direction = 0)
      and (F.ButtonLit = (A <> esOutside)), 'closing precedes travel');
    F := EvaluateFrame(T, T.DepartAt);
    Require((F.OpenAmount = 0) and (F.Direction = 1), 'departure starts fully closed');
    F := EvaluateFrame(T, T.ArriveAt + 60);
    Require(F.Arrived and (F.FloorIndex = T.Destination) and (F.OpenAmount = 0),
      'departure ends with doors closed');

    S.Motion := emTravelOnly;
    T := MakeSchedule(S);
    F := EvaluateFrame(T, T.DepartAt);
    Require((T.DepartAt = T.PressAt) and (F.Direction <> 0) and not F.ButtonLit
      and (F.OpenAmount = 0), 'travel only moves the car');
    Require(EvaluateFloorMotion(T, T.DepartAt + 0.25).Phase = fpLeaving,
      'travel only moves the floor image');
    Require(EvaluateFrame(T, T.ArriveAt + 60).OpenAmount = 0, 'travel only ends closed');

    S.Motion := emDoorsOnly;
    T := MakeSchedule(S);
    F := EvaluateFrame(T, T.OpenEnd);
    Require((T.OpenAt = T.PressAt) and (F.FloorIndex = T.OwnFloor) and (F.Direction = 0)
      and not F.ButtonLit and (F.OpenAmount = 1), 'doors only open on the parked floor');
    Require((EvaluateFloorMotion(T, T.OpenAt).Phase = fpStill) and
      (EvaluateFrame(T, T.CloseEnd).OpenAmount = 0), 'doors only close without movement');

    S.Motion := emArriveAndOpen;
    S.Values[etInitialFloor] := S.Values[etOwnFloor];
    S.Values[etDestination] := S.Values[etOwnFloor];
    S.Values[etOpen] := 0;
    T := MakeSchedule(S);
    F := EvaluateFrame(T, T.OpenAt);
    Require((T.DepartAt = T.ArriveAt) and (F.Direction = 0)
      and (F.OpenAmount = 1), 'same-floor arrival opens instantly with zero opening time');
  end;

  Select('動作パターン', Ord(emArriveAndOpen));
  Preset(esOutside, eeReiwa, ekGlass);
  Require(Item^.Value = Ord(emArriveAndOpen), 'appearance preset preserves the motion');
  Track(etOwnFloor, 3);
  Track(etInitialFloor, 6);
  Track(etDestination, 1);
  Track(etWait, 0.5);
  Track(etTravel, 2);
  Track(etArrivalWait, 0.75);
  Track(etOpen, 1);
  Track(etHold, 1);
  Track(etClose, 1);

  DrawFrame(150);
  OpenHash := HashBytes;
  DrawFrame(300);
  Require(HashBytes = OpenHash, 'arrival hold persists in host video');
  DrawFrame(0);
  Require(HashBytes <> OpenHash, 'arrival is closed before the call');
  DrawFrame(150);
  Require(HashBytes = OpenHash, 'arrival hold reproduces after a backward seek');
  Require((Energy(2.6) > 0.1) and (Energy(3.7) > 0.1) and (Energy(5.7) = 0),
    'arrival chime and opening play without a later close');

  Select('動作パターン', Ord(emCloseAndDepart));
  DrawFrame(0);
  Require(HashBytes = OpenHash, 'outside departure starts parked and open');
  DrawFrame(60);
  Require(HashBytes <> OpenHash, 'outside departure leaves the landing');
  Require((Energy(0.9) > 0.1) and (Energy(1.9) > 0.1) and (Energy(3.6) = 0),
    'departure plays closing and driving with no arrival effect');

  Select('動作パターン', Ord(emTravelOnly));
  Require((Energy(1.2) > 0.1) and (Energy(2.6) = 0) and (Energy(3.7) = 0),
    'travel only plays the driving motor');
  Select('動作パターン', Ord(emDoorsOnly));
  DrawFrame(54);
  Require(HashBytes = OpenHash, 'doors only open on the landing in host video');
  Require((Energy(0.9) > 0.1) and (Energy(1.8) = 0) and (Energy(2.8) > 0.1) and (Energy(3.7) = 0),
    'doors only play the opening and closing effects');

  Select('動作パターン', Ord(emAutomatic));
  DrawFrame(210);
  DefaultHash := HashBytes;
  Select('動作パターン', High(Integer));
  DrawFrame(210);
  Require(HashBytes = DefaultHash, 'invalid motion falls back to the default');
  Select('動作パターン', Ord(emAutomatic));
end;

procedure Run;
var
  Required: TRequired;
  Initialize: TInitialize;
  Uninitialize: TUninitialize;
  GetTable: TGetTable;
begin
  DLL := LoadLibrary(PWideChar(ParamStr(1)));
  Require(DLL <> 0, 'load AUF2');
  try
    @Required := GetProcAddress(DLL, 'RequiredVersion');
    @Initialize := GetProcAddress(DLL, 'InitializePlugin');
    @Uninitialize := GetProcAddress(DLL, 'UninitializePlugin');
    @GetTable := GetProcAddress(DLL, 'GetFilterPluginTable');
    Require(Assigned(Required) and Assigned(Initialize) and Assigned(Uninitialize) and Assigned(GetTable), 'exports');
    Require((Initialize(Required() - 1) = 0) and (Initialize(Required()) = 1), 'version gate');
    Table := GetTable();
    Require((Table <> nil) and (string(Table^.Name) = 'エレベーター演出') and
      (string(Table^.Label_) = 'SYNC'), 'registered name and group');
    Require(Table^.Flag = (FILTER_FLAG_INPUT or FILTER_FLAG_VIDEO or FILTER_FLAG_AUDIO or FILTER_FLAG_USERDATA), 'media flags');
    Scene.Width := 480;
    Scene.Height := 360;
    Scene.Rate := 30;
    Scene.Scale := 1;
    Scene.SampleRate := 48000;
    Obj.ChannelNum := 2;
    Edit.GetObjectItemValue := ReadItem;
    Edit.SetObjectItemValue := StoreItem;
    Video.Scene := @Scene;
    Video.Object_ := @Obj;
    Video.SetImageData := PublishImage;
    Audio.Scene := @Scene;
    Audio.Object_ := @Obj;
    Audio.SetSampleData := PublishSamples;
    Video.UserData := Table^.Func_Create(1);
    Require(Video.UserData <> nil, 'create renderer');
    try
      TestTimeline;
      TestVideo;
      TestFloorTransit;
      TestAudio;
      TestStartDoor;
      TestDoorWaits;
      TestDoorCenter;
      TestCarFrontScenery;
      TestGroundTransition;
      TestNearScenery;
      TestExteriorApproach;
      TestExteriorOnward;
      TestExteriorLandingBackground;
      TestMotionPatterns;
    finally
      Table^.Func_Destroy(1, Video.UserData);
      Uninitialize();
    end;
  finally
    FreeLibrary(DLL);
  end;
end;

begin
  Digest := TStringList.Create;
  try
    try
      Run;
      if ParamCount >= 2 then Digest.SaveToFile(IncludeTrailingPathDelimiter(ParamStr(2)) + 'Frames.sha256');
      WriteLn(Checks, ' checks passed. ', Digest.Count, ' sampled frame hashes.');
    except
      on E: Exception do
      begin
        WriteLn(E.ClassName, ': ', E.Message);
        ExitCode := 1;
      end;
    end;
  finally
    Digest.Free;
  end;
end.

