# Oracle RAC στο εργαστήριο (i9)

Ένα **RAC δύο κόμβων**: μία βάση, δύο instances σε δύο VMs, που γράφουν μαζί στους ίδιους δίσκους (ASM). Αν πέσει ο ένας
κόμβος, οι συνδέσεις του πηγαίνουν στον άλλο. Τρέχει στο i9 (Intel i9-12900H, 64 GB), **ξεχωριστά** από το Data Guard
του laptop ([ODIGIES_DG.md](ODIGIES_DG.md)). Λογισμικό: Grid Infrastructure και βάση 26ai (23.26.1) Enterprise Edition.

| | Public | VIP | Interconnect |
|---|---|---|---|
| rac1 | 192.168.178.231 | .233 (rac1-vip) | 10.10.10.1 (rac1-priv) |
| rac2 | 192.168.178.232 | .234 (rac2-vip) | 10.10.10.2 (rac2-priv) |
| SCAN | .235 (rac-scan) | | |

- **Public:** η κάρτα που γεφυρώνεται στο FRITZ!Box.
- **VIP:** μια διεύθυνση που ο Clusterware μεταφέρει στον άλλο κόμβο όταν πέσει ο δικός της.
- **SCAN:** το ένα όνομα με το οποίο συνδέονται οι εφαρμογές, όποιοι κόμβοι κι αν τρέχουν.
- **Interconnect:** ένα internal network του VirtualBox (`racpriv`) μόνο για τους δύο κόμβους. Από εδώ περνά το Cache Fusion.

Οι .231–.235 πρέπει να είναι **έξω από το DHCP** του FRITZ!Box: Home Network → Network → Network Settings → IPv4 Settings.

Τα βήματα, ένα PR για καθένα:

1. **Τα VMs, οι κοινοί δίσκοι, το δίκτυο, το ssh** (αυτός ο οδηγός, §1–§5).
2. Το Grid Infrastructure: Clusterware και ASM (`gridSetup.sh -silent`).
3. Τα disk groups DATA και RECO, το λογισμικό της βάσης και στους δύο κόμβους, και η RAC βάση με PDB (dbca).
4. Η τράπεζα στο RAC και δοκιμές: πτώση κόμβου και ενημέρωση κόμβο-κόμβο.

## 0. Το i9

- **Χωρίς Hyper-V/VBS**, αλλιώς το VirtualBox τρέχει πάνω από τον hypervisor των Windows και είναι πολύ αργό. Σε PowerShell ως
  Administrator, το `Get-CimInstance -ClassName Win32_DeviceGuard -Namespace root\Microsoft\Windows\DeviceGuard |
  Select-Object VirtualizationBasedSecurityStatus` πρέπει να δείχνει **0**.
- VirtualBox 7.1.
- Η κάρτα για το bridge είναι αυτή με IP 192.168.178.x, εδώ η `Realtek USB 5GbE Family Controller`. Δες τη λίστα με
  `VBoxManage list bridgedifs`.
- Σε έναν φάκελο, π.χ. `D:\RAC`:
  - το ISO του Oracle Linux 9;
  - το `LINUX.X64_2326100_grid_home.zip` και το `LINUX.X64_2326100_db_home.zip`;
  - τα `vms.ps1` και `rac_disks.ps1`.

  Τα δύο scripts τα παίρνεις από το forms1. Στο forms1, ως oracle:
  ```bash
  cd ~/bank && git pull && cp k8s/vms.ps1 rac/rac_disks.ps1 /tmp/ && chmod 644 /tmp/vms.ps1 /tmp/rac_disks.ps1
  ```
  Στο i9:
  ```powershell
  scp chris@192.168.178.200:/tmp/vms.ps1 chris@192.168.178.200:/tmp/rac_disks.ps1 D:\RAC\
  ```

## 1. Τα VMs (i9)

Στο `D:\RAC`, σε PowerShell, **στο ίδιο παράθυρο** και όχι με `powershell -File`:

