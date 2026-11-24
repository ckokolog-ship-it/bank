# Το bank σε cluster Kubernetes (k3s)

Η υπηρεσία REST, οι σελίδες και το ATM (`bk-api`) τρέχουν σε **3 VMs με k3s**, σε 2 ή περισσότερα αντίγραφα (replicas). Αν πέσει ένα VM, ή αν ανεβαίνει νέα έκδοση, η τράπεζα συνεχίζει να εξυπηρετεί.

Η βάση μένει στο forms1. Τα αντίγραφα δεν έχουν δική τους κατάσταση: οι συνδέσεις των σελίδων είναι στη βάση (`bk_session`), οπότε οποιοδήποτε αντίγραφο εξυπηρετεί οποιονδήποτε χρήστη.

```
                      ┌──────── laptop: Windows, VirtualBox, 64 GB ─────────────────────────────┐
  browser ──:80──▶    │  k3s1 .211 (server)    k3s2 .212 (worker)    k3s3 .213 (worker)          │
                      │  Traefik (Ingress) σε κάθε κόμβο ─▶ Service bk-api ─▶ pods bk-api × 2..4 │
                      │                                                     │                    │
                      │  forms1 .200: Oracle (FREEPDB1) ◀───── :1521 ───────┘                    │
                      │  Windows .54: Ollama (κάρτα NVIDIA) ◀── η βάση (βοηθός ταμία)            │
                      └─────────────────────────────────────────────────────────────────────────┘
```

| Αρχείο | Τι κάνει | Πού τρέχει |
|---|---|---|
| `k8s/vms.ps1` | Τα 3 VMs (Oracle Linux 9, 2 vCPU, 4 GB, 30 GB), με αυτόματη εγκατάσταση όπως το forms1 | Windows (PowerShell) |
| `k8s/node.sh` | Σταθερή διεύθυνση, όνομα, firewalld, k3s (server ή worker) | κάθε νέο VM |
| `k8s/Dockerfile` | Η εικόνα του `bk-api` (Java 21, χρήστης χωρίς δικαιώματα root, χωρίς κωδικό μέσα) | — |
| `k8s/ship_image.sh` | Χτίζει jar και εικόνα (podman), τη στέλνει στο containerd κάθε κόμβου, αντιγράφει τα αρχεία στον server | forms1 |
| `k8s/bank.yaml` | Namespace, ConfigMap, Deployment, Service, Ingress, PodDisruptionBudget, HorizontalPodAutoscaler | — |
| `k8s/deploy.sh` | Το Secret με τον κωδικό της βάσης (ζητείται), το `bank.yaml` με την εικόνα, αναμονή του rollout | k3s1 |
| `k8s/headlamp.sh` | Η κονσόλα του Kubernetes στον browser (Headlamp) στο `/headlamp/`, με token διαχειριστή | k3s1 |

Μνήμη: 3 × 4 GB = 12 GB. Με το forms1 (16 GB) και τα Windows με το Ollama μένουν περίπου 25 GB ελεύθερα στα 64 του laptop.

## 1. Τα VMs (Windows)

Θέλεις το ISO του Oracle Linux 9 (DVD, π.χ. `OracleLinux-R9-U8-x86_64-dvd.iso`). Το `k8s/vms.ps1` το παίρνεις από το GitHub (Raw), ή από το forms1 με το SFTP του MobaXterm. Ο φάκελος `/home/oracle` δεν ανοίγει για τον chris, οπότε το αντιγράφεις πρώτα στο home του:

```bash
sudo cp ~oracle/bank/k8s/vms.ps1 ~oracle/bank/k8s/node.sh ~chris/ && sudo chown chris: ~chris/vms.ps1 ~chris/node.sh
```

Βάλε το ISO και το `vms.ps1` στον ίδιο φάκελο, π.χ. `L:\Cluster Setup`. Σε PowerShell:

