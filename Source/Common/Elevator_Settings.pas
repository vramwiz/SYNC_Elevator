unit Elevator_Settings;

// Copyright (c) 2026 VRAMの魔術師
// SPDX-License-Identifier: GPL-3.0-only
// 設定値の範囲、プリセットの構成、年代・種類ごとの配色を定義する。

interface

type
  TElevatorScene = (esOutside, esInside, esCarFront);
  TElevatorMotion = (emAutomatic, emArriveAndOpen, emCloseAndDepart, emTravelOnly, emDoorsOnly);
  TElevatorEra = (eeMeiji, eeEarlyShowa, eeMidShowa, eeLateShowa,
    eeHeisei, eeReiwa, eeFuture);
  TElevatorKind = (ekStandard, ekGlass, ekFreight, ekConstruction, ekMine);
  TDoorStyle = (dsCenter, dsSingle, dsMulti, dsLattice, dsGlass, dsFreight);
  TStartDoor = (sdClosed, sdCloseFromOpen);
  TDoorWindowMode = (wmByEra, wmOn, wmOff);
  TIndicatorStyle = (isNeedle, isLamps, isSegment, isDots, isLCD, isFuture);
  TPanelStyle = (psMechanical, psMetal, psTouch);
  TBackground = (bgNone, bgResidential, bgOffice, bgMall, bgScenic);
  TElevatorTrack = (etMinFloor, etMaxFloor, etOwnFloor, etInitialFloor,
    etDestination, etWait, etTravel, etOpen, etHold, etClose, etVolume, etWindowTransparency,
    etClosedWait, etArrivalWait);
  TElevatorColors = array[0..3] of Cardinal;

  TTrackDefinition = record
    Name: PWideChar;
    Initial, Minimum, Maximum, Step: Double;
  end;

  TElevatorSettings = record
    Scene: TElevatorScene;
    Motion: TElevatorMotion;
    Era: TElevatorEra;
    Kind: TElevatorKind;
    Door: TDoorStyle;
    StartDoor: TStartDoor;
    WindowMode: TDoorWindowMode;
    Indicator: TIndicatorStyle;
    Panel: TPanelStyle;
    Background: TBackground;
    RearLayer, FrontLayer, DisplayVisible, PanelVisible, Sound, UseFloorImage: Boolean;
    Values: array[TElevatorTrack] of Double;
    Colors: TElevatorColors; // $RRGGBB
  end;

const
  SCENE_NAMES: array[TElevatorScene] of PWideChar = ('外', '中', '中（かご正面）');
  MOTION_NAMES: array[TElevatorMotion] of PWideChar = ('従来どおり', '到着して開く',
    '閉じて出発', '移動のみ', '開閉のみ');
  ERA_NAMES: array[TElevatorEra] of PWideChar = ('明治・大正風', '昭和初期風',
    '昭和中期風', '昭和後期風', '平成風', '令和風', '近未来風');
  KIND_NAMES: array[TElevatorKind] of PWideChar = ('標準', '展望・ガラス張り',
    '貨物用', '工事用カゴ式', '鉱山用カゴ式');
  DOOR_NAMES: array[TDoorStyle] of PWideChar = ('中央開き', '片開き', '多枚扉',
    '蛇腹格子扉', 'ガラス扉', '貨物用扉');
  START_DOOR_NAMES: array[TStartDoor] of PWideChar = ('閉じた状態', '全開から閉める');
  WINDOW_MODE_NAMES: array[TDoorWindowMode] of PWideChar = ('年代に合わせる', 'あり', 'なし');
  INDICATOR_NAMES: array[TIndicatorStyle] of PWideChar = ('針式', '階数別ランプ式',
    '7セグメント式', 'ドットマトリクス式', '液晶風', '近未来風');
  PANEL_NAMES: array[TPanelStyle] of PWideChar = ('機械式', '金属押しボタン', 'タッチパネル風');
  BACKGROUND_NAMES: array[TBackground] of PWideChar = ('背景なし', '住宅街',
    'オフィスビル', 'ショッピングモール', '展望・観光施設');
  ELEVATOR_TRACKS: array[TElevatorTrack] of TTrackDefinition = (
    (Name: '建物の最低階'; Initial: 1; Minimum: -99; Maximum: 99; Step: 1),
    (Name: '建物の最高階'; Initial: 8; Minimum: -99; Maximum: 99; Step: 1),
    (Name: '自分の階'; Initial: 1; Minimum: -99; Maximum: 99; Step: 1),
    (Name: 'エレベーターの初期階'; Initial: 5; Minimum: -99; Maximum: 99; Step: 1),
    (Name: '目的階'; Initial: 6; Minimum: -99; Maximum: 99; Step: 1),
    (Name: '開始待機時間'; Initial: 0.5; Minimum: 0; Maximum: 600; Step: 0.01),
    (Name: '時間'; Initial: 2.5; Minimum: 0; Maximum: 600; Step: 0.01),
    (Name: '扉開時間'; Initial: 0.85; Minimum: 0; Maximum: 600; Step: 0.01),
    (Name: '開放時間'; Initial: 2; Minimum: 0; Maximum: 600; Step: 0.01),
    (Name: '扉閉時間'; Initial: 0.9; Minimum: 0; Maximum: 600; Step: 0.01),
    (Name: '音量'; Initial: 50; Minimum: 0; Maximum: 100; Step: 0.01),
    (Name: '縦窓の透明度'; Initial: 50; Minimum: 0; Maximum: 100; Step: 0.01),
    (Name: '閉扉後待機時間'; Initial: 0; Minimum: 0; Maximum: 600; Step: 0.01),
    (Name: '到着後待機時間'; Initial: 0; Minimum: 0; Maximum: 600; Step: 0.01));

