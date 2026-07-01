#!/usr/bin/env python3
import argparse
import json
import math
import tempfile
import zipfile
from datetime import datetime
from pathlib import Path
from xml.etree import ElementTree as ET


CITY_POINTS = [
    ("南京", 118.7969, 32.0603),
    ("上海", 121.4737, 31.2304),
    ("北京", 116.4074, 39.9042),
    ("苏州", 120.5853, 31.2989),
    ("无锡", 120.3119, 31.4912),
    ("常州", 119.9741, 31.8112),
    ("镇江", 119.4250, 32.1878),
    ("扬州", 119.4127, 32.3942),
    ("杭州", 120.1551, 30.2741),
    ("宁波", 121.5504, 29.8746),
    ("合肥", 117.2272, 31.8206),
    ("武汉", 114.3054, 30.5931),
    ("厦门", 118.0894, 24.4798),
    ("广州", 113.2644, 23.1291),
    ("深圳", 114.0579, 22.5431),
    ("重庆", 106.5516, 29.5630),
    ("成都", 104.0665, 30.5728),
]


def parse_apple_date(value):
    if not value:
        return None
    cleaned = value.replace(" +0000", "+00:00")
    if len(cleaned) >= 6 and cleaned[-5] in ["+", "-"] and cleaned[-3] != ":":
        cleaned = f"{cleaned[:-2]}:{cleaned[-2:]}"
    try:
        return datetime.fromisoformat(cleaned)
    except ValueError:
        return datetime.strptime(value[:19], "%Y-%m-%d %H:%M:%S")


def seconds_to_hms(seconds):
    seconds = int(round(seconds))
    h = seconds // 3600
    m = (seconds % 3600) // 60
    s = seconds % 60
    return f"{h:02d}:{m:02d}:{s:02d}"


def pace_for(distance_km, duration_seconds):
    if not distance_km or not duration_seconds:
        return "--"
    seconds = int(round(duration_seconds / distance_km))
    return f"{seconds // 60:02d}:{seconds % 60:02d}"


def distance_to_km(value, unit):
    distance = float(value or 0)
    normalized = (unit or "").lower()
    if normalized in ["km", "kilometer", "kilometers"]:
        return distance
    if normalized in ["mi", "mile", "miles"]:
        return distance * 1.609344
    if normalized in ["m", "meter", "meters"]:
        return distance / 1000
    return distance


def duration_to_seconds(value, unit):
    duration = float(value or 0)
    normalized = (unit or "").lower()
    if normalized in ["min", "minute", "minutes"]:
        return duration * 60
    if normalized in ["hr", "hour", "hours"]:
        return duration * 3600
    return duration


def haversine_km(a, b):
    lat1, lon1 = math.radians(a[1]), math.radians(a[0])
    lat2, lon2 = math.radians(b[1]), math.radians(b[0])
    dlat = lat2 - lat1
    dlon = lon2 - lon1
    h = math.sin(dlat / 2) ** 2 + math.cos(lat1) * math.cos(lat2) * math.sin(dlon / 2) ** 2
    return 6371 * 2 * math.asin(math.sqrt(h))


def route_distance_km(points):
    return sum(haversine_km(points[i - 1], points[i]) for i in range(1, len(points)))


def trim_points(points, count):
    if len(points) <= count * 2 + 2:
        return []
    return points[count : len(points) - count]


def downsample_points(points, max_points):
    if max_points <= 0:
        return points
    if len(points) <= max_points:
        return points
    step = (len(points) - 1) / (max_points - 1)
    sampled = [points[round(i * step)] for i in range(max_points)]
    sampled[0] = points[0]
    sampled[-1] = points[-1]
    return sampled


def infer_city(points):
    if not points:
        return ""
    lon = sum(point[0] for point in points) / len(points)
    lat = sum(point[1] for point in points) / len(points)
    city, _, distance = min(
        ((name, (city_lon, city_lat), haversine_km((lon, lat), (city_lon, city_lat))) for name, city_lon, city_lat in CITY_POINTS),
        key=lambda item: item[2],
    )
    return city if distance <= 120 else ""


def run_time_label(start, distance_km):
    if distance_km >= 20:
        return "长距离"
    if not start:
        return "跑步"
    hour = start.hour
    if 5 <= hour < 11:
        return "晨跑"
    if 11 <= hour < 15:
        return "午跑"
    if 15 <= hour < 19:
        return "下午跑"
    if 19 <= hour < 24:
        return "夜跑"
    return "跑步"


def build_run_title(start, city, distance_km):
    place = city or "户外"
    return f"{place}{run_time_label(start, distance_km)} {distance_km:.1f}km"


def route_name_for(workout, city):
    place = city or "户外"
    return f"{place}{run_time_label(workout.get('start'), workout.get('distanceKm') or 0)}路线 {workout.get('date')}"


