<#
rac_disks.ps1 -- on the Windows of the i9 (VirtualBox), once, with rac1 and rac2 made (k8s/vms.ps1 -Names rac1,rac2,
docs/ODIGIES_RAC.md) and POWERED OFF: what makes two VMs a cluster.
  - a second network card on each: an internal network of VirtualBox (racpriv), the interconnect of the cluster
    (10.10.10.x: rac/rac_host.sh), seen only by rac1 and rac2
  - three disks shared by both (fixed size, shareable: ASM writes to them from both nodes at once):
      rac-crs.vdi   10 GB   the disk group CRS: the registry of the cluster (OCR) and its voting file
      rac-data.vdi  40 GB   the disk group DATA: the files of the database
      rac-reco.vdi  20 GB   the disk group RECO: archived logs, flashback, backups
    in <machine folder>\rac-shared; ~70 GB of disk at once (fixed: written in full now, some minutes)
PowerShell, from the folder of this file:

  powershell -ExecutionPolicy Bypass -File .\rac_disks.ps1
#>
param(
  [string[]]$Names = @('rac1', 'rac2'),
  [int]$CrsGB = 10,
  [int]$DataGB = 40,
  [int]$RecoGB = 20
)
$ErrorActionPreference = 'Stop'
$vbox = Join-Path $env:ProgramFiles 'Oracle\VirtualBox\VBoxManage.exe'
if (-not (Test-Path $vbox)) { throw "no VBoxManage: $vbox" }
function vb { & $vbox @args; if ($LASTEXITCODE -ne 0) { throw "VBoxManage $($args -join ' ')" } }
$Names = @($Names | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })

$running = & $vbox list runningvms
foreach ($n in $Names) {
  if (-not ((& $vbox list vms) -match "`"$n`"")) { throw "no VM $n (first: vms.ps1 -Names rac1,rac2)" }
  if ($running -match "`"$n`"") { throw "$n is running: off first (in it: sudo shutdown -h now)" }
}
$folder = ((& $vbox list systemproperties) | Where-Object { $_ -like 'Default machine folder:*' }) -replace '^Default machine folder:\s*', ''
$shared = Join-Path $folder 'rac-shared'
New-Item -ItemType Directory -Force -Path $shared | Out-Null

Write-Host "== the interconnect: a second card on each, internal network racpriv"
foreach ($n in $Names) {
  vb modifyvm $n --nic2 intnet --intnet2 racpriv --nictype2 82540EM --cableconnected2 on
}

Write-Host "== the shared disks in $shared (fixed size: some minutes)"
$disks = @(@{ Name = 'rac-crs'; GB = $CrsGB; Port = 1 }, @{ Name = 'rac-data'; GB = $DataGB; Port = 2 },
           @{ Name = 'rac-reco'; GB = $RecoGB; Port = 3 })
foreach ($d in $disks) {
  $vdi = Join-Path $shared "$($d.Name).vdi"
  if (-not (Test-Path $vdi)) {
    Write-Host "   $($d.Name): $($d.GB) GB"
    vb createmedium disk --filename $vdi --size ($d.GB * 1024) --format VDI --variant Fixed
    vb modifymedium disk $vdi --type shareable
  }
}
foreach ($n in $Names) {
  vb storagectl $n --name SATA --portcount 4
  foreach ($d in $disks) {
    $vdi = Join-Path $shared "$($d.Name).vdi"
    vb storageattach $n --storagectl SATA --port $d.Port --device 0 --type hdd --medium $vdi --mtype shareable
  }
}
Write-Host "== done: start rac1 and rac2; then on each rac/rac_host.sh (docs/ODIGIES_RAC.md)"
