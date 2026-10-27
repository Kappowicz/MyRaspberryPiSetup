import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

def module(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'tools' / (name + '.py'))
    obj = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(obj)
    return obj

class RecoveryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.home = Path(self.tmp.name) / 'home'
        self.home.mkdir()
    def tearDown(self): self.tmp.cleanup()
    def prepare(self):
        return subprocess.run(['bash', str(ROOT/'install.sh')], env={**os.environ, 'HOME':str(self.home)}, capture_output=True, text=True)
    def test_prepare_complete_and_idempotent(self):
        result = self.prepare()
        self.assertEqual(result.returncode, 0, result.stderr)
        for path in ['sensor-app/Containerfile', 'city-app/Containerfile', 'unbound/unbound.conf', 'pihole/load-rules.sh', '.githooks/pre-commit', 'host/setup-host.sh', 'macbook/backup-all.sh', '.config/site.conf']:
            self.assertTrue((self.home/path).exists(), path)
        secret = self.home/'.config/secrets/grafana.env'
        secret.write_text('DO_NOT_REPLACE=private\n')
        self.assertEqual(self.prepare().returncode, 0)
        self.assertEqual(secret.read_text(), 'DO_NOT_REPLACE=private\n')
        self.assertFalse(list(self.home.rglob('*.backup-*')))
        self.assertTrue((self.home/'.config/systemd/user/podman-auto-update.timer').is_symlink())
    def test_changed_files_are_backed_up(self):
        installer = module('install-files')
        installer.install_files(ROOT, self.home)
        target=self.home/'backup.sh'; target.write_text('old version')
        installer.install_files(ROOT, self.home)
        self.assertEqual(list(target.parent.glob('backup.sh.backup-*'))[0].read_text(), 'old version')
    def test_same_directory_preserves_private_files(self):
        private=self.home/'private'; private.write_text('sentinel')
        module('install-files').install_files(self.home,self.home)
        self.assertEqual(private.read_text(),'sentinel')
    def test_placeholder_config_blocks_start_before_systemctl(self):
        self.assertEqual(self.prepare().returncode, 0)
        fake=self.home/'fakebin'; fake.mkdir()
        marker=self.home/'systemctl-called'
        tool=fake/'systemctl'; tool.write_text('#!/bin/sh\ntouch "'+str(marker)+'"\n'); tool.chmod(0o755)
        result=subprocess.run(['bash',str(ROOT/'install.sh'),'--start'],env={**os.environ,'HOME':str(self.home),'PATH':str(fake)+':'+os.environ['PATH']},capture_output=True,text=True)
        self.assertNotEqual(result.returncode,0)
        self.assertFalse(marker.exists())
    def test_bad_backup_never_publishes_success(self):
        result=subprocess.run(['bash',str(ROOT/'backup.sh')],env={**os.environ,'HOME':str(self.home)},capture_output=True,text=True)
        self.assertNotEqual(result.returncode,0)
        self.assertFalse(list((self.home/'backups').glob('malinka-*')))
    def test_json_and_datasource_uids(self):
        self.assertEqual(self.prepare().returncode, 0)
        for name, uid in [('air-quality.json','afl1398xamxa8b'),('system-metrics.json','influx-system')]:
            data=json.loads((self.home/'grafana/dashboards'/name).read_text())
            self.assertIsNone(data['id'])
            refs=[]
            def walk(obj):
                if isinstance(obj,dict):
                    if isinstance(obj.get('datasource'),dict) and obj['datasource'].get('type')=='influxdb': refs.append(obj['datasource']['uid'])
                    for value in obj.values(): walk(value)
                elif isinstance(obj,list):
                    for value in obj: walk(value)
            walk(data)
            self.assertTrue(refs)
            self.assertEqual(set(refs),{uid})
    def test_mac_failure_preserves_old_archives(self):
        local=self.home/'local'; local.mkdir()
        old=local/'malinka-2020-01-01-000000.tar.gz.enc'; old.write_text('old')
        key=local/'.archive-passphrase'; key.write_text('test-only')
        conf=self.home/'backup.conf'; conf.write_text(f'HOST=invalid\nLOCAL="{local}"\nDRIVE="{self.home}/drive"\nOSSL=/usr/bin/openssl\n')
        fake=self.home/'fakebin'; fake.mkdir(); ssh=fake/'ssh'; ssh.write_text('#!/bin/sh\nexit 1\n'); ssh.chmod(0o755)
        result=subprocess.run(['bash',str(ROOT/'macbook/backup-all.sh')],env={**os.environ,'HOME':str(self.home),'MALINKA_BACKUP_CONFIG':str(conf),'PATH':str(fake)+':'+os.environ['PATH']},capture_output=True,text=True)
        self.assertNotEqual(result.returncode,0)
        self.assertEqual(old.read_text(),'old')
        self.assertFalse((local/'.backup-all.lock').exists())

    def test_mac_success_encrypts_and_verifies_before_retention(self):
        import hashlib
        local=self.home/'local'; local.mkdir()
        old=local/'malinka-2020-01-01-000000.tar.gz.enc'; old.write_text('old')
        (local/'.archive-passphrase').write_text('synthetic-test-passphrase')
        fixture=self.home/'remote'; fixture.mkdir()
        (fixture/'SUCCESS').write_text('1234567890\n')
        (fixture/'payload').write_text('synthetic data')
        (fixture/'SHA256SUMS').write_text(''.join(hashlib.sha256((fixture/name).read_bytes()).hexdigest()+'  '+name+'\n' for name in ['SUCCESS','payload']))
        name='malinka-2026-10-08-120000'
        conf=self.home/'backup.conf'; conf.write_text(f'HOST=fixture\nLOCAL="{local}"\nDRIVE="{self.home}/drive"\nOSSL=/usr/bin/openssl\nITER=1000\n')
        fake=self.home/'fakebin'; fake.mkdir()
        ssh=fake/'ssh'; ssh.write_text('#!/bin/sh\ncase "$*" in\n*backup.sh*) echo BACKUP_NAME='+name+';;\n*SHA256SUMS*) cat "$FIXTURE/SHA256SUMS";;\n*) cat >/dev/null;;\nesac\n'); ssh.chmod(0o755)
        rsync=fake/'rsync'; rsync.write_text('#!/bin/sh\nfor last do :; done\ncp -R "$FIXTURE/." "$last"\n'); rsync.chmod(0o755)
        result=subprocess.run(['bash',str(ROOT/'macbook/backup-all.sh')],env={**os.environ,'HOME':str(self.home),'MALINKA_BACKUP_CONFIG':str(conf),'FIXTURE':str(fixture),'PATH':str(fake)+':'+os.environ['PATH']},capture_output=True,text=True)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertFalse(old.exists())
        encrypted=local/(name+'.tar.gz.enc')
        self.assertEqual(encrypted.read_bytes(),(self.home/'drive'/encrypted.name).read_bytes())
        self.assertFalse((local/'.backup-all.lock').exists())

if __name__ == '__main__': unittest.main()
