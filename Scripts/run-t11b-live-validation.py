"""Run only audited T09-B and T11-B live cases; keep credentials out of the app bundle."""
import os,pathlib,plistlib,subprocess,sys
root=pathlib.Path(__file__).resolve().parents[1]
device=sys.argv[1]
run_name=sys.argv[2] if len(sys.argv)>2 else "live-final"
if not run_name.replace("-", "").isalnum(): raise SystemExit("Use an alphanumeric run name")
values={}
for line in (root/'Secrets.xcconfig').read_text().splitlines():
 if '=' in line and not line.lstrip().startswith('//'):
  k,v=line.split('=',1); values[k.strip()]=v.strip().replace('$()','')
source=next((root/'tmp/t11b-validation/DerivedData/Build/Products').glob('BiaoXia_*.xctestrun'))
d=plistlib.loads(source.read_bytes())
for config in d['TestConfigurations']:
 for target in config['TestTargets']:
  target.setdefault('EnvironmentVariables',{}).update({'T09B_LIVE_RELAY':'1','T11B_LIVE_RELAY':'1','BIAOXIA_RELAY_BASE_URL':values['RELAY_BASE_URL'],'BIAOXIA_RELAY_CLIENT_TOKEN':values['RELAY_CLIENT_TOKEN']})
# Keep paths relative to the same products directory; remove credentials after the run.
target=source.with_name('T11B-live.xctestrun')
fd=os.open(target,os.O_WRONLY|os.O_CREAT|os.O_TRUNC,0o600)
with os.fdopen(fd,'wb') as f: plistlib.dump(d,f)
try:
 with open(root/f'tmp/t11b-validation/{run_name}.log','w') as log:
  code=subprocess.call(['xcodebuild','test-without-building','-xctestrun',str(target),'-destination',f'platform=iOS Simulator,id={device}','-parallel-testing-enabled','NO','-collect-test-diagnostics','never','-only-testing:BiaoXiaTests/T09BOutboundPrivacyTests','-only-testing:BiaoXiaTests/T11BWorkflowTests/userReviewMatchesActualHTTPAfterFailureAndReopen()','-only-testing:BiaoXiaUITests/MainFlowUITests/testReviewedFieldsReachLiveRelay','-resultBundlePath',str(root/f'tmp/t11b-validation/{run_name}.xcresult')],stdout=log,stderr=subprocess.STDOUT)
 print('Test process exit:',code)
finally: target.unlink(missing_ok=True)

sys.exit(code)
