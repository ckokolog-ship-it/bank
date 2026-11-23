# Τα reports της τράπεζας (Oracle Reports 14)

Τα reports βρίσκονται στον φάκελο `reports/` και φτιάχνονται όπως του mini market:
- το `mkreports.py` γράφει το report σε XML (μόνο ASCII)·
- στο forms1, το `build_reports.sh` το μετατρέπει σε `.rdf` (rwconverter) στον φάκελο του Reports Server, `/u01/app/oracle/reports`.

Οι γραμμές τους βγαίνουν από τη βάση, από το πακέτο `BK_REPORT` (`db/BK_REPORT.sql`). Από εκεί έρχονται και τα ελληνικά: ο τίτλος, οι επικεφαλίδες και οι λέξεις.

| Report | Τι δείχνει |
|---|---|
| `BK_STATEMENT` | Η **καρτέλα** ενός λογαριασμού σε ένα διάστημα: κάθε γραμμή με ημερομηνία λογισμού και αξίας, την εγγραφή (`#`), το είδος και την περιγραφή, χρέωση, πίστωση και το τρέχον υπόλοιπο. Πρώτα το υπόλοιπο πριν από το διάστημα. Ένας αντιλογισμός σημειώνεται «(αντιλογίστηκε)» |
| `BK_CC_STATEMENT` | Η **κίνηση (statement) μιας πιστωτικής κάρτας**: οι γραμμές του κύκλου της, όπως στην καρτέλα, αλλά το υπόλοιπο είναι η **οφειλή** (χρεώσεις μείον πληρωμές). Ξεκινά από το προηγούμενο υπόλοιπο και τελειώνει στο νέο. Κάτω από τον τίτλο: η ημερομηνία της κίνησης, η ελάχιστη καταβολή, η λήξη της και το όριο |
| `BK_LN_SCHEDULE` | Το **πρόγραμμα αποπληρωμής ενός δανείου**: κάθε δόση με τη λήξη της, το ποσό, το επιτόκιο και την κατάστασή της (θα έρθει, οφείλεται, σε καθυστέρηση με τέλος και τόκους υπερημερίας, πληρώθηκε στις …). Ο τόκος είναι στη χρέωση, το κεφάλαιο στην πίστωση, και το υπόλοιπο είναι το κεφάλαιο που μένει. Κάτω από τον τίτλο: κεφάλαιο, μήνες, σταθερό ή κυμαινόμενο επιτόκιο τώρα, ημέρα δόσης |
| `BK_INTEREST` | Η **εξήγηση των τόκων**: κάθε διάστημα με το ίδιο υπόλοιπο και επιτόκιο, γραμμένο ως «υπόλοιπο × επιτόκιο × ημέρες / ημέρες έτους», με τον τόκο του στην πίστωση (6 δεκαδικά, όπως το `BK_ACCRUAL`). Κάθε κεφαλαιοποίηση εμφανίζεται στη χρέωση (το μικτό ποσό, με τον φόρο και το καθαρό στην περιγραφή). Το «υπόλοιπο» είναι οι δεδουλευμένοι τόκοι που δεν έχουν κεφαλαιοποιηθεί ακόμα |

Όλα έχουν σε κάθε σελίδα:
- πάνω «Από μεταφορά» και κάτω «Σε μεταφορά»·
- στο τέλος τα σύνολα του διαστήματος, το υπόλοιπο πριν από αυτό και το υπόλοιπο στο τέλος.

Οι παράμετροί τους:
- `P_KIND` είναι `S` (καρτέλα), `I` (τόκοι), `C` (κίνηση κάρτας) ή `L` (πρόγραμμα δανείου)·
- `P_ACCOUNT` είναι ο κωδικός του λογαριασμού·
- `P_FROM` και `P_TO` είναι οι ημερομηνίες, `ΗΗ/ΜΜ/ΕΕΕΕ`· στην κίνηση κάρτας, η αρχή του κύκλου και η ημερομηνία της κίνησης.

## 1. Στο forms1, μία φορά

Οι φόρμες πρέπει να είναι ήδη στημένες ([ODIGIES_FORMS.md](ODIGIES_FORMS.md): το wallet και το κλειδί `bank` του `cgicmd.dat` τα γράφει το `bk_wallet.sh`).