```powershell
cd "L:\Cluster Setup"
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" list bridgedifs | findstr /b "Name:"   # το όνομα της κάρτας δικτύου
powershell -ExecutionPolicy Bypass -File .\vms.ps1 -Iso "L:\Cluster Setup\OracleLinux-R9-U8-x86_64-dvd.iso"
```

- **Ο κωδικός:** ζητείται μία φορά, για τον χρήστη `chris` και τον root. Δεν φαίνεται, και το script δεν τυπώνει την έξοδο του VirtualBox.
- **Η εγκατάσταση:** τρέχει χωρίς παράθυρο και στα τρία μαζί, περίπου 10–15 λεπτά. Την παρακολουθείς από το VirtualBox Manager (Show).
- **Η κάρτα δικτύου:** αν δεν είναι η `ASUS 2.5G Ethernet USB Adapter`, δώσε `-Adapter "<όνομα>"`.
- **Ο δίσκος με το ISO:** αν είναι εξωτερικός (π.χ. `L:`), μην τον βγάλεις μέχρι να τελειώσει η εγκατάσταση.

Μετά την εγκατάσταση, σε κάθε VM άλλαξε τους κωδικούς: `passwd` και `sudo passwd root`. Το VirtualBox γράφει τον αρχικό κωδικό καθαρό στο `ks.cfg` της εγκατάστασης. Με τα VMs **σβηστά**, σβήσε και τα βοηθητικά αρχεία της:

```powershell
foreach ($n in "k3s1","k3s2","k3s3") {
  & "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" storageattach $n --storagectl IDE --port 1 --device 0 --medium emptydrive
  Remove-Item "$env:USERPROFILE\VirtualBox VMs\$n\Unattended-*" -Force -ErrorAction SilentlyContinue
}
```

## 2. Κάθε VM γίνεται κόμβος

**Πρώτα ο k3s1 (server), μετά οι k3s2 και k3s3 (workers).** Κάθε φορά δες στο prompt σε ποιο μηχάνημα είσαι (`[chris@k3s1 ~]$`). Το `node.sh` αρνείται να τρέξει στο forms1 ή σε μηχάνημα με Oracle, αλλά κάλλιο να το βλέπεις κι εσύ.

**α. Στην κονσόλα του VM** (VirtualBox Manager → Show), σύνδεση ως `chris`:

```bash
id                     # να φαίνεται 10(wheel): ο chris έχει sudo
ip -4 a | grep inet    # η προσωρινή διεύθυνση (DHCP), π.χ. 192.168.178.145
```

Αν το `id` δεν δείχνει `wheel` (το `sudo` γράφει «chris is not in the sudoers file»):

```bash
su -                   # ο κωδικός του root (με παύλα: su -, όχι su ~)
usermod -aG wheel chris
exit
exit                   # αποσύνδεση, και ξανά login ως chris
```

**β. Η σταθερή διεύθυνση, πριν από το ssh.** Με την προσωρινή διεύθυνση, η σύνδεση ssh κόβεται τη στιγμή που αλλάζει. Δώσ' την λοιπόν από την κονσόλα, π.χ. για τον k3s3:

```bash
sudo nmcli con mod enp0s3 ipv4.method manual ipv4.addresses 192.168.178.213/24 ipv4.gateway 192.168.178.1 ipv4.dns 192.168.178.1
sudo nmcli con up enp0s3
```

**γ. Ssh από το MobaXterm** στη σταθερή διεύθυνση (εκεί δουλεύει η επικόλληση) και:

```bash
scp chris@192.168.178.200:node.sh .         # από το forms1 (ο κωδικός του chris στο forms1)
chmod +x node.sh
sudo ./node.sh server 192.168.178.211                    # στον k3s1
sudo ./node.sh agent 192.168.178.212 192.168.178.211     # στον k3s2
sudo ./node.sh agent 192.168.178.213 192.168.178.211     # στον k3s3
```

**Το token** που ζητούν οι workers είναι το token του k3s, **όχι** κάποιο κλειδί ssh. Είναι μία γραμμή της μορφής `K10…::server:…`, και τη βλέπεις στον k3s1:

