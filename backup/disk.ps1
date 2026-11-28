<#
disk.ps1 -- on the Windows of the i9 (VirtualBox): a second disk for em1, for the backups of the databases (RMAN):
docs/ODIGIES_BACKUP.md. Dynamic (it grows as it fills), 500 GB at most, in D:\Oracle\backup -- another computer than
the laptop of db1 and db2: a fault of the laptop does not take the backups with the databases. With em1 off:

  powershell -ExecutionPolicy Bypass -File .\disk.ps1
  powershell -ExecutionPolicy Bypass -File .\disk.ps1 -SizeGB 800 -Folder E:\backup

Then em1 on, and on it backup/nfs_server.sh (the disk as /backup, shared by NFS).
#>
param(
  [string]$Vm = 'em1',
  [int]$SizeGB = 500,
  [string]$Folder = 'D:\Oracle\backup'
)
$ErrorActionPreference = 'Stop'
$vbox = Join-Path $env:ProgramFiles 'Oracle\VirtualBox\VBoxManage.exe'
if (-not (Test-Path $vbox)) { throw "no VBoxManage: $vbox" }
function vb { & $vbox @args; if ($LASTEXITCODE -ne 0) { throw "VBoxManage $($args -join ' ')" } }
$info = & $vbox showvminfo $Vm --machinereadable
if ($LASTEXITCODE -ne 0) { throw "no VM $Vm" }
if ($info -match '^VMState="running"') { throw "$Vm is running: shut it down first (sudo shutdown -h now)" }
$vdi = Join-Path $Folder "$Vm-backup.vdi"
if ($info -match [regex]::Escape($vdi)) { Write-Host "== $vdi is on $Vm already"; exit 0 }
New-Item -ItemType Directory -Force -Path $Folder | Out-Null
if (-not (Test-Path $vdi)) {
  Write-Host "== the disk $vdi ($SizeGB GB, dynamic)"
  vb createmedium disk --filename $vdi --size ($SizeGB * 1024) --format VDI --variant Standard
}
# (vms.ps1 made the SATA of the VM with one port)
vb storagectl $Vm --name SATA --portcount 2
vb storageattach $Vm --storagectl SATA --port 1 --device 0 --type hdd --medium $vdi
Write-Host "== $Vm has the disk of the backups. Start it, then on it: sudo bash ~/nfs_server.sh"
