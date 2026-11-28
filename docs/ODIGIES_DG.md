# Η βάση σε Oracle Enterprise με Data Guard

Σήμερα η βάση της τράπεζας είναι η Oracle 26ai **Free** στο forms1 (.200). Είναι μία μόνο, οπότε αν πέσει το forms1,
σταματούν όλα: φόρμες, ATM, το cluster k3s. Το σχέδιο είναι η **Oracle AI Database 26ai Enterprise Edition** σε δύο νέα VMs,
με **Data Guard**:

| VM | IP | Ρόλος |
|----|----|-------|
| `db1` | 192.168.178.221 | primary (η βάση που γράφει) |
| `db2` | 192.168.178.222 | physical standby: παίρνει κάθε αλλαγή (redo) του db1 |
| `forms1` | 192.168.178.200 | ο observer του Fast-Start Failover: αν πέσει ο db1, ο db2 γίνεται primary μόνος του |

Ο οδηγός γίνεται σε βήματα, ένα PR για καθένα:

1. **Τα VMs και το λογισμικό** (αυτός ο οδηγός, §1–§4).
2. Η βάση `BANK` (CDB) με το PDB `BANKPDB` στον db1.
3. Η μεταφορά του σχήματος `BANK` από το forms1 με Data Pump (μαζί τα μοντέλα του AI).
4. Ο standby στον db2 (RMAN `DUPLICATE ... FROM ACTIVE DATABASE`).
5. Ο Broker, το Fast-Start Failover, ο observer στο forms1.
6. Οι εφαρμογές στη νέα βάση (`bk-api` στο k3s, οι φόρμες, τα reports) και δοκιμές failover.

## 1. Τα VMs (Windows)

Με το ίδιο `k8s/vms.ps1` του cluster, με άλλες παραμέτρους. Η βάση θέλει περισσότερη μνήμη και δίσκο: 8 GB, 3 vCPU,
100 GB (ο δίσκος του VirtualBox μεγαλώνει όσο γεμίζει, δεν πιάνει αμέσως 100 GB).