```bash
sudo cat /var/lib/rancher/k3s/server/node-token
```

Στο MobaXterm, με διπλό κλικ πάνω στο token αντιγράφεται όλο, και με δεξί κλικ γίνεται επικόλληση (δεν φαίνεται), και μετά Enter. Αν δοθεί λάθος token, το `node.sh` το καταλαβαίνει από τη μορφή του και σταματά.

Στο τέλος, στον k3s1:

```bash
sudo k3s kubectl get nodes -o wide      # 3 κόμβοι Ready
```

Το `node.sh` βάζει στο sudo και το `/usr/local/bin`, οπότε το `sudo k3s …` βρίσκει το k3s. Χωρίς αυτό, στο Oracle Linux βγαίνει «sudo: k3s: command not found».

Οι διευθύνσεις .211–.213 είναι έξω από το εύρος DHCP του FRITZ!Box (εξ ορισμού .20–.200). Για σιγουριά, κράτησέ τες και εκεί: Home Network → Network → Network Connections → το μολύβι (Edit) → «Always assign this network device the same IPv4 address».

## 3. Η εικόνα (forms1)

Μία φορά: η βάση να δέχεται συνδέσεις από τους κόμβους, και κλειδιά ssh προς αυτούς. Αν το firewalld του forms1 δεν τρέχει («FirewallD is not running»), η θύρα 1521 είναι ήδη ανοιχτή και το πρώτο κομμάτι δεν χρειάζεται.

```bash
for ip in 192.168.178.211 192.168.178.212 192.168.178.213; do
  sudo firewall-cmd --permanent --add-rich-rule="rule family=ipv4 source address=$ip/32 port port=1521 protocol=tcp accept"
done
sudo firewall-cmd --reload
[ -f ~/.ssh/id_ed25519 ] || ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519
for ip in 192.168.178.211 192.168.178.212 192.168.178.213; do ssh-copy-id chris@$ip; done
# έλεγχος: όνομα και import-ok από κάθε κόμβο, χωρίς κωδικό
for ip in 192.168.178.211 192.168.178.212 192.168.178.213; do ssh -o BatchMode=yes chris@$ip 'hostname; sudo -n /usr/local/bin/k3s ctr version >/dev/null && echo import-ok'; done
```

Κάθε φορά που αλλάζει ο κώδικας:

```bash
sudo -iu oracle git -C bank pull
sudo ~oracle/bank/k8s/ship_image.sh
```

Τι κάνει το `ship_image.sh`:
- χτίζει το jar και την εικόνα `localhost/bank/bk-api:<commit>`· την πρώτη φορά εγκαθιστά το podman και κατεβάζει τη Java 21·
- στέλνει την εικόνα σε κάθε κόμβο (ssh και `k3s ctr images import`, χωρίς registry)·
- αντιγράφει τα `bank.yaml`, `deploy.sh` και `headlamp.sh` στον k3s1, στο `~/bank-k8s/`·
- στο τέλος γράφει την εντολή για το επόμενο βήμα.

## 4. Το deploy (k3s1)

**Στον k3s1** (ssh chris@192.168.178.211, το prompt γράφει `[chris@k3s1 ~]$`):

```bash
sudo ~/bank-k8s/deploy.sh <commit>          # την πρώτη φορά ζητά τον κωδικό του χρήστη BANK της βάσης, δύο φορές
sudo ~/bank-k8s/deploy.sh --status          # τα pods (σε ποιον κόμβο), service, ingress, autoscaler
```

Ο κωδικός μπαίνει σε ένα **Secret** του cluster (`bk-db`). Δεν γράφεται σε αρχείο, ούτε στην εικόνα, ούτε στο repo. Για να τον αλλάξεις: `sudo ~/bank-k8s/deploy.sh <commit> --password`.

Η τράπεζα ανοίγει από **οποιονδήποτε κόμβο**: http://192.168.178.211/web/ (ή .212, .213), και το ATM στο http://192.168.178.211/atm/. Το Traefik του k3s ακούει στη θύρα 80 κάθε κόμβου.

