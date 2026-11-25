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


def test_vms_ps1_splits_the_names():
    # powershell -File passes -Names db1,db2 as the one string 'db1,db2' (it made a VM 'db1,db2')
    with open(os.path.join(DG, '..', 'k8s', 'vms.ps1'), encoding='utf-8') as f:
        s = f.read()
    assert "-split ','" in s and 'Resolve-Path $Iso' in s


def test_primary():
    s = text('primary.sh')
    assert re.search(r'db1\) ;;', s) and 'die "as root' in s
    assert '-createAsContainerDatabase true' in s and '-pdbName BANKPDB' in s and '-enableArchive true' in s
    # the passwords: asked by dbca, never on its command line
    assert not re.search(r'-(sys|system|pdbAdmin)Password', s)
    for want in ('force logging', 'flashback on', 'add standby logfile', 'standby_file_management = AUTO',
                 'dg_broker_start = TRUE', "db_unique_name='%s'", 'BANK_DB1_DGMGRL', 'oracle-bank'):
        assert want in s or want.replace('BANK_DB1', '${UNIQUE}') in s, want


def test_export_and_import():
    e, i = text('export.sh'), text('import.sh')
    assert 'forms1*) ;;' in e and 'expdp' in e and 'schemas=BANK' in e and 'flashback_time' in e
    assert 'db1) ;;' in i and 'impdp' in i and 'PRIMARY' in i
    # what Data Pump does not carry: the grant of SYS, the directories, the ACL
    for want in ('dbms_crypto', 'bk_models', 'bk_docs', 'append_host_ace', 'compile_schema'):
        assert want in i, want
    # never a password on the command line (expdp, impdp ask)
    assert not re.search(r'(?i)(system|bank)/\S', e + i)


def test_standby_and_broker():
    s, b = text('standby.sh'), text('broker.sh')
    assert 'db2) ;;' in s and 'for standby from active database' in s and "db_unique_name = '$UNIQUE'" in s
    assert 'orapw$SID' in s and 'BANK_DB2_DGMGRL' in s.replace('${UNIQUE}', 'BANK_DB2')
    # RMAN asks the passwords: never on its command line
    assert 'rman target sys@BANK_DB1 auxiliary sys@BANK_DB2 ' in s and not re.search(r'sys/\S', s)
    assert 'db1) ;;' in b and 'create configuration bank' in b and 'enable configuration' in b
    assert 'dgmgrl -silent /' in b


def test_running_asked_to_the_instance():
    # 26ai names its processes otherwise: pgrep missed a running standby and standby.sh began a duplicate again
    for f in ('primary.sh', 'standby.sh'):
        s = text(f)
        assert 'pgrep' not in s and 'select status from v$instance' in s, f
    s = text('standby.sh')
    assert "set state='APPLY-OFF'" in s and "set state='APPLY-ON'" in s


def test_fsfo_and_observer():
    f, o = text('fsfo.sh'), text('observer.sh')
    for want in ("LogXptMode = 'FASTSYNC'", 'MaxAvailability', 'FastStartFailoverTarget', 'enable fast_start failover',
                 'FastStartFailoverAutoReinstate = TRUE'):
        assert want in f, want
    assert 'forms1*) ;;' in o and 'mkstore' in o and 'createCredential BANK_DB1 sys' in o
    assert 'dgmgrl -silent /@BANK_DB1' in o and 'start observer' in o and 'Restart=always' in o
    # the wallet: never a password in clear
    assert not re.search(r'sys/\S', f + o)
