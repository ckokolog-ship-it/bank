#!/bin/bash
# fsfo.sh -- on db1 (the primary), as root, once the broker is there (dg/broker.sh): Fast-Start Failover. The redo
# to db2 synchronous (FASTSYNC: a commit waits until db2 has it in memory, so a failover loses no transaction), the
# protection MaxAvailability, the target bank_db2 (and back: BANK_DB1), 30 seconds without the primary before the
# observer fails over, the old primary reinstated by itself when it comes back (flashback). Then the observer on
# forms1: dg/observer.sh. dgmgrl as sysdba of this host (no password):
#
#   sudo bash ~/fsfo.sh
set -euo pipefail
THRESHOLD=${BK_FSFO_THRESHOLD:-30}
die() { echo "== $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "as root: sudo bash $0"
case $(hostname -s) in db1|db2) ;; *) die "this is $(hostname): fsfo.sh is for db1 (or db2)" ;; esac
dg() { runuser -l oracle -c "dgmgrl -silent /"; }
echo "show configuration;" | dg | grep -qi "bank_db2" || die "no configuration of the broker: first broker.sh"
echo "== FASTSYNC both ways, MaxAvailability, Fast-Start Failover ($THRESHOLD s)"
dg <<DG
edit database BANK_DB1 set property LogXptMode = 'FASTSYNC';
edit database bank_db2 set property LogXptMode = 'FASTSYNC';
edit configuration set protection mode as MaxAvailability;
edit database BANK_DB1 set property FastStartFailoverTarget = 'bank_db2';
edit database bank_db2 set property FastStartFailoverTarget = 'BANK_DB1';
edit configuration set property FastStartFailoverThreshold = $THRESHOLD;
edit configuration set property FastStartFailoverAutoReinstate = TRUE;
enable fast_start failover;
DG
dg <<'DG'
show configuration;
show fast_start failover;
DG
echo "== now the observer on forms1: sudo bash dg/observer.sh (docs/ODIGIES_DG.md §9)"
