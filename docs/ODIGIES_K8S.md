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

Μνήμη: 3 × 4 GB = 12 GB. Με το forms1 (16 GB) και τα Windows με το Ollama μένουν περίπου 25 GB ελεύθερα στα 64 του laptop.

## 1. Τα VMs (Windows)

Θέλεις το ISO του Oracle Linux 9 (DVD, π.χ. `OracleLinux-R9-U5-x86_64-dvd.iso`, το ίδιο που έστησε το forms1). Πάρε το `k8s/vms.ps1` από το GitHub (Raw) σε έναν φάκελο των Windows. Μετά, σε PowerShell:

```powershell
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" list bridgedifs | findstr /b "Name:"   # το όνομα της κάρτας δικτύου
powershell -ExecutionPolicy Bypass -File .\vms.ps1 -Iso D:\iso\OracleLinux-R9-U5-x86_64-dvd.iso
```

Ζητά τον κωδικό του χρήστη `chris` (και του root) των VMs μία φορά· δεν φαίνεται και δεν μένει σε αρχείο. Η εγκατάσταση τρέχει χωρίς παράθυρο, περίπου 10–15 λεπτά για κάθε VM· την παρακολουθείς από το VirtualBox Manager (Show). Αν η κάρτα δεν είναι η `ASUS 2.5G Ethernet USB Adapter`, δώσε `-Adapter "<όνομα>"`.

## 2. Κάθε VM γίνεται κόμβος (στην κονσόλα του)

Στο VirtualBox Manager → το VM → Show, σύνδεση ως `chris`. Το VM παίρνει πρώτα διεύθυνση από το router· τη βλέπεις με `ip -4 a`. Από το forms1 στείλε του το `node.sh`:

```bash
scp ~oracle/bank/k8s/node.sh chris@<προσωρινή IP του VM>:
```

Μετά, **στην κονσόλα** του VM. Η διεύθυνσή του αλλάζει, οπότε μια σύνδεση ssh θα κοβόταν.

```bash
# k3s1: ο server (δείχνει στο τέλος το token)
sudo ./node.sh server 192.168.178.211
# k3s2, k3s3: workers (ζητούν το token του server)
sudo ./node.sh agent 192.168.178.212 192.168.178.211
sudo ./node.sh agent 192.168.178.213 192.168.178.211
```

Το token το ξαναβλέπεις στον server με `sudo cat /var/lib/rancher/k3s/server/node-token`. Στο τέλος, στο k3s1:

```bash
sudo k3s kubectl get nodes -o wide      # 3 κόμβοι Ready
```

Οι διευθύνσεις .211–.213 είναι έξω από το εύρος DHCP του FRITZ!Box (εξ ορισμού .20–.200). Για σιγουριά, κράτησέ τες και εκεί: Home Network → Network → Network Connections → το μολύβι (Edit) → «Always assign this network device the same IPv4 address».

## 3. Η εικόνα (forms1)

Μία φορά: η βάση να δέχεται συνδέσεις από τους κόμβους (μόνο από αυτούς), και κλειδιά ssh προς αυτούς:

```bash
for ip in 192.168.178.211 192.168.178.212 192.168.178.213; do
  sudo firewall-cmd --permanent --add-rich-rule="rule family=ipv4 source address=$ip/32 port port=1521 protocol=tcp accept"
done
sudo firewall-cmd --reload
[ -f ~/.ssh/id_ed25519 ] || ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519
for ip in 192.168.178.211 192.168.178.212 192.168.178.213; do ssh-copy-id chris@$ip; done
```

Κάθε φορά που αλλάζει ο κώδικας (μετά από ένα `git pull`):

```bash
sudo ~oracle/bank/k8s/ship_image.sh
```

Χτίζει το jar και την εικόνα `localhost/bank/bk-api:<commit>`, και τη στέλνει σε κάθε κόμβο. Δεν χρειάζεται registry: γίνεται με ssh και `k3s ctr images import`. Στο τέλος γράφει την εντολή για το επόμενο βήμα.

## 4. Το deploy (k3s1)

```bash
sudo ~/bank-k8s/deploy.sh <commit>          # την πρώτη φορά ζητά τον κωδικό του χρήστη BANK της βάσης
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
