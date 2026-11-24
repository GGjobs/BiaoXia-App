#!/usr/bin/env python3
"""Explicit T12 holdout run; invoke only after simulator testing is authorized.

Build-for-testing must have completed in tmp/t12-validation/DerivedData.
No secrets are read or injected. Unique artifacts preserve the first evaluation.
"""
import datetime
import pathlib
import plistlib
import subprocess
import uuid

root = pathlib.Path(__file__).resolve().parents[1]
products = root / 'tmp/t12-validation/DerivedData/Build/Products'
sources = list(products.glob('BiaoXia_*.xctestrun'))
if len(sources) != 1:
    raise SystemExit('Build T12 for testing first; expected exactly one BiaoXia xctestrun')
config = plistlib.loads(sources[0].read_bytes())
for configuration in config['TestConfigurations']:
    for target in configuration['TestTargets']:
        target.setdefault('EnvironmentVariables', {})['T12_ACCEPTANCE'] = '1'
run_id = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ') + '-' + uuid.uuid4().hex[:8]
temporary = products / f'T12-{run_id}.xctestrun'
output = root / 'tmp/t12-validation' / run_id
output.mkdir(parents=True, exist_ok=False)
try:
    with temporary.open('xb') as stream:
        plistlib.dump(config, stream)
    with (output / 'test.log').open('x') as log:
        result = subprocess.run([
            'xcodebuild', 'test-without-building', '-xctestrun', str(temporary),
            '-destination', 'platform=iOS Simulator,name=iPhone 18 Pro Max',
            '-parallel-testing-enabled', 'NO', '-collect-test-diagnostics', 'never',
            '-only-testing:BiaoXiaTests/T12AcceptanceTests',
            '-resultBundlePath', str(output / 'acceptance.xcresult')
        ], stdout=log, stderr=subprocess.STDOUT)
    print(f'T12 exit {result.returncode}; evidence: {output}')
    raise SystemExit(result.returncode)
finally:
    temporary.unlink(missing_ok=True)
