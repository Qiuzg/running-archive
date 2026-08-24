import hmac
import math
import os
from datetime import datetime

from fastapi import APIRouter, Depends, Header, HTTPException
from sqlalchemy.orm import Session

from ..database import get_db
from ..models import Route, RunRecord
from ..schemas import (
    AppleWorkoutSyncRequest,
    AppleWorkoutSyncResponse,
    AppleWorkoutSyncResult,
    HealthRoutePoint,
)

router = APIRouter(prefix="/api/sync", tags=["sync"])
PRIVACY_RADIUS_METERS = 600


def require_sync_token(authorization: str | None = Header(None)):
    expected = os.getenv("RUNNING_SYNC_TOKEN", "").strip()
    if not expected:
        raise HTTPException(status_code=503, detail="Apple Health sync is not configured")
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="Missing sync token")
    supplied = authorization.removeprefix("Bearer ").strip()
    if not hmac.compare_digest(supplied, expected):
        raise HTTPException(status_code=403, detail="Invalid sync token")


def haversine_meters(a: HealthRoutePoint, b: HealthRoutePoint) -> float:
    radius = 6_371_000
    lat1, lat2 = math.radians(a.latitude), math.radians(b.latitude)
    dlat = lat2 - lat1
    dlon = math.radians(b.longitude - a.longitude)
    value = math.sin(dlat / 2) ** 2 + math.cos(lat1) * math.cos(lat2) * math.sin(dlon / 2) ** 2
    return 2 * radius * math.asin(math.sqrt(value))


def trim_route(points: list[HealthRoutePoint], radius_meters: int) -> list[HealthRoutePoint]:
    if len(points) < 3 or radius_meters <= 0:
        return points
    cumulative = [0.0]
    for previous, current in zip(points, points[1:]):
        cumulative.append(cumulative[-1] + haversine_meters(previous, current))
    total = cumulative[-1]
    if total <= radius_meters * 2:
        return []
    start = next((index for index, distance in enumerate(cumulative) if distance >= radius_meters), len(points))
    end = next((index for index, distance in enumerate(cumulative) if total - distance <= radius_meters), len(points))
    return points[start:end]


def sample_coordinates(coordinates: list[list[float]], limit: int = 300) -> list[list[float]]:
    if len(coordinates) <= limit:
        return coordinates
    step = (len(coordinates) - 1) / (limit - 1)
    return [coordinates[round(index * step)] for index in range(limit)]


def elevation_gain(elevations: list[float]) -> float:
    return round(sum(max(0.0, current - previous) for previous, current in zip(elevations, elevations[1:])), 1)


def duration_text(seconds: float) -> str:
    total = max(0, round(seconds))
    hours, remainder = divmod(total, 3600)
    minutes, secs = divmod(remainder, 60)
    return f"{hours:02d}:{minutes:02d}:{secs:02d}"


def pace_text(distance_km: float, duration_seconds: float) -> str:
    if distance_km <= 0:
        return ""
    seconds = round(duration_seconds / distance_km)
    minutes, secs = divmod(seconds, 60)
    return f"{minutes:02d}:{secs:02d}"


def upsert_workout(data, db: Session) -> AppleWorkoutSyncResult:
    run_id = data.id.strip()
    if not run_id or len(run_id) > 128:
        raise HTTPException(status_code=422, detail="Invalid workout id")

    points = sorted(data.route_points, key=lambda point: point.timestamp)
    trimmed = trim_route(points, PRIVACY_RADIUS_METERS)
    route_id = f"route-{run_id}" if trimmed else None
    if route_id:
        coordinates = [[point.longitude, point.latitude] for point in trimmed]
        elevations = [round(point.altitude, 1) for point in trimmed]
        start_time = data.start_date
        elapsed = [max(0, round((point.timestamp - start_time).total_seconds(), 1)) for point in trimmed]
        pace = [round(1000 / point.speed_mps / 60, 2) if point.speed_mps and point.speed_mps > 0.4 else None for point in trimmed]
        heart_rate = [round(sample.value) for sample in data.heart_rate_samples]
        heart_elapsed = [round(sample.elapsed_seconds, 1) for sample in data.heart_rate_samples]
        time_series = {
            "elapsed": elapsed,
            "pace": pace,
            "elevation": elevations,
            "heartRate": heart_rate,
            "heartRateElapsed": heart_elapsed,
        }
        route = db.get(Route, route_id)
        if route is None:
            route = Route(id=route_id)
            db.add(route)
        route.name = data.name
        route.city = data.city
        route.distance_km = data.distance_km
        route.elevation_gain = elevation_gain(elevations)
        route.point_count = len(coordinates)
        route.privacy = f"start/end {PRIVACY_RADIUS_METERS}m hidden"
        route.hidden_start_end_meters = PRIVACY_RADIUS_METERS
        route.preview_coordinates = sample_coordinates(coordinates)
        route.coordinates = coordinates
        route.elevations = elevations
        route.time_series = time_series

    run = db.get(RunRecord, run_id)
    status = "updated" if run else "created"
    if run is None:
        run = RunRecord(id=run_id)
        db.add(run)
    run.name = data.name
    run.date = data.start_date.date()
    run.city = data.city
    run.distance_km = data.distance_km
    run.duration = duration_text(data.duration_seconds)
    run.finish_time = run.duration
    run.pace = pace_text(data.distance_km, data.duration_seconds)
    run.route_id = route_id
    run.avg_heart_rate = data.avg_heart_rate
    run.max_heart_rate = data.max_heart_rate
    run.avg_cadence = data.avg_cadence
    run.avg_power = data.avg_power
    run.source = "healthkit"
    return AppleWorkoutSyncResult(id=run_id, status=status, route_points=len(trimmed))


@router.post("/apple-workouts", response_model=AppleWorkoutSyncResponse)
def sync_apple_workouts(
    request: AppleWorkoutSyncRequest,
    _: None = Depends(require_sync_token),
    db: Session = Depends(get_db),
):
    if not 1 <= len(request.workouts) <= 50:
        raise HTTPException(status_code=422, detail="Send between 1 and 50 workouts")
    results = []
    try:
        for workout in request.workouts:
            results.append(upsert_workout(workout, db))
        db.commit()
    except Exception:
        db.rollback()
        raise
    return AppleWorkoutSyncResponse(synced=results)
