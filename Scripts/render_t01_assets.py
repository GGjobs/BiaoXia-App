#!/usr/bin/env python3
"""Render fixture QA separately from product validation. Holdout is opt-in.

Use the documents skill renderer, overriding only LibreOffice resolution to honor
this project's explicit desktop-LibreOffice requirement. Never modifies inputs.
"""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
from PIL import Image, ImageDraw
from pdf2image import convert_from_path

ROOT=Path(__file__).resolve().parents[1]

def main():
    ap=argparse.ArgumentParser()
    ap.add_argument('--root',type=Path,default=ROOT/'TestAssets/GeneralForms')
    ap.add_argument('--output',type=Path,required=True)
    ap.add_argument('--docx-renderer',type=Path,required=True)
    ap.add_argument('--soffice',type=Path,default=Path('/Applications/LibreOffice.app/Contents/MacOS/soffice'))
    ap.add_argument('--include-independent',action='store_true',help='T01 creation QA / T12 only')
    args=ap.parse_args()
    spec=importlib.util.spec_from_file_location('docx_renderer',args.docx_renderer)
    renderer=importlib.util.module_from_spec(spec); spec.loader.exec_module(renderer)
    renderer._resolve_soffice=lambda:str(args.soffice.resolve())
    renderer._default_macos_tmpdir_for_soffice()
    if args.output.exists() and any(args.output.iterdir()):
        ap.error('Output directory must be empty to prevent stale page images from contaminating evidence.')
    args.output.mkdir(parents=True,exist_ok=True)
    m=json.loads((args.root/'manifest.json').read_text()); records=[]; pages=[]
    for sample in m['samples']:
        if sample['split']=='independent' and not args.include_independent: continue
        path=(args.root/sample['file']).resolve(); out=(args.output/sample['id']).resolve(); out.mkdir(exist_ok=True)
        before=hashlib.sha256(path.read_bytes()).hexdigest()
        if sample['format']=='DOCX': renderer.rasterize(str(path),str(out),90,verbose=False,emit_pdf=True)
        else:
            for i,im in enumerate(convert_from_path(str(path),dpi=90),1): im.save(out/f'page-{i}.png')
        images=sorted(out.glob('page-*.png'),key=lambda p:int(p.stem.split('-')[-1]))
        assert images, sample['id']
        assert before==hashlib.sha256(path.read_bytes()).hexdigest()==sample['sha256']
        records.append({'sample':sample['id'],'sha256':before,'pages':len(images),'render':'passed'})
        pages.extend((sample['id'],im) for im in images)
        print(f'{sample["id"]}: {len(images)} pages rendered',flush=True)
    # Full page pair sheets preserve the 90-dpi pixels; no thumbnail downsampling.
    for i in range(0,len(pages),2):
        pair=pages[i:i+2]; ims=[Image.open(path).convert('RGB') for _,path in pair]
        sheet=Image.new('RGB',(sum(im.width for im in ims),max(im.height for im in ims)+30),'#dddddd')
        draw=ImageDraw.Draw(sheet); x=0
        for (sid,path),im in zip(pair,ims):
            draw.text((x+10,8),sid+' / '+path.name,fill='black'); sheet.paste(im,(x,30)); x+=im.width
        sheet.save(args.output/f'review-{i//2+1:02}.png')
    report={'manifestSha256':hashlib.sha256((args.root/'manifest.json').read_bytes()).hexdigest(),
        'renderer':'documents render_docx.py + pdf2image/Poppler','libreOffice':str(args.soffice),
        'dpi':90,'independentContentDecoded':args.include_independent,'records':records,
        'pageCount':len(pages),'visualReview':'pending','productEvaluation':'not_run'}
    (args.output/'render-report.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')

if __name__=='__main__': main()
