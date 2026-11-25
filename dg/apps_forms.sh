#!/bin/bash
# apps_forms.sh -- on forms1, as oracle: the forms and the reports of the bank to the new database (Data Guard).
# The alias BK_DB of the domain (forms/bk_wallet.sh: its credential, user bank, stays in the wallet; the password
# of BANK came with Data Pump, the same) now names the service bank_rw on db1 and on db2: whichever is the primary
# answers (after a failover, db2: by itself). The mini market (MM_DB) and the rest untouched. The file kept first as
# tnsnames.ora.<date>.bak; back: that file again. Then, as chris: sudo systemctl restart weblogic-forms.
#
#   cd ~/bank && bash dg/apps_forms.sh
set -euo pipefail
D=${DOMAIN_HOME:-/u01/app/oracle/config/domains/forms_domain}
CFG=$D/config/fmwconfig
TNS=$CFG/tnsnames.ora
ALIAS=${ALIAS:-BK_DB}
die() { echo "== $*" >&2; exit 1; }
[ "$(id -un)" = oracle ] || die "as oracle (sudo su - oracle)"
[ -f "$TNS" ] || die "no $TNS (forms/bk_wallet.sh first)"
grep -Eq "^[[:space:]]*$ALIAS[[:space:]]*=" "$TNS" || die "no $ALIAS in $TNS (forms/bk_wallet.sh first)"
cp -p "$TNS" "$TNS.$(date +%Y%m%d-%H%M%S).bak"

# the old entry out (from its name to where its parentheses close), the new one in
awk -v a="$ALIAS" '
  skip == 0 && $0 ~ "^[[:space:]]*" a "[[:space:]]*=" { skip = 1; depth = 0; seen = 0 }
  skip == 1 {
    n = split($0, c, "")
    for (i = 1; i <= n; i++) { if (c[i] == "(") { depth++; seen = 1 } else if (c[i] == ")") depth-- }
    if (seen && depth <= 0) skip = 2
    next
  }
  { print }
' "$TNS" > "$TNS.new"
cat >> "$TNS.new" <<NEW
$ALIAS =
  (DESCRIPTION = (CONNECT_TIMEOUT = 5)(TRANSPORT_CONNECT_TIMEOUT = 3)(RETRY_COUNT = 20)(RETRY_DELAY = 3)
    (ADDRESS_LIST = (LOAD_BALANCE = off)(FAILOVER = on)
      (ADDRESS = (PROTOCOL = TCP)(HOST = 192.168.178.221)(PORT = 1521))
      (ADDRESS = (PROTOCOL = TCP)(HOST = 192.168.178.222)(PORT = 1521)))
    (CONNECT_DATA = (SERVICE_NAME = bank_rw)))
NEW
mv "$TNS.new" "$TNS"
echo "== $ALIAS in $TNS: bank_rw on db1, db2"

echo "== a check: /@$ALIAS (the wallet of the domain)"
DBH=$(awk -F: '/^[A-Za-z0-9_]+:\// {print $2; exit}' /etc/oratab)
OUT=$(printf "set heading off feedback off pages 0\nselect sys_context('userenv','server_host') || ' ' || sys_context('userenv','database_role') || ' ' || (select count(*) from bk_account) from dual;\n" \
  | TNS_ADMIN=$CFG "${DBH:-$ORACLE_HOME}/bin/sqlplus" -s -L "/@$ALIAS" 2>&1 || true)
echo "$OUT"
grep -q "PRIMARY" <<<"$OUT" || die "/@$ALIAS did not reach the primary (the file before: $TNS.*.bak)"
echo "== now, as chris: sudo systemctl restart weblogic-forms"