function PresetSettings(Scene: TElevatorScene; Era: TElevatorEra;
  Kind: TElevatorKind): TElevatorSettings;
function TrackValue(Track: TElevatorTrack; Value: Double): Double;
function SeeThroughDoor(Door: TDoorStyle): Boolean;
function HasDoorWindow(const S: TElevatorSettings): Boolean;

implementation

uses System.Math;

const
  ERA_COLORS: array[TElevatorEra] of TElevatorColors = (
    ($735037, $AD8252, $332520, $FFDC94),
    ($4F484B, $A88552, $443638, $FFD491),
    ($6B8583, $BBC4B8, $495957, $FFC06E),
    ($9DA2AA, $6B7781, $45494F, $F59064),
    ($A5AEB7, $4C5D70, $3B4A53, $F18F4D),
    ($ABB6BF, $455661, $425461, $79DBFC),
    ($344758, $233D52, $1D3142, $56FFE3));
  ERA_DOORS: array[TElevatorEra] of TDoorStyle = (
    dsLattice, dsSingle, dsMulti, dsCenter, dsCenter, dsCenter, dsMulti);
  ERA_INDICATORS: array[TElevatorEra] of TIndicatorStyle = (
    isNeedle, isNeedle, isLamps, isSegment, isDots, isLCD, isFuture);
  ERA_PANELS: array[TElevatorEra] of TPanelStyle = (
    psMechanical, psMechanical, psMechanical, psMetal, psMetal, psTouch, psTouch);

function TrackValue(Track: TElevatorTrack; Value: Double): Double;
begin
  if IsNan(Value) then Exit(ELEVATOR_TRACKS[Track].Initial);
  Result := EnsureRange(Value, ELEVATOR_TRACKS[Track].Minimum, ELEVATOR_TRACKS[Track].Maximum);
  if Track <= etDestination then Result := Round(Result);
end;

function SeeThroughDoor(Door: TDoorStyle): Boolean;
begin
  Result := Door in [dsLattice, dsGlass];
end;

function HasDoorWindow(const S: TElevatorSettings): Boolean;
begin
  Result := (S.Door in [dsCenter, dsSingle, dsMulti]) and
    ((S.WindowMode = wmOn) or ((S.WindowMode = wmByEra) and
      (S.Era in [eeEarlyShowa, eeMidShowa, eeLateShowa])));
end;

function PresetSettings(Scene: TElevatorScene; Era: TElevatorEra;
  Kind: TElevatorKind): TElevatorSettings;
var
  Track: TElevatorTrack;
begin
  Result := Default(TElevatorSettings);
  Result.Scene := Scene;
  Result.Era := Era;
  Result.Kind := Kind;
  Result.Door := ERA_DOORS[Era];
  Result.StartDoor := sdClosed;
  Result.Indicator := ERA_INDICATORS[Era];
  Result.Panel := ERA_PANELS[Era];
  Result.Colors := ERA_COLORS[Era];
  Result.RearLayer := True;
  Result.FrontLayer := True;
  Result.DisplayVisible := True;
  Result.PanelVisible := True;
  Result.Sound := True;
  Result.UseFloorImage := True;
  for Track := Low(TElevatorTrack) to High(TElevatorTrack) do
    Result.Values[Track] := ELEVATOR_TRACKS[Track].Initial;

  case Kind of
    ekGlass:
      begin
        Result.Door := dsGlass;
        Result.Background := bgScenic;
      end;
    ekFreight:
      begin
        Result.Door := dsFreight;
        Result.Panel := psMetal;
        Result.Colors[0] := $737D81;
        Result.Colors[2] := $38434A;
      end;
    ekConstruction:
      begin
        Result.Door := dsLattice;
        Result.Panel := psMechanical;
        Result.Background := bgOffice;
        Result.Colors[0] := $DFA43F;
        Result.Colors[1] := $30363A;
      end;
    ekMine:
      begin
        Result.Door := dsLattice;
        Result.Panel := psMechanical;
        Result.Colors[0] := $926649;
        Result.Colors[1] := $372B27;
        Result.Colors[2] := $3E3631;
      end;
  end;
end;

end.

