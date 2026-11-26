"""test_rac.py -- the scripts of the RAC of the lab (rac/): bash -n; rac_host.sh refuses the other hosts, wants root,
the addresses of the plan, the shared disks by udev for oracle:asmadmin; rac_ssh.sh on rac1 only, no password in
it; rac_disks.ps1: the internal network racpriv, three fixed shareable disks attached to both. Runs everywhere.

    python3 -m pytest -q tests/test_rac.py
"""
import glob
import os
import re
import subprocess

RAC = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'rac')


def text(name):
    with open(os.path.join(RAC, name), encoding='utf-8') as f:
        return f.read()


def test_the_shell_scripts_parse():
    files = glob.glob(os.path.join(RAC, '*.sh'))
    assert len(files) >= 2
    for f in files:
        subprocess.run(['bash', '-n', f], check=True)


def test_rac_host():
    s = text('rac_host.sh')
    assert 'set -euo pipefail' in s and 'die "as root' in s
    assert re.search(r'forms1\*\|k3s\*\|db1\|db2\) die', s)
    for a in ('192.168.178.231 rac1', '192.168.178.232 rac2', '192.168.178.233 rac1-vip', '192.168.178.234 rac2-vip',
              '192.168.178.235 rac-scan', '10.10.10.1 rac1-priv', '10.10.10.2 rac2-priv'):
        assert a in s, a
    assert 'SYMLINK+=\\"oracleasm/$NAME\\"' in s and 'GROUP=\\"asmadmin\\"' in s and 'ID_SERIAL' in s
    assert 'asmadmin,asmdba,asmoper' in s and '/u01/app/23.0.0/grid' in s
    # connection names with spaces: read line by line, not split by the shell
    assert 'while IFS= read -r c' in s


def test_rac_ssh():
    s = text('rac_ssh.sh')
    assert 'rac1) ;;' in s and 'ssh-keyscan' in s and 'BatchMode=yes' in s and 'cvuqdisk' in s
    assert not re.search(r'(?i)password\s*=', s)


def test_rac_disks_ps1():
    s = text('rac_disks.ps1')
    assert '--intnet2 racpriv' in s and '--variant Fixed' in s and '--type shareable' in s
    assert '--mtype shareable' in s and "-split ','" in s and 'is running' in s
