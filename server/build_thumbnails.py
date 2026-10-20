"""Pre-render theme-aware mini SVGs; publish the manifest only after all files exist."""
import argparse
import hashlib
import json
from pathlib import Path
import sqlite3
from datetime import datetime
from zoneinfo import ZoneInfo
from .build_atlas import project, publish


def svg_for(coordinates):
    points = project(coordinates, 180, 140, 14)
    if not points:
        return None
    start, end = points.split(' ')[0].split(','), points.split(' ')[-1].split(',')
    return f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 180 140">
<style>.line{{stroke:#3b8bff}}.accent{{stroke:#2dd4a8}}.start{{fill:#0a0f18;stroke:#2dd4a8}}.end{{fill:#ff5e3a;stroke:#0a0f18}}</style>
<polyline points="{points}" fill="none" stroke="#3b8bff" stroke-width="5" opacity=".3" stroke-linejoin="round" stroke-linecap="round"/>
<polyline class="line" points="{points}" fill="none" stroke-width="3" stroke-linejoin="round" stroke-linecap="round"/>
<polyline class="accent" points="{points}" fill="none" stroke-width="1.5" stroke-linejoin="round" stroke-linecap="round"/>
<circle class="start" cx="{start[0]}" cy="{start[1]}" r="3.5" stroke-width="2"/>
<circle class="end" cx="{end[0]}" cy="{end[1]}" r="3.5" stroke-width="2"/></svg>'''


def build(db_path, output):
    output = Path(output)
    directory = output.parent / 'thumbnails'
    directory.mkdir(parents=True, exist_ok=True)
    entries = {}
    with sqlite3.connect(f'file:{Path(db_path).resolve()}?mode=ro', uri=True) as db:
        for route_id, coords, preview in db.execute('SELECT id,coordinates,preview_coordinates FROM routes'):
            svg = svg_for(json.loads(coords or '[]') or json.loads(preview or '[]'))
            if not svg:
                entries[route_id] = None
                continue
            filename = hashlib.sha256(svg.encode()).hexdigest() + '.svg'
            path = directory / filename
            if not path.exists():
                temporary = path.with_suffix('.tmp')
                temporary.write_text(svg, encoding='utf-8')
                temporary.chmod(0o644)
                temporary.replace(path)
            entries[route_id] = filename
    snapshot = dict(version=1, generated_at=datetime.now(ZoneInfo('Asia/Shanghai')).isoformat(), entries=entries)
    publish(snapshot, output)
    print(f'Thumbnails: {len(entries)} routes')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--database', default=str(Path(__file__).with_name('running.db')))
    parser.add_argument('--output', default='dist/generated/thumbnails.json')
    args = parser.parse_args()
    build(args.database, args.output)
