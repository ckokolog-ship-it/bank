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


def test_rac_grid():
    s = text('rac_grid.sh')
    assert 'rac1) ;;' in s and '-ignorePrereqFailure' in s and '-executeConfigTools' in s
    for want in ('CRS_CONFIG', 'FLEX_ASM_STORAGE', 'clusterName clusterName rac', 'rac-scan.home.lan',
                 'rac1.home.lan:rac1-vip.home.lan,rac2.home.lan:rac2-vip.home.lan', 'diskList /dev/oracleasm/crs1',
                 ':192.168.178.0:1,', ':10.10.10.0:5', 'executeRootScript false'):
        assert want in s, want
    # the password: asked, into a file readable by oracle only, removed; never on a command line
    assert 'read -rsp' in s and '-m 600' in s and "trap 'rm -f \"$RSP\"' EXIT" in s
    assert not re.search(r'-(sysasm|asmsnmp)Password\s', s, re.I)
    # root.sh: rac1 first, then rac2
    assert s.index('"$GRID_HOME/root.sh"') < s.index('chris@$OTHER')


def test_rac_grid_keys_of_23_26():
    # INS-10105 of 23.26: clusterUsage RAC|GENERAL_PURPOSE; no configureRHPS, configureAFD, ORACLE_BASE in its rsp
    s = text('rac_grid.sh')
    assert 'clusterUsage RAC' in s and 'STANDALONE' not in s
    for gone in ('configureRHPS', 'configureAFD', 'setk ORACLE_BASE'):
        assert gone not in s, gone


def test_rac_db():
    s = text('rac_db.sh')
    assert 'rac1) ;;' in s and "create diskgroup %s external redundancy" in s
    assert 'DATA:data1 RECO:reco1' in s and 'for node in rac1 rac2' in s and '-ignorePreReqs' in s
    assert 'clusterNodes rac1,rac2' in s and 'INSTALL_DB_SWONLY' in s and 'installEdition EE' in s
    assert '-databaseConfigType RAC -nodelist rac1,rac2' in s and '-diskGroupName +DATA' in s and '-recoveryGroupName +RECO' in s
    # the passwords: asked by dbca, never on its command line
    assert not re.search(r'-(sys|system|pdbAdmin)Password', s)
    # root.sh: rac1 first, then rac2
    assert s.index('"$DB_HOME/root.sh"') < s.index('sudo $DB_HOME/root.sh')


def test_the_bank_on_rac():
    e, b = text('db1_export.sh'), text('rac_bank.sh')
    assert 'PRIMARY' in e and 'schemas=BANK' in e and 'flashback_time' in e
    assert 'rac1) ;;' in b and 'cluster=n' in b and 'impdp system@//rac1.home.lan:1521/bankpdb' in b
    for want in ('dbms_crypto', 'bk_models', 'bk_docs', 'append_host_ace', 'compile_schema'):
        assert want in b, want
    # the service: both instances, Transparent Application Continuity
    for want in ('-service bank_rac', '-preferred ${DB}1,${DB}2', '-failovertype AUTO', '-commit_outcome TRUE',
                 '-notification TRUE', '-drain_timeout'):
        assert want in b, want
    assert not re.search(r'(?i)(system|bank)/\S', e + b)
