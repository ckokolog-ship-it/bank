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

Για επιστροφή στην αρχική κατάσταση, χωρίς απώλεια:

```
switchover to BANK_DB1;
```

Επόμενο βήμα: οι εφαρμογές στη νέα βάση (k3s, φόρμες, reports).
