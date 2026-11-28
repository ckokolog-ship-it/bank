"""test_backup.py -- the backups with RMAN (backup/): bash -n; the disk of em1 on the i9 (off first), NFS only to the
four database hosts with root_squash, the client with hard and nofail; rman_setup.sh only on db1 and db2 after
/backup, the policies of RMAN, the timers; rman_backup.sh backs up only on the primary, catalogs first, no password.
Runs everywhere.

    python3 -m pytest -q tests/test_backup.py
"""
import glob
import os
import re
import subprocess

BK = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'backup')
DOCS = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'docs')


def text(name, d=BK):
    with open(os.path.join(d, name), encoding='utf-8') as f:
        return f.read()


def test_the_shell_scripts_parse():
    files = glob.glob(os.path.join(BK, '*.sh'))
    assert len(files) == 4
    for f in files:
        subprocess.run(['bash', '-n', f], check=True)
        assert os.access(f, os.X_OK), f


def test_disk():
    s = text('disk.ps1')
    assert "D:\\Oracle\\backup" in s and '500' in s
    assert 'Standard' in s or 'createmedium' in s
    assert re.search(r'running', s, re.I)  # refuses a running em1


def test_nfs_server():
    s = text('nfs_server.sh')
    assert 'set -euo pipefail' in s and 'em1' in s
    assert 'mkfs.xfs' in s and 'LABEL=backup' in s and 'nofail' in s
    for ip in ('192.168.178.221', '192.168.178.222', '192.168.178.231', '192.168.178.232'):
        assert ip in s
    assert 'root_squash' in s and 'no_root_squash' not in s
    assert '*(rw' not in s  # never to everyone


def test_nfs_client():
    s = text('nfs_client.sh')
    assert '192.168.178.236' in s and '"$EM:$MNT $MNT nfs' in s
    for o in ('hard', '_netdev', 'nofail'):
        assert o in s
    assert 'soft' not in s  # a soft mount can corrupt a backup


def test_rman_setup():
    s = text('rman_setup.sh')
    assert 'die "as root' in s and 'db1|db2)' in s and 'findmnt -n /backup' in s
    for c in ('recovery window of 7 days', 'controlfile autobackup on',
              'applied on all standby backed up 1 times', 'enable block change tracking', "'BASIC'"):
        assert c in s, c
    assert 'User=oracle' in s and 'RequiresMountsFor=/backup' in s
    for t in ("'Sun *-*-* 01:30' level0", "'Mon..Sat *-*-* 01:30' level1", "'*-*-* 00/4:15' arch"):
        assert t in s, t


def test_rman_backup():
    s = text('rman_backup.sh')
    assert 'database_role' in s and '"$ROLE" = PRIMARY' in s
    assert "catalog start with '$DEST/' noprompt;\ncrosscheck backup;\n$WHAT" in s
    assert 'delete noprompt obsolete' in s and 'exit 1' in s
    # / as sysdba: never a password
    assert not re.search(r'target\s+\S+/\S+@', s) and 'password' not in s.lower()


def test_the_doc():
    d = text('ODIGIES_BACKUP.md', DOCS)
    for c in ('disk.ps1', 'nfs_server.sh', 'nfs_client.sh', 'rman_setup.sh --now', 'restore database validate',
              'list backup summary'):
        assert c in d, c
