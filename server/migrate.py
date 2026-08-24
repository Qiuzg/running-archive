#!/usr/bin/env python3
"""
One-time migration: reads the generated JS files and populates the SQLite database.
Run from the project root:
  python3 server/migrate.py
"""
import json
import re
import sys
from datetime import date
from pathlib import Path

# Add project root to path so we can import server modules
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from server.database import engine, SessionLocal, Base
from server.models import Route, Race, RunRecord, CityBoundary, Profile

PROJECT_ROOT = Path(__file__).resolve().parent.parent


def extract_json_from_js(filepath: Path) -> dict | list:
    """Parse a JS file that assigns to window.X = { ... } and return the value.

    Handles:
      - window.VAR = { ... };
      - window.VAR = window.VAR || {};\\nwindow.VAR["key"] = { ... };
    """
    text = filepath.read_text(encoding="utf-8").strip()

    # Find the position after the LAST " = " or "= " or "=" that precedes a JSON object
    # Strategy: find the outermost { } started after the last "=" sign.
    last_eq = text.rfind("=")
    if last_eq < 0:
        raise ValueError(f"No assignment found in {filepath}")

    # Find the first "{" after the last "="
    brace_start = text.find("{", last_eq)
    if brace_start < 0:
        raise ValueError(f"No JSON object found in {filepath}")

    # Now find the matching closing brace
    depth = 0
    i = brace_start
    while i < len(text):
        ch = text[i]
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                json_str = text[brace_start:i + 1]
                return json.loads(json_str)
        i += 1

    raise ValueError(f"Unclosed JSON object in {filepath}")