## 5. Δοκιμές

```bash
K="sudo k3s kubectl -n bank"
$K get pods -o wide                         # 2 pods, σε διαφορετικούς κόμβους
```

| Δοκιμή | Πώς | Τι βλέπεις |
|---|---|---|
| **Νέα έκδοση χωρίς διακοπή** | στο forms1 `git pull` και `ship_image.sh`, στο k3s1 `deploy.sh <νέο commit>` | Ένα νέο pod ανεβαίνει, γίνεται Ready, μόνο τότε σβήνει ένα παλιό. Ποτέ λιγότερα από 2 έτοιμα (`maxUnavailable: 0`). Η σελίδα δεν κόβεται. |
| **Πίσω** | `deploy.sh --undo` | Στην προηγούμενη έκδοση, με τον ίδιο τρόπο |
| **Ένα VM πέφτει** | Windows: `VBoxManage controlvm k3s2 poweroff` | Το άλλο pod συνεχίζει αμέσως. Σε περίπου 5 λεπτά το Kubernetes ξαναφτιάχνει το χαμένο pod σε άλλο κόμβο. |
| **Συντήρηση κόμβου** | `sudo k3s kubectl drain k3s2 --ignore-daemonsets --delete-emptydir-data`, μετά `uncordon k3s2` | Το PodDisruptionBudget κρατά πάντα 1 pod ζωντανό |
| **Περισσότερα αντίγραφα** | `$K scale deploy/bk-api --replicas=3`, ή φόρτος: ο autoscaler πάει ως 4 με CPU > 70% | `$K get hpa` |
| **Η βάση πέφτει** | στο forms1 σβήνεις τη βάση | Τα pods γίνονται «not ready» (το `/api/health` αποτυγχάνει) αλλά δεν επανεκκινούνται. Με τη βάση πίσω, ξαναγίνονται Ready μόνα τους. |
| **Logs** | `$K logs deploy/bk-api -f`, `$K describe pod <pod>` | |

## 6. Πώς είναι φτιαγμένο

- **Δύο αντίγραφα σε διαφορετικούς κόμβους** (`topologySpreadConstraints`), 2–4 με τον autoscaler (το metrics-server είναι μέσα στο k3s).
- **Έλεγχοι υγείας:**
  - *startup*: η θύρα, για να έχει χρόνο να ξεκινήσει η Java·
  - *readiness*: το `/api/health`, δηλαδή η υπηρεσία **και** η βάση· ένα pod χωρίς βάση βγαίνει από την κυκλοφορία·
  - *liveness*: μόνο η θύρα. Αν έλεγχε και τη βάση, μια πτώση της βάσης θα επανεκκινούσε όλα τα pods χωρίς λόγο.
- **Sticky sessions για το ATM:** το `bk-api` κρατά τη συνεδρία της κάρτας στο ATM στη μνήμη του αντιγράφου (`Atm.java`, 2 λεπτά). Το Service έχει sticky cookie του Traefik (`bk_node`), οπότε ένα ATM μένει στο ίδιο αντίγραφο. Αν εκείνο πέσει, η κάρτα «επιστρέφεται» και ο πελάτης ξαναβάζει PIN. Οι σελίδες δεν το χρειάζονται, γιατί οι συνδέσεις τους είναι στη βάση.
- **Ασφάλεια:**
  - το container τρέχει ως χρήστης `10001`, χωρίς δικαιώματα (`capabilities: drop ALL`, χωρίς privilege escalation)·
  - ο κωδικός μόνο στο Secret·
  - η βάση δέχεται στη θύρα 1521 μόνο τους τρεις κόμβους.
