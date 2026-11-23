#!/bin/bash
# pdf_fonts.sh -- on forms1, as oracle: the Greek of the reports in PDF. The fonts built into a PDF have no Greek;
# the Reports Server puts a TrueType font in their place by uifont.ali ([ PDF:Subset ]): Helvetica and Arial (the
# reports of the bank, of the mini market) to DejaVu Sans, Courier to DejaVu Sans Mono, their bold to the bold.
# As on Windows for PROPO (retro/oracle/windows/reports_server.ps1, FORMS_REPORTS_ODIGOS.md):
#   - the engine of WLS_REPORTS reads uifont.ali from the Oracle_Home (guicommon/tk/admin, tools/common), not the
#     one of the domain, even with TK_FONTALIAS: the file of the domain is made right, then copied there;
#   - an alias of these faces in [ Global ] makes it skip [ PDF:Subset ] (the Type 1 fonts of the PDF: no Greek):
#     such lines put in comments;
#   - it looks for the .ttf in REPORTS_PATH: the folder of the fonts in it (setUserOverrides.sh of WLS_REPORTS).
#
#   ./pdf_fonts.sh            then, as chris: sudo systemctl restart weblogic-forms
#   ./pdf_fonts.sh --check    what is there now
#
# A second run changes nothing. Every file changed is kept first (.bk-<date>).
set -u
D=${DOMAIN_HOME:-/u01/app/oracle/config/domains/forms_domain}
MW=${MW_HOME:-/u01/app/oracle/middleware}
U=$D/config/fmwconfig/components/ReportsToolsComponent/reptools1/guicommon/tk/admin/uifont.ali
HOMES=("$MW/guicommon/tk/admin/uifont.ali" "$MW/tools/common/uifont.ali")
O=$D/bin/setUserOverrides.sh
F=${FONT_DIR:-/u01/app/oracle/fonts}
R=${REPORTS_DIR:-/u01/app/oracle/reports}
FACES='"Courier New"|"Times New Roman"|Courier New|Times New Roman|Courier|Helvetica|Arial|Times'
STAMP=$(date +%Y%m%d%H%M%S)
die() { echo "== $*"; exit 1; }
[ "$(id -un)" = oracle ] || die "as oracle: sudo -iu oracle, then this again"
[ -f "$U" ] || die "no $U (DOMAIN_HOME=$D?)"
[ -d "$MW" ] || die "no $MW (MW_HOME?)"

# the environment of the running WLS_REPORTS (its process: by its command line, without pgrep -f)
wls_env() {
  local pid
  pid=$(ps -eo pid=,args= | grep 'weblogic.Name=WLS_REPORTS' | grep -v grep | awk 'NR == 1 {print $1}')
  [ -n "$pid" ] && tr '\0' '\n' < /proc/"$pid"/environ 2>/dev/null |
    grep -E '^(NLS_LANG|REPORTS_PATH|REPORTS_FONT_DIRECTORY|TK_FONTALIAS|REPORTS_ENHANCED_SUBSET)='
}

# the lines of a section of an ini file (not the comments)
section() { awk -v s="$2" '$0 ~ "^\\[ *" s " *\\]" {on = 1; next} /^\[/ {on = 0} on && !/^#/ && NF' "$1"; }

check() {
  echo "== WLS_REPORTS now:"
  wls_env | sed 's/^/   /' || echo "   (not running, or not its environment)"
  echo "== $U:"
  echo "   [ Global ], the aliases of the faces of the reports (none: right):"
  section "$U" Global | grep -E "^\s*($FACES)\s*=" | sed 's/^/     /'
  echo "   [ PDF:Subset ]:"
  section "$U" PDF:Subset | sed 's/^/     /'
  for h in "${HOMES[@]}"; do
    if cmp -s "$U" "$h"; then echo "== $h: the same (right)"; else echo "== $h: NOT the same: ./pdf_fonts.sh"; fi
  done
  echo "== $F:"
  ls "$F" 2>/dev/null | sed 's/^/   /'
  echo "== a PDF: open a report in the browser; with pdffonts (sudo dnf -y install poppler-utils), right: DejaVuSans, emb yes"
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

# 2. uifont.ali of the domain: no alias of the faces in [ Global ]; the faces in [ PDF:Subset ], the most
# particular first (bold before the face itself)
want=('Arial...Bold = "DejaVuSans-Bold.ttf"' 'Arial = "DejaVuSans.ttf"'
      'Helvetica...Bold = "DejaVuSans-Bold.ttf"' 'Helvetica = "DejaVuSans.ttf"'
      '"Courier New"...Bold = "DejaVuSansMono-Bold.ttf"' '"Courier New" = "DejaVuSansMono.ttf"'
      'Courier...Bold = "DejaVuSansMono-Bold.ttf"' 'Courier = "DejaVuSansMono.ttf"')
new=$(mktemp)
awk -v faces="$FACES" '
  /^\[/ { sec = $0; gsub(/^\[ *| *\].*$/, "", sec) }
  sec == "Global" && $0 ~ "^[ \t]*(" faces ")[ \t]*=" { print "# (pdf_fonts.sh: no alias, for the PDF subset) " $0; next }
  { print }' "$U" > "$new"
missing=()
for w in "${want[@]}"; do
  key=${w%% = *}
  if ! section "$new" PDF:Subset | awk -v k="$key" '{ split($0, a, "="); g = a[1]; gsub(/[ \t]+$/, "", g); if (g == k) f = 1 }
                                                   END {exit !f}'; then
    missing+=("$w")
  fi
done
if [ ${#missing[@]} -gt 0 ]; then
  grep -q '^\[ *PDF:Subset *\]' "$new" || printf '\n[ PDF:Subset ]\n' >> "$new"
  add=$(printf '%s\\n' "${missing[@]}")
  sed -i "/^\[ *PDF:Subset *\]/a ${add%\\n}" "$new"
fi
if cmp -s "$U" "$new"; then
  echo "== $U: as it should be already"
  rm -f "$new"
else
  cp -p "$U" "$U.bk-$STAMP"
  cat "$new" > "$U"
  rm -f "$new"
  echo "== $U: written (its copy: $U.bk-$STAMP)"
fi

# 3. the same file in the Oracle_Home, where the engine reads it
for h in "${HOMES[@]}"; do
  if cmp -s "$U" "$h"; then
    echo "== $h: the same already"
  else
    mkdir -p "$(dirname "$h")" || die "the folder of $h: not made"
    [ -f "$h" ] && cp -p "$h" "$h.bk-$STAMP"
    cp "$U" "$h" || die "$h: not written"
    echo "== $h: written (the engine of WLS_REPORTS reads it there)"
  fi
done

# 4. the environment of WLS_REPORTS: the fonts, uifont.ali, NLS_LANG; the folder of the fonts in REPORTS_PATH
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
if grep -q "REPORTS_PATH=.*$F" "$O" 2>/dev/null; then
  echo "== $O: $F in REPORTS_PATH already"
else
  [ -f "$O.bk-$STAMP" ] || cp -p "$O" "$O.bk-$STAMP"
  cat >> "$O" <<END
# the TrueType fonts of the PDF: the engine looks for them in REPORTS_PATH (bank/reports/pdf_fonts.sh)
if [ "\$SERVER_NAME" = "WLS_REPORTS" ]; then
  export REPORTS_PATH=$F:$R\${REPORTS_PATH:+:\$REPORTS_PATH}
fi
END
  echo "== $O: $F in REPORTS_PATH"
fi
echo "== now, as chris: sudo systemctl restart weblogic-forms   (some minutes), then: $0 --check, and a report in PDF"
