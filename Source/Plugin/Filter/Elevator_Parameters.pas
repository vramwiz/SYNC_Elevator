unit Elevator_Parameters;

// Copyright (c) 2026 VRAMの魔術師
// SPDX-License-Identifier: GPL-3.0-only
// ホスト設定の登録と、ボタンを押した対象オブジェクトへのプリセット反映を担当する。

interface

uses Elevator_Settings;

// 項目本体と選択肢を DLL の有効期間中保持する。
procedure RegisterElevatorParameters;
// 当該コールバック用に更新された項目を値として読み取る。
function ReadElevatorSettings: TElevatorSettings;

implementation

uses System.SysUtils, System.Math, Winapi.Windows, AviUtl2FilterTypes, PluginFilterTable;

const
  GROUP_NAMES: array[0..8] of PWideChar = ('プリセット設定', '描画レイヤー設定',
    '階数設定', '時間設定', '扉・構造設定', '階数表示・操作パネル設定',
    '色設定', '背景設定', '効果音設定');
  COLOR_NAMES: array[0..3] of PWideChar = ('色1', '色2', '色3', '色4');

var
  PresetScene, PresetEra, PresetKind, SceneItem, EraItem, KindItem: TFILTER_ITEM_SELECT;
  DoorItem, DoorWindowItem, IndicatorItem, PanelItem, BackgroundItem: TFILTER_ITEM_SELECT;
  StartDoorItem: TFILTER_ITEM_SELECT;
  HideStartDoor, HideClosedWait, HideFrontCabControls: TFILTER_ITEM_HIDE_RULE;
  SceneOptions: array[0..Ord(High(TElevatorScene)) + 1] of TFILTER_ITEM_SELECT_ITEM;
  EraOptions: array[0..Ord(High(TElevatorEra)) + 1] of TFILTER_ITEM_SELECT_ITEM;
  KindOptions: array[0..Ord(High(TElevatorKind)) + 1] of TFILTER_ITEM_SELECT_ITEM;
  DoorOptions: array[0..Ord(High(TDoorStyle)) + 1] of TFILTER_ITEM_SELECT_ITEM;
  StartDoorOptions: array[0..Ord(High(TStartDoor)) + 1] of TFILTER_ITEM_SELECT_ITEM;
  DoorWindowOptions: array[0..Ord(High(TDoorWindowMode)) + 1] of TFILTER_ITEM_SELECT_ITEM;
  IndicatorOptions: array[0..Ord(High(TIndicatorStyle)) + 1] of TFILTER_ITEM_SELECT_ITEM;
  PanelOptions: array[0..Ord(High(TPanelStyle)) + 1] of TFILTER_ITEM_SELECT_ITEM;
  BackgroundOptions: array[0..Ord(High(TBackground)) + 1] of TFILTER_ITEM_SELECT_ITEM;
  ApplyButton: TFILTER_ITEM_BUTTON;
  RearLayer, FrontLayer, DisplayVisible, PanelVisible, Sound: TFILTER_ITEM_CHECK;
  FloorImage: TFILTER_ITEM_CHECK;
  Tracks: array[TElevatorTrack] of TFILTER_ITEM_TRACK;
  Colors: array[0..3] of TFILTER_ITEM_COLOR;
  Groups, GroupEnds: array[Low(GROUP_NAMES)..High(GROUP_NAMES)] of TFILTER_ITEM_GROUP;

procedure FillOptions(const Names: array of PWideChar; var Options: array of TFILTER_ITEM_SELECT_ITEM);
var
  I: Integer;
begin
  for I := Low(Names) to High(Names) do
  begin
    Options[I].Name := Names[I];
    Options[I].Value := I;
  end;
  Options[High(Options)] := Default(TFILTER_ITEM_SELECT_ITEM);
end;

procedure ApplyPreset(Edit: PEDIT_SECTION; Obj: OBJECT_HANDLE; Effect, Item: PWideChar); cdecl;
var
  S: TElevatorSettings;
  EffectName: string;
  I: Integer;
  function Selection(const Selector: TFILTER_ITEM_SELECT; const Names: array of PWideChar): Integer;
  var
    Saved: PAnsiChar;
    Value: string;
    Index: Integer;
  begin
    Result := EnsureRange(Selector.Value, Low(Names), High(Names));
    if not Assigned(Edit^.GetObjectItemValue) then Exit;
    Saved := Edit^.GetObjectItemValue(Obj, PWideChar(EffectName), Selector.Name);
    if Saved = nil then Exit;
    Value := string(UTF8String(Saved));
    for Index := Low(Names) to High(Names) do
      if Value = string(Names[Index]) then Exit(Index);
  end;
  procedure SetValue(Name: PWideChar; const Value: string);
  var
    Encoded: UTF8String;
  begin
    Encoded := UTF8String(Value);
    if not Edit^.SetObjectItemValue(Obj, PWideChar(EffectName), Name, PAnsiChar(Encoded)) then
      OutputDebugString(PWideChar('SYNC_Elevator preset: ' + string(Name)));
  end;
