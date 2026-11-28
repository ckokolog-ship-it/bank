# Oracle Enterprise Manager 24ai (i9)

Μία κονσόλα για όλες τις βάσεις του εργαστηρίου: το **Data Guard** (db1/db2: ρόλοι, καθυστέρηση, switchover/failover από
τη σελίδα, FSFO), το **RAC** (rac1/rac2: cluster, instances, το service `bank_rac`), τα PDB, οι listeners, οι
επιδόσεις (ASH, AWR), τα alerts. Τρέχει σε δικό του VM στο i9, το **em1**.

| | |
|---|---|
| VM | em1, 192.168.178.236, Oracle Linux 9, 16 GB μνήμη, 4 vCPU, δίσκος 200 GB (στον D:) |
| Repository | η βάση EMCDB με το PDB **EMREP**, στο em1 (19c, ή 26ai: §2) |
| Κονσόλα | **https://em1.home.lan:7803/em** (ή https://192.168.178.236:7803/em), χρήστης SYSMAN |

Το .236 πρέπει να είναι **έξω από το DHCP** του FRITZ!Box (όπως τα .231–.235 του RAC).

Τα βήματα, ένα PR για καθένα:

1. **Το VM, η βάση του repository, ο Enterprise Manager** (αυτός ο οδηγός, §1–§3: `em/em_host.sh`, `em/em_oms.sh`).
2. Οι agents στα db1, db2, rac1, rac2, forms1 και η ανακάλυψη του Data Guard και του RAC.

## 0. Τα αρχεία (i9)

Στο `D:\Oracle\em`:

- τα 5 zip του edelivery: `V1046951-01.zip` … `V1046955-01.zip` (Linux x86-64, περίπου 8,2 GB): ο installer
  `em24100_linux64.bin` και τα `em24*.zip` του;
- το `LINUX.X64_193000_db_home.zip`: η βάση 19c για το repository.

Το ISO του Oracle Linux 9 και το `vms.ps1` υπάρχουν ήδη στο `D:\RAC` (ODIGIES_RAC.md §0).

## 1. Το VM (i9)

Σε PowerShell, **στο ίδιο παράθυρο**:

```powershell
cd D:\RAC
Set-ExecutionPolicy -Scope Process Bypass -Force
.\vms.ps1 -Iso "D:\RAC\OracleLinux-R9-U8-x86_64-dvd.iso" -Names em1 -MemoryMB 16384 -Cpus 4 -DiskGB 200 -Adapter "Realtek USB 5GbE Family Controller"
```

- Ζητά έναν **καινούργιο** κωδικό για τον chris και τον root. Η εγκατάσταση θέλει 10–15 λεπτά.
- Στην **κονσόλα** του em1, login ως chris: `sudo whoami` → `root`, και `ip -4 addr | grep 192.168`: η IP του DHCP,
  **σημείωσέ τη**.

Μετά, από το i9 τα zip, στην IP του DHCP (στο `/home` του chris: εκεί είναι ο μεγάλος χώρος):

```powershell
ssh chris@<IP του em1> "mkdir -p em"
scp D:\Oracle\em\V10469*.zip D:\Oracle\em\LINUX.X64_193000_db_home.zip chris@<IP του em1>:em/
```

και από το **forms1** (ως oracle) τα scripts:

```bash
cd ~/bank && git pull
scp em/em_host.sh em/em_oms.sh chris@<IP του em1>:
```

## 2. Ο υπολογιστής και η βάση του repository (κονσόλα του em1)

Αλλάζει την IP, οπότε **από την κονσόλα** του VirtualBox:

```bash
sudo bash ~/em_host.sh ~/em/LINUX.X64_193000_db_home.zip
```

- Το όνομα em1, η IP .236, τα ονόματα του εργαστηρίου στο `/etc/hosts`, το πακέτο των προαπαιτούμενων της Oracle,
  swap 8 GB, οι θύρες του EM (7803 κονσόλα, 4903 agents, 7102 WebLogic, 1521).