```bash
sudo -iu oracle git -C bank pull

# 1. ξανά το INSTALL χωρίς demo: τα δεδομένα μένουν, μπαίνει το BK_REPORT (και οι νέες λέξεις των φορμών)
sudo -iu oracle bash -c 'cd ~/bank/db && export NLS_LANG=GREEK_GREECE.AL32UTF8 && sqlplus bank@localhost:1521/FREEPDB1 @INSTALL.sql'

# 2. πού ανοίγουν οι φόρμες τα reports (μία φορά): η διεύθυνση του Reports Server και η μορφή (PDF ή HTML)
sudo -iu oracle bash -c 'cd ~/bank/db && sqlplus /@BK_DB @SET_REPORTS_URL.sql http://forms1.home.lan:9012 PDF'

# 3. τα reports και οι φόρμες: σε session κατευθείαν ως oracle (MobaXterm με X11-forwarding)
su - oracle
cd ~/bank/reports && ./build_reports.sh                  # XML -> .rdf στο /u01/app/oracle/reports
cd ~/bank/forms && ./build_forms.sh /@BK_DB BK_ACCOUNTS    # τα νέα κουμπιά της φόρμας
```

### Τα ελληνικά στο PDF (μία φορά)

Όταν το HTML βγαίνει σωστό και το PDF έχει «ιερογλυφικά», φταίει η γραμματοσειρά του PDF:
- **Γιατί:** οι γραμματοσειρές που έχει μέσα του ένα PDF δεν έχουν ελληνικά, και ο Reports Server βάζει στη θέση τους μια TrueType, σύμφωνα με το `uifont.ali` (`[ PDF:Subset ]`).
- **Η γραμματοσειρά των πεδίων:** τα reports ζητούν `Helvetica`, που υπάρχει στο Linux. Αρχικά ζητούσαν `Arial`, που στο Linux δεν υπάρχει, και το `rwconverter` έβαζε στη θέση της **Symbol**. Το σύμπτωμα ήταν:
  - το IBAN έβγαινε «ΓΡ…» αντί για «GR…», ήδη στο HTML·
  - τα ελληνικά έβγαιναν μαθηματικά σύμβολα στο PDF.

  Αν το ξαναδείς, τα reports είναι χτισμένα από παλιό XML: `./build_reports.sh`.
- **Τι κάνει το `pdf_fonts.sh`** (όπως το `reports_server.ps1` του PROPO στα Windows):
  - αντιστοιχίζει τα `Helvetica`, `Arial`, `Courier` και `Courier New` στο DejaVu, που έχει ελληνικά (και τα έντονα στο DejaVu Bold), στο `[ PDF:Subset ]` του `uifont.ali`·
  - βάζει σε σχόλιο ένα alias αυτών των γραμματοσειρών στο `[ Global ]`, που αλλιώς κάνει τον engine να αγνοεί το `[ PDF:Subset ]`·
  - **αντιγράφει το `uifont.ali` στο Oracle_Home** (`middleware/guicommon/tk/admin` και `middleware/tools/common`). Εκεί το διαβάζει ο engine του `WLS_REPORTS`, και όχι το αρχείο του domain, ακόμα και με `TK_FONTALIAS`. Αυτό βρέθηκε στα Windows, και ισχύει και στο Linux·
  - βάζει τις γραμματοσειρές στο `/u01/app/oracle/fonts`, και τον φάκελο στο `REPORTS_PATH` του `WLS_REPORTS`, όπου ο engine ψάχνει τα `.ttf`·
  - κάνει **`FontSpecific`** το `EncodingScheme` στα αρχεία AFM των Helvetica, Courier και Times (`guicommon/tk/admin/AFM`). Ο server, χωρίς οθόνη, μετρά τις γραμματοσειρές από αυτά. Με το αρχικό `AdobeStandardEncoding` δεν τις δέχεται για ελληνικό κείμενο και βάζει σε **όλα** τα πεδία τη Symbol. Αυτό είναι το Oracle bug 2906401, με σύμπτωμα το «ΓΡ» στη θέση του «GR» στο HTML (`face="symbol"` στο Ctrl+U) και σύμβολα στο PDF. Ο φάκελος κρατιέται πρώτα (`AFM.bk-<ημερομηνία>`), και με `--undo-afm` ξαναγίνεται όπως ήταν·
  - ελέγχει το υπόλοιπο περιβάλλον του `WLS_REPORTS` (`REPORTS_FONT_DIRECTORY`, `TK_FONTALIAS`, `NLS_LANG`) στο `setUserOverrides.sh`·
  - κρατά πρώτα αντίγραφο κάθε αρχείου που αλλάζει (`.bk-<ημερομηνία>`), και μια δεύτερη εκτέλεση δεν αλλάζει τίποτα.

```bash
# ως chris, μία φορά: οι γραμματοσειρές DejaVu, και το pdffonts για τον έλεγχο
sudo dnf -y install dejavu-sans-fonts dejavu-sans-mono-fonts poppler-utils
sudo -iu oracle ~oracle/bank/reports/pdf_fonts.sh
sudo systemctl restart weblogic-forms
sudo -iu oracle ~oracle/bank/reports/pdf_fonts.sh --check     # μετά από λίγα λεπτά
```

