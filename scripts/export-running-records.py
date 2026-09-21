#!/usr/bin/env python3
"""Export running and race records for an inclusive date range to CSV.

Examples:
    # Export from the local database.
    python3 scripts/export-running-records.py \
        --start 2026-06-09 --end 2026-09-09 \
        --db server/running.db \
        --output running-records.csv \
        --segments-output running-intervals.csv

    # Export from the production server. ssh will ask for the SSH password.
    python3 scripts/export-running-records.py \
        --start 2026-06-09 --end 2026-09-09 \
        --ssh-host root@123.56.181.123
"""

from __future__ import annotations

import argparse
import csv
import json
import os
import shlex
import sqlite3
import subprocess
import sys
import tempfile
from datetime import date
from pathlib import Path
from typing import Any, Iterable


CSV_COLUMNS = [
    "record_type",
    "id",
    "date",
    "name",
    "city",
    "distance_km",
    "duration",
    "finish_time",
    "pace_min_per_km",
    "average_heart_rate_bpm",
    "max_heart_rate_bpm",
    "average_cadence_spm",
    "average_power_w",
    "elevation_gain_m",
    "route_id",
    "route_point_count",
    "pace_sample_count",
    "elevation_sample_count",
    "heart_rate_sample_count",
    "interval_count",
    "source",
    "race_type",
    "is_personal_best",
    "country",
    "notes",
]

INTERVAL_COLUMNS = [
    "record_type",
    "record_id",
    "date",
    "name",
    "interval_index",
    "kind",
    "activity_type",
    "start_elapsed_seconds",
    "end_elapsed_seconds",
    "duration_seconds",
    "distance_km",
    "pace_seconds_per_km",
    "pace_min_per_km",
    "average_heart_rate_bpm",
    "max_heart_rate_bpm",
    "average_cadence_spm",
    "average_power_w",
    "event_type",
    "label",
]


