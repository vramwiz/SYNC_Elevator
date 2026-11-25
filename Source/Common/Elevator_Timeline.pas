unit Elevator_Timeline;

// Copyright (c) 2026 VRAMの魔術師
// SPDX-License-Identifier: GPL-3.0-only
// 階数を0階のない連続インデックスへ変換し、映像と効果音で共用する動作時刻を求める。

interface

uses Elevator_Settings;

type
  TElevatorSchedule = record
    FirstFloor, LastFloor, OwnFloor, Destination: Integer; // 連続階インデックス
    // 外側の TargetFloor は最初に到着する乗り場を指す。目的階への移動は閉扉後に始まる。
    StartFloor, TargetFloor, Direction, CallDirection, OnwardDirection: Integer;
    StartsOpen: Boolean;
    // オブジェクト先頭からの秒。外側の DestinationAt は閉扉後の移動が終わる時刻。
    // 移動区間が無い場合は CloseEnd と同じ値を使い、効果音の長さを0秒にする。
    PressAt, EntryClosedAt, DepartAt, ArriveAt, OpenAt, OpenEnd, CloseAt, CloseEnd, DestinationAt: Double;
  end;

  TElevatorFrame = record
    FloorIndex, Direction: Integer;
    FloorPosition: Double; // 階と階の間を表せる連続階位置。計器表示には FloorIndex を使う。
    OpenAmount: Single;   // 扉の開き具合。0 が全閉、1 が全開。
    ButtonLit, Arrived: Boolean;
  end;

  TFloorPhase = (fpStill, fpLeaving, fpTravel, fpArriving);
  TFloorMotion = record
    Phase: TFloorPhase;
    Offset: Single; // 窓の高さを1とした、上下の移動量
  end;

// 設定の階数を建物の範囲に収め、場面に合わせた映像・音声用の時刻を返す。
function MakeSchedule(const S: TElevatorSettings): TElevatorSchedule;
// オブジェクト内の経過秒から座標と表示状態を求める。シーク時も同じ時刻なら同じ状態を返す。
function EvaluateFrame(const S: TElevatorSchedule; Seconds: Double): TElevatorFrame;
// 内側の窓に合成するフロア画像の切り替え区間と、窓の高さを1とした移動量を返す。
function EvaluateFloorMotion(const S: TElevatorSchedule; Seconds: Double): TFloorMotion;
// 連続階インデックスを階数表示用の B1、1F などに変換する。
function FloorLabel(Index: Integer): string;
// 始階、終階、現在階、目的階を優先し、残りを範囲内に分散して昇順で返す。
function FloorButtons(const S: TElevatorSchedule; Capacity: Integer): TArray<Integer>;
// 0〜1 の進行率に上下限を適用し、両端で速度が0になる補間率を返す。
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
  Result.CloseEnd := Result.CloseAt + S.Values[etClose];
  Result.OnwardDirection := 0;
  Result.DestinationAt := Result.CloseEnd;
  if S.Scene = esOutside then
  begin
    // 呼び寄せと閉扉後の移動に同じ「時間」を使い、タイムラインの長さで必要な区間を選べるようにする。
    Result.OnwardDirection := Sign(Result.Destination - Result.OwnFloor);
    if Result.OnwardDirection <> 0 then
      Result.DestinationAt := Result.CloseEnd + S.Values[etTravel];
  end;
end;

function Ease(Value: Double): Double;
begin
  Value := EnsureRange(Value, 0.0, 1.0);
  Result := Value * Value * (3 - 2 * Value);
end;

function EvaluateFrame(const S: TElevatorSchedule; Seconds: Double): TElevatorFrame;
  procedure MoveBetween(StartAt, FinishAt: Double; FromFloor, ToFloor, MotionDirection: Integer);
  var
    Steps: Integer;
    Travelled: Double;
  begin
    Steps := Abs(ToFloor - FromFloor);
    Travelled := Steps * Ease((Seconds - StartAt) / (FinishAt - StartAt));
    Result.FloorPosition := FromFloor + MotionDirection * Travelled;
    // 終点の階数は到着時刻から表示する。丸め誤差で表示が先行するのを防ぐ。
    Result.FloorIndex := FromFloor + MotionDirection * Min(Steps - 1, Trunc(Travelled));
    Result.Direction := MotionDirection;
  end;
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
  if Seconds < S.ArriveAt then
  begin
    MoveBetween(S.DepartAt, S.ArriveAt, S.StartFloor, S.TargetFloor, S.Direction);
    Exit;
  end;

  if (S.OnwardDirection <> 0) and (Seconds >= S.CloseEnd) then
  begin
    // 外側のカメラは乗り場に残る。閉扉後はかごと階数表示を進め、乗り場の戸は全閉を保つ。
    Result.ButtonLit := False;
    if Seconds < S.DestinationAt then
      MoveBetween(S.CloseEnd, S.DestinationAt, S.OwnFloor, S.Destination, S.OnwardDirection)
    else
    begin
      Result.FloorIndex := S.Destination;
      Result.FloorPosition := S.Destination;
      Result.Arrived := True;
    end;
    Exit;
  end;

  Result.Arrived := True;
  Result.FloorIndex := S.TargetFloor;
  Result.FloorPosition := S.TargetFloor;
  if Seconds < S.OpenAt then Exit;
  if Seconds < S.OpenEnd then
    Result.OpenAmount := Ease((Seconds - S.OpenAt) / (S.OpenEnd - S.OpenAt))
  else if Seconds < S.CloseAt then
    Result.OpenAmount := 1
  else if Seconds < S.CloseEnd then
    Result.OpenAmount := 1 - Ease((Seconds - S.CloseAt) / (S.CloseEnd - S.CloseAt));
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

