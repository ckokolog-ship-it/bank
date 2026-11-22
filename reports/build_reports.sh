#!/bin/bash
# build_reports.sh -- on forms1 (Oracle Linux 9, Reports 14.1.2), as oracle: the reports of the bank, from the XML
# of the repo (mkreports.py) to the .rdf in the folder of the Reports Server (its sourceDir: /u01/app/oracle/reports),
# with rwconverter.
#
#   ./build_reports.sh                          all of them
#   ./build_reports.sh BK_STATEMENT             one
#
# The connection: /@BK_DB, the wallet of the domain (forms/bk_wallet.sh), no password; BK_REPORT in the database
# (INSTALL.sql). The log of each one: <OUT>/<name>.log. rwconverter wants an X display, as XML2Forms of the forms
# (build_forms.sh): that of a session as oracle itself (su - oracle, MobaXterm with X11 forwarding) when it has its
# cookie, else a virtual one (xvfb-run, 24 bits: sudo dnf install -y xorg-x11-server-Xvfb). XML_DISPLAY=session
# or xvfb: that one. With no display: REP-3000.
set -u
cd "$(dirname "$0")" || exit 1
HERE=$(pwd)
REPORTS=${*:-BK_STATEMENT BK_INTEREST BK_CC_STATEMENT}
USERID=${USERID:-/@BK_DB}
D=${DOMAIN_HOME:-/u01/app/oracle/config/domains/forms_domain}
MW=${MW_HOME:-/u01/app/oracle/middleware}
OUT=${OUT:-/u01/app/oracle/reports}
die() { echo "== $*"; exit 1; }
[ "$(id -un)" = oracle ] || die "as oracle: su - oracle (with MobaXterm X11 forwarding: the display), then this again"

CONV=
for c in "$D/reports/bin/rwconverter.sh" "$MW/bin/rwconverter.sh" "$MW/bin/rwconverter"; do
  [ -x "$c" ] && { CONV=$c; break; }
done
[ -n "$CONV" ] || die "rwconverter: not in $D/reports/bin nor $MW/bin"
mkdir -p "$OUT" || die "the folder $OUT: not made"
export TNS_ADMIN=$D/config/fmwconfig
export NLS_LANG=AMERICAN_GREECE.AL32UTF8
grep -Eqs '^[[:space:]]*BK_DB[[:space:]]*=' "$TNS_ADMIN/tnsnames.ora" || die "no BK_DB in $TNS_ADMIN/tnsnames.ora: forms/bk_wallet.sh first"

# the display: the session's (with its cookie), else a virtual one
if [ -n "${XAUTHORITY:-}" ] && [ ! -r "$XAUTHORITY" ]; then unset XAUTHORITY; fi    # (of another user: sudo)
MODE=${XML_DISPLAY:-auto}
HAS_COOKIE=
if [ -n "${DISPLAY:-}" ]; then
  if ! command -v xauth > /dev/null 2>&1 || [ -n "$(xauth list "$DISPLAY" 2> /dev/null)" ]; then HAS_COOKIE=1; fi
fi
RUNX=()
if [ "$MODE" = session ] || { [ "$MODE" = auto ] && [ -n "$HAS_COOKIE" ]; }; then
  echo "== rwconverter on the display of the session (DISPLAY=${DISPLAY:-none})"
elif command -v xvfb-run > /dev/null 2>&1; then
  RUNX=(xvfb-run -a -s "-screen 0 1280x1024x24")
  echo "== rwconverter on a virtual display (xvfb-run, 24 bits)"
else
  echo "== [!] no display: rwconverter may stop with REP-3000 (su - oracle with X11 forwarding, or xorg-x11-server-Xvfb)"
fi

conv() {      # $1: batch=yes or no
  (cd "$OUT" && "${RUNX[@]}" "$CONV" batch="$1" source="$xml" stype=xmlfile dest="$rdf" dtype=rdffile overwrite=yes \
     compile_all=yes userid="$USERID" logfile="$log")
}
done_=
for r in $REPORTS; do
  name=$(echo "$r" | tr '[:lower:]' '[:upper:]')
  xml=$HERE/$name.xml
  [ -f "$xml" ] || die "no $xml: python3 mkreports.py"
  rdf=$OUT/$name.rdf
  log=$OUT/$name.log
  rm -f "$rdf" "$log"
  echo "== $name: $xml -> $rdf"
  conv yes
  rc=$?
  [ -f "$log" ] && sed 's/^/   /' "$log"
  if [ ! -f "$rdf" ]; then
    # "Conversion ... canceled" with batch=yes, the same XML fine with batch=no (the mini market): once more so
    echo "== $name: once more with batch=no"
    rm -f "$log"
    conv no
    rc=$?
    [ -f "$log" ] && sed 's/^/   /' "$log"
  fi
  [ -f "$rdf" ] || die "$name: rwconverter $rc, no .rdf (the messages above, $log)"
  done_="$done_ $name"
done
echo "== OK:$done_ in $OUT"
echo "== the forms open them through SET_REPORTS_URL.sql (once): cd ../db && sqlplus /@BK_DB @SET_REPORTS_URL.sql http://forms1.home.lan:9012 PDF"
echo "== one by hand: http://forms1.home.lan:9012/reports/rwservlet?bank&report=BK_STATEMENT.rdf&destype=cache&desformat=PDF&P_KIND=S&P_ACCOUNT=1&P_FROM=01/01/2026&P_TO=31/12/2026"