```powershell
cd D:\RAC
Set-ExecutionPolicy -Scope Process Bypass -Force
.\vms.ps1 -Iso "D:\RAC\OracleLinux-R9-U8-x86_64-dvd.iso" -Names rac1,rac2 -MemoryMB 12288 -Cpus 4 -DiskGB 100 -Adapter "Realtek USB 5GbE Family Controller"
```

- Κάθε VM έχει 12 GB μνήμη, 4 vCPU και δίσκο 100 GB. Ο δίσκος μεγαλώνει όσο γεμίζει.
- Το script ζητά έναν **καινούργιο** κωδικό για τον chris και τον root.
- Η εγκατάσταση θέλει 10–15 λεπτά.

Μετά, στην **κονσόλα** κάθε VM, login ως chris:
- `sudo whoami` πρέπει να απαντήσει `root`. Αν πει «not in the sudoers file», γράψε `su -` (με παύλα), μετά
  `usermod -aG wheel chris`, `exit`, `exit`, και ξανά login.
- `ip -4 addr | grep 192.168` δείχνει την IP που πήρε από το DHCP. **Σημείωσέ τη.**

## 2. Οι κοινοί δίσκοι και το interconnect (i9)

**Σβήσε και τα δύο VMs** (`sudo shutdown -h now`). Μετά:

```powershell
.\rac_disks.ps1
```

- Προσθέτει σε κάθε VM μια δεύτερη κάρτα στο internal network `racpriv`.
- Φτιάχνει τρεις **κοινούς δίσκους**, σταθερού μεγέθους (shareable):
  - CRS, 10 GB: το registry του cluster και το voting file;
  - DATA, 40 GB;
  - RECO, 20 GB.

  Τους συνδέει και στα δύο VMs. Γράφονται ολόκληροι, περίπου 70 GB, και θέλουν μερικά λεπτά.

Ξεκίνα τα δύο VMs.

## 3. Τα αρχεία στα VMs

**Από το i9**, το zip του grid **μόνο στο rac1**, στην IP του DHCP που σημείωσες:

```powershell
scp "D:\RAC\LINUX.X64_2326100_grid_home.zip" chris@<IP του rac1>:
```

**Από το forms1** (ως oracle), τα scripts:

```bash
scp rac/rac_host.sh rac/rac_ssh.sh chris@<IP του rac1>:
scp rac/rac_host.sh chris@<IP του rac2>:
```

## 4. Κάθε κόμβος (κονσόλα)

Το script αλλάζει την IP, οπότε το ssh θα κοπεί. Γι' αυτό τρέξ' το **από την κονσόλα του VirtualBox**.

**rac1:**
```bash
sudo bash ~/rac_host.sh 1 ~/LINUX.X64_2326100_grid_home.zip
```

**rac2:**
```bash
sudo bash ~/rac_host.sh 2
```

Τι κάνει:
- όνομα και IPs (public .231/.232, interconnect 10.10.10.1/.2);
- το `/etc/hosts` με κόμβους, VIPs και SCAN;
- το πακέτο προαπαιτούμενων και τις ομάδες του ASM;
- το firewall: ο άλλος κόμβος και το interconnect είναι trusted, και η θύρα 1521 ανοιχτή για τους clients;
- τους κοινούς δίσκους ως `/dev/oracleasm/crs1`, `data1`, `reco1`, ιδιοκτησίας `oracle:asmadmin`;
- στο rac1, αποσυμπιέζει το grid στο `/u01/app/23.0.0/grid`.

Στο τέλος βλέπεις τα τρία `/dev/oracleasm/...`. Από εδώ και πέρα δουλεύεις με ssh στις .231 και .232. Σβήσε και το zip:
`rm ~/LINUX.X64_2326100_grid_home.zip`.

## 5. ssh ανάμεσα στους κόμβους (rac1)

Ο installer του grid αντιγράφει το home του στο rac2 και τρέχει εντολές εκεί ως `oracle`, χωρίς κωδικό. Στο rac1:

```bash
sudo bash ~/rac_ssh.sh
```

Ζητά τον κωδικό του chris στο rac2: μία φορά για το scp, μία για το ssh και μία για το sudo εκεί. Στο τέλος δείχνει `rac2` και
`rac1`, δηλαδή ο oracle πήγε από το rac1 στο rac2 και πίσω χωρίς κωδικό.

