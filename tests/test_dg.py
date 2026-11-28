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


def test_observer_check_reads_all():
    # grep -q in a pipe with pipefail: a connection that worked counted as failed
    o = text('observer.sh')
    assert 'tee /dev/stderr | grep -q' not in o and 'grep -qi "bank_db2" <<<"$OUT"' in o


def test_the_listener_starts_with_the_database():
    # after a power off of db1 the database came up, its listener not: the reinstate could not reach it
    for f in ('primary.sh', 'standby.sh', 'oracle_unit.sh'):
        s = text(f)
        assert 'ExecStartPre=-$ORACLE_HOME/bin/lsnrctl start' in s, f
        assert s.index('ExecStartPre=-') < s.index('ExecStart=$ORACLE_HOME/bin/dbstart'), f


def test_observer_knows_the_host_names():
    # the broker starts a database by the host name of its static entry (db2.home.lan): ORA-12545 on forms1
    o = text('observer.sh')
    assert '192.168.178.222 db2.home.lan' in o and '192.168.178.221 db1.home.lan' in o


def test_active_data_guard_and_the_services():
    s = text('adg.sh')
    assert "mk('bank_rw')" in s and "mk('bank_ro')" in s
    assert 'after startup on database' in s and 'open read only' in s
    # bank_rw only on the primary; the apply stopped and started again around the open
    assert "if r = 'PRIMARY' then" in s and "down('bank_rw')" in s
    assert s.index("APPLY-OFF") < s.index('alter database open read only') < s.index("APPLY-ON")


def test_adg_switches_the_log_from_the_root():
    s = text('adg.sh')
    assert s.index('alter session set container = CDB$ROOT;') < s.index('alter system archive log current;')


def test_local_listener_by_address():
    # LISTENER_BANK (dbca) went to db2 with the spfile; its tnsnames.ora did not know it: bank_ro not registered
    assert "(HOST=db1.home.lan)(PORT=1521))'' scope = both" in text('primary.sh')
    s = text('standby.sh')
    assert s.count("local_listener = '(ADDRESS=(PROTOCOL=TCP)(HOST=db2.home.lan)(PORT=1521))'") == 2


def test_the_applications_to_bank_rw():
    a = text('apps_forms.sh')
    assert 'SERVICE_NAME = $SERVICE' in a and 'SERVICE=${SERVICE:-bank_rw}' in a and 'ALIAS=${ALIAS:-BK_DB}' in a
    assert '192.168.178.221' in a and '192.168.178.222' in a
    # another application (the mini market) with its own alias, service and table of the check
    assert 'ALIAS=MM_DB SERVICE=mm_rw CHECK=mm_item' in a and 'from $CHECK' in a
    assert '.bak' in a and 'RETRY_COUNT' in a and 'PRIMARY' in a
    with open(os.path.join(DG, '..', 'k8s', 'deploy.sh'), encoding='utf-8') as f:
        d = f.read()
    url = re.search(r"DG_URL='([^']*)'", d).group(1)
    # through the sed of deploy.sh (# its delimiter) and into YAML
    assert '#' not in url and '&' not in url and 'SERVICE_NAME=bank_rw' in url and 'DB_URL=${BK_DB_URL:-$DG_URL}' in d


def test_apps_forms_replaces_only_its_entry(tmp_path):
    # the awk of apps_forms.sh: BK_DB out (its parentheses to the end), MM_DB and the rest kept
    a = text('apps_forms.sh')
    prog = a[a.index("awk -v a=\"$ALIAS\" '") + len("awk -v a=\"$ALIAS\" '"):]
    prog = prog[:prog.index("' \"$TNS\"")]
    t = tmp_path / 't.ora'
    t.write_text('MM_DB =\n  (DESCRIPTION = (ADDRESS = (PROTOCOL = TCP)(HOST = forms1)(PORT = 1521))\n'
                 '    (CONNECT_DATA = (SERVICE_NAME = FREEPDB1)))\n\nBK_DB =\n  (DESCRIPTION = (ADDRESS = '
                 '(PROTOCOL = TCP)(HOST = forms1.home.lan)(PORT = 1521))\n    (CONNECT_DATA = (SERVICE_NAME = '
                 'FREEPDB1)))\nX = (DESCRIPTION = (CONNECT_DATA = (SID = Y)))\n')
    out = subprocess.run(['awk', '-v', 'a=BK_DB', prog, str(t)], capture_output=True, text=True, check=True).stdout
    assert 'BK_DB' not in out and 'MM_DB =' in out and 'X = (DESCRIPTION' in out and out.count('FREEPDB1') == 1


def test_a_pdb_for_another_application():
    s = text('pdb.sh')
    assert 'create pluggable database %s admin user %sadmin identified by' in s and 'save state' in s
    assert "mk('${PFX}_rw')" in s and "mk('${PFX}_ro')" in s and 'after startup on database' in s
    assert "if r = 'PRIMARY' then" in s and 'PRIMARY' in s and 'BANKPDB is the bank' in s
    # a PDB from the seed has no USERS
    assert 'create tablespace users' in s and 'default tablespace users' in s
    # the password: asked, through stdin, never an argument
    assert 'read -rsp' in s and not re.search(r'sqlplus[^|\n]*identified by', s)


def test_another_schema_to_its_pdb():
    e = text('schema_export.sh')
    assert 'forms1*) ;;' in e and 'schemas="$SCHEMA"' in e and 'flashback_time=systimestamp' in e
    assert 'die "the bank: dg/export.sh' in e and 'TNS_ADMIN=$DP/tns expdp' in e and 'schema_import.sh' in e
    i = text('schema_import.sh')
    assert 'database_role' in i and "open_mode = 'READ WRITE'" in i and 'BANKPDB is the bank' in i
    assert 'impdp system@$PDB' in i and 'drop user $NAME cascade' in i and 'compile_schema' in i
    # what Data Pump does not carry, for MM: DBMS_CRYPTO (the logins), DATA_PUMP_DIR (the backups)
    assert 'grant execute on sys.dbms_crypto to mm;' in i and 'grant read, write on directory data_pump_dir to mm;' in i
    for s in (e, i):
        assert not re.search(r'(?i)identified by|password=', s), 'the passwords: asked by expdp / impdp only'
