#!/usr/bin/env python3
"""Run T12 unit/UI/live regression after explicit simulator authorization.

Live mode reuses the existing ignored Relay configuration. Credentials are only
in a mode-0600 temporary test configuration and are removed after the run.
"""
import argparse
import datetime
import json
import os
import pathlib
import plistlib
import subprocess
import sys
import uuid

parser = argparse.ArgumentParser()
parser.add_argument('suite', choices=['unit', 'ui', 'live', 't16', 'ai-fill'])
parser.add_argument('--only', help='run only selected tests whose identifier contains this text')
args = parser.parse_args()
root = pathlib.Path(__file__).resolve().parents[1]
products = root / 'tmp/t12-validation/DerivedData/Build/Products'
# SDK upgrades leave older xctestrun files beside the new one; use the latest build.
candidates = sorted(products.glob('BiaoXia_*.xctestrun'), key=lambda path: path.stat().st_mtime)
if not candidates:
    raise SystemExit('No xctestrun found; run build-for-testing first')
source = candidates[-1]
print(f'Using {source.name}')
config = plistlib.loads(source.read_bytes())

devices = json.loads(subprocess.check_output(
    ['xcrun', 'simctl', 'list', 'devices', 'available', '--json'], text=True
))['devices']
matches = [(runtime, device) for runtime, entries in devices.items() for device in entries
           if device['name'] == 'iPhone 18 Pro Max' and device.get('isAvailable', True)]
if not matches:
    raise SystemExit('No available iPhone 18 Pro Max simulator')
runtime, simulator = max(matches, key=lambda match: match[0])
device_id = simulator['udid']
if simulator['state'] != 'Booted':
    subprocess.run(['xcrun', 'simctl', 'boot', device_id], check=True)
subprocess.run(['xcrun', 'simctl', 'bootstatus', device_id, '-b'], check=True)
if args.suite in {'ui', 'live', 't16', 'ai-fill'}:
    subprocess.run([sys.executable, str(root / 'Scripts/prepare-t11b-ui.py'), device_id], check=True)
print(f'Using iPhone 18 Pro Max ({runtime}, {device_id})')

if args.suite in {'live', 't16', 'ai-fill'}:
    values = {}
    for line in (root / 'Secrets.xcconfig').read_text().splitlines():
        if '=' in line and not line.lstrip().startswith('//'):
            key, value = line.split('=', 1)
            values[key.strip()] = value.strip().replace('$()', '')
    for configuration in config['TestConfigurations']:
        for target in configuration['TestTargets']:
            target.setdefault('EnvironmentVariables', {}).update({
                'T09B_LIVE_RELAY': '1', 'T11B_LIVE_RELAY': '1', 'T15_LIVE_RELAY': '1', 'T16_LIVE_RELAY': '1',
                'BIAOXIA_RELAY_BASE_URL': values['RELAY_BASE_URL'],
                'BIAOXIA_RELAY_CLIENT_TOKEN': values['RELAY_CLIENT_TOKEN']
            })
run = args.suite + '-' + datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ') + '-' + uuid.uuid4().hex[:8]
output = root / 'tmp/t12-validation' / run
output.mkdir(parents=True, exist_ok=False)
temporary = products / f'T12-{run}.xctestrun'
selected = {'unit': ['BiaoXiaTests'], 'ui': ['BiaoXiaUITests'], 'live': [
    'BiaoXiaTests/T09BOutboundPrivacyTests',
    'BiaoXiaTests/T11BWorkflowTests/userReviewMatchesActualHTTPAfterFailureAndReopen()',
    'BiaoXiaUITests/MainFlowUITests/testReviewedFieldsReachLiveRelay'
], 't16': [
    'BiaoXiaUITests/MainFlowUITests/testT16WholeFormReachesLiveRelayAndExportsPDF',
    'BiaoXiaUITests/MainFlowUITests/testT16WholeFormReachesLiveRelayAndExportsWord',
    'BiaoXiaUITests/MainFlowUITests/testT16SelectAllUsesLiveBatches'
], 'ai-fill': [
    # Whole-form and single-field filling share /v1/plan-form and item permissions.
    'BiaoXiaUITests/MainFlowUITests/testT16WholeFormReachesLiveRelayAndExportsPDF',
    'BiaoXiaUITests/MainFlowUITests/testT16WholeFormReachesLiveRelayAndExportsWord',
    'BiaoXiaUITests/MainFlowUITests/testT16SelectAllUsesLiveBatches',
    'BiaoXiaUITests/MainFlowUITests/testSelectedSnippetsReachLiveRelayAndExportPDF',
    'BiaoXiaUITests/MainFlowUITests/testSelectedSnippetsReachLiveRelayAndExportWord'
]}[args.suite]
if args.only:
    selected = [target for target in selected if args.only in target]
    if not selected:
        raise SystemExit(f'No {args.suite} test matches {args.only}')
try:
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, 'wb') as stream:
        plistlib.dump(config, stream)
    with (output / 'test.log').open('x') as log:
        result = subprocess.run([
            'xcodebuild', 'test-without-building', '-xctestrun', str(temporary),
            '-destination', f'platform=iOS Simulator,id={device_id}',
            '-parallel-testing-enabled', 'NO', '-collect-test-diagnostics', 'never',
            *['-only-testing:' + target for target in selected],
            '-resultBundlePath', str(output / 'result.xcresult')
        ], stdout=log, stderr=subprocess.STDOUT)
    print(f'{args.suite}: exit {result.returncode}; evidence: {output}')
    raise SystemExit(result.returncode)
finally:
    temporary.unlink(missing_ok=True)