def parse_route_datetime(path):
    stem = path.stem
    parts = stem.split("_")
    if len(parts) < 3:
        return None
    raw_time = parts[2].replace(".", ":")
    for fmt in ["%Y-%m-%d %I:%M%p", "%Y-%m-%d %H:%M"]:
        try:
            return datetime.strptime(f"{parts[1]} {raw_time}", fmt)
        except ValueError:
            continue
    return None


def find_export_root(path):
    candidates = []
    for name in ["export.xml", "导出.xml"]:
        candidates.extend(path.rglob(name))
    if not candidates:
        raise FileNotFoundError("Could not find export.xml or 导出.xml in Apple Health export.")
    return candidates[0].parent


def find_export_xml(export_root):
    for name in ["export.xml", "导出.xml"]:
        candidate = export_root / name
        if candidate.exists():
            return candidate
    raise FileNotFoundError("Could not find export.xml or 导出.xml in Apple Health export root.")


def parse_workouts(export_xml):
    workouts = []
    for _, elem in ET.iterparse(export_xml, events=("end",)):
        if elem.tag != "Workout":
            continue
        if elem.attrib.get("workoutActivityType") != "HKWorkoutActivityTypeRunning":
            elem.clear()
            continue

        start = parse_apple_date(elem.attrib.get("startDate"))
        duration_seconds = duration_to_seconds(elem.attrib.get("duration"), elem.attrib.get("durationUnit"))
        distance_km = distance_to_km(elem.attrib.get("totalDistance"), elem.attrib.get("totalDistanceUnit"))
        for child in elem:
            if child.tag != "WorkoutStatistics":
                continue
            if child.attrib.get("type") == "HKQuantityTypeIdentifierDistanceWalkingRunning":
                distance_km = distance_to_km(child.attrib.get("sum"), child.attrib.get("unit"))
                break
        workout_id = f"apple-{start.strftime('%Y%m%d-%H%M%S')}" if start else f"apple-{len(workouts) + 1}"

        workouts.append(
            {
                "id": workout_id,
                "date": start.date().isoformat() if start else "",
                "start": start,
                "title": build_run_title(start, "", distance_km),
                "distanceKm": round(distance_km, 2),
                "duration": seconds_to_hms(duration_seconds),
                "pace": pace_for(distance_km, duration_seconds),
                "runType": "long" if distance_km >= 25 else "easy",
                "location": "",
                "notes": "",
            }
        )
        elem.clear()
    return workouts


def parse_gpx(path):
    tree = ET.parse(path)
    points = []
    for point in tree.iter():
        if not point.tag.endswith("trkpt"):
            continue
        lat = point.attrib.get("lat")
        lon = point.attrib.get("lon")
        if lat and lon:
            points.append([round(float(lon), 6), round(float(lat), 6)])
    return points


def assign_routes(export_root, workouts, trim_count, privacy_radius, max_points):
    routes = {}
    route_files = sorted((export_root / "workout-routes").glob("*.gpx"))
    unmatched = []
    used_workout_ids = set()

    for route_file in route_files:
        raw_points = parse_gpx(route_file)
        public_points = downsample_points(trim_points(raw_points, trim_count), max_points)
        if len(public_points) < 2:
            continue

        route_start = parse_route_datetime(route_file)
        route_date = route_start.date() if route_start else None

        candidates = [item for item in workouts if route_date and item["start"] and item["start"].date() == route_date]
        if not candidates:
            unmatched.append(route_file.name)
            continue

        available = [item for item in candidates if item["id"] not in used_workout_ids] or candidates
        if route_start:
            workout = min(
                available,
                key=lambda item: abs((item["start"].replace(tzinfo=None) - route_start).total_seconds()),
            )
        else:
            workout = min(available, key=lambda item: abs(item["distanceKm"] - route_distance_km(public_points)))
        used_workout_ids.add(workout["id"])
        route_id = f"route-{workout['id']}"
        city = infer_city(public_points)
        workout["location"] = city or "户外"
        workout["title"] = build_run_title(workout.get("start"), city, workout.get("distanceKm") or 0)
        workout["routeId"] = route_id
        routes[route_id] = {
            "id": route_id,
            "name": route_name_for(workout, city),
            "city": city or "户外",
            "distanceKm": workout["distanceKm"],
            "privacy": "起终点附近已裁剪",
            "hiddenStartEndMeters": privacy_radius,
            "coordinates": public_points,
        }

    return routes, unmatched


