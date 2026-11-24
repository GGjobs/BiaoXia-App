#!/usr/bin/env python3
"""Explicit fictional T16 smoke. Reads existing local config; never prints credentials or responses."""
import json
from pathlib import Path
import sys
import urllib.request
import urllib.error
import uuid
from datetime import datetime, timezone

root = Path(__file__).resolve().parents[1]
values = {}
for line in (root / 'Secrets.xcconfig').read_text().splitlines():
    if '=' in line and not line.lstrip().startswith('//'):
        key, value = line.split('=', 1)
        values[key.strip()] = value.strip().replace('$()', '')
endpoint = values['RELAY_BASE_URL'].rstrip('/')
assert endpoint.startswith('https://')
class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None
opener = urllib.request.build_opener(NoRedirect())

def field(n, label, section='本人', kind='singleLineText', mode='fact', options=None):
    return {'id': f'field-{n}', 'label': label, 'section': section, 'instructions': '', 'kind': kind, 'mode': mode, 'options': options or []}

def send(fields, sources, authorized=True):
    rid = str(uuid.uuid4())
    body = {'schemaVersion': 1, 'requestId': rid, 'fields': fields, 'sources': sources}
    headers = {'Content-Type': 'application/json'}
    if authorized: headers['Authorization'] = 'Bearer ' + values['RELAY_CLIENT_TOKEN']
    req = urllib.request.Request(endpoint + '/v1/plan-form', json.dumps(body, ensure_ascii=False).encode(), headers=headers, method='POST')
    try:
        with opener.open(req, timeout=75) as response:
            return rid, response.status, json.load(response)
    except urllib.error.HTTPError as error:
        return rid, error.code, {}
    except Exception as error:
        return rid, 0, {'transportErrorType': type(error).__name__}

sources = [
    {'id': 'source-1', 'text': '虚构演示材料。本人姓名林晓，父亲姓名林山。数学成绩92分。本人曾参与社区志愿服务，负责活动签到。出生日期2001-01-01。'},
    {'id': 'source-2', 'text': '另一份虚构本人材料：林晓，出生日期2002-02-02。'},
]
fields = [field(1, '姓名'), field(2, '父亲姓名', '父亲'), field(3, '数学成绩'),
          field(4, '参加过志愿服务', kind='singleChoice', options=[{'id': 'option-1', 'label': '是'}, {'id': 'option-2', 'label': '否'}]),
          field(5, '手机号码'), field(6, '出生日期', kind='date'), field(7, '本人签名', mode='manual')]
receipt = {'date': datetime.now(timezone.utc).isoformat(), 'fictionalOnly': True, 'checks': []}
def record(name, rid, status, passed):
    receipt['checks'].append({'name': name, 'requestId': rid, 'statusCode': status, 'passed': bool(passed)})

rid, status, _ = send(fields[:1], sources[:1], False)
record('missing-credential-rejected', rid, status, status == 401)
rid, status, result = send(fields, sources)
by_id = {s['fieldId']: s for s in result.get('suggestions', [])}
record('batch-http', rid, status, status == 200)
if status == 200:
    record('self-and-family', rid, status, by_id.get('field-1', {}).get('answer') == '林晓' and by_id.get('field-2', {}).get('answer') == '林山')
    record('score', rid, status, by_id.get('field-3', {}).get('answer') in ['92', '92分'])
    record('choice', rid, status, by_id.get('field-4', {}).get('selectedOptionIDs') == ['option-1'])
    record('missing-fact', rid, status, by_id.get('field-5', {}).get('status') in ['missing', 'manual'] and by_id.get('field-5', {}).get('answer') is None)
    record('conflicting-date', rid, status, by_id.get('field-6', {}).get('status') == 'conflict' and by_id.get('field-6', {}).get('answer') is None)
    record('signature-manual', rid, status, by_id.get('field-7', {}).get('status') == 'manual')
    def valid_evidence(s):
        return s.get('status') != 'suggested' or bool(s.get('evidence')) and all(any(p['id'] == e['sourceId'] and e['quote'] in p['text'] for p in sources) for e in s['evidence'])
    record('evidence-quotes', rid, status, all(valid_evidence(s) for s in by_id.values()))
    paragraph = field(1, '自我评价', kind='multilineText', mode='generated')
    paragraph['maximumCharacters'] = 150
    rid, status, result = send([paragraph], sources[:1])
    suggestion = next(iter(result.get('suggestions', [])), {})
    record('generated-draft', rid, status, status == 200 and suggestion.get('generated') is True and suggestion.get('status') == 'suggested' and 0 < len(suggestion.get('answer') or '') <= 150)
    # Fictional output is saved only for explicit human fact-checking; never a real user's material.
    receipt['fictionalGeneratedAnswer'] = suggestion.get('answer')
receipt['passed'] = all(c['passed'] for c in receipt['checks'])
output = Path(sys.argv[1])
output.parent.mkdir(parents=True, exist_ok=True)
output.write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + '\n')
print(json.dumps({k: v for k, v in receipt.items() if k != 'fictionalGeneratedAnswer'}, ensure_ascii=False))
sys.exit(0 if receipt['passed'] else 1)