Στον φάκελο όπου είναι το `vms.ps1` και το ISO των k3s (π.χ. `L:\Cluster Setup`), σε PowerShell:

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
.\vms.ps1 -Iso "L:\Cluster Setup\OracleLinux-R9-U8-x86_64-dvd.iso" -Names db1,db2 -MemoryMB 8192 -Cpus 3 -DiskGB 100
```

Το ISO είναι το ίδιο με των k3s. Αν πάρεις το `vms.ps1` πριν από αυτή τη διόρθωση και το τρέξεις με `powershell -File`,
το `db1,db2` γίνεται **ένα** VM με όνομα `db1,db2`. Το σβήνεις με
`& "$env:ProgramFiles\Oracle\VirtualBox\VBoxManage.exe" unregistervm "db1,db2" --delete`.

Ο κωδικός του `chris` ζητείται μία φορά. Βάλε **καινούργιο** κωδικό, όχι αυτόν των
άλλων VMs. Η εγκατάσταση κάθε VM θέλει 10–15 λεπτά.

## 2. Σταθερή IP από την κονσόλα

Όπως στα k3s (μάθημα από εκεί), η IP αλλάζει **από την κονσόλα του VirtualBox** και όχι από ssh, γιατί η σύνδεση ssh κόβεται.
Login ως `chris` στην κονσόλα του db1:

```bash
CON=$(nmcli -t -f NAME,DEVICE con show --active | awk -F: '$2!="lo"{print $1; exit}')
sudo nmcli con mod "$CON" ipv4.method manual ipv4.addresses 192.168.178.221/24 ipv4.gateway 192.168.178.1 ipv4.dns 192.168.178.1
sudo nmcli con up "$CON"
ip -4 addr | grep 192.168
```

Το ίδιο στον db2 με `192.168.178.222/24`. Μετά ο υπόλοιπος οδηγός γίνεται με ssh (MobaXterm).

Αν το `sudo` απαντήσει «chris is not in the sudoers file»: `su -` (ο κωδικός του root είναι ίδιος), μετά
`usermod -aG wheel chris`, `exit`, και ξανά login.

## 3. Το zip (Windows) και το script (forms1) στα VMs

Το zip (περίπου 2 GB) είναι στο `L:\Oracle\Oracle 21\LINUX.X64_2326100_db_home.zip`. Πάει στο home του `chris`
(όχι στο `/tmp`, γιατί μπορεί να είναι μικρό). Από το PowerShell των Windows (OpenSSH):

```powershell
scp "L:\Oracle\Oracle 21\LINUX.X64_2326100_db_home.zip" chris@192.168.178.221:
scp "L:\Oracle\Oracle 21\LINUX.X64_2326100_db_home.zip" chris@192.168.178.222:
```

Το `db_host.sh` πάει από το forms1, όπου είναι το repo (ως `oracle`):

```bash
cd ~/bank && git pull
scp dg/db_host.sh chris@192.168.178.221:
scp dg/db_host.sh chris@192.168.178.222:
```

## 4. Το λογισμικό σε κάθε VM

Με ssh στον db1:

```bash
sudo bash ~/db_host.sh 192.168.178.221 ~/LINUX.X64_2326100_db_home.zip
```

Και στον db2:

```bash
sudo bash ~/db_host.sh 192.168.178.222 ~/LINUX.X64_2326100_db_home.zip
```

Τι κάνει (θέλει περίπου 10–20 λεπτά):

- **Όνομα** `db1`/`db2` (από το τελευταίο νούμερο της IP) και σταθερή IP, αν δεν την έχει ήδη.
- **`/etc/hosts`**: forms1, db1, db2, k3s1–3. Ο Data Guard μιλάει με ονόματα.
- **Το πακέτο προαπαιτούμενων** `oracle-ai-database-preinstall-26ai` (αν λείπει, το `...-23ai`). Αυτό φτιάχνει τον
  χρήστη `oracle`, τις ομάδες `oinstall`/`dba`/`dgdba`…, τις ρυθμίσεις του kernel και τα limits.
- **firewalld**: η θύρα 1521 (οι εφαρμογές, και το redo από τον db1 στον db2).
- **`/u01/app/oracle/product/26ai/dbhome_1`**: το zip αποσυμπιέζεται εκεί ως `oracle`. Μετά τρέχει
  `runInstaller -silent`, **μόνο λογισμικό**, Enterprise Edition, με το response file του ίδιου του zip
  (`install/response/db_install.rsp`), συμπληρωμένα τα κλειδιά του. Μετά τρέχουν τα `orainstRoot.sh` και `root.sh`.
- **Το περιβάλλον του `oracle`** (`~/.bash_profile`): `ORACLE_HOME`, `ORACLE_SID=BANK`, `PATH`.

Στο τέλος πρέπει να δεις κάτι σαν:

```
SQL*Plus: Release 23.26.1.0.0 - Production
== db1 ready (software). Next: docs/ODIGIES_DG.md
```

Έλεγχος:

```bash
sudo su - oracle
echo $ORACLE_HOME
$ORACLE_HOME/OPatch/opatch lspatches
```

Αν τρέξει ξανά, το script αφήνει ό,τι υπάρχει ήδη και δεν ξαναεγκαθιστά.

### Αν κάτι πάει στραβά

| Μήνυμα | Τι κάνεις |
|--------|-----------|
| `this is forms1...` / `k3s...` | Είσαι σε λάθος μηχάνημα. Το script είναι μόνο για τα db1/db2 |
| `no package oracle-ai-database-preinstall-26ai nor -23ai` | `dnf repolist`: πρέπει να υπάρχουν τα `ol9_baseos_latest` και `ol9_appstream` |
| `runInstaller: 1` (ή άλλο νούμερο) | Το log είναι στο `/u01/app/oraInventory/logs/`. Στείλε μου τις τελευταίες γραμμές: `sudo tail -50 /u01/app/oraInventory/logs/InstallActions*/installActions*.log` |
| `No space left on device` | `df -h /u01 ~`. Μετά την εγκατάσταση σβήσε το zip: `rm ~/LINUX.X64_2326100_db_home.zip` |

Μετά την εγκατάσταση σβήσε το zip: `rm ~/LINUX.X64_2326100_db_home.zip`.

## 5. Η βάση στον db1 (primary)

Από το forms1 (ως `oracle`) πάει το script στον db1:

```bash
cd ~/bank && git pull
scp dg/primary.sh chris@192.168.178.221:
```

Με ssh στον db1:

```bash
sudo bash ~/primary.sh
```

Τι κάνει (περίπου 15–30 λεπτά):

- **Listener** στη θύρα 1521. Έχει και μια στατική εγγραφή `BANK_DB1_DGMGRL`, ώστε ο Broker να μπορεί να ξεκινήσει τη βάση σε switchover.
- **`tnsnames.ora`** με τα `BANK_DB1`, `BANK_DB2` και `BANKPDB`. Το `BANKPDB` δοκιμάζει πρώτα τον db1 και μετά τον db2,
  ώστε να βρίσκει τη βάση όπου είναι ανοιχτή.
- **dbca χωρίς παράθυρο**: η CDB `BANK` με το PDB `BANKPDB`, AL32UTF8, αρχεία OMF στο `/u01/app/oracle/oradata`,
  archive log, fast recovery area 30 GB, μνήμη 3 GB.
  Το **dbca ζητά τους κωδικούς** του SYS, του SYSTEM και του διαχειριστή του PDB. Οι κωδικοί δεν γράφονται ποτέ σε αρχείο.
  Βάλε έναν ισχυρό κωδικό, ίδιο και για τους τρεις, και **κράτα τον**. Θα χρειαστεί για τον standby και τον Broker.
- **Ό,τι θέλει ο Data Guard**:
  - `db_unique_name = BANK_DB1`;
  - force logging και flashback;
  - 4 standby redo logs (όσο μεγάλα είναι τα redo logs);
  - `standby_file_management = AUTO`;
  - ο Broker (`dg_broker_start`).
- **Η βάση ξεκινά μαζί με το VM**, μέσα από την υπηρεσία systemd `oracle-bank` (`dbstart`/`dbshut`). Το PDB ανοίγει σε κάθε εκκίνηση.

Στο τέλος δείχνει κάτι σαν:

```
NAME   DB_UNIQUE_NAME DATABASE_ROLE    OPEN_MODE    LOG_MODE     FOR FLASHBACK_ON
BANK   BANK_DB1       PRIMARY          READ WRITE   ARCHIVELOG   YES YES
BANKPDB  READ WRITE
```

Έλεγχος:

```bash
sudo su - oracle
sqlplus system@BANKPDB
```

Αν βγει λάθος από το dbca, το log του είναι στο `/u01/app/oracle/cfgtoollogs/dbca/BANK/`.

## 6. Το σχήμα BANK από το forms1 στον db1 (Data Pump)

Αντίγραφο του σχήματος `BANK`, με τους πίνακες, τα πακέτα, τα μοντέλα του AI, τον χρήστη και τα δικαιώματά του. Οι
εφαρμογές **συνεχίζουν στο forms1**, γιατί εδώ δεν μεταφέρεται καμία σύνδεση. Αυτό γίνεται σε επόμενο βήμα.
Το αντίγραφο μπορεί να ξαναγίνει όσες φορές θέλεις. Το τελευταίο θα γίνει με τις εφαρμογές σταματημένες, πριν
μεταφερθούν στον db1.

**Στο forms1** (ως `oracle`):

```bash
cd ~/bank && git pull
bash dg/export.sh
```

- Το `expdp` ζητά τον κωδικό του **SYSTEM** της βάσης Free.
- Το `scp` στο τέλος ζητά τον κωδικό του **chris στον db1**.
- Στέλνει στο home του chris στον db1:
  - το `bank.dmp`;
  - το `bank_files.tgz` (το μοντέλο `bk_embed.onnx` και τα `docs/` για τη γνώση του βοηθού);
  - το `import.sh`.

**Στον db1** (ssh):

```bash
sudo bash ~/import.sh
```

- Το `impdp` ζητά τον κωδικό του **SYSTEM της νέας βάσης**, αυτόν που έδωσες στο dbca. Ο χρήστης `BANK` έρχεται με
  τον κωδικό που είχε στο forms1.
- Αν ο `BANK` υπάρχει ήδη, το script ρωτά αν θέλεις να τον σβήσει και να τον ξαναφέρει (`yes`).
- Το Data Pump δεν μεταφέρει μερικά πράγματα, οπότε τα ξαναφτιάχνει το script:
  - το δικαίωμα στο `DBMS_CRYPTO` (το login των φορμών);
  - τους καταλόγους `BK_MODELS` και `BK_DOCS` στο `/u01/app/oracle/bank`;
  - το ACL προς το Ollama στα Windows (`192.168.178.54:11434`). Για άλλη IP: `sudo bash ~/import.sh <ip>`.
- Μετά κάνει compile όλο το σχήμα και δείχνει τα αντικείμενα, όσα είναι invalid (πρέπει να μην υπάρχει κανένα) και τα
  μοντέλα του AI (`BK_EMBED` και το μοντέλο των ύποπτων κινήσεων).

Έλεγχος:

```bash
sudo su - oracle
sqlplus bank@BANKPDB
```
```sql
select count(*) from bk_account;
select bk_vec.model_info from dual;
```

## 7. Ο standby στον db2

Ο db2 γίνεται **physical standby**: ένα ακριβές αντίγραφο της βάσης του db1, που παίρνει και εφαρμόζει κάθε αλλαγή.

**Στο forms1** (ως `oracle`), τα scripts:

```bash
cd ~/bank && git pull
scp dg/standby.sh chris@192.168.178.222:
scp dg/broker.sh chris@192.168.178.221:
```

**Στον db1**: το password file πάει στον db2. Πρέπει να είναι **το ίδιο αρχείο**, αλλιώς ο db2 δεν δέχεται το redo.

```bash
sudo cp /u01/app/oracle/product/26ai/dbhome_1/dbs/orapwBANK ~/ && sudo chown chris: ~/orapwBANK
scp ~/orapwBANK chris@192.168.178.222: && rm ~/orapwBANK
```

**Στον db2:**

```bash
sudo bash ~/standby.sh
```

Τι κάνει (10–30 λεπτά):

- **Listener** με στατικές εγγραφές:
  - `BANK_DB2`, για να συνδέεται το RMAN όσο η βάση είναι μόνο ξεκινημένη (NOMOUNT);
  - `BANK_DB2_DGMGRL`, για τον Broker.
- **`tnsnames.ora`**, ίδιο με του db1.
- **RMAN `DUPLICATE ... FOR STANDBY FROM ACTIVE DATABASE`**:
  - τα αρχεία έρχονται από τον db1 μέσω δικτύου, χωρίς backup;
  - το spfile αντιγράφεται με `db_unique_name = BANK_DB2`.
- Το RMAN **ζητά δύο φορές τον κωδικό του SYS**: μία για τον db1 (target) και μία για τον db2 (auxiliary). Είναι ο ίδιος κωδικός. Αν έχει `@`, γράψ' τον **μέσα σε διπλά εισαγωγικά**.
- Flashback, ο Broker ξεκινά, και η βάση ξεκινά μαζί με το VM (`oracle-bank`).

Στο τέλος:

```
NAME     DB_UNIQUE_NA DATABASE_ROLE    OPEN_MODE   FLASHBACK_ON
BANK     BANK_DB2     PHYSICAL STANDBY MOUNTED     YES
```

Το flashback του standby **δεν ανάβει αμέσως μετά το RMAN** (ORA-38788), γιατί θέλει πρώτα να εφαρμοστεί λίγο redo.
Γι' αυτό, αφού τρέξει το `broker.sh` (§8), τρέξε ξανά το `sudo bash ~/standby.sh` στον db2. Τότε σταματά για λίγο το apply,
ανάβει το flashback και ξαναξεκινά το apply. Το ξανατρέξιμο είναι ασφαλές: δεν ξαναφτιάχνει τον standby.

Αν το RMAN αποτύχει, το log του είναι στο `/u01/app/oracle/dup_standby.log`: `sudo tail -40 /u01/app/oracle/dup_standby.log`.

## 8. Ο Broker (db1)

**Στον db1:**

```bash
sudo bash ~/broker.sh
```

Φτιάχνει τη διαμόρφωση `BANK`:
- `BANK_DB1` primary;
- `BANK_DB2` physical standby.

Μετά την ενεργοποιεί. Από εκεί και πέρα το redo πηγαίνει μόνο του στον db2 και εφαρμόζεται. Στο τέλος δείχνει:

```
Configuration - bank
  Protection Mode: MaxPerformance
  Members:
  BANK_DB1 - Primary database
    BANK_DB2 - Physical standby database