begin
  if (Edit = nil) or (Obj = nil) or (Effect = nil) or not Assigned(Edit^.SetObjectItemValue) then Exit;
  try
    EffectName := Effect;
    S := PresetSettings(TElevatorScene(Selection(PresetScene, SCENE_NAMES)),
      TElevatorEra(Selection(PresetEra, ERA_NAMES)), TElevatorKind(Selection(PresetKind, KIND_NAMES)));
    // オブジェクトの複製後も、階数、秒数、レイヤー、音声の設定を引き継げる。
    SetValue(SceneItem.Name, SCENE_NAMES[S.Scene]);
    SetValue(EraItem.Name, ERA_NAMES[S.Era]);
    SetValue(KindItem.Name, KIND_NAMES[S.Kind]);
    SetValue(DoorItem.Name, DOOR_NAMES[S.Door]);
    SetValue(IndicatorItem.Name, INDICATOR_NAMES[S.Indicator]);
    SetValue(PanelItem.Name, PANEL_NAMES[S.Panel]);
    SetValue(BackgroundItem.Name, BACKGROUND_NAMES[S.Background]);
    for I := Low(Colors) to High(Colors) do
      SetValue(Colors[I].Name, IntToHex(S.Colors[I], 6));
  except
    on E: Exception do OutputDebugString(PWideChar('SYNC_Elevator preset: ' + E.Message));
  end;
end;

procedure RegisterElevatorParameters;
var
  S: TElevatorSettings;
  I: Integer;
  Color: Cardinal;
  procedure BeginGroup(Index: Integer);
  begin
    AddGroup(Groups[Index], GROUP_NAMES[Index], Ord(Index = 0));
  end;
  procedure EndGroup(Index: Integer);
  begin
    AddGroup(GroupEnds[Index], '', 0);
  end;
  procedure AddTracks(First, Last: TElevatorTrack);
  var
    Track: TElevatorTrack;
    Def: TTrackDefinition;
  begin
    for Track := First to Last do
    begin
      Def := ELEVATOR_TRACKS[Track];
      AddTrack(Tracks[Track], Def.Name, Def.Initial, Def.Minimum, Def.Maximum, Def.Step);
    end;
  end;
