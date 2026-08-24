#!/usr/bin/env python3
"""
Generate a single-run sharing card from local generated running data.

The rendered HTML uses Leaflet with a light CartoDB Positron tile layer, then
Chrome headless captures it as a PNG.
"""
from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parent.parent
SITE_URL = "https://123.56.181.123/run/"


def extract_json_from_assignment(path: Path):
    text = path.read_text(encoding="utf-8").strip()
    match = re.search(r"=\s*(\{.*\});?\s*$", text, re.S)
    if not match:
        raise ValueError(f"Cannot parse {path}")
    return json.loads(match.group(1))


def load_today_run(date: str | None):
    data = extract_json_from_assignment(PROJECT_ROOT / "data.generated.js")
    runs = data.get("runs", [])
    if date:
        candidates = [run for run in runs if run.get("date") == date]
    else:
        latest_date = max(run.get("date", "") for run in runs)
        candidates = [run for run in runs if run.get("date") == latest_date]
    if not candidates:
        raise ValueError(f"No run found for {date or 'latest date'}")
    return max(candidates, key=lambda run: (run.get("distanceKm") or 0, run.get("id") or ""))


def sample(values, limit):
    if not values or len(values) <= limit:
        return values or []
    step = (len(values) - 1) / (limit - 1)
    return [values[round(i * step)] for i in range(limit)]


def clean_pace(values):
    cleaned = []
    for value in values or []:
      if isinstance(value, (int, float)) and 2.5 <= value <= 15:
          cleaned.append(round(float(value), 2))
      else:
          cleaned.append(None)
    return cleaned


