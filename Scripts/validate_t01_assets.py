#!/usr/bin/env python3
"""Validate T01 fixture contracts. Default never decodes holdout docs/answers.

This is fixture QA, not a field recognizer or a product evaluation. Counts are
predefined denominators; no product success percentages are fabricated here.
"""
import argparse
import hashlib
from datetime import date
import json
from collections import Counter
from pathlib import Path
from zipfile import ZipFile
from lxml import etree
from pypdf import PdfReader

ROOT=Path(__file__).resolve().parents[1]
NS={'w':'http://schemas.openxmlformats.org/wordprocessingml/2006/main'}

def digest(path): return hashlib.sha256(path.read_bytes()).hexdigest()
def read(path): return json.loads(path.read_text())
def require(condition,message):
    if not condition: raise ValueError(message)

def validate(root,include_independent=False):
    m=read(root/'manifest.json'); samples=m['samples']
    require(m['version']=='1.1.0','Unexpected fixture version')
    require(len(samples)==36,'Expected 36 fixtures')
    require(len({s['id'] for s in samples})==36,'Duplicate sample ID')
    require(Counter(s['kind'] for s in samples)=={'normal':24,'boundary':12},'Normal/boundary counts')
    families={f['id']:f for f in m['families']}
    require(len(families)==12,'Expected 12 families')
    require(len({f['layout'] for f in families.values()})==12,'Topology identity missing')
    require(Counter(f['scenario'] for f in families.values())==dict.fromkeys(['求职','入职','报名','培训','会员','个人申请'],2),'Scenario counts')
    freeze=read(root/'independent/FREEZE.json')
    require(digest(root/'independent/FREEZE.json')==(root/'independent/FREEZE.sha256').read_text().split()[0],'Freeze seal changed')
    require(digest(root/'manifest.json')==freeze['manifestSha256'],'Manifest changed since freeze')
    require(freeze['samples']==[s for s in samples if s['split']=='independent'],'Holdout manifest drift')
    for key in ('file','answers'):
        hashkey='sha256' if key=='file' else 'answersSha256'
        require(digest(ROOT/'TestAssets/GeneralForms'/m['regression'][key])==m['regression'][hashkey],'Fixed regression changed')
    for p in m['profileFiles']: require(digest(root/p['file'])==p['sha256'],'Profile source changed')
    profile=read(root/'profiles/profile.json'); sources={f['id']:f for f in profile['facts']}
    lines=(root/'profiles/fictional_profile.txt').read_text().splitlines()
    for fact in sources.values(): require(lines[fact['line']-1].startswith(fact['standard']+'：'),'Invalid source line')
    decoded=0; checkpoint_count=0
    for fid,family in families.items():
        normal=[s for s in samples if s['family']==fid and s['kind']=='normal']
        require(Counter(s['format'] for s in normal)=={'PDF':1,'DOCX':1},f'{fid}: pair missing')
        require(all(s['split']==family['split'] for s in samples if s['family']==fid),f'{fid}: family leakage')
    require(Counter(s['category'] for s in samples if s['kind']=='boundary')=={'privacy':4,'input_service':4,'matching_layout':4},'Boundary groups')
    for s in samples:
        path=root/s['file']; ar=root/s['answer']
        require(path.suffix.lower()=='.'+s['format'].lower(),f'{s["id"]}: format mismatch')
        require(digest(path)==s['sha256'] and digest(ar)==s['answerSha256'],f'{s["id"]}: fingerprint mismatch')
        if s['split']=='independent' and not include_independent: continue
        decoded+=1; a=read(ar); fields=a['fields']
        require(a['sample']==s['id'] and len(fields)==s['standardFieldCount'],f'{s["id"]}: answer count mismatch')
        require(len({f['id'] for f in fields})==len(fields),f'{s["id"]}: duplicate field')
        if s['kind']=='normal':
            require(sum(f['basicEligible'] for f in fields)==s['basicMatchDenominator'],'Basic denominator mismatch')
        checkpoints=a['checkpoints']
        require(len({c.get('id') for c in checkpoints})==len(checkpoints),f'{s["id"]}: duplicate checkpoint')
        for checkpoint in checkpoints:
            require(set(('id','expected','result'))<=set(checkpoint),f'{s["id"]}: incomplete checkpoint')
            require(checkpoint['id'] and checkpoint['expected'],f'{s["id"]}: empty checkpoint definition')
            require(checkpoint['result'] in ('pending','passed','failed'),f'{s["id"]}: invalid checkpoint result')
        checkpoint_count+=len(checkpoints)
        if s['format']=='PDF':
            reader=PdfReader(path); require(not reader.is_encrypted,'Unexpected encrypted PDF')
            widgets=reader.get_fields() or {}
        else:
            with ZipFile(path) as z:
                require(z.testzip() is None,'Corrupt DOCX member')
                xml=etree.fromstring(z.read('word/document.xml'))
                settings=etree.fromstring(z.read('word/settings.xml'))
                for name in z.namelist():
                    if name.endswith(('.xml','.rels')): etree.fromstring(z.read(name))
                if s['id']=='B02':
                    require(xml.xpath('//w:vanish',namespaces=NS),'Hidden run missing')
                    require('word/comments.xml' in z.namelist(),'DOCX comments missing')
                if s['id']=='B04': require(xml.xpath('//w:ins',namespaces=NS),'Revision missing')
                if s['id']=='B07': require(settings.xpath('//w:documentProtection[@w:enforcement="1"]',namespaces=NS),'Protection missing')
                if s['id']=='B12': require(xml.xpath('//w:tbl//w:tbl',namespaces=NS),'Nested table missing')
        for f in fields:
            for key in ('standard','location','type','constraints','expected','question','refusalReason','relation','sources'):
                require(key in f,f'{s["id"]}: missing {key}')
            require(f['expectedState'] in ('automatic','ask','reject'),'Invalid expected state')
            if f['expectedState']=='ask': require(f['question'] and f['expected'] is None,'Ask needs null + question')
            if f['expectedState']=='reject': require(f['refusalReason'] and f['expected'] is None,'Reject needs null + reason')
            if f['expectedState']=='automatic':
                require(f['expected'] is not None and f['sources'],'Automatic needs answer + source')
                require(all(x in sources for x in f['sources']),'Unknown fact source')
                require(f['expected']==sources[f['sources'][0]]['value'],'Source/answer mismatch')
            if f['type']=='date' and f['expected'] is not None: date.fromisoformat(f['expected'])
            if f['type']=='single' and f['expected'] is not None: require(f['expected'] in f['options'],'Invalid single choice')
            if f['type']=='multi' and f['expected'] is not None: require(set(f['expected'])<=set(f['options']),'Invalid multiple choice')
            loc=f['location']
            if s['format']=='PDF':
                require(0<=loc['page']<len(reader.pages),'Page outside PDF')
                x,y,w,h=loc['rect']; page=reader.pages[loc['page']]
                require(x>=0 and y>=0 and w>0 and h>0 and x+w<=float(page.mediabox.width)+.01 and y+h<=float(page.mediabox.height)+.01,'Rect outside page')
                if 'widgetName' in loc:
                    require(loc['widgetName'] in widgets,'Widget absent from canonical form tree')
                    pagewidgets=[ann.get_object() for ann in page.get('/Annots',[]) if ann.get_object().get('/Subtype')=='/Widget']
                    require(any(wg.get('/T')==loc['widgetName'] for wg in pagewidgets),'Widget absent from page')
                if f['options']: require(set(loc['optionRects'])==set(f['options']),'Missing checkbox positions')
            else:
                hits=xml.xpath(loc['xpath'],namespaces=NS)
                require(len(hits)==1,'Anchor must resolve exactly once')
                require(''.join(hits[0].itertext())==loc['placeholder'],'Anchor target changed')
                if 'sdtTag' in loc: require(hits[0].xpath('ancestor::w:sdt/w:sdtPr/w:tag/@w:val',namespaces=NS)==[loc['sdtTag']],'SDT tag mismatch')
        if s['id'] in ('B05','B06'):
            require(not reader.pages[-1].extract_text().strip(),'Scan has text layer')
            require(reader.pages[-1].get('/Resources').get('/XObject'),'Scan has no image')
            if s['id']=='B06': require(len(reader.pages)==2 and reader.pages[0].extract_text().strip(),'Mixed file lacks text page')
        if s['id']=='B03':
            require(any(x.get_object().get('/Subtype')=='/Text' for x in reader.pages[0]['/Annots']),'PDF comment missing')
            require(b'3 Tr' in reader.pages[0].get_contents().get_data(),'Invisible PDF text missing')
        if s['id']=='B08': require(len(a['faultCases'])==6,'Service fault cases missing')
        if s['id']=='B09':
            labels={f['standard']:f['label'] for f in fields}
            require(labels.get('fullName')=='本人姓名','B09 synonym stimulus missing: fullName')
            require(labels.get('address')=='常住地址','B09 synonym stimulus missing: address')
            require(labels.get('contact.name')=='紧急联络人','B09 synonym stimulus missing: contact')
            require(labels.get('contact.phone')=='联系人手机','B09 synonym stimulus missing: phone')
            require(labels.get('spouse.name')=='配偶姓名','B09 synonym stimulus missing: spouse')
            require('synonyms' in {c['id'] for c in checkpoints},'B09 synonyms checkpoint missing')
    for group,expected in m['denominators'].items():
        split,fmt=group.split('/'); rows=[s for s in samples if s['split']==split and s['format']==fmt and s['kind']=='normal']
        actual={'samples':len(rows),'standardFields':sum(s['standardFieldCount'] for s in rows),'basicMatch':sum(s['basicMatchDenominator'] for s in rows)}
        require(actual==expected and actual['basicMatch']>0,'Invalid frozen denominator')
        require(actual['samples']==(8 if split=='debug' else 4),'Invalid split size')
        if split=='independent': require(expected==freeze['denominators'][group],'Frozen denominator drift')
    return {'status':'passed','manifestSha256':digest(root/'manifest.json'),'filesHashed':36,'samplesDecoded':decoded,'checkpointDefinitionsChecked':checkpoint_count,
            'independentContentDecoded':include_independent,'denominators':m['denominators'],
            'productEvaluation':'not_run'}

if __name__=='__main__':
    ap=argparse.ArgumentParser(); ap.add_argument('--root',type=Path,default=ROOT/'TestAssets/GeneralForms')
    ap.add_argument('--include-independent',action='store_true',help='Only T01 authoring QA or T12 formal evaluation; never tuning')
    ap.add_argument('--report',type=Path)
    args=ap.parse_args(); result=validate(args.root,args.include_independent)
    if args.report: args.report.parent.mkdir(parents=True,exist_ok=True); args.report.write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
    print(json.dumps(result,ensure_ascii=False,indent=2))