begin
  S := PresetSettings(esOutside, eeReiwa, ekStandard);
  FillOptions(SCENE_NAMES, SceneOptions);
  FillOptions(ERA_NAMES, EraOptions);
  FillOptions(KIND_NAMES, KindOptions);
  FillOptions(DOOR_NAMES, DoorOptions);
  FillOptions(START_DOOR_NAMES, StartDoorOptions);
  FillOptions(WINDOW_MODE_NAMES, DoorWindowOptions);
  FillOptions(INDICATOR_NAMES, IndicatorOptions);
  FillOptions(PANEL_NAMES, PanelOptions);
  FillOptions(BACKGROUND_NAMES, BackgroundOptions);
  BeginGroup(0);
  AddSelect(PresetScene, 'プリセット場面', Ord(S.Scene), @SceneOptions[0]);
  AddSelect(PresetEra, 'プリセット年代', Ord(S.Era), @EraOptions[0]);
  AddSelect(PresetKind, 'プリセット種類', Ord(S.Kind), @KindOptions[0]);
  AddButton(ApplyButton, '設定を反映', ApplyPreset);
  EndGroup(0);

  BeginGroup(1);
  AddCheck(RearLayer, '奥側の構造物', Ord(S.RearLayer));
  AddCheck(FrontLayer, '手前側の構造物', Ord(S.FrontLayer));
  EndGroup(1);

  BeginGroup(2);
  AddTracks(etMinFloor, etDestination);
  EndGroup(2);

  BeginGroup(3);
  AddTracks(etWait, etWait);
  AddTracks(etClosedWait, etClosedWait);
  AddTracks(etTravel, etTravel);
  AddTracks(etArrivalWait, etArrivalWait);
  AddTracks(etOpen, etClose);
  EndGroup(3);

  BeginGroup(4);
  AddSelect(SceneItem, '場面', Ord(S.Scene), @SceneOptions[0]);
  AddSelect(EraItem, '年代', Ord(S.Era), @EraOptions[0]);
  AddSelect(KindItem, '種類', Ord(S.Kind), @KindOptions[0]);
  AddSelect(DoorItem, '扉の構造', Ord(S.Door), @DoorOptions[0]);
  AddSelect(StartDoorItem, '開始時の扉', Ord(S.StartDoor), @StartDoorOptions[0]);
  AddHideRule(HideStartDoor, StartDoorItem.Name, SceneItem.Name, HIDE_RULE_EQUAL, Ord(esOutside));
  AddSelect(DoorWindowItem, '扉の縦窓', Ord(S.WindowMode), @DoorWindowOptions[0]);
  AddTracks(etWindowTransparency, etWindowTransparency);
  EndGroup(4);

  BeginGroup(5);
  AddCheck(DisplayVisible, '階数・方向表示', Ord(S.DisplayVisible));
  AddSelect(IndicatorItem, '階数表示方式', Ord(S.Indicator), @IndicatorOptions[0]);
  AddCheck(PanelVisible, '操作パネル表示', Ord(S.PanelVisible));
  AddSelect(PanelItem, '操作パネル方式', Ord(S.Panel), @PanelOptions[0]);
  EndGroup(5);

  BeginGroup(6);
  for I := Low(Colors) to High(Colors) do
  begin
    Color := S.Colors[I];
    AddColor(Colors[I], COLOR_NAMES[I], Byte(Color and 255),
      Byte((Color shr 8) and 255), Byte((Color shr 16) and 255));
  end;
  EndGroup(6);

  BeginGroup(7);
  AddSelect(BackgroundItem, '背景', Ord(S.Background), @BackgroundOptions[0]);
  AddCheck(FloorImage, '奥のフロア画像を使う', Ord(S.UseFloorImage));
  EndGroup(7);

  BeginGroup(8);
  AddCheck(Sound, '音声出力', Ord(S.Sound));
  AddTracks(etVolume, etVolume);
  EndGroup(8);
  AddHideRule(HideClosedWait, Tracks[etClosedWait].Name, SceneItem.Name, HIDE_RULE_EQUAL, Ord(esOutside));
  AddHideRule(HideFrontCabControls, GROUP_NAMES[5], SceneItem.Name, HIDE_RULE_EQUAL, Ord(esCarFront));
end;

function ReadElevatorSettings: TElevatorSettings;
var
  I: Integer;
  Track: TElevatorTrack;
begin
  Result := Default(TElevatorSettings);
  Result.Scene := TElevatorScene(EnsureRange(SceneItem.Value, 0, Ord(High(TElevatorScene))));
  Result.Era := TElevatorEra(EnsureRange(EraItem.Value, 0, Ord(High(TElevatorEra))));
  Result.Kind := TElevatorKind(EnsureRange(KindItem.Value, 0, Ord(High(TElevatorKind))));
  Result.Door := TDoorStyle(EnsureRange(DoorItem.Value, 0, Ord(High(TDoorStyle))));
  Result.StartDoor := TStartDoor(EnsureRange(StartDoorItem.Value, 0, Ord(High(TStartDoor))));
  Result.WindowMode := TDoorWindowMode(EnsureRange(DoorWindowItem.Value, 0, Ord(High(TDoorWindowMode))));
  Result.Indicator := TIndicatorStyle(EnsureRange(IndicatorItem.Value, 0, Ord(High(TIndicatorStyle))));
  Result.Panel := TPanelStyle(EnsureRange(PanelItem.Value, 0, Ord(High(TPanelStyle))));
  Result.Background := TBackground(EnsureRange(BackgroundItem.Value, 0, Ord(High(TBackground))));
  Result.RearLayer := RearLayer.Value <> 0;
  Result.FrontLayer := FrontLayer.Value <> 0;
  Result.DisplayVisible := DisplayVisible.Value <> 0;
  Result.PanelVisible := PanelVisible.Value <> 0;
  Result.Sound := Sound.Value <> 0;
  Result.UseFloorImage := FloorImage.Value <> 0;
  for I := Low(Colors) to High(Colors) do
    Result.Colors[I] := (Cardinal(Colors[I].R) shl 16) or (Cardinal(Colors[I].G) shl 8) or Colors[I].B;
  for Track := Low(TElevatorTrack) to High(TElevatorTrack) do
    Result.Values[Track] := TrackValue(Track, Tracks[Track].Value);
end;

end.

