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

```powershell
cd C:\bank\k8s
powershell -ExecutionPolicy Bypass -File .\vms.ps1 -Iso D:\iso\OracleLinux-R9-U5-x86_64-dvd.iso -Names db1,db2 -MemoryMB 8192 -Cpus 3 -DiskGB 100
```

Το ISO είναι το ίδιο με των k3s. Ο κωδικός του `chris` ζητείται μία φορά. Βάλε **καινούργιο** κωδικό, όχι αυτόν των
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

## 3. Το zip και τα scripts στα VMs (Windows)

Το zip (περίπου 2 GB) είναι στο `L:\Oracle\Oracle 21\LINUX.X64_2326100_db_home.zip`. Πάει στο home του `chris`
(όχι στο `/tmp`, γιατί μπορεί να είναι μικρό). Από το PowerShell των Windows (OpenSSH):

```powershell
scp "L:\Oracle\Oracle 21\LINUX.X64_2326100_db_home.zip" chris@192.168.178.221:
scp "L:\Oracle\Oracle 21\LINUX.X64_2326100_db_home.zip" chris@192.168.178.222:
scp C:\bank\dg\db_host.sh chris@192.168.178.221:
scp C:\bank\dg\db_host.sh chris@192.168.178.222:
```

(Αν το repo στα Windows δεν είναι στο `C:\bank`, άλλαξε τη διαδρομή. Πρώτα κάνε `git pull`.)

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

Επόμενο βήμα: η βάση `BANK` στον db1.
