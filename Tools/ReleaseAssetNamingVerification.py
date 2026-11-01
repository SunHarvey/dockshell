"""Offline contract tests for release-asset maintenance; no real credentials or network."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
OLD = 'DockShell-0.4.0-25-arm64-local-preview.dmg'
NEW = 'DockShell-0.4.0-arm64.dmg'
TAG = '6da5c98c98f79937246bddf7c732db9a46cddd98'
SOURCE = 'aec968f07206b3279ee8c3fa21eaaf82058c092e'
STUB = r'''#!/usr/bin/env python3
import hashlib,json,os,sys
from pathlib import Path
root=Path(os.environ['FIXTURE_ROOT']); state_path=root/'state.json'; s=json.loads(state_path.read_text()); a=sys.argv[1:]
def save():state_path.write_text(json.dumps(s))
def record():
 with (root/'writes.jsonl').open('a') as f:f.write(json.dumps(a)+'\n')
if Path(sys.argv[0]).name=='curl':
 url=next(v for v in a if v.startswith('https://')); name=url.rsplit('/',1)[1]
 if not any(x['name']==name for x in s['assets']):sys.exit(22)
 if name.endswith('.dmg'):data=(root/'installer').read_bytes()
 elif name=='ReleaseManifest.plist':data=(root/'manifest').read_bytes()
 elif name=='SHA256SUMS':
  if s.pop('serve_stale_once',False):data=(root/'stale-checksums').read_bytes();save()
  else:data=(root/'checksums').read_bytes()
 else:sys.exit(22)
 Path(a[a.index('--output')+1]).write_bytes(data);sys.exit(0)
if a[:2]==['release','upload']:
 record()
 if s.pop('fail_upload_once',False):
  s['assets']=[x for x in s['assets'] if x['name']!='SHA256SUMS'];save();sys.exit(7)
 data=Path(a[3]).read_bytes()
 if s.get('inject_stale_read') and 'after' in Path(a[3]).parts:
  (root/'stale-checksums').write_bytes((root/'checksums').read_bytes());s['serve_stale_once']=True
 (root/'checksums').write_bytes(data)
 s['assets']=[x for x in s['assets'] if x['name']!='SHA256SUMS']
 s['assets'].append({'id':999,'name':'SHA256SUMS','state':'uploaded','digest':'sha256:'+hashlib.sha256(data).hexdigest()})
 save();sys.exit(0)
assert a[0]=='api',a
url=next(v for v in a if v.startswith('repos/'))
if '--method' in a and a[a.index('--method')+1]=='PATCH':
 record()
 if '/releases/assets/' in url:
  identity=int(url.rsplit('/',1)[1]);name=a[a.index('-f')+1].split('=',1)[1]
  next(x for x in s['assets'] if x['id']==identity)['name']=name
 else:s['body']=json.loads(Path(a[a.index('--input')+1]).read_text())['body']
 save();print(json.dumps(s));sys.exit(0)
if '/git/ref/tags/' in url:print(json.dumps({'object':{'type':'tag','sha':s['tag']}}))
elif '/git/tags/' in url:print(json.dumps({'object':{'type':'commit','sha':s['source']},'verification':{'verified':True}}))
elif url.endswith('/releases/latest'):print('v0.4.0')
elif '/releases/tags/' in url:print(json.dumps(s))
else:raise RuntimeError(a)
'''


class AssetNamingTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='dockshell-asset-tests-')
        self.root = Path(self.temporary.name)
        (self.root / 'bin').mkdir()
        stub = self.root / 'bin/stub'
        stub.write_text(STUB)
        stub.chmod(0o755)
        for name in ['gh', 'curl']:
            (self.root / 'bin' / name).symlink_to(stub)
        sleeper = self.root / 'bin/sleep'
        sleeper.write_text('#!/bin/sh\nexit 0\n')
        sleeper.chmod(0o755)
        data = b'Synthetic installer bytes, never an application.'
        manifest = b'Synthetic reviewed source manifest.'
        self.digest = hashlib.sha256(data).hexdigest()
        self.manifest_digest = hashlib.sha256(manifest).hexdigest()
        (self.root / 'installer').write_bytes(data)
        (self.root / 'manifest').write_bytes(manifest)
        (self.root / 'checksums').write_text(f'{self.digest}  {OLD}\n')
        self.state = {
            'id': 430263236, 'tag_name': 'v0.4.0', 'name': 'v0.4.0', 'immutable': False,
            'draft': False, 'prerelease': False, 'tag': TAG, 'source': SOURCE,
            'body': '# v0.4.0\n从下方 **Assets** 下载 `.dmg`，安装。\n',
            'assets': [
                {'id': 696828965, 'name': OLD, 'digest': 'sha256:' + self.digest, 'state': 'uploaded'},
                {'id': 696828966, 'name': 'SHA256SUMS', 'state': 'uploaded'},
                {'id': 696828967, 'name': 'ReleaseManifest.plist', 'state': 'uploaded'}]
        }
        self.save()
        # Change only the pinned public fixture digests in a disposable script copy.
        source = (ROOT / 'Scripts/rename-v040-assets.sh').read_text()
        source = source.replace('f745f92d4b5d5a62e1260b4a7b269d1e4e5222856967b97e437ec9430ed2f6db', self.digest)
        source = source.replace('ba8483df58f368f7347acacfc8f55d77e7ede6b52e63990913bb13cc1723cb29', self.manifest_digest)
        self.script = self.root / 'maintenance.sh'
        self.script.write_text(source)
        self.environment = {**os.environ, 'PATH': str(self.root/'bin')+os.pathsep+os.environ['PATH'],
                            'GH_REPO': 'SunHarvey/dockshell', 'FIXTURE_ROOT': str(self.root),
                            'ASSET_MAINTENANCE_DIR': str(self.root/'operation')}

    def tearDown(self):
        self.temporary.cleanup()

    def save(self):
        (self.root/'state.json').write_text(json.dumps(self.state))

    def run_script(self, mode='apply'):
        return subprocess.run(['sh', str(self.script), mode], env=self.environment,
                              text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    def writes(self):
        path = self.root/'writes.jsonl'
        return path.read_text().splitlines() if path.exists() else []

    def test_plan_never_mutates(self):
        self.assertEqual(self.run_script('plan').returncode, 0)
        self.assertEqual(self.writes(), [])

    def test_rename_preserves_binary_id_digest_manifest_and_is_idempotent(self):
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        state = json.loads((self.root/'state.json').read_text())
        binary = next(a for a in state['assets'] if a['id'] == 696828965)
        self.assertEqual((binary['name'], binary['digest']), (NEW, 'sha256:'+self.digest))
        self.assertEqual((self.root/'checksums').read_text(), f'{self.digest}  {NEW}\n')
        self.assertEqual(state['body'], self.state['body'].replace('`.dmg`', f'`{NEW}`'))
        self.assertEqual((self.root/'operation/before/installer.dmg').read_bytes(), (self.root/'operation/after/installer.dmg').read_bytes())
        count = len(self.writes())
        self.assertEqual(self.run_script().returncode, 0)
        self.assertEqual(len(self.writes()), count)

    def test_unreviewed_release_tag_binary_and_checksum_refused(self):
        for field, value in [('immutable', True), ('tag', '0'*40), ('source', '1'*40), ('name', 'other')]:
            self.state[field] = value; self.save()
            self.assertNotEqual(self.run_script().returncode, 0)
            self.assertEqual(self.writes(), [])
            self.state[field] = {'immutable': False, 'tag': TAG, 'source': SOURCE, 'name': 'v0.4.0'}[field]
        self.save()
        (self.root/'installer').write_bytes(b'Unreviewed bytes')
        self.assertNotEqual(self.run_script().returncode, 0)
        self.assertEqual(self.writes(), [])

    def test_checksum_replacement_failure_restores_original_name_and_contents(self):
        self.state['fail_upload_once'] = True; self.save()
        self.assertNotEqual(self.run_script().returncode, 0)
        state = json.loads((self.root/'state.json').read_text())
        self.assertEqual(next(a['name'] for a in state['assets'] if a['id']==696828965), OLD)
        self.assertEqual((self.root/'checksums').read_text(), f'{self.digest}  {OLD}\n')
        self.assertEqual(state['body'], self.state['body'])
        self.assertEqual(self.run_script().returncode, 0)

    def test_stale_public_checksum_is_retried_without_accepting_wrong_contents(self):
        self.state['inject_stale_read'] = True; self.save()
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('verification pending', result.stdout)
        self.assertEqual((self.root/'checksums').read_text(), f'{self.digest}  {NEW}\n')

    def test_conflicting_destination_is_not_overwritten(self):
        self.state['assets'].append({'id': 123, 'name': NEW});self.save()
        self.assertNotEqual(self.run_script().returncode, 0)
        self.assertEqual(self.writes(), [])


if __name__ == '__main__':
    unittest.main()
