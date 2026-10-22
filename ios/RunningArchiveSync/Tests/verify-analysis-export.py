"""Independent reader checks the model-facing contract, without production imports."""
import csv
import io
import json
from pathlib import Path
import sys
import zipfile
import xml.etree.ElementTree as ET
import datetime

root = Path(sys.argv[1])
NS = {'s': 'http://schemas.openxmlformats.org/spreadsheetml/2006/main'}

def read_book(data):
    with zipfile.ZipFile(data) as book:
        assert book.testzip() is None
        for name in book.namelist():
            if name.endswith(('.xml', '.rels')):
                ET.fromstring(book.read(name))
        workbook = ET.fromstring(book.read('xl/workbook.xml'))
        names = [s.attrib['name'] for s in workbook.findall('s:sheets/s:sheet', NS)]
        sheets = {}
        for i, name in enumerate(names, 1):
            xml = ET.fromstring(book.read(f'xl/worksheets/sheet{i}.xml'))
            rows = []
            for row in xml.findall('s:sheetData/s:row', NS):
                cells = {}
                for cell in row.findall('s:c', NS):
                    col = ''.join(c for c in cell.attrib['r'] if c.isalpha())
                    cells[col] = ''.join(cell.itertext()) if cell.attrib.get('t') == 'inlineStr' else float(cell.find('s:v', NS).text)
                    assert cell.find('s:f', NS) is None, 'snapshot cells must not become formulas'
                rows.append(cells)
            headers = rows[0]
            assert len(set(headers.values())) == len(headers), 'unique model-readable column names'
            assert xml.find('s:sheetViews/s:sheetView/s:pane', NS).attrib['state'] == 'frozen'
            sheets[name] = [{headers[k]: v for k, v in row.items()} for row in rows[1:]]
        return sheets

def near(a, b):
    assert abs(a - b) < 1e-6, (a, b)