def migrate_data():
    # HealthKit records arrive directly on the server and do not exist in the
    # generated JS source. Preserve them while rebuilding the portable data.
    synced_runs = []
    synced_routes_by_id = {}
    synced_races = []
    try:
        existing = SessionLocal()
        for run in existing.query(RunRecord).filter(RunRecord.source == "healthkit").all():
            synced_runs.append({column.name: getattr(run, column.name) for column in RunRecord.__table__.columns})
            if run.route_id:
                route = existing.get(Route, run.route_id)
                if route:
                    synced_routes_by_id[route.id] = {
                        column.name: getattr(route, column.name) for column in Route.__table__.columns
                    }
        # Race workouts do not have a duplicate RunRecord. The privacy marker
        # lets their richer HealthKit route and metrics survive future rebuilds.
        for route in existing.query(Route).filter(Route.privacy.like("healthkit %")).all():
            synced_routes_by_id[route.id] = {
                column.name: getattr(route, column.name) for column in Route.__table__.columns
            }
        for race in existing.query(Race).all():
            route = existing.get(Route, race.route_id) if race.route_id else None
            if route and route.privacy.startswith("healthkit "):
                synced_races.append({
                    "source_run_id": race.source_run_id,
                    "distance_km": race.distance_km,
                    "finish_time": race.finish_time,
                    "pace": race.pace,
                    "route_id": race.route_id,
                    "avg_heart_rate": race.avg_heart_rate,
                    "max_heart_rate": race.max_heart_rate,
                    "avg_cadence": race.avg_cadence,
                    "avg_power": race.avg_power,
                })
        existing.close()
    except Exception:
        # First migration or an older/incompatible database.
        synced_runs = []
        synced_routes_by_id = {}
        synced_races = []

    Base.metadata.drop_all(engine)
    Base.metadata.create_all(engine)

    db = SessionLocal()

    try:
        # 1. Profile
        data_path = PROJECT_ROOT / "data.generated.js"
        if data_path.exists():
            data = extract_json_from_js(data_path)
            print(f"Loaded data.generated.js: {len(data.get('races', []))} races, {len(data.get('runs', []))} runs")

            profile = data.get("profile", {})
            for k, v in profile.items():
                db.add(Profile(key=k, value=json.dumps(v) if not isinstance(v, str) else v))

            # 2. Routes from route-index (lightweight version)
            route_index_path = PROJECT_ROOT / "route-index.generated.js"
            route_index = {}
            if route_index_path.exists():
                route_index = extract_json_from_js(route_index_path)
                print(f"Loaded route-index: {len(route_index)} routes")

            # 3. Routes from detail files (full coordinates)
            routes_dir = PROJECT_ROOT / "routes"
            route_details = {}
            if routes_dir.exists():
                for f in sorted(routes_dir.glob("*.js")):
                    detail = extract_json_from_js(f)
                    rid = detail.get("id", "")
                    route_details[rid] = detail
            print(f"Loaded route details: {len(route_details)} routes")

            # Merge: route_index has preview, detail files have full coords + timeSeries
            all_route_ids = set(route_index.keys()) | set(route_details.keys())
            for rid in all_route_ids:
                ri = route_index.get(rid, {})
                rd = route_details.get(rid, {})
                merged = {**ri, **rd}  # detail wins for overlapping keys
                route = Route(
                    id=rid,
                    name=merged.get("name", ""),
                    city=merged.get("city", ""),
                    distance_km=merged.get("distanceKm", 0),
                    elevation_gain=merged.get("elevationGain", 0),
                    point_count=merged.get("pointCount", 0),
                    privacy=merged.get("privacy", ""),
                    hidden_start_end_meters=merged.get("hiddenStartEndMeters", 0),
                    preview_coordinates=merged.get("previewCoordinates", []),
                    coordinates=merged.get("coordinates", []),
                    elevations=merged.get("elevations", []),
                    time_series=merged.get("timeSeries", None),
                )
                db.add(route)

            # 4. Races
            for race_data in data.get("races", []):
                race = Race(
                    id=race_data.get("id", ""),
                    source_run_id=race_data.get("sourceRunId", ""),
                    name=race_data.get("name", ""),
                    type=race_data.get("type", ""),
                    date=date.fromisoformat(race_data["date"]) if race_data.get("date") else None,
                    city=race_data.get("city", ""),
                    country=race_data.get("country", ""),
                    distance_km=race_data.get("distanceKm", 0),
                    finish_time=race_data.get("finishTime", ""),
                    pace=race_data.get("pace", ""),
                    bib_number=race_data.get("bibNumber", ""),
                    is_pb=race_data.get("isPB", False),
                    route_id=race_data.get("routeId", None),
                    notes=race_data.get("notes", ""),
                    photos=race_data.get("photos", []),
                    avg_heart_rate=race_data.get("avgHeartRate"),
                    max_heart_rate=race_data.get("maxHeartRate"),
                    avg_cadence=race_data.get("avgCadence"),
                    avg_power=race_data.get("avgPower"),
                )
                db.add(race)

            # 5. Runs (non-race activities)
            race_source_ids = {r.get("sourceRunId") for r in data.get("races", []) if r.get("sourceRunId")}
            for run_data in data.get("runs", []):
                if run_data.get("id") in race_source_ids:
                    continue  # already recorded as a race
                run_record = RunRecord(
                    id=run_data.get("id", ""),
                    name=run_data.get("name") or run_data.get("title", ""),
                    date=date.fromisoformat(run_data["date"]) if run_data.get("date") else None,
                    city=run_data.get("city", ""),
                    distance_km=run_data.get("distanceKm", 0),
                    duration=run_data.get("duration", "") or run_data.get("finishTime", ""),
                    finish_time=run_data.get("finishTime", "") or run_data.get("duration", ""),
                    pace=run_data.get("pace", ""),
                    route_id=run_data.get("routeId", None),
                    avg_heart_rate=run_data.get("avgHeartRate"),
                    max_heart_rate=run_data.get("maxHeartRate"),
                    avg_cadence=run_data.get("avgCadence"),
                    avg_power=run_data.get("avgPower"),
                    source="apple",
                )
                db.add(run_record)

            # 6. City boundaries
            cb_path = PROJECT_ROOT / "city-boundaries.generated.js"
            if cb_path.exists():
                boundaries = extract_json_from_js(cb_path)
                print(f"Loaded city boundaries: {len(boundaries)} cities")
                for city_name, geojson in boundaries.items():
                    db.add(CityBoundary(city=city_name, geojson=geojson))

            # HealthKit uses the same deterministic IDs as the full Apple
            # export. Its denser route/heart-rate data must replace generated
            # rows with the same ID, rather than being discarded on deploy.
            db.flush()
            for route_data in synced_routes_by_id.values():
                route = db.get(Route, route_data["id"])
                if route is None:
                    db.add(Route(**route_data))
                else:
                    for key, value in route_data.items():
                        setattr(route, key, value)
            db.flush()
            for race_data in synced_races:
                race = db.query(Race).filter(Race.source_run_id == race_data["source_run_id"]).first()
                if race:
                    for key, value in race_data.items():
                        if key != "source_run_id":
                            setattr(race, key, value)
            for run_data in synced_runs:
                is_migrated_race = db.query(Race).filter(Race.source_run_id == run_data["id"]).first() is not None
                if is_migrated_race:
                    continue
                run = db.get(RunRecord, run_data["id"])
                if run is None:
                    db.add(RunRecord(**run_data))
                else:
                    for key, value in run_data.items():
                        setattr(run, key, value)

            db.commit()
            print("Migration completed successfully!")
            print(f"  Routes: {db.query(Route).count()}")
            print(f"  Races: {db.query(Race).count()}")
            print(f"  Run records: {db.query(RunRecord).count()}")
            print(f"  City boundaries: {db.query(CityBoundary).count()}")

    except Exception as e:
        db.rollback()
        print(f"Migration failed: {e}")
        raise
    finally:
        db.close()


if __name__ == "__main__":
    migrate_data()
