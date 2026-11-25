unit SYNC_Elevator_FilterPlugin;

// Copyright (c) 2026 VRAMの魔術師
// SPDX-License-Identifier: GPL-3.0-only
// エレベーター演出のメディア登録、映像・音声の出力、描画資源の寿命を管理する。

interface

uses AviUtl2FilterTypes;

const
  ELEVATOR_REQUIRED_VERSION = 2011600;

// DLL 所有の登録テーブルを返す。呼び出し側で解放しない。
function GetElevatorFilterTable: PFILTER_PLUGIN_TABLE;

implementation

uses System.SysUtils, System.Math, System.SyncObjs, Winapi.Windows, PluginFilterTable,
  Elevator_Settings, Elevator_Timeline, Elevator_Renderer, Elevator_Audio, Elevator_Parameters;

type
  TElevatorSession = class
    Renderer: TElevatorRenderer;
    Lock: TCriticalSection;
    constructor Create;
    destructor Destroy; override;
  end;

var
  TableInitialized: Boolean;

constructor TElevatorSession.Create;
begin
  inherited Create;
  Lock := TCriticalSection.Create;
  Renderer := TElevatorRenderer.Create;
end;

destructor TElevatorSession.Destroy;
begin
  Renderer.Free;
  Lock.Free;
  inherited;
end;

function ElevatorVideo(Video: PFILTER_PROC_VIDEO): Byte; cdecl;
var
  S: TElevatorSettings;
  Schedule: TElevatorSchedule;
  Frame: TElevatorFrame;
  Session: TElevatorSession;
  Seconds: Double;
begin
  Result := 0;
  if (Video = nil) or (Video^.Object_ = nil) or (Video^.UserData = nil) or
    not Assigned(Video^.SetImageData) then Exit;
  try
    S := ReadElevatorSettings;
    Schedule := MakeSchedule(S);
    Seconds := Video^.Object_^.Time;
    if (Video^.Scene <> nil) and (Video^.Scene^.Rate > 0) and (Video^.Scene^.Scale > 0) then
      Seconds := Double(Video^.Object_^.Frame) * Video^.Scene^.Scale / Video^.Scene^.Rate;
    if IsNan(Seconds) or IsInfinite(Seconds) then Seconds := 0;
    Seconds := Max(0.0, Seconds);
    Frame := EvaluateFrame(Schedule, Seconds);
    Session := TElevatorSession(Video^.UserData);
    Session.Lock.Acquire;
    try
      Session.Renderer.Render(S, Schedule, Frame, Seconds, Video);
      Result := 1;
    finally
      Session.Lock.Release;
    end;
  except
    on E: Exception do OutputDebugString(PWideChar('SYNC_Elevator video: ' + E.Message));
  end;
end;

function ElevatorAudio(Audio: PFILTER_PROC_AUDIO): Byte; cdecl;
begin
  Result := 0;
  if (Audio = nil) or (Audio^.Object_ = nil) or not Assigned(Audio^.SetSampleData) then Exit;
  try
    Result := Ord(RenderElevatorAudio(Audio, ReadElevatorSettings));
  except
    on E: Exception do OutputDebugString(PWideChar('SYNC_Elevator audio: ' + E.Message));
  end;
end;

function CreateElevator(EffectID: Int64): Pointer; cdecl;
begin
  Result := nil;
  try
    Result := TElevatorSession.Create;
  except
    on E: Exception do OutputDebugString(PWideChar('SYNC_Elevator create: ' + E.Message));
  end;
end;

procedure DestroyElevator(EffectID: Int64; UserData: Pointer); cdecl;
begin
  try
    TElevatorSession(UserData).Free;
  except
    on E: Exception do OutputDebugString(PWideChar('SYNC_Elevator destroy: ' + E.Message));
  end;
end;

function GetElevatorFilterTable: PFILTER_PLUGIN_TABLE;
begin
  if not TableInitialized then
  begin
    SetupPluginTable(FILTER_FLAG_VIDEO or FILTER_FLAG_AUDIO or FILTER_FLAG_INPUT or
      FILTER_FLAG_USERDATA, 'エレベーター演出', 'SYNC', 'エレベーター演出 / SYNC_Elevator v0.1.0',
      ElevatorVideo, ElevatorAudio);
    RegisterElevatorParameters;
    GetPluginTable^.Func_Create := CreateElevator;
    GetPluginTable^.Func_Destroy := DestroyElevator;
    TableInitialized := True;
  end;
  Result := GetPluginTable;
end;

end.