with zipfile.ZipFile(root / 'full/跑步分析完整数据包.zip') as bundle:
    assert bundle.testzip() is None
    manifest = json.loads(bundle.read('manifest.json'))
    assert manifest['schema_version'] == 2
    assert manifest['activity_count'] == 4 and manifest['failed_count'] == 1 and manifest['partial_metric_failures'] == 1
    assert set(manifest['files']) | {'manifest.json'} == set(bundle.namelist())
    sheets = read_book(io.BytesIO(bundle.read('跑步分析.xlsx')))
    first, failed, missing, partial = sheets['逐次跑步']
    assert first['距离（km）'] == 2.5 and first['运动计时（s）'] == 500.25 and first['总经过时间（s）'] == 540.25
    near(first['暂停差值（s）'], 40)
    near(first['平均配速（s/km）'], 200.1)
    near(first['平均心率（bpm）'], 152)
    near(first['最高心率（bpm）'], 160)  # Other device's 200 bpm not mixed in.
    assert first['心率均值来源'] == '采样区间加权估算'
    assert first['平均步频（步/min）'] == 170  # Official whole-workout value retained.
    near(first['平均步长（m）'], 1.1)
    assert first['平均触地时间（ms）'] == 250 and first['平均垂直振幅（cm）'] == 8
    assert '累计爬升（m）' not in first, 'missing elevation is not zero'
    assert '距离（km）' not in missing and '平均配速（s/km）' not in missing
    assert '读取失败' in failed['读取状态'] and failed['运动计时（s）'] == 1600
    assert '部分指标读取失败' in partial['读取状态'] and partial['平均功率（W）'] == 230
    local = datetime.datetime(1899, 12, 30) + datetime.timedelta(days=first['开始时间（本地）'])
    assert local == datetime.datetime(2026, 10, 1, 7)
    split = sheets['公里分段']
    assert len(split) == 3
    near(split[0]['经过时间（s）'], 200)
    near(split[0]['运动计时（s，事件校验后）'], 160)
    near(split[0]['平均心率（bpm）'], 140)
    near(split[1]['平均心率（bpm）'], 160)
    near(split[-1]['GPS 距离（km）'], .5)
    near(split[-1]['平均步频（步/min）'], 180)
    near(split[0]['海拔变化（m，GPS估算）'], 10)
    process = [r for r in sheets['过程数据'] if r['记录 ID'] == 'run-1']
    assert len(process) == 19
    near(process[0]['平均功率（W）'], 230.5)
    near(process[0]['功率覆盖比例（0–1，估算）'], 1/3)
    near(process[-1]['区间长度（s）'], .25)
    assert '平均心率（bpm）' not in process[-1]
    distribution = [r for r in sheets['心率分布'] if r['记录 ID'] == 'run-1']
    near(sum(r['支持时长（s，估算）'] for r in distribution), 540.25)
    near(next(r for r in distribution if r['心率范围（bpm）'] == '未覆盖')['支持时长（s，估算）'],40.25)
    assert len(sheets['体能参考']) == 1 and sheets['体能参考'][0]['数值'] == 52.3
    assert len(sheets['目标赛事']) == 1 and sheets['训练计划'][0]['关联记录 ID'] == 'run-1'
    apple = [r for r in sheets['Apple心率区间'] if r['记录 ID'] == 'run-1']
    assert len(apple) == 5 and sum(r['区间时长（s）'] for r in apple) == 540.25
    assert all(r['使用口径'] == 'recorded_workout' and r['配置来源'] == 'user' for r in apple)
    assert apple[0].get('心率下界（bpm）') is None and apple[-1].get('心率上界（bpm）') is None
    load_rows = [r for r in sheets['训练指标'] if r['记录 ID'] == 'run-1' and r['指标'] == '心率负荷']
    assert load_rows[0]['参考最大心率'] == 180 and load_rows[0]['是否采用估算依据'] == '是'
    quality = next(r for r in sheets['指标可用性'] if r['记录 ID'] == 'partial' and r['指标'] == '触地时间')
    assert '读取失败' in quality['读取状态']
    assert '覆盖比例（0–1，估算）' not in quality
    samples = list(csv.DictReader(io.StringIO(bundle.read(first['原始采样 CSV']).decode('utf-8-sig'))))
    assert len(samples) == 9, 'raw intervals retained without endpoint expansion'
    assert len([s for s in samples if s['metric'] == 'heart_rate']) == 3, 'raw archive retains alternative source'
    assert float(samples[-1]['value']) == 8
    coords = list(csv.DictReader(io.StringIO(bundle.read(first['路线 CSV']).decode('utf-8-sig'))))
    assert len(coords) == 251 and float(coords[-1]['elapsed_s']) == 500
    assert len(ET.fromstring(bundle.read(first['路线 GPX / 状态'])).findall('.//{*}trkpt')) == 251
    summary = list(csv.DictReader(io.StringIO(bundle.read('逐次跑步.csv').decode('utf-8-sig'))))
    assert summary[0]['开始时间（UTC）'].endswith('Z')
    assert all(b'THIS_PRIVATE_NOTE_MUST_NOT_BE_EXPORTED' not in bundle.read(n) for n in bundle.namelist())
    (root / 'sample.xlsx').write_bytes(bundle.read('跑步分析.xlsx'))

analysis = read_book(root / 'analysis/跑步分析.xlsx')
expected = {'逐次跑步','公里分段','过程数据','心率分布','体能参考','指标可用性','训练指标','Apple心率区间','导出说明'}
assert set(analysis) == expected
for sheet in ['公里分段','心率分布','体能参考','训练指标','Apple心率区间']:
    comparable = [r for r in sheets[sheet] if r.get('记录 ID', 'run-1') == 'run-1']
    assert analysis[sheet] == comparable, f'{sheet} has the same analysis in both formats'
assert analysis['过程数据'] == process
assert '主观强度 RPE' not in analysis['逐次跑步'][0] and '手记' not in analysis['逐次跑步'][0]
assert '周期汇总' not in analysis
near(analysis['逐次跑步'][0]['GPS 点数'],251)
print('Independent workbook/ZIP/CSV contract passed: rich analysis parity, weighted metrics, missing values, pauses, sources, raw GPX and objective-only content')