### Αν κάτι πάει στραβά

| Μήνυμα | Τι κάνεις |
|--------|-----------|
| `not the 3 shared disks` | Τα VMs ξεκίνησαν πριν από το `rac_disks.ps1`, ή αυτό δεν τελείωσε. Ξαναέλεγξε με `lsblk` |
| `no second card` | Το `rac_disks.ps1` δεν έβαλε τη δεύτερη κάρτα. Τρέξ' το ξανά με τα VMs σβηστά |
| `ssh of oracle without a password did not work` | Τρέξε ξανά το `rac_ssh.sh` |

## 6. Το Grid Infrastructure (rac1)

Ο **Clusterware** ενώνει τους δύο κόμβους σε cluster. Το **ASM** διαχειρίζεται τους κοινούς δίσκους. Από το forms1 (ως oracle):

```bash
cd ~/bank && git pull
scp rac/rac_grid.sh chris@192.168.178.231:
```

Στο **rac1** (ssh στην .231):

```bash
sudo bash ~/rac_grid.sh
```

1. **Έλεγχοι:** το grid έχει αποσυμπιεστεί, ο oracle μπαίνει στο rac2 χωρίς κωδικό, και ο κοινός δίσκος φαίνεται και στους δύο κόμβους.
2. **Ο κωδικός του ASM** (SYS και ASMSNMP), δύο φορές. **Χωρίς `@`, `"` και `/`**, γιατί σπάνε τα εργαλεία. Μπαίνει σε ένα
   response file που διαβάζει μόνο ο oracle και σβήνεται στο τέλος.
3. **cluvfy:** ο έλεγχος των προαπαιτούμενων. Η αναφορά του γράφεται στο `/u01/app/oracle/rac_grid/cluvfy.txt`. Σε εργαστήριο
   κάποια αποτυγχάνουν (swap, DNS για το SCAN), και αυτό δεν σταματά την εγκατάσταση.
4. **`gridSetup.sh -silent`** (10–20 λεπτά): αντιγράφει το λογισμικό στο rac2 και ρυθμίζει το cluster `rac`, με SCAN `rac-scan`,
   τα VIPs και το disk group **CRS** στο `/dev/oracleasm/crs1`.
5. **Τα scripts του root:** πρώτα στο rac1 (ξεκινά το cluster) και μετά στο rac2 (μπαίνει στο cluster). Για το rac2 ζητά τον
   κωδικό του chris και του sudo εκεί. Το `root.sh` θέλει 5–10 λεπτά σε κάθε κόμβο.
6. **Τα configuration tools.**
7. **Τι τρέχει:** στο τέλος δείχνει το `crsctl stat res -t`, το SCAN και το ASM.

Στο τέλος πρέπει να δεις:

```
CRS-4537: Cluster Ready Services is online
...
ora.asm  ONLINE ONLINE rac1 / rac2
ora.rac1.vip  ONLINE ONLINE rac1
ora.rac2.vip  ONLINE ONLINE rac2
ora.scan1.vip ONLINE ONLINE ...
```

Έλεγχος, ως oracle (`sudo su - oracle`):

```bash
crsctl stat res -t
olsnodes -n -s
asmcmd lsdg
```

### Αν κάτι πάει στραβά

| Μήνυμα | Τι κάνεις |
|--------|-----------|
| `gridSetup.sh: <νούμερο>` | Το log είναι στο `/u01/app/oraInventory/logs/GridSetupActions*/gridSetupActions*.log`. Στείλε μου τις τελευταίες 50 γραμμές |
| το `root.sh` του rac1 αποτυγχάνει | `sudo tail -50 /u01/app/oracle/crsdata/rac1/crsconfig/rootcrs_rac1_*.log` |
| `PRVG-…` / `INS-…` στο cluvfy | Στείλε μου το `grep -B2 -A6 FAILED /u01/app/oracle/rac_grid/cluvfy.txt` |

Επόμενο βήμα: η βάση (DATA, RECO, το λογισμικό της, το dbca).