Το `--check` δείχνει:
- το περιβάλλον του `WLS_REPORTS`, με το `REPORTS_PATH`·
- τα aliases του `[ Global ]` (σωστό: κανένα) και τις αντιστοιχίσεις του `[ PDF:Subset ]`·
- αν τα αρχεία του Oracle_Home είναι ίδια με αυτό του domain.

Για τον έλεγχο του ίδιου του PDF, άνοιξε ένα report στον browser. Το `pdffonts` σε ένα κατεβασμένο PDF πρέπει να δείχνει `DejaVuSans` με `emb yes`.

Τα reports του mini market ζητούν ακόμα `Arial`. Αν χτιστούν στο forms1, θέλουν την ίδια αλλαγή (`FONT` στο `mkreports.py`).

Αν δεν υπάρχει οθόνη από το session, το `build_reports.sh` χρησιμοποιεί εικονική (`xvfb-run`), όπως και το `build_forms.sh`. Με `XML_DISPLAY=session` ή `XML_DISPLAY=xvfb` διαλέγεις ποια από τις δύο.

Δοκιμή με το χέρι, στον browser:

```
http://forms1.home.lan:9012/reports/rwservlet?bank&report=BK_STATEMENT.rdf&destype=cache&desformat=PDF&P_KIND=S&P_ACCOUNT=1&P_FROM=01/01/2026&P_TO=31/12/2026
http://forms1.home.lan:9012/reports/rwservlet?bank&report=BK_INTEREST.rdf&destype=cache&desformat=PDF&P_KIND=I&P_ACCOUNT=2&P_FROM=01/01/2026&P_TO=31/12/2026
```

Το `?bank` είναι το κλειδί του `cgicmd.dat` (`userid=/@BK_DB`), οπότε στη διεύθυνση δεν υπάρχει κωδικός.

## 2. Από τη φόρμα των λογαριασμών

Στη φόρμα **Λογαριασμοί** (`BK_ACCOUNTS`), κάτω από τις κινήσεις, υπάρχουν:
- τα πεδία **Από** (η 1η Ιανουαρίου) και **Έως** (σήμερα)·
- τα κουμπιά **Εκτύπωση καρτέλας** και **Εκτύπωση τόκων**.

Τα κουμπιά ανοίγουν το report του λογαριασμού της οθόνης σε νέο παράθυρο του browser. Η «Εκτύπωση τόκων» πρώτα μετρά τους τόκους ως χθες (`bk_core.accrue`), ώστε να φαίνονται και οι πιο πρόσφατοι.

Αν δεν έχει τρέξει το `SET_REPORTS_URL.sql`, η φόρμα το λέει.

Το πρόγραμμα αποπληρωμής ενός δανείου τυπώνεται από τη φόρμα **Δάνεια** (`BK_LOANS`), με «Εκτύπωση προγράμματος».

Η κίνηση μιας πιστωτικής κάρτας τυπώνεται από τη φόρμα **Πιστωτικές κάρτες** (`BK_CCARDS`): διαλέγεις μια κίνηση από κάτω και πατάς «Εκτύπωση της επιλεγμένης κίνησης».

## 3. Πώς είναι φτιαγμένα

Η λογική τους είναι στη βάση: `bk_report.report_rows(p_kind, p_account_id, p_from, p_to)`, pipelined. Κάθε γραμμή έχει:
- `ldate`, `doc_text`, `descr`, `debit`, `credit`, `balance`·
- `prior_debit`, `prior_credit`, `prior_balance`: τα σύνολα του διαστήματος πριν από τη γραμμή·
- `cum_debit`, `cum_credit`: τα σύνολα μαζί με αυτήν.

Το report κρατά την πρώτη `prior_*` κάθε σελίδας (την «Από μεταφορά») και την τελευταία `cum_*` (τη «Σε μεταφορά»). Χωρίς καμία κίνηση στο διάστημα, βγαίνει μία γραμμή: το υπόλοιπο πριν από αυτό.

Μπορείς να τις δεις και από SQL:

```sql
select * from table(bk_report.report_rows('S', 1, date '2026-11-01', date '2026-11-30'));
select * from table(bk_report.report_rows('I', 2, date '2026-07-01', date '2026-09-30'));
```

Στους τόκους, ένα διάστημα που αρχίζει πριν από το `P_FROM` και τελειώνει μέσα του εμφανίζεται ολόκληρο. Οι τόκοι του μετρούν στο διάστημα του report και όχι στο «πριν».

Τα tests είναι στο `tests/test_reports.py`:
- το XML·
- οι γραμμές της καρτέλας και των τόκων, απέναντι στο `BK_LINE`, το `BK_ACCRUAL`, το `BK_CAPITAL` και τα δεδουλευμένα του λογαριασμού·
- οι λέξεις.

Το κουμπί της φόρμας ελέγχεται στο `tests/test_forms.py`.