- **Εκδόσεις:** κάθε εικόνα έχει ως tag το commit του repo, οπότε κάθε deploy είναι μια συγκεκριμένη έκδοση και γυρίζει πίσω με `--undo`.
- **Χωρίς registry:** η εικόνα πάει σε κάθε κόμβο με `ssh … k3s ctr images import -` (`imagePullPolicy: IfNotPresent`). Το `node.sh` επιτρέπει στον χρήστη μόνο αυτή την εντολή χωρίς κωδικό (`/etc/sudoers.d/bk-k3s-import`).
- **Η βάση έξω από το cluster:** το Oracle Free δεν έχει RAC ούτε Data Guard. Η βάση μένει ένα σημείο, και το cluster δίνει διαθεσιμότητα και κλιμάκωση στο κομμάτι της εφαρμογής.

Τα manifests ελέγχθηκαν με k3s v1.31.4 (`kubectl apply --dry-run=server`), και η εικόνα μέσα σε container με την Oracle της δοκιμής: `/api/health` απάντησε `ok`, ως χρήστης `10001`. Το k3s με 3 κόμβους μέσα σε docker δεν μπόρεσε να τρέξει pods σε εκείνο το περιβάλλον (εμφωλευμένα containers σε VM). Η πραγματική δοκιμή είναι στα VMs.

## 7. Προβλήματα

| Τι βλέπεις | Τι σημαίνει |
|---|---|
| `ErrImageNeverPull` / `ImagePullBackOff` | Η εικόνα δεν έφτασε σε εκείνον τον κόμβο: `ship_image.sh` ξανά (με όλους τους κόμβους) |
| Pods `Running` αλλά `0/1` Ready | Η βάση δεν απαντά: firewall στο forms1 (θύρα 1521 για τους κόμβους), listener (`lsnrctl status`), λάθος κωδικός (`deploy.sh <commit> --password`) |
| `Pending` | Δεν χωρά σε κανέναν κόμβο: `$K describe pod <pod>` (μνήμη, ή κόμβος NotReady) |
| `404 page not found` από το Traefik | Λάθος διαδρομή· οι σελίδες είναι στο `/web/`, το ATM στο `/atm/` |
| Κόμβος `NotReady` | `sudo systemctl status k3s` (server) ή `k3s-agent` (worker)· firewalld: θύρες 6443, 10250, 8472/udp |
| Το ATM «ξεχνά» την κάρτα | Ο browser δεν κράτησε το cookie `bk_node` (π.χ. ιδιωτικό παράθυρο που κλείνει) |
| «chris is not in the sudoers file» | Ο chris δεν είναι στο `wheel`: `su -`, `usermod -aG wheel chris`, ξανά login (§2) |
| «sudo: k3s: command not found» | Το sudo δεν βλέπει το `/usr/local/bin`: `sudo /usr/local/bin/k3s …`, ή ξανά το `node.sh`, που το διορθώνει |
| Ο worker κολλά στο «Starting k3s-agent» | Λάθος token (π.χ. κλειδί ssh αντί για το `K10…` του k3s1): Ctrl+C, και ξανά το `node.sh` με το σωστό |
| «scp: … /home/oracle/…: Permission denied» | Ο chris δεν διαβάζει το home του oracle: `sudo cp … ~chris/` πρώτα (§1) |
| Η σύνδεση ssh κόβεται στο «a fixed address» | Το `node.sh` άλλαξε τη διεύθυνση: ssh στη νέα και ξανά το `node.sh` (§2β) |
| Το `node.sh` έτρεξε σε λάθος μηχάνημα | `sudo /usr/local/bin/k3s-uninstall.sh` (ή `k3s-agent-uninstall.sh`), και το όνομα και η διεύθυνσή του πίσω με `hostnamectl` και `nmcli` |

## 8. Διαχείριση: πώς βλέπεις το cluster

### kubectl (στον k3s1)

Μία φορά, ένα σύντομο όνομα:

```bash
echo "alias k='sudo k3s kubectl'" >> ~/.bashrc && source ~/.bashrc
```

