#!/usr/bin/env python3
"""T01/T12 only: verify reproducibility and freeze guards using temporary copies."""
import importlib.util
import json
from pathlib import Path
import shutil
import tempfile
import subprocess
import sys
sys.dont_write_bytecode = True
root=Path(__file__).resolve().parents[3]
spec=importlib.util.spec_from_file_location('validator',root/'Scripts/validate_t01_assets.py')
v=importlib.util.module_from_spec(spec); spec.loader.exec_module(v)
corpus=root/'TestAssets/GeneralForms'; m=v.read(corpus/'manifest.json')
repro_dir=tempfile.TemporaryDirectory(prefix='biaoxia-t01-repro-')
repro=Path(repro_dir.name)/'corpus'
subprocess.run([sys.executable,str(corpus/'authoring/generate_assets.py'),'--output',str(repro)],check=True)
for s in m['samples']:
    assert v.digest(repro/s['file'])==s['sha256']
    assert v.digest(repro/s['answer'])==s['answerSha256']
repro_dir.cleanup()
results=[{'check':'reproducible_document_and_answer_fingerprints','status':'passed','count':36}]
for key in ['file','answer']:
    with tempfile.TemporaryDirectory(prefix='biaoxia-t01-guard-') as d:
        target=Path(d)/'corpus'; shutil.copytree(corpus,target)
        path=target/next(s for s in m['samples'] if s['split']=='independent')[key]
        with path.open('ab') as stream: stream.write(b'\nTAMPER_TEST')
        try: v.validate(target)
        except ValueError as e: assert 'fingerprint mismatch' in str(e)
        else: raise AssertionError('Holdout tampering accepted')
    results.append({'check':'reject_independent_'+key+'_tampering','status':'passed'})
with tempfile.TemporaryDirectory(prefix='biaoxia-t01-guard-') as d:
    target=Path(d)/'corpus'; shutil.copytree(corpus,target)
    manifest=v.read(target/'manifest.json'); manifest['denominators']['independent/PDF']['basicMatch']=1
    (target/'manifest.json').write_text(json.dumps(manifest))
    try: v.validate(target)
    except ValueError as e: assert 'Manifest changed' in str(e)
    else: raise AssertionError('Denominator changed silently')
results.append({'check':'reject_frozen_denominator_change','status':'passed'})

def reseal_debug_change(target, manifest):
    (target/'manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n')
    freeze=v.read(target/'independent/FREEZE.json')
    freeze['manifestSha256']=v.digest(target/'manifest.json')
    (target/'independent/FREEZE.json').write_text(json.dumps(freeze,ensure_ascii=False,indent=2)+'\n')
    (target/'independent/FREEZE.sha256').write_text(v.digest(target/'independent/FREEZE.json')+'  FREEZE.json\n')

with tempfile.TemporaryDirectory(prefix='biaoxia-t01-guard-') as d:
    target=Path(d)/'corpus'; shutil.copytree(corpus,target)
    manifest=v.read(target/'manifest.json'); sample=next(s for s in manifest['samples'] if s['id']=='F01-pdf')
    answer=v.read(target/sample['answer']); answer['checkpoints'][0].pop('result')
    (target/sample['answer']).write_text(json.dumps(answer,ensure_ascii=False,indent=2)+'\n')
    sample['answerSha256']=v.digest(target/sample['answer']); reseal_debug_change(target,manifest)
    try: v.validate(target,include_independent=True)
    except ValueError as e: assert 'incomplete checkpoint' in str(e)
    else: raise AssertionError('Incomplete checkpoint accepted')
results.append({'check':'reject_incomplete_checkpoint','status':'passed'})

with tempfile.TemporaryDirectory(prefix='biaoxia-t01-guard-') as d:
    target=Path(d)/'corpus'; shutil.copytree(corpus,target)
    manifest=v.read(target/'manifest.json'); sample=next(s for s in manifest['samples'] if s['id']=='B09')
    answer=v.read(target/sample['answer']); next(f for f in answer['fields'] if f['standard']=='fullName')['label']='申请人姓名'
    (target/sample['answer']).write_text(json.dumps(answer,ensure_ascii=False,indent=2)+'\n')
    sample['answerSha256']=v.digest(target/sample['answer']); reseal_debug_change(target,manifest)
    try: v.validate(target,include_independent=True)
    except ValueError as e: assert 'B09 synonym stimulus missing' in str(e)
    else: raise AssertionError('Missing B09 synonym stimulus accepted')
results.append({'check':'reject_missing_b09_synonym_stimulus','status':'passed'})

# The default validation must not decode the holdout answers.
original=v.read
def guarded(path):
    assert '/independent/answers/' not in str(path),'Default decoded holdout answers'
    return original(path)
v.read=guarded
assert v.validate(corpus)['samplesDecoded']==28
results.append({'check':'default_does_not_decode_holdout_answers','status':'passed'})
run=subprocess.run([sys.executable,str(corpus/'authoring/generate_assets.py'),'--output',str(corpus)],capture_output=True,text=True)
assert run.returncode==2 and 'Existing corpus refused' in run.stderr
results.append({'check':'generator_refuses_existing_corpus','status':'passed'})
(corpus/'evidence/guards.json').write_text(json.dumps(results,indent=2)+'\n')
print(json.dumps(results,indent=2))