def format_js(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def make_html(run, route, leaflet_css: Path, leaflet_js: Path, qr_js: Path):
    coords = route.get("coordinates") or route.get("previewCoordinates") or []
    ts = route.get("timeSeries") or {}
    chart_limit = 720
    chart_data = {
        "elapsed": sample([int(v) for v in ts.get("elapsed", []) if isinstance(v, (int, float))], chart_limit),
        "pace": sample(clean_pace(ts.get("pace")), chart_limit),
        "elevation": sample([round(float(v), 1) for v in ts.get("elevation", []) if isinstance(v, (int, float))], chart_limit),
        "heartRate": sample([int(v) for v in ts.get("heartRate", []) if isinstance(v, (int, float))], chart_limit),
    }
    route_coords = sample(coords, 1800)

    return f"""<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=1080, initial-scale=1">
  <title>Run Share</title>
  <style>{leaflet_css.read_text(encoding="utf-8")}</style>
  <style>
    * {{ box-sizing: border-box; }}
    body {{
      margin: 0;
      width: 1080px;
      min-height: 2800px;
      overflow: hidden;
      font-family: -apple-system, BlinkMacSystemFont, "SF Pro Display", "PingFang SC", "Microsoft YaHei", sans-serif;
      color: #18202b;
      background: #f6f9fc;
    }}
    .card {{
      position: relative;
      width: 1080px;
      height: 2800px;
      padding: 48px;
      background: #f6f9fc;
      overflow: hidden;
    }}
    .header {{
      position: relative;
      z-index: 2;
      display: flex;
      align-items: center;
      gap: 24px;
      height: 112px;
    }}
    .avatar {{
      width: 82px; height: 82px; border-radius: 50%; object-fit: cover;
      border: 4px solid #fff; box-shadow: 0 12px 28px rgba(28, 38, 58, .14);
    }}
    .eyebrow {{ margin: 0 0 6px; color: #ff5e3a; font-size: 24px; font-weight: 850; letter-spacing: 4px; text-transform: uppercase; }}
    h1 {{ margin: 0; font-size: 58px; line-height: 1.04; letter-spacing: 0; color: #1a1d24; }}
    .date {{ margin-left: auto; text-align: right; color: #6b7280; font-size: 25px; font-weight: 750; }}
    .map-wrap {{
      position: absolute;
      inset: 0;
      z-index: 0;
      margin: 0;
      height: auto;
      border-radius: 0;
      overflow: hidden;
      border: 0;
      box-shadow: none;
      background: #f4f7fa;
    }}
    #map {{ position: absolute; inset: 0; }}
    .map-glass {{
      position: absolute; inset: 0; pointer-events: none;
      background:
        linear-gradient(180deg, rgba(246,249,252,.84) 0%, rgba(246,249,252,.32) 9%, rgba(246,249,252,.02) 24%, rgba(246,249,252,.02) 76%, rgba(246,249,252,.62) 92%, rgba(246,249,252,.92) 100%),
        linear-gradient(90deg, rgba(246,249,252,.50) 0%, rgba(246,249,252,.05) 20%, rgba(246,249,252,.04) 78%, rgba(246,249,252,.44) 100%);
    }}
    .map-badge {{
      position: absolute; left: 48px; top: 184px;
      padding: 12px 16px; border-radius: 14px;
      background: rgba(255,255,255,.92); backdrop-filter: blur(10px);
      border: 1px solid rgba(20, 28, 40, 0.08);
      font-size: 19px; font-weight: 750; color: rgba(24, 28, 36, 0.62);
      box-shadow: 0 10px 24px rgba(28,38,58,.10);
    }}
    .leaflet-control-container {{ display: none; }}
    .stats {{
      position: relative;
      z-index: 2;
      display: grid; grid-template-columns: repeat(5, minmax(0, 1fr)); gap: 0;
      margin-top: 1500px;
      border: 1px solid rgba(20, 28, 40, 0.08);
      border-radius: 18px;
      background: rgba(255,255,255,.88);
      backdrop-filter: blur(10px);
      box-shadow: 0 18px 46px rgba(28, 38, 58, 0.14);
      overflow: hidden;
    }}
    .stat {{
      min-height: 126px;
      padding: 22px 20px;
      border-right: 1px solid rgba(20, 28, 40, 0.08);
      background: transparent;
    }}
    .stat:last-child {{ border-right: 0; }}
    .stat span {{ display: block; color: #ff5e3a; font-size: 18px; font-weight: 800; letter-spacing: .04em; }}
    .stat strong {{ display: block; margin-top: 12px; color: #1a1d24; font-size: 34px; line-height: 1; font-weight: 850; letter-spacing: 0; }}
    .stat small {{ display: block; margin-top: 8px; color: #6b7280; font-size: 17px; font-weight: 650; }}
    .charts {{
      position: relative;
      z-index: 2;
      margin-top: 28px;
      padding: 0;
      border-radius: 18px;
      background: rgba(255,255,255,.92);
      backdrop-filter: blur(10px);
      border: 1px solid rgba(20, 28, 40, 0.08);
      box-shadow: 0 18px 48px rgba(28, 38, 58, 0.14);
      overflow: hidden;
    }}
    .charts-title {{
      display: flex; align-items: baseline; justify-content: space-between;
      min-height: 70px;
      padding: 22px 26px 14px;
      border-bottom: 1px solid rgba(20, 28, 40, 0.06);
    }}
    .charts-title strong {{ color: rgba(24, 28, 36, 0.88); font-size: 28px; font-weight: 850; }}
    .charts-title span {{ color: rgba(24, 28, 36, 0.46); font-size: 18px; font-weight: 650; }}
    .chart {{
      height: 168px;
      padding: 0 8px;
      border-top: 1px solid rgba(20, 28, 40, 0.06);
    }}
    .chart:first-of-type {{ border-top: 0; }}
    .chart svg {{ width: 100%; height: 100%; display: block; }}
    .footer {{
      position: relative;
      z-index: 2;
      display: flex;
      flex-direction: row;
      align-items: center;
      justify-content: flex-start;
      gap: 28px;
      width: calc(100% + 96px);
      margin: 36px -48px 0;
      min-height: 360px;
      padding: 34px 64px 40px;
      border-top: 1px solid rgba(20, 28, 40, 0.08);
      border-radius: 0;
      background: #ffffff;
      box-shadow: 0 -14px 40px rgba(28, 38, 58, 0.08);
    }}
    .qr {{
      width: 184px; height: 184px; padding: 12px; border-radius: 24px;
      background: #fff;
      border: 1px solid rgba(20, 28, 40, 0.08);
      box-shadow: 0 12px 28px rgba(28, 38, 58, 0.10);
    }}
    .qr svg {{ width: 100%; height: 100%; display: block; }}
    .footer-text {{ min-width: 0; text-align: left; }}
    .footer-text strong {{ display: block; color: #1a1d24; font-size: 32px; line-height: 1.2; }}
    .footer-text span {{ display: block; margin-top: 8px; color: #6b7280; font-size: 22px; font-weight: 650; }}
    .signature {{ margin-left: auto; color: #ff5e3a; font-size: 22px; font-weight: 900; letter-spacing: 3px; white-space: nowrap; }}
  </style>
</head>
<body>
  <main class="card">
    <section class="map-wrap">
      <div id="map"></div>
      <div class="map-glass"></div>
      <div class="map-badge">Leaflet / CartoDB Positron · {route.get("city") or run.get("location") or ""}</div>
    </section>
    <header class="header">
      <img class="avatar" src="../assets/profile.png" alt="">
      <div>
        <p class="eyebrow">Today Run</p>
        <h1>{run.get("title", "今日跑步")}</h1>
      </div>
      <div class="date">{run.get("date", "")}<br>{run.get("location", "")}</div>
    </header>

    <section class="stats">
      <div class="stat"><span>平均心率</span><strong>{run.get("avgHeartRate") or "--"}</strong><small>bpm</small></div>
      <div class="stat"><span>平均功率</span><strong>{round(run.get("avgPower") or 0)}</strong><small>W</small></div>
      <div class="stat"><span>平均配速</span><strong>{run.get("pace")}</strong><small>/km</small></div>
      <div class="stat"><span>用时</span><strong>{run.get("duration")}</strong><small>hh:mm:ss</small></div>
      <div class="stat"><span>累计爬升</span><strong>{round(route.get("elevationGain") or 0)}</strong><small>m</small></div>
    </section>

    <section class="charts">
      <div class="charts-title">
        <strong>详细折线图</strong>
        <span>配速 · 爬升 · 心率</span>
      </div>
      <div class="chart" id="paceChart"></div>
      <div class="chart" id="elevationChart"></div>
      <div class="chart" id="hrChart"></div>
    </section>

    <footer class="footer">
      <div class="qr" id="qr"></div>
      <div class="footer-text">
        <strong>扫码查看我的跑步档案</strong>
        <span>{SITE_URL}</span>
      </div>
      <div class="signature">RUN LOG</div>
    </footer>
  </main>

  <script>{leaflet_js.read_text(encoding="utf-8")}</script>
  <script>{qr_js.read_text(encoding="utf-8")}</script>
  <script>
    const routeCoords = {format_js(route_coords)};
    const chartData = {format_js(chart_data)};
    const siteUrl = {format_js(SITE_URL)};

    const map = L.map('map', {{
      zoomControl: false,
      attributionControl: false,
      dragging: false,
      scrollWheelZoom: false,
      doubleClickZoom: false,
      boxZoom: false,
      keyboard: false,
      tap: false,
    }});
    L.tileLayer('https://{{s}}.basemaps.cartocdn.com/light_all/{{z}}/{{x}}/{{y}}{{r}}.png', {{
      subdomains: 'abcd',
      maxZoom: 19,
      crossOrigin: true,
    }}).addTo(map);
    const latlngs = routeCoords.map(([lon, lat]) => [lat, lon]).filter(([lat, lon]) => Number.isFinite(lat) && Number.isFinite(lon));
    const shadow = L.polyline(latlngs, {{ color: '#ffffff', weight: 13, opacity: .92, lineCap: 'round', lineJoin: 'round' }}).addTo(map);
    const line = L.polyline(latlngs, {{ color: '#ff5e3a', weight: 7, opacity: .96, lineCap: 'round', lineJoin: 'round' }}).addTo(map);
    L.circleMarker(latlngs[0], {{ radius: 9, color: '#ffffff', weight: 4, fillColor: '#27b696', fillOpacity: 1 }}).addTo(map);
    L.circleMarker(latlngs[latlngs.length - 1], {{ radius: 9, color: '#ffffff', weight: 4, fillColor: '#e94e2f', fillOpacity: 1 }}).addTo(map);
    map.fitBounds(line.getBounds(), {{
      paddingTopLeft: [130, 230],
      paddingBottomRight: [130, 1250],
    }});

    function fmtPace(v) {{
      if (!Number.isFinite(v)) return '--';
      const minutes = Math.floor(v);
      const seconds = Math.round((v - minutes) * 60);
      return `${{String(minutes).padStart(2, '0')}}:${{String(seconds).padStart(2, '0')}}`;
    }}

    function fmtElapsed(seconds) {{
      if (!Number.isFinite(seconds)) return '';
      const total = Math.max(0, Math.round(seconds));
      const h = Math.floor(total / 3600);
      const m = Math.floor((total % 3600) / 60);
      return h > 0 ? `${{h}}:${{String(m).padStart(2, '0')}}` : `${{m}}分`;
    }}

    function renderChart(id, values, labels, color, unit, formatter, reverseY = false) {{
      const width = 944, height = 168, padL = 54, padR = 104, padT = 26, padB = 34;
      const pts = values.map((v, i) => [i, v]).filter(([, v]) => Number.isFinite(v));
      const min = Math.min(...pts.map(([, v]) => v));
      const max = Math.max(...pts.map(([, v]) => v));
      const span = Math.max(max - min, 1);
      const x = i => padL + (i / Math.max(values.length - 1, 1)) * (width - padL - padR);
      const y = v => padT + (reverseY ? (v - min) : (max - v)) / span * (height - padT - padB);
      const segments = [];
      let current = [];
      values.forEach((v, i) => {{
        if (!Number.isFinite(v)) {{
          if (current.length) segments.push(current);
          current = [];
          return;
        }}
        current.push([i, v]);
      }});
      if (current.length) segments.push(current);
      const pathFor = segment => segment.map(([i, v], index) => `${{index ? 'L' : 'M'}}${{x(i).toFixed(1)}},${{y(v).toFixed(1)}}`).join('');
      const ticks = [min, (min + max) / 2, max];
      const tick = formatter || (v => `${{Math.round(v)}}${{unit}}`);
      const xTickIndexes = [0, Math.round((values.length - 1) / 2), values.length - 1];
      const tickLines = ticks.map(v => `
        <line x1="${{padL}}" y1="${{y(v).toFixed(1)}}" x2="${{width - padR}}" y2="${{y(v).toFixed(1)}}" stroke="rgba(20,28,40,.08)" stroke-dasharray="${{v === min || v === max ? '0' : '8 10'}}"/>
      `).join('');
      const yTicks = ticks.map(v => `
        <line x1="${{width - padR}}" y1="${{y(v).toFixed(1)}}" x2="${{width - padR + 7}}" y2="${{y(v).toFixed(1)}}" stroke="rgba(20,28,40,.22)" stroke-width="1"/>
        <text x="${{width - 12}}" y="${{(y(v) + 5).toFixed(1)}}" text-anchor="end" fill="rgba(24,28,36,.46)" font-size="15" font-weight="700">${{tick(v)}}</text>
      `).join('');
      const xTicks = xTickIndexes.map(i => `
        <line x1="${{x(i).toFixed(1)}}" y1="${{padT}}" x2="${{x(i).toFixed(1)}}" y2="${{height - padB}}" stroke="rgba(20,28,40,.055)" stroke-width="1"/>
        <line x1="${{x(i).toFixed(1)}}" y1="${{height - padB}}" x2="${{x(i).toFixed(1)}}" y2="${{height - padB + 7}}" stroke="rgba(20,28,40,.18)" stroke-width="1"/>
        <text x="${{x(i).toFixed(1)}}" y="${{height - 7}}" text-anchor="middle" fill="rgba(24,28,36,.38)" font-size="13" font-weight="650">${{fmtElapsed(labels?.[i])}}</text>
      `).join('');
      const baselineY = height - padB;
      const areaPaths = segments.map(segment => {{
        if (segment.length < 2) return '';
        const first = segment[0][0];
        const last = segment[segment.length - 1][0];
        return '<path d="' + pathFor(segment) + ' L' + x(last).toFixed(1) + ',' + baselineY + ' L' + x(first).toFixed(1) + ',' + baselineY + ' Z" fill="url(#' + id + 'Fill)"/>';
      }}).join('');
      const linePaths = segments.map(segment => `<path d="${{pathFor(segment)}}" fill="none" stroke="${{color}}" stroke-width="2.8" stroke-linecap="round" stroke-linejoin="round"/>`).join('');
      document.getElementById(id).innerHTML = `
        <svg viewBox="0 0 ${{width}} ${{height}}" xmlns="http://www.w3.org/2000/svg">
          <defs>
            <linearGradient id="${{id}}Fill" x1="0" y1="0" x2="0" y2="1">
              <stop offset="0" stop-color="${{color}}" stop-opacity=".16"/>
              <stop offset="1" stop-color="${{color}}" stop-opacity="0"/>
            </linearGradient>
          </defs>
          ${{tickLines}}
          ${{xTicks}}
          <line x1="${{padL}}" y1="${{padT}}" x2="${{padL}}" y2="${{height - padB}}" stroke="rgba(20,28,40,.16)" stroke-width="1"/>
          <line x1="${{padL}}" y1="${{height - padB}}" x2="${{width - padR}}" y2="${{height - padB}}" stroke="rgba(20,28,40,.16)" stroke-width="1"/>
          <line x1="${{width - padR}}" y1="${{padT}}" x2="${{width - padR}}" y2="${{height - padB}}" stroke="rgba(20,28,40,.18)" stroke-width="1"/>
          ${{yTicks}}
          ${{areaPaths}}
          ${{linePaths}}
        </svg>`;
    }}

    renderChart('paceChart', chartData.pace, chartData.elapsed, '#1a73e8', '/km', v => fmtPace(v) + '/km', true);
    renderChart('elevationChart', chartData.elevation, chartData.elapsed, '#e87a20', 'm', v => Math.round(v) + 'm');
    renderChart('hrChart', chartData.heartRate, chartData.elapsed, '#ff5e3a', ' bpm', v => Math.round(v) + 'bpm');

    const qr = qrcode(0, 'M');
    qr.addData(siteUrl);
    qr.make();
    document.getElementById('qr').innerHTML = qr.createSvgTag(5, 0).replace('<svg', '<svg aria-label="网站二维码"');
  </script>
</body>
</html>"""


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--date", default=None)
    parser.add_argument("--leaflet-css", required=True)
    parser.add_argument("--leaflet-js", required=True)
    parser.add_argument("--qr-js", required=True)
    parser.add_argument("--output-dir", default="share")
    parser.add_argument("--chrome", default="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
    args = parser.parse_args()

    run = load_today_run(args.date)
    route_id = run.get("routeId")
    if not route_id:
        raise ValueError("Selected run has no routeId")
    route = extract_json_from_assignment(PROJECT_ROOT / "routes" / f"{route_id}.js")

    out_dir = PROJECT_ROOT / args.output_dir
    out_dir.mkdir(parents=True, exist_ok=True)
    html_path = out_dir / "today-run-share.html"
    png_path = out_dir / "today-run-share.png"
    html_path.write_text(
        make_html(
            run,
            route,
            Path(args.leaflet_css),
            Path(args.leaflet_js),
            Path(args.qr_js),
        ),
        encoding="utf-8",
    )

    chrome = Path(args.chrome)
    if not chrome.exists():
        chrome = Path(shutil.which("google-chrome") or shutil.which("chromium") or "")
    if not chrome.exists():
        raise ValueError("Chrome/Chromium was not found")

    subprocess.run(
        [
            str(chrome),
            "--headless=new",
            "--disable-gpu",
            "--no-sandbox",
            "--hide-scrollbars",
            "--window-size=1080,2800",
            "--virtual-time-budget=9000",
            f"--screenshot={png_path}",
            html_path.resolve().as_uri(),
        ],
        check=True,
    )
    print(f"Wrote {png_path}")


if __name__ == "__main__":
    main()
