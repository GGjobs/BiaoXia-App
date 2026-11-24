#!/usr/bin/env python3
"""Seed only a fictional debug PDF into a booted simulator's Files provider."""
import pathlib
import shutil
import subprocess
import sys
root = pathlib.Path(__file__).resolve().parents[1]
device = sys.argv[1]
listing = subprocess.check_output(['xcrun', 'simctl', 'get_app_container', device, 'com.apple.DocumentsApp', 'groups'], text=True)
groups = dict(line.split('\t', 1) for line in listing.splitlines() if '\t' in line)
folder = pathlib.Path(groups['group.com.apple.FileProvider.LocalStorage']) / 'File Provider Storage'
folder.mkdir(parents=True, exist_ok=True)
shutil.copyfile(root / 'TestAssets/GeneralForms/debug/normal/F01-pdf.pdf', folder / 'T11B-debug-form.pdf')
for fixture in (root / 'TestAssets/GeneralForms/evidence/form-repair').glob('T15-project-*'):
    if fixture.suffix in {'.pdf', '.docx'}:
        shutil.copyfile(fixture, folder / fixture.name)
print('Fictional UI fixture prepared; existing files preserved.')
