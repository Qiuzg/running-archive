"""Build the public atlas snapshot from already privacy-trimmed database routes.

Run: python -m server.build_atlas --output dist/generated/atlas.json
No database writes. An unsuccessful build leaves the previous snapshot intact.
"""
import argparse
from datetime import datetime
import json
import math
import os
from pathlib import Path
import sqlite3
import tempfile
from zoneinfo import ZoneInfo
from .route_preview import compact_preview


def project(points, width=260, height=130, padding=10):
    points = compact_preview(points, 1200)
    xy = [(math.radians(p[0]), math.log(math.tan(math.pi / 4 + math.radians(max(-85.05112878, min(85.05112878, p[1]))) / 2))) for p in points]
    if len(xy) < 2:
        return ''
    xs, ys = zip(*xy)
    min_x, min_y = min(xs), min(ys)
    dx, dy = max(xs) - min_x, max(ys) - min_y
    scale = min((width - 2 * padding) / dx if dx else math.inf, (height - 2 * padding) / dy if dy else math.inf) if dx or dy else 1
    result = []
    for x, y in xy:
        pair = f'{(width - dx * scale) / 2 + (x - min_x) * scale:.1f},{height - (height - dy * scale) / 2 - (y - min_y) * scale:.1f}'
        if not result or result[-1] != pair:
            result.append(pair)
    return ' '.join(result)


def build(db_path):
    with sqlite3.connect(f'file:{Path(db_path).resolve()}?mode=ro', uri=True) as db:
        db.row_factory = sqlite3.Row
        db.execute('BEGIN')
        races = [dict(r) for r in db.execute('SELECT * FROM races')]
        runs = [dict(r) for r in db.execute('SELECT * FROM run_records')]
        routes = {r['id']: dict(r) for r in db.execute('SELECT id,name,distance_km,coordinates,preview_coordinates FROM routes')}
    race_ids = {r[k] for r in races for k in ('id', 'source_run_id') if r[k]}
    race_routes = {r['route_id'] for r in races if r['route_id']}
    activities = races + [r for r in runs if r['id'] not in race_ids and r['route_id'] not in race_routes]
    entries, seen = [], set()
    for item in sorted(activities, key=lambda r: r['date'], reverse=True):
        route = routes.get(item['route_id'])
        if not route or route['id'] in seen:
            continue
        distance = route['distance_km'] or item['distance_km'] or 0
        if distance <= 10:
            continue
        coords = json.loads(route['coordinates'] or '[]') or json.loads(route['preview_coordinates'] or '[]')
        points = project(coords)
        if not points:
            continue
        seen.add(route['id'])
        entries.append(dict(id=route['id'], name=item['name'] or route['name'], date=item['date'], distance_km=distance,
                            kind={'marathon': 'marathon', 'half_marathon': 'half'}.get(item.get('type'), 'run'), points=points))
    return dict(version=1, generated_at=datetime.now(ZoneInfo('Asia/Shanghai')).isoformat(timespec='seconds'), entries=entries)


def publish(snapshot, output):
    output = Path(output)
    output.parent.mkdir(parents=True, exist_ok=True)
    name = None
    try:
        with tempfile.NamedTemporaryFile(mode='w', encoding='utf-8', dir=output.parent, delete=False) as f:
            name = f.name
            json.dump(snapshot, f, ensure_ascii=False, separators=(',', ':'), allow_nan=False)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(name, 0o644)
        os.replace(name, output)
    finally:
        if name and os.path.exists(name):
            os.unlink(name)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--database', default=str(Path(__file__).with_name('running.db')))
    parser.add_argument('--output', default='dist/generated/atlas.json')
    args = parser.parse_args()
    snapshot = build(args.database)
    publish(snapshot, args.output)
    print(f"Atlas: {len(snapshot['entries'])} routes, {snapshot['generated_at']}")