| Τι θέλεις να δεις | Εντολή |
|---|---|
| Οι κόμβοι και η κατάστασή τους | `k get nodes -o wide` |
| Όλα τα pods (και του συστήματος) | `k get pods -A -o wide` |
| Το bank: pods, service, ingress, autoscaler | `k -n bank get all,ingress,hpa,pdb` |
| Ζωντανά | `k -n bank get pods -o wide -w` (Ctrl+C για έξοδο) |
| Γιατί ένα pod δεν ξεκινά | `k -n bank describe pod <όνομα>` (τα Events στο τέλος) |
| Logs της εφαρμογής | `k -n bank logs deploy/bk-api -f` |
| CPU και μνήμη | `k top nodes`, `k -n bank top pods` |
| Τα γεγονότα του cluster | `k get events -A --sort-by=.lastTimestamp \| tail -20` |
| Οι εκδόσεις | `k -n bank rollout history deploy/bk-api` |

### k9s: το cluster ζωντανά στο τερματικό

```bash
curl -sL https://github.com/derailed/k9s/releases/latest/download/k9s_Linux_amd64.tar.gz | tar xz k9s
sudo mv k9s /usr/local/bin/
sudo k9s --kubeconfig /etc/rancher/k3s/k3s.yaml -n bank
```

Μέσα στο k9s:
- **Προβολή:** `:pods`, `:nodes`, `:deploy`, `:svc`, `:events`, `:pods bank`· το `0` δείχνει όλα τα namespaces.
- **Σε ένα pod:** `l` για logs, `d` για describe, `s` για shell μέσα στο container, `Ctrl+D` για διαγραφή (το Kubernetes το ξαναφτιάχνει)· `Esc` για πίσω.
- **Βοήθεια και έξοδος:** `?` για βοήθεια, `:q` (ή Ctrl+C) για έξοδο.

Αν δεις άδεια λίστα με τίτλο `pods(default)[0]`, είσαι στο namespace `default`: πάτα `0`, ή γράψε `:pods bank`.

### Headlamp: η κονσόλα του Kubernetes στον browser

Στον k3s1, μία φορά (το `ship_image.sh` το έχει φέρει στο `~/bank-k8s/`):

```bash
sudo ~/bank-k8s/headlamp.sh
```

Τι κάνει:
- στήνει το Headlamp (kubernetes-sigs) στο `kube-system`, στη διαδρομή `/headlamp`·
- φτιάχνει ένα Ingress για αυτή τη διαδρομή· το bank μένει στο `/`·
- φτιάχνει τον λογαριασμό `headlamp-admin` και τυπώνει ένα **token 8 ωρών**.

Άνοιξε το **http://192.168.178.211/headlamp/**, με την κάθετο στο τέλος, και βάλε το token. Βλέπεις:
- κόμβους, pods, deployments·
- logs και events·
- γραφήματα CPU και μνήμης.

Και κάνεις από εκεί:
- επανεκκίνηση και διαγραφή pods·
- scale·
- επεξεργασία YAML.

```bash
sudo ~/bank-k8s/headlamp.sh --token     # νέο token (το προηγούμενο έληξε)
sudo ~/bank-k8s/headlamp.sh --remove    # όλο το Headlamp έξω
```

⚠️ Το token δίνει **πλήρη έλεγχο** του cluster, και η σελίδα είναι σε απλό HTTP. Είναι μόνο για το τοπικό δίκτυο: ποτέ στο internet, και το token σε κανέναν.

### Headlamp ως εφαρμογή των Windows

Η ίδια κονσόλα, χωρίς τίποτα μέσα στο cluster: headlamp.dev (ή `winget install Headlamp.Headlamp`). Θέλει το **kubeconfig**:

```bash
# στον k3s1
sudo cat /etc/rancher/k3s/k3s.yaml | sed 's#https://127.0.0.1:6443#https://192.168.178.211:6443#' > ~/k3s-bank.yaml
```

1. Κατέβασέ το με το SFTP του MobaXterm στο `C:\Users\<χρήστης>\.kube\config`.
2. Σβήσε το αντίγραφο στον k3s1: `rm ~/k3s-bank.yaml`.
3. Άνοιξε το Headlamp.

⚠️ Το kubeconfig είναι το κλειδί διαχειριστή του cluster: μόνο στα Windows σου.
