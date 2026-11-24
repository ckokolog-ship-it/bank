"""test_dg.py -- the scripts of Data Guard (dg/): bash -n; db_host.sh refuses forms1 and the k3s nodes, wants root,
installs software only, Enterprise Edition, into the home of 26ai; no password in it. Runs everywhere.

    python3 -m pytest -q tests/test_dg.py
"""
import glob
import os
import re
import subprocess

DG = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'dg')


def text(name):
    with open(os.path.join(DG, name), encoding='utf-8') as f:
        return f.read()


def test_the_shell_scripts_parse():
    files = glob.glob(os.path.join(DG, '*.sh'))
    assert files
    for f in files:
        subprocess.run(['bash', '-n', f], check=True)


def test_db_host():
    s = text('db_host.sh')
    assert 'set -euo pipefail' in s
    assert re.search(r'forms1\*\|k3s\*\) die', s)
    assert 'id -u' in s and 'die "as root' in s
    assert 'INSTALL_DB_SWONLY' in s and re.search(r'installEdition EE', s)
    assert '/u01/app/oracle/product/26ai/dbhome_1' in s
    assert 'oracle-ai-database-preinstall-26ai' in s and 'oracle-database-preinstall-23ai' in s
    assert '-silent' in s and 'root.sh' in s
    assert not re.search(r'(?i)password\s*=', s)


def test_db_host_refuses_without_arguments():
    r = subprocess.run(['bash', os.path.join(DG, 'db_host.sh')], capture_output=True, text=True)
    assert r.returncode != 0
