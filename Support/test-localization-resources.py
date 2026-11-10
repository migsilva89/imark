#!/usr/bin/env python3
"""Validate translation coverage, placeholders and packaged app/extension resources.
Run after build.sh: python3 Support/test-localization-resources.py
"""
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parent.parent

def strings(path):
    return json.loads(subprocess.check_output(
        ['plutil', '-convert', 'json', '-o', '-', str(path)]))

base = ROOT / 'Support/Localizations'
english = strings(base / 'en.lproj/Localizable.strings')
chinese = strings(base / 'zh-Hans.lproj/Localizable.strings')
assert english.keys() == chinese.keys(), 'Native translation keys differ'
for key, value in chinese.items():
    assert value.strip(), f'Empty translation: {key}'
    assert key.count('%@') == value.count('%@'), f'Format arguments differ: {key}'
    assert english[key] == key, f'English fallback differs: {key}'

for source in (ROOT / 'Sources').rglob('*.swift'):
    for raw in re.findall(r'NSLocalizedString\(("(?:\\.|[^"\\])*")', source.read_text()):
        key = json.loads(raw)
        assert key in english, f'Missing native key in {source}: {key}'

web = json.loads((ROOT / 'renderer/src/locales/zh-Hans.json').read_text())
for key, value in web.items():
    placeholders = lambda text: sorted(re.findall(r'\{\w+\}', text))
    assert placeholders(key) == placeholders(value), f'Web arguments differ: {key}'

app = ROOT / 'dist/Imark.app'
for bundle in [app, app / 'Contents/PlugIns/ImarkQuickLook.appex']:
    for language, expected in [('en', english), ('zh-Hans', chinese)]:
        actual = strings(bundle / f'Contents/Resources/{language}.lproj/Localizable.strings')
        assert actual == expected, f'Stale or absent translations: {bundle} / {language}'

print(f'PASS: {len(english)} native and {len(web)} web translations; matching placeholders and packaged resources')
