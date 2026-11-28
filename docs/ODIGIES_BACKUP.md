# Οδηγίες: backups της BANK με RMAN (στον δίσκο του em1)

Τα backups της βάσης **BANK** του Data Guard (db1, db2: όλα τα PDBs της, `BANKPDB`, `PROPOPDB`, `MMPDB`) πάνε σε
**άλλον υπολογιστή** από τις βάσεις: σε έναν δίσκο 500 GB του em1, στο D: του i9, που το em1 μοιράζει με NFS.

| Πότε | Τι | Πού |
|---|---|---|
| Κυριακή 01:30 | level 0: όλη η βάση και τα archived logs | `/backup/BANK` |
| Δευτέρα–Σάββατο 01:30 | level 1 cumulative: ό,τι άλλαξε από το level 0 (block change tracking: γρήγορο) | `/backup/BANK` |
| κάθε 4 ώρες (:15) | τα archived logs που δεν έχουν backup | `/backup/BANK` |

- Retention: **recovery window 7 ημερών** (ό,τι δεν χρειάζεται πια, σβήνεται μόνο του μετά από κάθε backup).
- Το control file και το spfile: autobackup μετά από κάθε backup (`/backup/BANK/cf_*`).
- Συμπιεσμένα (BASIC: χωρίς επιπλέον άδεια), 2 κανάλια.
- Τα timers είναι **και στους δύο** (db1, db2), αλλά backup παίρνει **μόνο ο primary**: μετά από switchover ή
  failover, ο άλλος μόνος του. Πριν από κάθε backup γίνεται `catalog` του κοινού φακέλου, ώστε ο primary του τώρα
  να ξέρει και τα backups του primary του πριν. Ο standby σβήνει μόνο τα archived logs του που έχουν εφαρμοστεί και
  έχουν backup (δεν γεμίζει το recovery area του).

Κανένας κωδικός: όλα ως `/ as sysdba` από τον oracle του κάθε μηχανήματος.

## 1. Ο δίσκος (Windows του i9, με το em1 σβηστό)

Σβήσε το em1 (`sudo shutdown -h now` στο em1, ή από το VirtualBox), και στο PowerShell, στο repo:

```powershell
cd C:\bank; git pull
powershell -ExecutionPolicy Bypass -File .\backup\disk.ps1
```

Φτιάχνει το `D:\Oracle\backup\em1-backup.vdi` (dynamic: μεγαλώνει όσο γεμίζει, έως 500 GB) και το βάζει στο em1
(SATA θύρα 1). Αρνείται αν το em1 τρέχει. Άλλο μέγεθος ή φάκελος: `-SizeGB 800 -Folder E:\backup`.

Μετά άναψε το em1.

## 2. Τα scripts στα μηχανήματα (forms1, ως oracle)

```bash
cd ~/bank && git pull
scp backup/nfs_server.sh chris@192.168.178.236:
for h in 192.168.178.221 192.168.178.222; do scp backup/nfs_client.sh backup/rman_setup.sh backup/rman_backup.sh chris@$h: ; done
```

## 3. Το NFS στο em1 (ως chris)

```bash
sudo bash ~/nfs_server.sh
```

- Βρίσκει τον άδειο δίσκο (100 GB και πάνω, χωρίς partitions), τον κάνει XFS με label `backup` και τον βάζει στο
  `/backup` (στο `/etc/fstab`, με `nofail`: χωρίς τον δίσκο το em1 ανάβει κανονικά).
- Φάκελοι `/backup/BANK`, `/backup/BANKRAC`, `/backup/EMCDB` (με `logs/`), του oracle (uid 54321 σε όλα).
- Το μοιράζει **μόνο** στους db1, db2, rac1, rac2 (`/etc/exports`, `root_squash`), και ανοίγει το NFS στο firewalld
  μόνο για αυτούς.

Έλεγχος: `df -h /backup` και `exportfs -v`.

## 4. Το NFS και το RMAN στον db1 και στον db2 (ως chris, σε κάθε έναν)

```bash
sudo bash ~/nfs_client.sh
sudo bash ~/rman_setup.sh
```

Στον **primary** (συνήθως ο db1) και ένα πρώτο level 0 τώρα (λίγα λεπτά):

```bash
sudo bash ~/rman_setup.sh --now
```

- `nfs_client.sh`: το `/backup` του em1 στο `/etc/fstab` (NFS 4.2, `hard`, `_netdev,nofail`), mount, και έλεγχος ότι
  ο oracle γράφει στο `/backup/BANK`.
- `rman_setup.sh`: το `configure` του RMAN (retention, autobackup, συμπίεση, deletion policy των archived logs), το
  block change tracking, το `rman_backup.sh` στο `/usr/local/bin`, και τα timers του systemd.

Έλεγχος:

```bash
systemctl list-timers 'rman-bank-*'
ls -lh /backup/BANK /backup/BANK/logs
```

## 5. Έλεγχος των backups (στον primary, ως oracle)

```bash
rman target /
```

```sql
list backup summary;
report need backup;
restore database validate;          -- διαβάζει τα backups σαν restore, χωρίς να γράψει τίποτα
restore archivelog all validate;
exit
```

Στον Enterprise Manager: η βάση BANK_DB1 → **Availability → Backup & Recovery → Backup Reports**.

Ένα backup με το χέρι (ως chris): `sudo systemctl start rman-bank@level1` (ή `level0`, `arch`), και η κατάστασή του:
`systemctl status rman-bank@level1`, `journalctl -u rman-bank@level1 -n 50`, και το log του στο `/backup/BANK/logs`.

## 6. Αν κάτι πάει στραβά

| Μήνυμα | Τι σημαίνει |
|---|---|
| `/backup/BANK is not writable` | δεν είναι mounted το `/backup`: `findmnt /backup`· στο em1 `systemctl status nfs-server` |
| `the standby: the backups are taken on the primary` | φυσιολογικό στον standby (level0/level1) |
| `FAILED: …log` | λάθος του RMAN: το log λέει ποιο (`RMAN-…`, `ORA-…`) |
| `ORA-19809` / `ORA-19804` | γέμισε το recovery area: `delete noprompt archivelog all;` στον primary, μετά ένα `arch` |

Το RAC (BANKRAC) και η βάση του EM (EMCDB) έχουν ήδη τους φακέλους τους στο `/backup`: έρχονται στο επόμενο βήμα.
