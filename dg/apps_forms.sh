#!/bin/bash
# apps_forms.sh -- on forms1, as oracle: the forms and the reports of the bank to the new database (Data Guard).
# The alias BK_DB of the domain (forms/bk_wallet.sh: its credential, user bank, stays in the wallet; the password
# of BANK came with Data Pump, the same) now names the service bank_rw on db1 and on db2: whichever is the primary
# answers (after a failover, db2: by itself). The mini market (MM_DB) and the rest untouched. The file kept first as
# tnsnames.ora.<date>.bak; back: that file again. Then, as chris: sudo systemctl restart weblogic-forms.
#
#   cd ~/bank && bash dg/apps_forms.sh
#
# Another application with its own alias in the same domain, after its schema moved (dg/schema_import.sh): the
# same, with its alias, its service and a table of it for the check. The mini market (the forms, the reports and
# mm-api: all through MM_DB; its credential, user mm, stays: the password came with Data Pump):
#
#   cd ~/bank && ALIAS=MM_DB SERVICE=mm_rw CHECK=mm_item bash dg/apps_forms.sh
#   (then, as chris: sudo systemctl restart weblogic-forms mm-api)
set -euo pipefail
D=${DOMAIN_HOME:-/u01/app/oracle/config/domains/forms_domain}
CFG=$D/config/fmwconfig
TNS=$CFG/tnsnames.ora
ALIAS=${ALIAS:-BK_DB}
SERVICE=${SERVICE:-bank_rw}
CHECK=${CHECK:-bk_account}
[[ $ALIAS =~ ^[A-Za-z][A-Za-z0-9_]*$ && $SERVICE =~ ^[a-z][a-z0-9_]*$ && $CHECK =~ ^[A-Za-z][A-Za-z0-9_]*$ ]] \
  || { echo "== ALIAS, SERVICE, CHECK: letters, digits, _" >&2; exit 1; }
die() { echo "== $*" >&2; exit 1; }
[ "$(id -un)" = oracle ] || die "as oracle (sudo su - oracle)"
[ -f "$TNS" ] || die "no $TNS (forms/bk_wallet.sh first)"
grep -Eq "^[[:space:]]*${ALIAS}[[:space:]]*=" "$TNS" || die "no $ALIAS in $TNS (its wallet first: forms/bk_wallet.sh, the mini market tools/linux/mm_wallet.sh)"
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
    (CONNECT_DATA = (SERVICE_NAME = $SERVICE)))
NEW
mv "$TNS.new" "$TNS"
echo "== $ALIAS in $TNS: $SERVICE on db1, db2"

echo "== a check: /@$ALIAS (the wallet of the domain)"
DBH=$(awk -F: '/^[A-Za-z0-9_]+:\// {print $2; exit}' /etc/oratab)
OUT=$(printf "set heading off feedback off pages 0\nselect sys_context('userenv','server_host') || ' ' || sys_context('userenv','database_role') || ' ' || (select count(*) from $CHECK) from dual;\n" \
  | TNS_ADMIN=$CFG "${DBH:-$ORACLE_HOME}/bin/sqlplus" -s -L "/@$ALIAS" 2>&1 || true)
echo "$OUT"
grep -q "PRIMARY" <<<"$OUT" || die "/@$ALIAS did not reach the primary (the file before: $TNS.*.bak)"
echo "== now, as chris: sudo systemctl restart weblogic-forms"
