#!/usr/bin/env python3
"""Run explicitly authorized fictional live UI tests without printing credentials."""
import os
from pathlib import Path
import plistlib
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
device = sys.argv[1]
products = Path(sys.argv[2]) if len(sys.argv) > 2 else Path('/tmp/biaoxia-repair-build/Build/Products')
values = {}
for line in (root / 'Secrets.xcconfig').read_text().splitlines():
    if '=' in line and not line.lstrip().startswith('//'):
        key, value = line.split('=', 1)
        values[key.strip()] = value.strip().replace('$()', '')
source = next(products.glob('BiaoXia_*.xctestrun'))
data = plistlib.loads(source.read_bytes())
for configuration in data['TestConfigurations']:
    for target in configuration['TestTargets']:
        target.setdefault('EnvironmentVariables', {}).update({
            'T15_LIVE_RELAY': '1', 'T11B_LIVE_RELAY': '1',
            'BIAOXIA_RELAY_BASE_URL': values['RELAY_BASE_URL'],
            'BIAOXIA_RELAY_CLIENT_TOKEN': values['RELAY_CLIENT_TOKEN'],
        })
run = source.with_name('T15-live.xctestrun')
fd = os.open(run, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(fd, 'wb') as stream:
    plistlib.dump(data, stream)
methods = sys.argv[3:] or [
    'testReviewedFieldsReachLiveRelay',
    'testSelectedSnippetsReachLiveRelayAndExportPDF',
    'testSelectedSnippetsReachLiveRelayAndExportWord',
]
allowed = {'testReviewedFieldsReachLiveRelay', 'testSelectedSnippetsReachLiveRelayAndExportPDF', 'testSelectedSnippetsReachLiveRelayAndExportWord'}
if not set(methods) <= allowed:
    run.unlink(missing_ok=True)
    raise SystemExit('Only audited fictional live cases allowed')
try:
    with open('/tmp/biaoxia-repair-live-ui.log', 'w') as log:
        status = subprocess.call([
            'xcodebuild', 'test-without-building', '-xctestrun', str(run),
            '-destination', f'platform=iOS Simulator,id={device}',
            '-parallel-testing-enabled', 'NO', '-collect-test-diagnostics', 'never',
            *[f'-only-testing:BiaoXiaUITests/MainFlowUITests/{method}' for method in methods],
        ], stdout=log, stderr=subprocess.STDOUT)
    print('Live UI exit:', status)
finally:
    run.unlink(missing_ok=True)
sys.exit(status)
