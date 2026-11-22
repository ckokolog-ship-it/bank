#!/bin/bash
# build_forms.sh -- on the Linux Forms server (forms1), as oracle: the forms of the bank, XML -> .fmb (XML2Forms)
# -> .fmx (frmcmp_batch) in the first folder of FORMS_PATH of default.env.
#
#   ./build_forms.sh [user@db or /@BK_DB] [FORM ...]      (by default /@BK_DB, all of them)
#
# /@BK_DB: the wallet of the domain (bk_wallet.sh, the alias BK_DB of the user BANK). The words of the forms
# (BK_TEXT) and the login (BK_AUTH) are in the database already: INSTALL.sql (and GRANT_CRYPTO.sql once).
#
# XML2Forms (the Forms Jdapi) does not start with an NLS_LANG of AL32UTF8 ("_jni_initialize: Failed to create
# new forms context", as the forms of the LOTTO found): it runs with XML_NLS_LANG (AMERICAN_AMERICA.WE8ISO8859P1;
# the forms are ASCII, their Greek is in BK_TEXT), whatever the profile of oracle says.
# It wants an X display as well it may use ("_jni_initialize: Failed to create new forms
# context" without one). A virtual one, if there is xvfb-run (sudo dnf install -y xorg-x11-server-Xvfb): no
# screen needed at all, from sudo -iu oracle too. Else the DISPLAY of the session: MobaXterm with X11
# forwarding, logged in as oracle itself (through sudo the cookie of X belongs to the user who logged in; this
# script says how to hand it over).
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
# the character set of XML2Forms: not UTF-8
XML_NLS=${XML_NLS_LANG:-AMERICAN_AMERICA.WE8ISO8859P1}
echo "== XML2Forms with NLS_LANG=$XML_NLS (the profile: ${NLS_LANG:-none})"
# the display of XML2Forms
RUNX=
if command -v xvfb-run > /dev/null 2>&1; then
  RUNX="xvfb-run -a"
  echo "== XML2Forms on a virtual display (xvfb-run)"
else
  # a XAUTHORITY of another user (sudo keeps it): not readable here, so not used (~/.Xauthority instead)
  if [ -n "${XAUTHORITY:-}" ] && [ ! -r "$XAUTHORITY" ]; then unset XAUTHORITY; fi
  if [ -z "${DISPLAY:-}" ]; then
    echo "== [!] no DISPLAY and no xvfb-run: XML2Forms needs a display. Once: sudo dnf install -y xorg-x11-server-Xvfb"
  elif command -v xauth > /dev/null 2>&1 && [ -z "$(xauth list "$DISPLAY" 2> /dev/null)" ]; then
    echo "== [!] DISPLAY=$DISPLAY but no cookie of X for $(id -un) (a session through sudo). Either once:"
    echo "        sudo dnf install -y xorg-x11-server-Xvfb      (then no display is needed)"
    echo "    or, from the session of the user who logged in (chris), before this script:"
    echo "        xauth extract - \$DISPLAY | sudo -iu oracle xauth merge -"
  fi
fi
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
  NLS_LANG=$XML_NLS LD_LIBRARY_PATH=$MW/lib:${LD_LIBRARY_PATH:-} $RUNX java -cp "$CP" oracle.forms.util.xmltools.XML2Forms OVERWRITE=YES "$name.xml"
  [ -f "$name.$src" ] || { echo "== no $name.$src: the messages above"; continue; }
  mv "$name.$src" "$FP"/
  cd "$FP" || exit 1
  rm -f "$name.$bin" "$name.err"
  "$CMP" module="$name.$src" userid="$USERID" module_type=$type compile_all=yes batch=yes
  if [ -f "$name.$bin" ]; then echo "== $FP/$name.$bin: OK"; done_="$done_ $name"
  else echo "== no $name.$bin: $FP/$name.err"; tail -30 "$name.err" 2>/dev/null; fi
done
echo "== done:$done_  -- frmservlet?config=bank&form=BK_MAIN"