Configuration Status:
SUCCESS
```

Το `validate database BANK_DB2` λέει αν ο db2 είναι έτοιμος για switchover (`Ready for Switchover: Yes`).

Έλεγχος, ως `oracle` στον db1:

```bash
dgmgrl /
```
```
show configuration lag;
```

## 9. Fast-Start Failover και ο observer (forms1)

Ο **observer** είναι ένα μικρό πρόγραμμα (`dgmgrl`) σε **τρίτο μηχάνημα**, το forms1, που βλέπει και τον db1 και τον db2.
Αν ο primary χαθεί για 30 δευτερόλεπτα, ενώ ο observer και ο standby βλέπουν ακόμα ο ένας τον άλλον, κάνει τον standby
primary **μόνος του**. Όταν ο παλιός primary ξαναγυρίσει, γίνεται standby μόνος του (reinstate, με το flashback).

**Στο forms1** (ως `oracle`), τα scripts:

```bash
cd ~/bank && git pull
scp dg/fsfo.sh chris@192.168.178.221:
```

**Στον db1:**

```bash
sudo bash ~/fsfo.sh
```

- Το redo πηγαίνει **σύγχρονα** στον db2 (`FASTSYNC`). Ένα commit περιμένει μέχρι να το έχει και ο db2, οπότε
  σε failover δεν χάνεται καμία συναλλαγή.
- Η προστασία γίνεται `MaxAvailability`, και το Fast-Start Failover ενεργοποιείται με όριο 30 δευτερόλεπτα.
- Μέχρι να ξεκινήσει ο observer, το `show fast_start failover` λέει ότι δεν υπάρχει observer. Αυτό είναι αναμενόμενο.

**Στο forms1** (ως chris, με sudo):

```bash
sudo bash /home/oracle/bank/dg/observer.sh
```

- Το `/home/oracle` δεν ανοίγει για τον chris, γι' αυτό δεν γίνεται `cd` εκεί. Με το `sudo` όμως το script διαβάζεται κανονικά.
- Το wallet: ο κωδικός του SYS γράφεται **χωρίς εισαγωγικά**, ακόμα κι αν έχει `@`. Τα εισαγωγικά χρειάζονται μόνο στα `expdp`/`impdp`/`rman`.
- Για δοκιμή με το χέρι, ως `oracle`: `export TNS_ADMIN=/home/oracle/dg`, γιατί αλλιώς το `TNS_ADMIN` δείχνει στο Forms domain.
- Το script φτιάχνει τα δικά του αρχεία δικτύου στο `/home/oracle/dg`, ώστε να μην πειράξει τις υπόλοιπες ρυθμίσεις του forms1.
- Φτιάχνει ένα **wallet** με τον κωδικό του SYS. Έτσι ο observer συνδέεται χωρίς να γράφεται κωδικός πουθενά. Το `mkstore` ζητά:
  1. έναν **νέο κωδικό για το wallet**, δύο φορές (όποιον θέλεις, κράτα τον);
  2. τον κωδικό του **SYS** της BANK, για τον BANK_DB1 και ξανά για τον BANK_DB2 (δύο φορές ο καθένας).
- Μετά ξεκινά την υπηρεσία `dg-observer`, που τρέχει πάντα και ξεκινά μαζί με το forms1.

Στο τέλος πρέπει να δεις:

```
Fast-Start Failover: Enabled in Zero Data Loss Mode
  Protection Mode:    MaxAvailability
  Threshold:          30 seconds
  Active Target:      bank_db2
  Observer:           forms1...
