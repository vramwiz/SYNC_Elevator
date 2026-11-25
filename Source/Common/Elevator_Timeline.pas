unit Elevator_Timeline;

// Copyright (c) 2026 VRAMの魔術師
// SPDX-License-Identifier: GPL-3.0-only
// 0階を含まない階数と、オブジェクトの経過秒から決まる動作時刻を管理する。

interface

uses Elevator_Settings;

type
  TElevatorSchedule = record
    FirstFloor, LastFloor, OwnFloor, Destination: Integer; // 連続階インデックス
    StartFloor, TargetFloor, Direction, CallDirection: Integer;
    StartsOpen: Boolean;
    // オブジェクト内の秒。戸が閉じた時刻と発進、到着と開扉を独立させる。
    PressAt, EntryClosedAt, DepartAt, ArriveAt, OpenAt, OpenEnd, CloseAt, EndAt: Double;
  end;

  TElevatorFrame = record
    FloorIndex, Direction: Integer;
    FloorPosition: Double;
    OpenAmount: Single;
    ButtonLit, Arrived: Boolean;
  end;

  TFloorPhase = (fpStill, fpLeaving, fpTravel, fpArriving);
  TFloorMotion = record
    Phase: TFloorPhase;
    Offset: Single; // 窓の高さを1とした、上下の移動量
  end;

function MakeSchedule(const S: TElevatorSettings): TElevatorSchedule;
function EvaluateFrame(const S: TElevatorSchedule; Seconds: Double): TElevatorFrame;
function EvaluateFloorMotion(const S: TElevatorSchedule; Seconds: Double): TFloorMotion;
function FloorLabel(Index: Integer): string;
// 始階、終階、現在階、目的階を優先し、残りを範囲内に分散して昇順で返す。
function FloorButtons(const S: TElevatorSchedule; Capacity: Integer): TArray<Integer>;
function Ease(Value: Double): Double;

implementation

uses System.Math, System.SysUtils;

function ToIndex(Floor: Integer): Integer;
begin
  if Floor < 0 then Result := Floor
  else Result := Max(0, Floor - 1);
end;

function MakeSchedule(const S: TElevatorSettings): TElevatorSchedule;
var
  Lower, Upper: Integer;
begin
  Lower := ToIndex(Round(S.Values[etMinFloor]));
  Upper := ToIndex(Round(S.Values[etMaxFloor]));
  Result.FirstFloor := Min(Lower, Upper);
  Result.LastFloor := Max(Lower, Upper);
  Result.OwnFloor := EnsureRange(ToIndex(Round(S.Values[etOwnFloor])), Result.FirstFloor, Result.LastFloor);
  Result.Destination := EnsureRange(ToIndex(Round(S.Values[etDestination])), Result.FirstFloor, Result.LastFloor);
  if S.Scene <> esOutside then
  begin
    Result.StartFloor := Result.OwnFloor;
    Result.TargetFloor := Result.Destination;
  end
  else
  begin
    Result.StartFloor := EnsureRange(ToIndex(Round(S.Values[etInitialFloor])), Result.FirstFloor, Result.LastFloor);
    Result.TargetFloor := Result.OwnFloor;
  end;

  Result.Direction := Sign(Result.TargetFloor - Result.StartFloor);
  Result.CallDirection := Sign(Result.Destination - Result.OwnFloor);
  if Result.CallDirection = 0 then Result.CallDirection := 1;
  Result.StartsOpen := (S.Scene <> esOutside) and (S.StartDoor = sdCloseFromOpen);
  Result.PressAt := S.Values[etWait];
  Result.EntryClosedAt := Result.PressAt;
  if Result.StartsOpen then Result.EntryClosedAt := Result.PressAt + S.Values[etClose];
  Result.DepartAt := Result.EntryClosedAt;
  if S.Scene <> esOutside then Result.DepartAt := Result.EntryClosedAt + S.Values[etClosedWait];
  Result.ArriveAt := Result.DepartAt;
  if Result.Direction <> 0 then
    Result.ArriveAt := Result.DepartAt + S.Values[etTravel];
  Result.OpenAt := Result.ArriveAt + S.Values[etArrivalWait];
  Result.OpenEnd := Result.OpenAt + S.Values[etOpen];
  Result.CloseAt := Result.OpenEnd + S.Values[etHold];
  Result.EndAt := Result.CloseAt + S.Values[etClose];
end;