- Το λογισμικό της βάσης (`runInstaller -silent`, μόνο λογισμικό), ο listener, η βάση **EMCDB** με το PDB **EMREP**
  (dbca, 20–40 λεπτά), με τις παραμέτρους που θέλει ο EM, και ξεκίνημα μαζί με το VM (`oracle-em`).
- Ο **dbca ζητά τους κωδικούς** (SYS, SYSTEM, ο admin του PDB). Κράτα τον SYS: τον ζητά ξανά το `em_oms.sh`.

**19c σε Oracle Linux 9:** η 19.3 δεν «ξέρει» το OL9. Το script της λέει ότι είναι OL8 (`CV_ASSUME_DISTID=OL8`), που
συνήθως αρκεί. Αν παρ' όλα αυτά το `runInstaller` αποτύχει (π.χ. στο link), δοκίμασε με το zip της **26ai** που
έχεις από το RAC (`D:\RAC\LINUX.X64_2326100_db_home.zip`, scp στο `em/`):

```bash
sudo bash ~/em_host.sh ~/em/LINUX.X64_2326100_db_home.zip
```

(Ο installer του EM λέει στο §3 αν δέχεται την έκδοση της βάσης· αν όχι, το ίδιο: η άλλη.)

Τώρα το ssh δουλεύει στη νέα IP: `ssh chris@192.168.178.236`.

## 3. Ο Enterprise Manager (em1)

Θέλει 1–2 ώρες, οπότε μέσα σε **tmux**: αν κοπεί το ssh, συνεχίζει (`tmux attach` για να ξαναμπείς).

```bash
tmux new -s em
sudo bash ~/em_oms.sh ~/em
```

- Αποσυμπιέζει τα 5 zip στο `/home/oracle/em-stage`.
- Παίρνει από τον ίδιο τον installer τα πρότυπα των αρχείων απαντήσεων και συμπληρώνει το `new_install.rsp`: τα
  homes κάτω από το `/u01/app/oracle`, το repository EMREP στο em1:1521, εγκατάσταση **SMALL**, τη βιβλιοθήκη
  λογισμικού. Αν κάποιο κλειδί δεν υπάρχει στο πρότυπο του 24ai, το λέει («not in the template»).
- Ζητά **πέντε κωδικούς** (δεν φαίνονται, δύο φορές ο καθένας): SYS της EMCDB, **SYSMAN** (με αυτόν μπαίνεις στην
  κονσόλα), weblogic και node manager του EM (**καινούργιοι**, όχι αυτοί των forms), και της εγγραφής των agents.
  Μπαίνουν στο αρχείο απαντήσεων μόνο όσο τρέχει ο installer (600, του oracle) και μετά σβήνεται.
- Τρέχει τον installer `-silent`, μετά το `allroot.sh` (ο EM ξεκινά μαζί με το VM).

Στο τέλος: **https://em1.home.lan:7803/em**, χρήστης **SYSMAN**. Ο browser θα πει ότι το πιστοποιητικό δεν είναι
έμπιστο (είναι του ίδιου του EM): Advanced → Continue. Στο PC, για το όνομα em1.home.lan:
`C:\Windows\System32\drivers\etc\hosts` → `192.168.178.236 em1.home.lan em1` (ή η IP απευθείας).

## Καθημερινά (em1, ως oracle)

| Εντολή | |
|---|---|
| `/u01/app/oracle/middleware/bin/emctl status oms` | ζει ο EM; |
| `/u01/app/oracle/middleware/bin/emctl stop oms -all` / `start oms` | σταμάτημα / ξεκίνημα |
| `/u01/app/oracle/agent/agent_inst/bin/emctl status agent` | ο agent του ίδιου του em1 |
| `sudo systemctl status oracle-em` | η βάση του repository |

Η σειρά στο κλείσιμο: πρώτα ο EM (`emctl stop oms -all`), μετά η βάση· στο άνοιγμα ανάποδα (γίνεται μόνο του).