```

Ο observer χρησιμοποιεί το `dgmgrl` της Free του forms1. Αν το script πει `no dgmgrl` ή `no mkstore`, στείλε μου
την έξοδο. Τότε ο observer θα μπει με άλλο τρόπο, π.χ. σε container ή στον k3s1.

## 10. Δοκιμή failover

**Στον Windows host**, κλείσε απότομα τον db1: VirtualBox → db1 → Close → **Power off**.

Μετά από 30–60 δευτερόλεπτα, στο forms1:

```bash
sudo su - oracle
TNS_ADMIN=/home/oracle/dg dgmgrl /@BANK_DB2
```
```
show configuration;
```

Πρέπει να δεις τον `bank_db2` ως **Primary**, και τον `BANK_DB1` να χρειάζεται reinstate. Ξεκίνα πάλι τον db1. Σε λίγα
λεπτά γίνεται **standby** μόνος του. Το log του observer: `tail -f /home/oracle/dg/observer.log`.

Αν το reinstate δεν γίνεται και ο observer γράφει `ORA-12541: ... No listener`, ο listener του db1 δεν ξεκίνησε μαζί
με το VM. Ξεκίνα τον στον db1 (ως oracle) με `lsnrctl start`. Αν χρειαστεί, κάνε το reinstate από το forms1:
`export TNS_ADMIN=/home/oracle/dg`, `dgmgrl /@BANK_DB2` (χωρίς κενό ανάμεσα στο `/` και στο `@`) και
`reinstate database BANK_DB1;`.

Μια φορά, στον db1 και στον db2, ώστε ο listener να ξεκινά πάντα μαζί με τη βάση. Τα VMs που φτιάχτηκαν πριν από αυτό
χρειάζονται αυτό το βήμα. Από το forms1 (ως oracle):

```bash
cd ~/bank && git pull
scp dg/oracle_unit.sh chris@192.168.178.221:
scp dg/oracle_unit.sh chris@192.168.178.222:
```

και σε κάθε VM: `sudo bash ~/oracle_unit.sh`.

Για επιστροφή στην αρχική κατάσταση, χωρίς απώλεια:

```
switchover to BANK_DB1;
```

Αν το switchover πει `ORA-12545` για το `db2.home.lan` και «start up and mount instance», το forms1 δεν ξέρει τα
ονόματα db1/db2. Το `observer.sh` τα βάζει πλέον στο `/etc/hosts`. Για να ολοκληρωθεί το switchover, στον db2 (ως oracle) τρέχεις
`sqlplus / as sysdba` και `startup mount`.

Το switchover γίνεται από το forms1, με `dgmgrl /@BANK_DB2`. Θέλει σύνδεση με κωδικό (το wallet), γιατί ο Broker
επανεκκινεί τις βάσεις. Με το `dgmgrl /` στον db2 δεν μπορεί.

## 11. Active Data Guard και οι υπηρεσίες ανά ρόλο

Ο standby ανοίγει **READ ONLY** και ταυτόχρονα εφαρμόζει το redo (Real Time Query). Έτσι τα SELECT στον db2 βλέπουν τα
δεδομένα του db1 με καθυστέρηση κάτω από ένα δευτερόλεπτο. Το Active Data Guard είναι option του Enterprise Edition με
**δική του άδεια**. Εδώ το χρησιμοποιούμε για εκμάθηση.

Στο `BANKPDB` υπάρχουν δύο υπηρεσίες που ακολουθούν τους ρόλους:

| Υπηρεσία | Τρέχει | Για |
|----------|--------|-----|
| `bank_rw` | μόνο στον **primary** | τις εφαρμογές που γράφουν (web, ATM, φόρμες) |
| `bank_ro` | στον **standby**, και στον primary ως εφεδρεία | μόνο ανάγνωση (reports, αναζήτηση) |

Τις ξεκινά ένα trigger κάθε φορά που ανοίγει το PDB, ανάλογα με τον ρόλο. Έτσι μετά από failover ή switchover η
`bank_rw` πηγαίνει μόνη της στον νέο primary. Ένα δεύτερο trigger στο root ανοίγει τα PDBs READ ONLY όταν ξεκινά ένας standby.

**Στο forms1** (ως oracle):

```bash
cd ~/bank && git pull
scp dg/adg.sh chris@192.168.178.221:
scp dg/adg.sh chris@192.168.178.222:
```

**Πρώτα στον db1**, γιατί ο primary φτιάχνει τις υπηρεσίες και τα triggers, και μετά **στον db2**:

```bash
sudo bash ~/adg.sh
```

Στον db2 στο τέλος πρέπει να δεις `PHYSICAL STANDBY  READ ONLY WITH APPLY`, το `BANKPDB` σε `READ ONLY` και την
υπηρεσία `bank_ro`. Στον db1 πρέπει να δεις τις `bank_rw` και `bank_ro`.

Δοκιμή, από το forms1 (ως oracle):

```bash
sqlplus bank@//192.168.178.222:1521/bank_ro
```
```sql
select count(*) from bk_account;
select database_role from v$database;      -- PHYSICAL STANDBY
insert into bk_setting values (null, null); -- ORA-16000: η βάση είναι ανοιχτή μόνο για ανάγνωση
```

## 12. Οι εφαρμογές στη νέα βάση

Όλες οι εφαρμογές που γράφουν συνδέονται στη **`bank_rw`**, με τον db1 και τον db2 στη σειρά. Απαντά όποιος είναι primary.
Μετά από failover, οι νέες συνδέσεις περιμένουν (`RETRY_COUNT`) και βρίσκουν τον db2 μόνες τους.

| Εφαρμογή | Πώς συνδέεται | Τι αλλάζει |
|----------|---------------|------------|
| bk-api στο k3s (web, ATM, REST) | `BK_DB_URL` του ConfigMap | το `deploy.sh` έχει πλέον ως προεπιλογή τη `bank_rw` |
| φόρμες και reports (forms1) | το όνομα `BK_DB` του wallet του domain | το `dg/apps_forms.sh` αλλάζει την εγγραφή `BK_DB` στο `tnsnames.ora` του domain |
| το παλιό bk-api (systemd) στο forms1 | `localhost/FREEPDB1` | σταματά: το web τρέχει πλέον στο k3s |
| mini market (`MM_DB`) | Free του forms1 | τίποτα: μένει στην Free |

Ο κωδικός του `BANK` είναι ο ίδιος, γιατί ήρθε με το Data Pump. Γι' αυτό το wallet και το Secret του k3s δεν αλλάζουν.

**Η σειρά.** Για 10–15 λεπτά η τράπεζα είναι εκτός λειτουργίας, γιατί κατά το τελευταίο αντίγραφο δεν πρέπει να γράφει κανείς στην Free.

**1. Σταματούν οι εφαρμογές.**

Στον **k3s1** (chris):
```bash
sudo /usr/local/bin/k3s kubectl -n bank get deploy bk-api -o jsonpath='{..image}'; echo
sudo /usr/local/bin/k3s kubectl -n bank scale deploy bk-api --replicas=0
```
Το πρώτο δείχνει την εικόνα, π.χ. `localhost/bank/bk-api:072399c`. **Κράτα το tag** μετά το `:`, γιατί θα χρειαστεί στο βήμα 5.

Στο **forms1** (chris):
```bash
sudo systemctl disable --now bk-api
sudo systemctl stop weblogic-forms
```
Το `weblogic-forms` σταματά και τις φόρμες του mini market για λίγα λεπτά.

**2. Το τελευταίο αντίγραφο.**

Στο **forms1** (oracle):
```bash
cd ~/bank && git pull
bash dg/export.sh
```

Στον **db1** (chris):
```bash
sudo bash ~/import.sh
```
Απάντησε `yes` στο «drop it and import again». Ο db2 τα παίρνει μόνος του, μέσω του redo.

**3. Οι φόρμες και τα reports.** Στο **forms1** (oracle):
```bash
bash dg/apps_forms.sh
```
Στο τέλος πρέπει να δείξει `db1 PRIMARY 97` (host, ρόλος, λογαριασμοί).

**4.** Στο **forms1** (chris):
```bash
sudo systemctl start weblogic-forms
```

**5. Το bk-api στο k3s.** Πρώτα στέλνεις το νέο `deploy.sh` στον k3s1. Στο **forms1** (oracle):
```bash
scp k8s/deploy.sh chris@192.168.178.211:bank-k8s/
```

Μετά, στον **k3s1** (chris), με το tag από το βήμα 1:
```bash
sudo ~/bank-k8s/deploy.sh <tag>
```
Το `apply` ξαναφέρνει τα 2 pods με τη νέα σύνδεση.

**6. Έλεγχος.**
- Το web στο http://192.168.178.211/web/ και το ATM.
- Οι φόρμες, από το URL του forms1.
- Ότι γράφουν στον db1: μια κίνηση από το web, και μετά στον **db2** (`bank_ro`) η ίδια κίνηση πρέπει να φαίνεται αμέσως.

**Επιστροφή στην Free**, αν κάτι δεν πάει καλά:
1. Στο forms1, πάρε πίσω το `tnsnames.ora.<ημερομηνία>.bak` του domain και κάνε restart το `weblogic-forms`.
2. Στον k3s1:
   ```bash
   sudo BK_DB_URL=jdbc:oracle:thin:@//192.168.178.200:1521/FREEPDB1 ~/bank-k8s/deploy.sh <tag>
   ```

## 13. Ένα PDB για άλλη εφαρμογή (PROPOPDB)

Μια δεύτερη εφαρμογή μπαίνει στη **ίδια** CDB με την τράπεζα, αλλά σε **δικό της PDB**. Έτσι παίρνει την ίδια προστασία
(redo στον db2, Active Data Guard, Fast-Start Failover) χωρίς να ανακατεύεται με το `BANKPDB`.

Από το forms1 (ως oracle):

```bash
cd ~/bank && git pull
scp dg/pdb.sh chris@192.168.178.221:
```

Στον **db1** (τον primary):

```bash
sudo bash ~/pdb.sh PROPOPDB propo
```

1. **Το PDB `PROPOPDB`** φτιάχνεται από το seed, με τον διαχειριστή του `propoadmin`. Ο κωδικός ζητείται χωρίς να φαίνεται και
   δεν γράφεται πουθενά. Ανοίγει μαζί με τη CDB (`save state`).
2. Στον **db2** έρχεται **μόνο του** με το redo και ανοίγει READ ONLY (Active Data Guard).
3. **Οι υπηρεσίες:**
   - `propo_rw` τρέχει μόνο στον primary, για τις εγγραφές;
   - `propo_ro` τρέχει στον standby, και στον primary ως εφεδρεία, για τις αναγνώσεις.

   Τις ξεκινά ένα trigger ανάλογα με τον ρόλο, όπως στην τράπεζα.
4. **Το `tnsnames.ora` του db1:** το όνομα `PROPOPDB` δείχνει στην `propo_rw`, στους db1 και db2.

Οι εφαρμογές συνδέονται έτσι:

```
jdbc:oracle:thin:@(DESCRIPTION=(CONNECT_TIMEOUT=5)(TRANSPORT_CONNECT_TIMEOUT=3)(RETRY_COUNT=20)(RETRY_DELAY=3)(ADDRESS_LIST=(LOAD_BALANCE=off)(FAILOVER=on)(ADDRESS=(PROTOCOL=TCP)(HOST=192.168.178.221)(PORT=1521))(ADDRESS=(PROTOCOL=TCP)(HOST=192.168.178.222)(PORT=1521)))(CONNECT_DATA=(SERVICE_NAME=propo_rw)))
```

Ο χρήστης και οι πίνακες της εφαρμογής φτιάχνονται από τα δικά της scripts (PROPOApplication, `db/`).

Επόμενο βήμα: δοκιμή failover με τις εφαρμογές ανοιχτές.

## 14. Το mini market στο Data Guard (MMPDB)

Το mini market τρέχει σήμερα στην Oracle Free του forms1 (FREEPDB1, χρήστης **MM**). Πηγαίνει στο Data Guard με τον
ίδιο τρόπο όπως η τράπεζα: δικό του PDB **MMPDB** στον db1, που πηγαίνει μόνο του στον db2 με το redo. Τα Forms, τα
reports και το `mm-api` συνδέονται όλα μέσω του alias **MM_DB** του domain, οπότε με μία αλλαγή του alias
μετακινούνται όλα μαζί. Κανένας κωδικός δεν αλλάζει: ο MM έρχεται με τον δικό του κωδικό μέσω του Data Pump, και το
wallet του domain στο forms1 ταιριάζει ως έχει.

**1. Το PDB (db1, ως chris).** Από το forms1 (ως oracle): `cd ~/bank && git pull && scp dg/pdb.sh chris@192.168.178.221:`.
Μετά στον db1:

```bash
sudo bash ~/pdb.sh MMPDB mm
```

Ζητά τον κωδικό του `mmadmin` (ο διαχειριστής του PDB· όχι ο MM). Φτιάχνει τα services **`mm_rw`** (μόνο στον primary)
και **`mm_ro`** (ο standby), όπως στο §13.

**2. Η τελευταία αντιγραφή (forms1).** Για να μη χαθεί καμία πώληση, **σταμάτησε πρώτα το mini market**: κανείς στα
ταμεία, και ως chris `sudo systemctl stop mm-api`. Μετά, ως oracle:

```bash
cd ~/bank && bash dg/schema_export.sh MM
```

Το expdp ζητά τον κωδικό του **SYSTEM** της Free, και το scp τον κωδικό του chris στον db1.

**3. Η εισαγωγή (db1, ως chris):**

```bash
sudo bash ~/schema_import.sh MM MMPDB
```

Το impdp ζητά τον κωδικό του **SYSTEM** της BANK (της CDB του Data Guard). Μετά δίνει στον MM όσα δεν μεταφέρει το Data
Pump (DBMS_CRYPTO για τα logins, DATA_PUMP_DIR), μεταγλωττίζει και δείχνει τα αντικείμενα. Στα «invalid» πρέπει να μην
υπάρχει τίποτα.

**4. Το alias MM_DB στο Data Guard (forms1, ως oracle):**

```bash
cd ~/bank && ALIAS=MM_DB SERVICE=mm_rw CHECK=mm_item bash dg/apps_forms.sh
```

Κρατά πρώτα αντίγραφο του `tnsnames.ora`, και στο τέλος συνδέεται με `/@MM_DB`: πρέπει να δείξει `db1 PRIMARY` και το
πλήθος των ειδών (mm_item).

**5. Επανεκκίνηση (forms1, ως chris):**

```bash
sudo systemctl restart weblogic-forms mm-api
```

Δοκιμή: τα Forms (`http://forms1.home.lan:9001/forms/frmservlet?config=mm&form=MM_MAIN`), το web και τα ταμεία
(`http://192.168.178.200:8090/`), και `curl -s http://127.0.0.1:8090/api/health` στο forms1.

**Μετά:**

- Σε failover ή switchover, το mini market πηγαίνει μόνο του στον νέο primary (το `mm_rw` ακολουθεί τον ρόλο).
- Η FREEPDB1 του forms1 μένει όπως είναι, ως αντίγραφο της στιγμής της μεταφοράς. Μην τη χρησιμοποιείς πια.
- **Τα αντίγραφα του `db/backup.sh`:** γράφουν με expdp στο DATA_PUMP_DIR της βάσης, που τώρα είναι στον db1, όχι
  στο forms1. Το script το καταλαβαίνει («no such folder on this computer») και η σελίδα του διευθυντή θα δείξει ότι
  το αντίγραφο απέτυχε. Τα δεδομένα προστατεύονται από το Data Guard (δύο βάσεις)· τα αντίγραφα θα γίνουν με RMAN
  στον db1 (επόμενο βήμα).
- **Πίσω στη Free:** το αντίγραφο `tnsnames.ora.<ώρα>.bak` του domain στη θέση του `tnsnames.ora`, και
  `sudo systemctl restart weblogic-forms mm-api` (μόνο αν δεν έχουν γίνει πωλήσεις στο Data Guard στο μεταξύ).
