"""Exercise backup transactions with isolated service/container/host command doubles."""
import json
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]
DISPATCH=r'''#!/usr/bin/env python3
import json, os, pathlib, sqlite3, subprocess, sys, tarfile
name=pathlib.Path(sys.argv[0]).name
a=sys.argv[1:]
home=pathlib.Path(os.environ['HOME'])
if name=='sudo':
    if a==['-n','true']: sys.exit(0)
    sys.exit(subprocess.call(a))
if name=='systemctl':
    a=[x for x in a if x not in ['--user','--quiet']]
    path=home/'states.json'; states=json.loads(path.read_text())
    if a[0]=='is-active': sys.exit(0 if states.get(a[1],False) else 3)
    for unit in a[1:]: states[unit]=(a[0]=='start')
    path.write_text(json.dumps(states)); sys.exit(0)
if name=='podman':
    if a[0]=='exec': sys.exit(1)
    if os.environ.get('FAIL_EXPORT')=='1': sys.exit(42)
    with tarfile.open(a[a.index('-o')+1], 'w'): pass
    sys.exit(0)
if name=='sqlite3':
    if a[1].startswith('.backup '):
        dest=a[1][len('.backup '):].strip("'")
        source=sqlite3.connect(a[0]); target=sqlite3.connect(dest)
        source.backup(target); target.close(); source.close()
    else:
        print(sqlite3.connect(a[0]).execute(a[1]).fetchone()[0])
    sys.exit(0)
if name=='tar':
    if '-C' in a and a[a.index('-C')+1]=='/':
        with tarfile.open(a[a.index('-czf')+1],'w:gz'): pass
        sys.exit(0)
    sys.exit(subprocess.call([os.environ['REAL_TAR']]+a))
if name=='df': print('Avail\n5000'); sys.exit(0)
if name=='dpkg-query': print('fixture-package\t1.0'); sys.exit(0)
if name=='crontab': sys.exit(1)
'''

@unittest.skipUnless(shutil.which('flock') and shutil.which('sha256sum'),'Linux tools required')
class BackupTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(); self.home=Path(self.tmp.name)/'home'; self.home.mkdir()
        subprocess.run(['bash',str(ROOT/'install.sh')],env={**os.environ,'HOME':str(self.home)},capture_output=True,check=True)
        (self.home/'.ssh').mkdir(); (self.home/'.ssh/config').write_text('fixture SSH config')
        db=self.home/'pihole/etc-pihole/gravity.db'; db.parent.mkdir(parents=True)
        con=sqlite3.connect(db); con.execute('CREATE TABLE fixture(value)'); con.execute("INSERT INTO fixture VALUES ('snapshot')"); con.commit(); con.close()
        self.initial={'influxdb':True,'grafana':True,'sds011':False,'city-air':True,'telegraf':False}
        (self.home/'states.json').write_text(json.dumps(self.initial))
        fake=self.home/'fakebin'; fake.mkdir(); dispatcher=fake/'dispatch'; dispatcher.write_text(DISPATCH); dispatcher.chmod(0o755)
        for name in ['sudo','systemctl','podman','sqlite3','tar','df','dpkg-query','crontab']: (fake/name).symlink_to('dispatch')
        self.env={**os.environ,'HOME':str(self.home),'PATH':str(fake)+':'+os.environ['PATH'],'REAL_TAR':shutil.which('tar')}
    def tearDown(self): self.tmp.cleanup()
    def run_backup(self,fail=False):
        return subprocess.run(['bash',str(ROOT/'backup.sh')],env={**self.env,'FAIL_EXPORT':'1' if fail else '0'},capture_output=True,text=True)
    def test_export_failure_restores_service_state_without_success(self):
        result=self.run_backup(True)
        self.assertNotEqual(result.returncode,0)
        self.assertEqual(json.loads((self.home/'states.json').read_text()),self.initial)
        self.assertFalse((self.home/'alerts/maintenance').exists())
        self.assertFalse(list((self.home/'backups').glob('malinka-*')))
        self.assertFalse(list((self.home/'backups').glob('*/SUCCESS')))
    def test_success_verifies_snapshots_and_private_configuration(self):
        result=self.run_backup()
        self.assertEqual(result.returncode,0,result.stderr)
        backups=list((self.home/'backups').glob('malinka-*')); self.assertEqual(len(backups),1)
        backup=backups[0]; self.assertTrue((backup/'SUCCESS').is_file())
        subprocess.run(['sha256sum','-c','SHA256SUMS'],cwd=backup,capture_output=True,check=True)
        import tarfile
        with tarfile.open(backup/'app-and-quadlets.tar.gz') as archive:
            self.assertIn('.config/site.conf',archive.getnames())
            self.assertIn('.ssh/config',archive.getnames())
        con=sqlite3.connect(backup/'gravity.db'); self.assertEqual(con.execute('select value from fixture').fetchone()[0],'snapshot'); con.close()
        self.assertEqual(json.loads((self.home/'states.json').read_text()),self.initial)
        self.assertIn('BACKUP_NAME='+backup.name,result.stdout)

if __name__=='__main__': unittest.main()
