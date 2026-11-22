#!/bin/bash
# build_forms.sh -- on the Linux Forms server (forms1), as oracle: the forms of the bank, XML -> .fmb (XML2Forms)
# -> .fmx (frmcmp_batch) in the first folder of FORMS_PATH of default.env.
#
#   ./build_forms.sh [user@db or /@BK_DB] [FORM ...]      (by default /@BK_DB, all of them)
#
# /@BK_DB: the wallet of the domain (bk_wallet.sh, the alias BK_DB of the user BANK). The words of the forms
# (BK_TEXT) and the login (BK_AUTH) are in the database already: INSTALL.sql (and GRANT_CRYPTO.sql once).
set -u
cd "$(dirname "$0")" || exit 1
HERE=$(pwd)
USERID=${1:-/@BK_DB}
shift || true
FORMS=${*:-BK_MENU BK_LOGIN BK_MAIN BK_CUSTOMERS BK_ACCOUNTS BK_MOVE BK_DAY}
MW=${MW_HOME:-/u01/app/oracle/middleware}
DOMAIN=${DOMAIN_HOME:-/u01/app/oracle/config/domains/forms_domain}
export ORACLE_HOME=$MW
export TNS_ADMIN=$DOMAIN/config/fmwconfig

CP=
for j in frmxmltools.jar frmjdapi.jar xmlparserv2.jar xschema.jar; do
  f=$(find "$MW" -name $j 2>/dev/null | head -1)
  [ -n "$f" ] || { echo "$j: not found under $MW"; exit 1; }
  CP=$CP${CP:+:}$f
done
CMP=
for f in "$DOMAIN"/config/fmwconfig/components/FORMS/instances/*/bin/frmcmp_batch.sh "$MW/bin/frmcmp_batch.sh"; do
  [ -x "$f" ] && { CMP=$f; break; }
done
[ -n "$CMP" ] || { echo "frmcmp_batch.sh: not found"; exit 1; }
ENV=$(find "$DOMAIN" -name default.env 2>/dev/null | grep -v /tmp/ | head -1)
FP=$(grep '^FORMS_PATH=' "$ENV" 2>/dev/null | cut -d= -f2 | cut -d: -f1)
[ -d "$FP" ] || { echo "FORMS_PATH of default.env ($ENV): no folder"; exit 1; }

done_=
for name in $FORMS; do
  cd "$HERE" || exit 1
  # BK_MENU: the menu module of all the forms (.mmb -> .mmx, module_type=menu)
  src=fmb; bin=fmx; type=form
  [ "$name" = BK_MENU ] && { src=mmb; bin=mmx; type=menu; }
  [ -f "$name.xml" ] || { echo "== $name: no $name.xml"; continue; }
  rm -f "$name.$src"
  echo "== $name.xml -> $name.$src"
  LD_LIBRARY_PATH=$MW/lib:${LD_LIBRARY_PATH:-} java -cp "$CP" oracle.forms.util.xmltools.XML2Forms OVERWRITE=YES "$name.xml"
  [ -f "$name.$src" ] || { echo "== no $name.$src: the messages above"; continue; }
  mv "$name.$src" "$FP"/
  cd "$FP" || exit 1
  rm -f "$name.$bin" "$name.err"
  "$CMP" module="$name.$src" userid="$USERID" module_type=$type compile_all=yes batch=yes
  if [ -f "$name.$bin" ]; then echo "== $FP/$name.$bin: OK"; done_="$done_ $name"
  else echo "== no $name.$bin: $FP/$name.err"; tail -30 "$name.err" 2>/dev/null; fi
done
echo "== done:$done_  -- frmservlet?config=bank&form=BK_MAIN"