REMOTE_EXPORT_SCRIPT = r'''import csv
import json
import sqlite3
import sys

db_path, start, end, mode = sys.argv[1:5]
connection = sqlite3.connect(db_path)
summary_columns = [
    "record_type", "id", "date", "name", "city", "distance_km",
    "duration", "finish_time", "pace_min_per_km",
    "average_heart_rate_bpm", "max_heart_rate_bpm",
    "average_cadence_spm", "average_power_w", "elevation_gain_m",
    "route_id", "route_point_count", "pace_sample_count",
    "elevation_sample_count", "heart_rate_sample_count", "interval_count",
    "source", "race_type", "is_personal_best", "country", "notes"
]
interval_columns = [
    "record_type", "record_id", "date", "name", "interval_index", "kind",
    "activity_type", "start_elapsed_seconds", "end_elapsed_seconds",
    "duration_seconds", "distance_km", "pace_seconds_per_km",
    "pace_min_per_km", "average_heart_rate_bpm", "max_heart_rate_bpm",
    "average_cadence_spm", "average_power_w", "event_type", "label"
]

def number(value, digits):
    if value is None:
        return ""
    return f"{float(value):.{digits}f}"

def series_counts(value):
    if not value:
        return "", "", ""
    try:
        series = json.loads(value) if isinstance(value, str) else value
    except (TypeError, ValueError):
        return "", "", ""
    if not isinstance(series, dict):
        return "", "", ""
    return (
        len(series.get("pace", []) or []),
        len(series.get("elevation", []) or []),
        len(series.get("heartRate", []) or []),
    )

def intervals(value):
    if not value:
        return []
    try:
        parsed = json.loads(value) if isinstance(value, str) else value
    except (TypeError, ValueError):
        return []
    return parsed if isinstance(parsed, list) else []

def field(value, *names):
    if not isinstance(value, dict):
        return None
    for name in names:
        if name in value:
            return value[name]
    return None

def present(value):
    return "" if value is None else value

def pace_text(value):
    if value is None:
        return ""
    total = max(0, round(float(value)))
    minutes, seconds = divmod(total, 60)
    return f"{minutes:02d}:{seconds:02d}"

has_intervals = any(row[1] == "intervals" for row in connection.execute("PRAGMA table_info(routes)"))
interval_select = "rt.intervals" if has_intervals else "NULL"
rows = []
run_query = (
    "SELECT r.id, r.date, r.name, r.city, r.distance_km, r.duration, "
    "r.finish_time, r.pace, r.route_id, r.avg_heart_rate, "
    "r.max_heart_rate, r.avg_cadence, r.avg_power, r.source, "
    f"rt.elevation_gain, rt.point_count, rt.time_series, {interval_select} "
    "FROM run_records AS r LEFT JOIN routes AS rt ON rt.id = r.route_id "
    "WHERE r.date >= ? AND r.date <= ?"
)
for row in connection.execute(run_query, (start, end)):
    (record_id, record_date, name, city, distance, duration, finish_time,
     pace, route_id, average_heart_rate, max_heart_rate, cadence, power,
     source, elevation_gain, point_count, time_series, interval_data) = row
    pace_count, elevation_count, heart_count = series_counts(time_series)
    interval_rows = intervals(interval_data)
    rows.append([
        "run", record_id, record_date, name or "", city or "", number(distance, 3),
        duration or "", finish_time or "", pace or "",
        average_heart_rate if average_heart_rate is not None else "",
        max_heart_rate if max_heart_rate is not None else "",
        number(cadence, 1), number(power, 1), number(elevation_gain, 1),
        route_id or "", point_count if point_count is not None else "",
        pace_count, elevation_count, heart_count, len(interval_rows),
        source or "", "", "", "", ""
    ])

race_query = (
    "SELECT r.id, r.date, r.name, r.city, r.distance_km, r.finish_time, "
    "r.pace, r.route_id, r.avg_heart_rate, r.max_heart_rate, r.avg_cadence, "
    "r.avg_power, r.type, r.is_pb, r.country, r.notes, rt.elevation_gain, "
    f"rt.point_count, rt.time_series, {interval_select} "
    "FROM races AS r LEFT JOIN routes AS rt ON rt.id = r.route_id "
    "WHERE r.date >= ? AND r.date <= ?"
)
for row in connection.execute(race_query, (start, end)):
    (record_id, record_date, name, city, distance, finish_time, pace, route_id,
     average_heart_rate, max_heart_rate, cadence, power, race_type, is_pb,
     country, notes, elevation_gain, point_count, time_series, interval_data) = row
    pace_count, elevation_count, heart_count = series_counts(time_series)
    interval_rows = intervals(interval_data)
    rows.append([
        "race", record_id, record_date, name or "", city or "", number(distance, 3),
        finish_time or "", finish_time or "", pace or "",
        average_heart_rate if average_heart_rate is not None else "",
        max_heart_rate if max_heart_rate is not None else "",
        number(cadence, 1), number(power, 1), number(elevation_gain, 1),
        route_id or "", point_count if point_count is not None else "",
        pace_count, elevation_count, heart_count, len(interval_rows), "race", race_type or "",
        "yes" if is_pb else "no", country or "", notes or ""
    ])

rows.sort(key=lambda row: (row[2], row[0]), reverse=True)
if mode == "summary":
    writer = csv.writer(sys.stdout, lineterminator="\n")
    writer.writerow(summary_columns)
    writer.writerows(rows)
else:
    output = []
    if has_intervals:
        for summary in rows:
            record_type, record_id, record_date, name = summary[:4]
            source_query = (
                "SELECT intervals FROM routes WHERE id = ("
                "SELECT route_id FROM run_records WHERE id = ?"
                "UNION ALL SELECT route_id FROM races WHERE id = ? LIMIT 1)"
            )
            interval_data = connection.execute(source_query, (record_id, record_id)).fetchone()
            for item in intervals(interval_data[0] if interval_data else None):
                pace_seconds = field(item, "pace_seconds_per_km", "paceSecondsPerKm")
                output.append([
                    record_type, record_id, record_date, name,
                present(field(item, "index")), present(field(item, "kind")),
                present(field(item, "activity_type", "activityType")),
                present(field(item, "start_elapsed_seconds", "startElapsedSeconds")),
                present(field(item, "end_elapsed_seconds", "endElapsedSeconds")),
                present(field(item, "duration_seconds", "durationSeconds")),
                    number(field(item, "distance_km", "distanceKm"), 3),
                    number(pace_seconds, 1), pace_text(pace_seconds),
                present(field(item, "avg_heart_rate", "avgHeartRate")),
                present(field(item, "max_heart_rate", "maxHeartRate")),
                    number(field(item, "avg_cadence", "avgCadence"), 1),
                    number(field(item, "avg_power", "avgPower"), 1),
                present(field(item, "event_type", "eventType")),
                present(field(item, "label")),
                ])
    output.sort(key=lambda row: (row[2], row[0], row[1], row[4]), reverse=True)
    writer = csv.writer(sys.stdout, lineterminator="\n")
    writer.writerow(interval_columns)
    writer.writerows(output)
connection.close()
'''