def write_outputs(out_dir, workouts, routes, privacy_radius):
    clean_workouts = []
    for item in workouts:
        copy = dict(item)
        copy.pop("start", None)
        if not copy.get("location"):
            copy["location"] = "户外"
        clean_workouts.append(copy)

    race_candidates = []
    for item in clean_workouts:
        distance = float(item.get("distanceKm") or 0)
        if 41 <= distance <= 44:
            race_type = "marathon"
            name = "全马"
        elif 20 <= distance <= 23:
            race_type = "half_marathon"
            name = "半马"
        else:
            continue

        # Only count morning runs as races (start hour < 12).
        # ID format: apple-YYYYMMDD-HHMMSS
        import re
        match = re.search(r"[_-](\d{2})(\d{2})(\d{2})$", item["id"])
        if match:
            hour = int(match.group(1))
            if hour >= 12:
                continue

        place = "" if item.get("location") == "户外" else item.get("location", "")
        display_name = f"{place}{name} {item['date']}" if place else f"{name} {item['date']}"
        race_candidates.append(
            {
                "id": f"race-{item['id']}",
                "sourceRunId": item["id"],
                "name": display_name,
                "type": race_type,
                "date": item["date"],
                "city": place,
                "country": "",
                "distanceKm": item["distanceKm"],
                "finishTime": item["duration"],
                "pace": item["pace"],
                "bibNumber": "",
                "isPB": False,
                "routeId": item.get("routeId"),
                "notes": "",
                "photos": [],
            }
        )

    for race_type in ["marathon", "half_marathon"]:
      typed = [item for item in race_candidates if item["type"] == race_type]
      if typed:
        best = min(typed, key=lambda item: sum(int(part) * 60 ** index for index, part in enumerate(reversed(item["finishTime"].split(":")))))
        best["isPB"] = True

    year = datetime.now().year
    data = {
        "profile": {
            "runnerName": "跑者档案",
            "currentYear": year,
            "syncPlan": {
                "source": "本地导出",
                "bridge": "本地健康数据",
                "publicPrivacyRadiusMeters": privacy_radius,
            },
        },
        "races": race_candidates,
        "runs": clean_workouts,
    }

    (out_dir / "data.generated.js").write_text(
        f"window.RUN_ARCHIVE_DATA = {json.dumps(data, ensure_ascii=False, indent=2)};\n",
        encoding="utf-8",
    )
    route_dir = out_dir / "routes"
    route_dir.mkdir(exist_ok=True)
    for old_file in route_dir.glob("*.js"):
        old_file.unlink()

    route_index = {}
    for route_id, route in routes.items():
        detail = dict(route)
        coordinates = detail.get("coordinates", [])
        route_index[route_id] = {key: value for key, value in detail.items() if key != "coordinates"}
        route_index[route_id]["pointCount"] = len(coordinates)
        route_index[route_id]["previewCoordinates"] = downsample_points(coordinates, 220)
        route_index[route_id]["routeFile"] = f"./routes/{route_id}.js"
        (route_dir / f"{route_id}.js").write_text(
            "window.RUN_ROUTE_DETAIL = window.RUN_ROUTE_DETAIL || {};\n"
            f"window.RUN_ROUTE_DETAIL[{json.dumps(route_id)}] = {json.dumps(detail, ensure_ascii=False, separators=(',', ':'))};\n",
            encoding="utf-8",
        )

    (out_dir / "route-index.generated.js").write_text(
        f"window.RUN_ROUTE_INDEX = {json.dumps(route_index, ensure_ascii=False, indent=2)};\n",
        encoding="utf-8",
    )


def main():
    parser = argparse.ArgumentParser(description="Import Apple Health export data into the running archive.")
    parser.add_argument("export", help="Path to Apple Health export zip or extracted apple_health_export directory.")
    parser.add_argument("--out", default=str(Path(__file__).resolve().parents[1]), help="Output directory.")
    parser.add_argument("--trim-points", type=int, default=8, help="Number of GPS points to remove from each end.")
    parser.add_argument("--privacy-radius", type=int, default=600, help="Displayed privacy radius in meters.")
    parser.add_argument("--max-route-points", type=int, default=0, help="Maximum public points kept per route. Use 0 to keep all public points.")
    args = parser.parse_args()

    source = Path(args.export).expanduser().resolve()
    out_dir = Path(args.out).expanduser().resolve()

    if source.suffix.lower() == ".zip":
        with tempfile.TemporaryDirectory() as tmp:
            with zipfile.ZipFile(source) as archive:
                archive.extractall(tmp)
            export_root = find_export_root(Path(tmp))
            workouts = parse_workouts(find_export_xml(export_root))
            routes, unmatched = assign_routes(
                export_root, workouts, args.trim_points, args.privacy_radius, args.max_route_points
            )
            write_outputs(out_dir, workouts, routes, args.privacy_radius)
    else:
        export_root = find_export_root(source)
        workouts = parse_workouts(find_export_xml(export_root))
        routes, unmatched = assign_routes(
            export_root, workouts, args.trim_points, args.privacy_radius, args.max_route_points
        )
        write_outputs(out_dir, workouts, routes, args.privacy_radius)

    print(f"Imported {len(workouts)} running workouts and {len(routes)} routes.")
    if unmatched:
        print(f"Skipped {len(unmatched)} route files that could not be matched by date.")


if __name__ == "__main__":
    main()
