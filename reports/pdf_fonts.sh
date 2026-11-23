#!/bin/bash
# pdf_fonts.sh -- on forms1, as oracle: the Greek of the reports in PDF. The fonts built into a PDF have no Greek;
# the Reports Server puts a TrueType font in its place by uifont.ali ([ PDF:Subset ]). The reports of the bank (and
# of the mini market) ask for Arial: on Linux, mapped here to DejaVu Sans (with Greek), bold to DejaVu Sans Bold; and
# Helvetica, Courier as the guide of PROPO (§13). The fonts in /u01/app/oracle/fonts, the environment of WLS_REPORTS
# (REPORTS_FONT_DIRECTORY, TK_FONTALIAS, NLS_LANG) checked, added to setUserOverrides.sh when it is not there.
#
#   ./pdf_fonts.sh            then, as chris: sudo systemctl restart weblogic-forms
#   ./pdf_fonts.sh --check    only what is there now (a PDF of a report, and its fonts: pdffonts)
#
# A second run changes nothing. The files changed are kept first (.bk-<date>).
set -u
D=${DOMAIN_HOME:-/u01/app/oracle/config/domains/forms_domain}
U=$D/config/fmwconfig/components/ReportsToolsComponent/reptools1/guicommon/tk/admin/uifont.ali
O=$D/bin/setUserOverrides.sh
F=${FONT_DIR:-/u01/app/oracle/fonts}
URL=${REPORT_URL:-http://localhost:9012/reports/rwservlet?bank&report=BK_STATEMENT.rdf&destype=cache&desformat=PDF&P_KIND=S&P_ACCOUNT=1&P_FROM=01/01/2000&P_TO=31/12/2100}
STAMP=$(date +%Y%m%d%H%M%S)
die() { echo "== $*"; exit 1; }
[ "$(id -un)" = oracle ] || die "as oracle: sudo -iu oracle, then this again"
[ -f "$U" ] || die "no $U (DOMAIN_HOME=$D?)"

# the environment of the running WLS_REPORTS (its process: by its command line, without pgrep -f)
wls_env() {
  local pid
  pid=$(ps -eo pid=,args= | grep 'weblogic.Name=WLS_REPORTS' | grep -v grep | awk 'NR == 1 {print $1}')
  [ -n "$pid" ] && tr '\0' '\n' < /proc/"$pid"/environ 2>/dev/null | grep -E '^(NLS_LANG|REPORTS_FONT_DIRECTORY|TK_FONTALIAS|REPORTS_ENHANCED_SUBSET)='
}

check() {
  echo "== WLS_REPORTS now:"
  wls_env | sed 's/^/   /' || echo "   (not running, or not its environment)"
  echo "== $U, [ PDF:Subset ]:"
  awk '/^\[ *PDF:Subset *\]/ {on = 1; next} /^\[/ {on = 0} on && !/^#/ && NF' "$U" | sed 's/^/   /'
  echo "== $F:"
  ls "$F" 2>/dev/null | sed 's/^/   /'
  if command -v pdffonts > /dev/null 2>&1 && command -v curl > /dev/null 2>&1; then
    echo "== the fonts of a PDF of BK_STATEMENT (right: DejaVuSans, emb yes):"
    curl -s -o /tmp/bk_fonts.pdf "$URL" && pdffonts /tmp/bk_fonts.pdf | sed 's/^/   /'
  else
    echo "== (pdffonts: sudo dnf -y install poppler-utils, to see the fonts of a PDF)"
  fi
}

if [ "${1:-}" = --check ]; then
  check
  exit 0
fi

# 1. the fonts
mkdir -p "$F" || die "the folder $F: not made"
for f in DejaVuSans.ttf DejaVuSans-Bold.ttf DejaVuSansMono.ttf DejaVuSansMono-Bold.ttf; do
  if [ ! -f "$F/$f" ]; then
    src=$(find /usr/share/fonts -name "$f" 2>/dev/null | head -1)
    [ -n "$src" ] || die "no $f in /usr/share/fonts: as chris, sudo dnf -y install dejavu-sans-fonts dejavu-sans-mono-fonts"
    cp "$src" "$F/" && echo "== $f -> $F"
  fi
done

# 2. uifont.ali: the faces of the reports, the most particular first (bold before the face itself)
want=('Arial...Bold = "DejaVuSans-Bold.ttf"' 'Arial = "DejaVuSans.ttf"'
      'Helvetica...Bold = "DejaVuSans-Bold.ttf"' 'Helvetica = "DejaVuSans.ttf"'
      '"Courier New"...Bold = "DejaVuSansMono-Bold.ttf"' '"Courier New" = "DejaVuSansMono.ttf"'
      'Courier...Bold = "DejaVuSansMono-Bold.ttf"' 'Courier = "DejaVuSansMono.ttf"')
missing=()
for w in "${want[@]}"; do
  key=${w%% = *}
  # (that face mapped already, in [ PDF:Subset ]: as it is)
  if ! awk -v k="$key" '/^\[ *PDF:Subset *\]/ {on = 1; next} /^\[/ {on = 0}
        on && !/^#/ { split($0, a, "="); g = a[1]; gsub(/[ \t]+$/, "", g); if (g == k) found = 1 } END {exit !found}' "$U"; then
    missing+=("$w")
  fi
done
if [ ${#missing[@]} -gt 0 ]; then
  cp -p "$U" "$U.bk-$STAMP"
  grep -q '^\[ *PDF:Subset *\]' "$U" || printf '\n[ PDF:Subset ]\n' >> "$U"
  add=$(printf '%s\\n' "${missing[@]}")
  sed -i "/^\[ *PDF:Subset *\]/a ${add%\\n}" "$U"
  echo "== $U: added (its copy: $U.bk-$STAMP)"
  printf '   %s\n' "${missing[@]}"
else
  echo "== $U: the faces mapped already"
fi

# 3. the environment of WLS_REPORTS: where the fonts are, which uifont.ali (and NLS_LANG), at its start
if grep -q 'REPORTS_FONT_DIRECTORY' "$O" 2>/dev/null; then
  echo "== $O: REPORTS_FONT_DIRECTORY there already"
else
  [ -f "$O" ] && cp -p "$O" "$O.bk-$STAMP"
  cat >> "$O" <<END
# the Greek of the reports in PDF (bank/reports/pdf_fonts.sh)
if [ "\$SERVER_NAME" = "WLS_REPORTS" ]; then
  export NLS_LANG=AMERICAN_GREECE.AL32UTF8
  export TNS_ADMIN=$D/config/fmwconfig
  export REPORTS_FONT_DIRECTORY=$F
  export REPORTS_ENHANCED_SUBSET=YES
  export TK_FONTALIAS=$U
fi
END
  chmod +x "$O"
  echo "== $O: the environment of WLS_REPORTS added"
fi
echo "== now, as chris: sudo systemctl restart weblogic-forms   (some minutes), then: $0 --check"