def parse_iso_date(value: str) -> date:
    try:
        return date.fromisoformat(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError(
            f"invalid date {value!r}; use YYYY-MM-DD"
        ) from exc


def number(value: Any, digits: int) -> str:
    if value is None:
        return ""
    return f"{float(value):.{digits}f}"


def series_counts(value: Any) -> tuple[int | str, int | str, int | str]:
    if not value:
        return "", "", ""
    try:
        series = json.loads(value) if isinstance(value, str) else value
    except (TypeError, ValueError):
        return "", "", ""
    if not isinstance(series, dict):
        return "", "", ""
    return (
        len(series.get("pace", []) or []),
        len(series.get("elevation", []) or []),
        len(series.get("heartRate", []) or []),
    )


def parse_intervals(value: Any) -> list[dict[str, Any]]:
    if not value:
        return []
    try:
        parsed = json.loads(value) if isinstance(value, str) else value
    except (TypeError, ValueError):
        return []
    return [item for item in parsed if isinstance(item, dict)] if isinstance(parsed, list) else []


def route_has_intervals(connection: sqlite3.Connection) -> bool:
    return any(
        row[1] == "intervals"
        for row in connection.execute("PRAGMA table_info(routes)")
    )


def interval_field(interval: dict[str, Any], *names: str) -> Any:
    for name in names:
        if name in interval:
            return interval[name]
    return None


def present(value: Any) -> Any:
    return "" if value is None else value


def pace_text(seconds: Any) -> str:
    if seconds in (None, ""):
        return ""
    try:
        total = max(0, round(float(seconds)))
    except (TypeError, ValueError):
        return ""
    minutes, remainder = divmod(total, 60)
    return f"{minutes:02d}:{remainder:02d}"


def run_rows(
    connection: sqlite3.Connection,
    start: str,
    end: str,
) -> Iterable[dict[str, Any]]:
    interval_select = "rt.intervals" if route_has_intervals(connection) else "NULL"
    query = """
        SELECT r.id, r.date, r.name, r.city, r.distance_km, r.duration,
               r.finish_time, r.pace, r.route_id, r.avg_heart_rate,
               r.max_heart_rate, r.avg_cadence, r.avg_power, r.source,
               rt.elevation_gain, rt.point_count, rt.time_series,
               {interval_select}
        FROM run_records AS r
        LEFT JOIN routes AS rt ON rt.id = r.route_id
        WHERE r.date >= ? AND r.date <= ?
    """.format(interval_select=interval_select)
    for row in connection.execute(query, (start, end)):
        (
            record_id,
            record_date,
            name,
            city,
            distance,
            duration,
            finish_time,
            pace,
            route_id,
            average_heart_rate,
            max_heart_rate,
            cadence,
            power,
            source,
            elevation_gain,
            point_count,
            time_series,
            interval_data,
        ) = row
        pace_count, elevation_count, heart_count = series_counts(time_series)
        intervals = parse_intervals(interval_data)
        yield {
            "record_type": "run",
            "id": record_id,
            "date": record_date,
            "name": name or "",
            "city": city or "",
            "distance_km": number(distance, 3),
            "duration": duration or "",
            "finish_time": finish_time or "",
            "pace_min_per_km": pace or "",
            "average_heart_rate_bpm": (
                average_heart_rate if average_heart_rate is not None else ""
            ),
            "max_heart_rate_bpm": (
                max_heart_rate if max_heart_rate is not None else ""
            ),
            "average_cadence_spm": number(cadence, 1),
            "average_power_w": number(power, 1),
            "elevation_gain_m": number(elevation_gain, 1),
            "route_id": route_id or "",
            "route_point_count": point_count if point_count is not None else "",
            "pace_sample_count": pace_count,
            "elevation_sample_count": elevation_count,
            "heart_rate_sample_count": heart_count,
            "interval_count": len(intervals),
            "source": source or "",
            "race_type": "",
            "is_personal_best": "",
            "country": "",
            "notes": "",
            "_intervals": intervals,
        }


def race_rows(
    connection: sqlite3.Connection,
    start: str,
    end: str,
) -> Iterable[dict[str, Any]]:
    interval_select = "rt.intervals" if route_has_intervals(connection) else "NULL"
    query = """
        SELECT r.id, r.date, r.name, r.city, r.distance_km,
               r.finish_time, r.pace, r.route_id, r.avg_heart_rate,
               r.max_heart_rate, r.avg_cadence, r.avg_power,
               r.type, r.is_pb, r.country, r.notes,
               rt.elevation_gain, rt.point_count, rt.time_series,
               {interval_select}
        FROM races AS r
        LEFT JOIN routes AS rt ON rt.id = r.route_id
        WHERE r.date >= ? AND r.date <= ?
    """.format(interval_select=interval_select)
    for row in connection.execute(query, (start, end)):
        (
            record_id,
            record_date,
            name,
            city,
            distance,
            finish_time,
            pace,
            route_id,
            average_heart_rate,
            max_heart_rate,
            cadence,
            power,
            race_type,
            is_personal_best,
            country,
            notes,
            elevation_gain,
            point_count,
            time_series,
            interval_data,
        ) = row
        pace_count, elevation_count, heart_count = series_counts(time_series)
        intervals = parse_intervals(interval_data)
        yield {
            "record_type": "race",
            "id": record_id,
            "date": record_date,
            "name": name or "",
            "city": city or "",
            "distance_km": number(distance, 3),
            "duration": finish_time or "",
            "finish_time": finish_time or "",
            "pace_min_per_km": pace or "",
            "average_heart_rate_bpm": (
                average_heart_rate if average_heart_rate is not None else ""
            ),
            "max_heart_rate_bpm": (
                max_heart_rate if max_heart_rate is not None else ""
            ),
            "average_cadence_spm": number(cadence, 1),
            "average_power_w": number(power, 1),
            "elevation_gain_m": number(elevation_gain, 1),
            "route_id": route_id or "",
            "route_point_count": point_count if point_count is not None else "",
            "pace_sample_count": pace_count,
            "elevation_sample_count": elevation_count,
            "heart_rate_sample_count": heart_count,
            "interval_count": len(intervals),
            "source": "race",
            "race_type": race_type or "",
            "is_personal_best": "yes" if is_personal_best else "no",
            "country": country or "",
            "notes": notes or "",
            "_intervals": intervals,
        }


def interval_rows(rows: Iterable[dict[str, Any]]) -> list[dict[str, Any]]:
    exported: list[dict[str, Any]] = []
    for row in rows:
        for interval in row.get("_intervals", []):
            pace_seconds = interval_field(interval, "pace_seconds_per_km", "paceSecondsPerKm")
            exported.append(
                {
                    "record_type": row["record_type"],
                    "record_id": row["id"],
                    "date": row["date"],
                    "name": row["name"],
                    "interval_index": present(interval_field(interval, "index")),
                    "kind": present(interval_field(interval, "kind")),
                    "activity_type": present(interval_field(interval, "activity_type", "activityType")),
                    "start_elapsed_seconds": present(interval_field(
                        interval, "start_elapsed_seconds", "startElapsedSeconds"
                    )),
                    "end_elapsed_seconds": present(interval_field(
                        interval, "end_elapsed_seconds", "endElapsedSeconds"
                    )),
                    "duration_seconds": present(interval_field(
                        interval, "duration_seconds", "durationSeconds"
                    )),
                    "distance_km": number(
                        interval_field(interval, "distance_km", "distanceKm"), 3
                    ),
                    "pace_seconds_per_km": number(pace_seconds, 1),
                    "pace_min_per_km": pace_text(pace_seconds),
                    "average_heart_rate_bpm": present(interval_field(
                        interval, "avg_heart_rate", "avgHeartRate"
                    )),
                    "max_heart_rate_bpm": present(interval_field(
                        interval, "max_heart_rate", "maxHeartRate"
                    )),
                    "average_cadence_spm": number(
                        interval_field(interval, "avg_cadence", "avgCadence"), 1
                    ),
                    "average_power_w": number(
                        interval_field(interval, "avg_power", "avgPower"), 1
                    ),
                    "event_type": present(interval_field(interval, "event_type", "eventType")),
                    "label": present(interval_field(interval, "label")),
                }
            )
    exported.sort(
        key=lambda row: (row["date"], row["record_type"], row["record_id"], row["interval_index"]),
        reverse=True,
    )
    return exported


def export_database(
    db_path: Path,
    start: date,
    end: date,
    output_path: Path,
    segments_output: Path | None = None,
) -> tuple[int, int]:
    if not db_path.is_file():
        raise FileNotFoundError(f"database not found: {db_path}")

    connection = sqlite3.connect(str(db_path))
    try:
        rows = list(run_rows(connection, start.isoformat(), end.isoformat()))
        rows.extend(race_rows(connection, start.isoformat(), end.isoformat()))
    finally:
        connection.close()

    rows.sort(key=lambda row: (row["date"], row["record_type"]), reverse=True)
    segments = interval_rows(rows)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    with output_path.open("w", encoding="utf-8-sig", newline="") as handle:
        writer = csv.DictWriter(
            handle, fieldnames=CSV_COLUMNS, extrasaction="ignore", lineterminator="\n"
        )
        writer.writeheader()
        writer.writerows(rows)
    if segments_output is not None:
        segments_output.parent.mkdir(parents=True, exist_ok=True)
        with segments_output.open("w", encoding="utf-8-sig", newline="") as handle:
            writer = csv.DictWriter(handle, fieldnames=INTERVAL_COLUMNS, lineterminator="\n")
            writer.writeheader()
            writer.writerows(segments)
    return len(rows), len(segments)


def count_csv_rows(path: Path) -> int:
    with path.open("r", encoding="utf-8-sig", newline="") as handle:
        return sum(1 for _ in csv.DictReader(handle))


def export_remote_database(
    ssh_host: str,
    remote_db: str,
    start: date,
    end: date,
    output_path: Path,
    segments_output: Path | None = None,
) -> tuple[int, int]:
    """Filter on the server and stream only the requested CSV rows locally."""
    targets = [(output_path, "summary")]
    if segments_output is not None:
        targets.append((segments_output, "segments"))
    temporary_outputs: list[tuple[Path, Path]] = []
    try:
        for target_path, mode in targets:
            target_path.parent.mkdir(parents=True, exist_ok=True)
            with tempfile.NamedTemporaryFile(
                mode="wb", prefix=f".{target_path.name}.", suffix=".tmp",
                dir=target_path.parent, delete=False
            ) as handle:
                temp_path = Path(handle.name)
                remote_command = " ".join(
                    [
                        "python3",
                        "-c",
                        shlex.quote(REMOTE_EXPORT_SCRIPT),
                        shlex.quote(remote_db),
                        shlex.quote(start.isoformat()),
                        shlex.quote(end.isoformat()),
                        shlex.quote(mode),
                    ]
                )
                temporary_outputs.append((temp_path, target_path))
                subprocess.run(
                    ["ssh", ssh_host, remote_command],
                    stdout=handle,
                    check=True,
                )
        for temp_path, target_path in temporary_outputs:
            os.replace(temp_path, target_path)
        summary_count = count_csv_rows(output_path)
        segment_count = count_csv_rows(segments_output) if segments_output else 0
        return summary_count, segment_count
    except FileNotFoundError as exc:
        raise RuntimeError("ssh was not found; install or enable OpenSSH") from exc
    except subprocess.CalledProcessError as exc:
        raise RuntimeError(
            "ssh export failed; check the SSH host, remote path, and your credentials"
        ) from exc
    finally:
        for temp_path, _ in temporary_outputs:
            temp_path.unlink(missing_ok=True)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Export running and race records for an inclusive date range."
    )
    parser.add_argument("--start", required=True, type=parse_iso_date)
    parser.add_argument("--end", required=True, type=parse_iso_date)
    parser.add_argument(
        "--output",
        type=Path,
        help="CSV path; defaults to running-records-START-to-END.csv",
    )
    parser.add_argument(
        "--segments-output",
        "--intervals-output",
        dest="segments_output",
        type=Path,
        help="optional CSV path for one row per HealthKit interval/lap/segment",
    )
    parser.add_argument(
        "--db",
        type=Path,
        default=Path(__file__).resolve().parents[1] / "server" / "running.db",
        help="local SQLite database path",
    )
    parser.add_argument(
        "--ssh-host",
        help="SSH host such as root@example.com; filters records on the server",
    )
    parser.add_argument(
        "--remote-db",
        default="/opt/running-archive/server/running.db",
        help="remote SQLite path used with --ssh-host",
    )
    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    if args.end < args.start:
        parser.error("--end must be on or after --start")

    output_path = args.output or Path(
        f"running-records-{args.start.isoformat()}-to-{args.end.isoformat()}.csv"
    )
    segments_output = args.segments_output

    try:
        if args.ssh_host:
            count, segment_count = export_remote_database(
                args.ssh_host, args.remote_db, args.start, args.end, output_path,
                segments_output,
            )
        else:
            count, segment_count = export_database(
                args.db, args.start, args.end, output_path, segments_output
            )
    except (FileNotFoundError, RuntimeError, sqlite3.Error) as exc:
        print(f"Export failed: {exc}", file=sys.stderr)
        return 1

    print(
        f"Exported {count} records ({args.start.isoformat()} to "
        f"{args.end.isoformat()}) to {output_path}"
    )
    if segments_output is not None:
        print(f"Exported {segment_count} interval rows to {segments_output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
