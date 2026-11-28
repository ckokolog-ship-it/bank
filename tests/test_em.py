"""test_em.py -- the scripts of Enterprise Manager (em/): bash -n; em_host.sh refuses the other hosts, wants root,
the address of the plan, the names of the lab, 19c on OL9 told it is OL8, dbca asks the passwords (none in the
script); em_oms.sh: on em1 after em_host.sh, the passwords asked and only in a temporary response file (600, deleted),
the keys of the template of the installer itself. Runs everywhere.

    python3 -m pytest -q tests/test_em.py
"""
import glob
import os
import re
import subprocess

EM = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'em')


def text(name):
    with open(os.path.join(EM, name), encoding='utf-8') as f:
        return f.read()


def test_the_shell_scripts_parse():
    files = glob.glob(os.path.join(EM, '*.sh'))
    assert len(files) >= 2
    for f in files:
        subprocess.run(['bash', '-n', f], check=True)


def test_em_host():
    s = text('em_host.sh')
    assert 'set -euo pipefail' in s and 'die "as root' in s
    assert re.search(r'forms1\*\|k3s\*\|db1\|db2\|rac1\|rac2\) die', s)
    assert '192.168.178.236' in s
    for a in ('192.168.178.221 db1', '192.168.178.222 db2', '192.168.178.231 rac1', '192.168.178.232 rac2',
              '192.168.178.235 rac-scan', '192.168.178.200 forms1'):
        assert a in s, a
    assert 'CV_ASSUME_DISTID=OL8' in s and 'INSTALL_DB_SWONLY' in s
    for p in ('7803', '4903', '7102'):
        assert p in s
    # dbca asks the passwords: never in the script or on its command line
    assert '-sysPassword' not in s and '-systemPassword' not in s and '-pdbAdminPassword' not in s
    assert 'oracle-em.service' in s and 'save state' in s
    # mkswap of Oracle Linux 9 has no -q; each step of the swap again after a stop
    # an inventory of an install that stopped (INS-32035): moved aside, never one that has homes
    assert '[ ! -f /etc/oraInst.loc ]' in s and 'ContentsXML/inventory.xml' in s and 'oraInventory.failed-' in s
    # installed: the home in the inventory, never a file of it (the image of 26ai has bin/oracle from the zip)
    assert 'ContentsXML/inventory.xml" && [ -f /etc/oratab ]' in s and 'if ! installed; then' in s
    assert '[ ! -x "$ORACLE_HOME/bin/oracle" ]' not in s
    assert 'mkswap -q' not in s and 'blkid -t TYPE=swap /swapfile' in s and 'swapon --show' in s


def test_em_oms():
    s = text('em_oms.sh')
    assert 'set -euo pipefail' in s and '[ "$(hostname -s)" = em1 ]' in s and "grep -q '^EMCDB:' /etc/oratab" in s
    for z in ('V1046951-01.zip', 'V1046955-01.zip'):
        assert z in s
    assert '-getResponseFileTemplates' in s and 'new_install.rsp' in s and '-silent -responseFile' in s
    # the passwords: read -s, in a temporary file of 600 deleted at the end, never in the repo
    assert 'read -rsp' in s and 'chmod 600 "$RSP"' in s and 'shred -u "$RSP"' in s and 'trap' in s
    assert 'unset P_SYS P_SYSMAN P_WLS P_NM P_AGENT' in s
    assert not re.search(r'(?i)(PASSWORD)=[A-Za-z0-9]', s), 'no password written in the script'
    # unzipped as root, then given to oracle: the zips may be in a home closed to oracle (700)
    assert 'runuser -u oracle -- unzip' not in s and 'chown -R oracle:oinstall "$STAGE"' in s
    assert 'DEPLOYMENT_SIZE SMALL' in s and 'SERVICENAME_OR_SID EMREP' in s and 'allroot.sh' in s


def test_the_guide():
    with open(os.path.join(EM, '..', 'docs', 'ODIGIES_EM.md'), encoding='utf-8') as f:
        g = f.read()
    assert 'em_host.sh' in g and 'em_oms.sh' in g and '7803/em' in g and 'tmux' in g
    assert 'LINUX.X64_2326100_db_home.zip' in g, 'the way out when 19c does not install on OL9'