function Ease(Value: Double): Double;
begin
  Value := EnsureRange(Value, 0.0, 1.0);
  Result := Value * Value * (3 - 2 * Value);
end;

function EvaluateFrame(const S: TElevatorSchedule; Seconds: Double): TElevatorFrame;
var
  Progress, Travelled: Double;
  Steps: Integer;
begin
  Result := Default(TElevatorFrame);
  Result.FloorIndex := S.StartFloor;
  Result.FloorPosition := S.StartFloor;
  if Seconds < S.PressAt then
  begin
    if S.StartsOpen then Result.OpenAmount := 1;
    Exit;
  end;
  Result.ButtonLit := Seconds < Max(S.ArriveAt, S.PressAt + 0.12);
  if Seconds < S.EntryClosedAt then
  begin
    Result.OpenAmount := 1 - Ease((Seconds - S.PressAt) / (S.EntryClosedAt - S.PressAt));
    Exit;
  end;
  if Seconds < S.DepartAt then Exit;
  Result.Arrived := Seconds >= S.ArriveAt;
  if not Result.Arrived then
  begin
    Progress := Ease((Seconds - S.DepartAt) / (S.ArriveAt - S.DepartAt));
    Steps := Abs(S.TargetFloor - S.StartFloor);
    Travelled := Steps * Progress;
    Result.FloorPosition := S.StartFloor + S.Direction * Travelled;
    Result.FloorIndex := S.StartFloor + S.Direction * Min(Steps - 1, Trunc(Travelled));
    Result.Direction := S.Direction;
    Exit;
  end;

  Result.FloorIndex := S.TargetFloor;
  Result.FloorPosition := S.TargetFloor;
  if Seconds < S.OpenAt then Exit;
  if Seconds < S.OpenEnd then
    Result.OpenAmount := Ease((Seconds - S.OpenAt) / (S.OpenEnd - S.OpenAt))
  else if Seconds < S.CloseAt then
    Result.OpenAmount := 1
  else if Seconds < S.EndAt then
    Result.OpenAmount := 1 - Ease((Seconds - S.CloseAt) / (S.EndAt - S.CloseAt));
end;

function EvaluateFloorMotion(const S: TElevatorSchedule; Seconds: Double): TFloorMotion;
var
  Transition, Elapsed, UntilArrival: Double;
begin
  Result := Default(TFloorMotion);
  if (S.Direction = 0) or (Seconds < S.DepartAt) or (Seconds >= S.ArriveAt) then Exit;
  Transition := Min(0.5, (S.ArriveAt - S.DepartAt) * 0.35);
  Elapsed := Seconds - S.DepartAt;
  UntilArrival := S.ArriveAt - Seconds;
  if Elapsed < Transition then
  begin
    Result.Phase := fpLeaving;
    Result.Offset := S.Direction * Ease(Elapsed / Transition);
  end
  else if UntilArrival < Transition then
  begin
    Result.Phase := fpArriving;
    Result.Offset := -S.Direction * Ease(UntilArrival / Transition);
  end
  else Result.Phase := fpTravel;
end;

function FloorLabel(Index: Integer): string;
begin
  if Index < 0 then Result := 'B' + IntToStr(-Index)
  else Result := IntToStr(Index + 1) + 'F';
end;

function FloorButtons(const S: TElevatorSchedule; Capacity: Integer): TArray<Integer>;
var
  Included: array[-99..98] of Boolean;
  Index, Count, Span, Limit: Integer;
  procedure Add(Floor: Integer);
  begin
    if (Count >= Limit) or Included[Floor] then Exit;
    Included[Floor] := True;
    Inc(Count);
  end;
begin
  Span := S.LastFloor - S.FirstFloor;
  Limit := EnsureRange(Capacity, 1, Span + 1);
  FillChar(Included, SizeOf(Included), 0);
  Count := 0;
  Add(S.OwnFloor);
  Add(S.Destination);
  Add(S.FirstFloor);
  Add(S.LastFloor);
  for Index := 1 to Limit - 2 do
    Add(S.FirstFloor + Round(Span * Index / (Limit - 1)));
  for Index := S.FirstFloor to S.LastFloor do
    Add(Index);

  SetLength(Result, Count);
  Count := 0;
  for Index := S.FirstFloor to S.LastFloor do
    if Included[Index] then
    begin
      Result[Count] := Index;
      Inc(Count);
    end;
end;

end.

