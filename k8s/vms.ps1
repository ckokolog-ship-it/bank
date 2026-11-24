<#
vms.ps1 -- on the Windows of the laptop (VirtualBox): the 3 VMs of the cluster k3s, Oracle Linux 9, each installed by
itself (VBoxManage unattended install, as forms1 was): 2 vCPU, 4 GB, a disk of 30 GB, bridged to the network of
forms1 (192.168.178.x). PowerShell, from the folder of this file:

  powershell -ExecutionPolicy Bypass -File .\vms.ps1 -Iso D:\iso\OracleLinux-R9-U5-x86_64-dvd.iso
  powershell -ExecutionPolicy Bypass -File .\vms.ps1 -Iso ... -Names k3s1,k3s2 -MemoryMB 6144
  powershell -ExecutionPolicy Bypass -File .\vms.ps1 -Iso ... -Names db1,db2 -MemoryMB 8192 -Cpus 3 -DiskGB 100

The password of the user (chris, with sudo) asked once, not shown; to VirtualBox in a temporary file, deleted at
the end. The installation runs headless, some 10-15 minutes each; then on each VM, on its console:
k8s/node.sh (its fixed address, k3s). -Adapter: the network card of the bridge (VBoxManage list bridgedifs).
#>
param(
  [Parameter(Mandatory = $true)][string]$Iso,
  [string[]]$Names = @('k3s1', 'k3s2', 'k3s3'),
  [string]$Adapter = 'ASUS 2.5G Ethernet USB Adapter',
  [string]$User = 'chris',
  [int]$MemoryMB = 4096,
  [int]$Cpus = 2,
  [int]$DiskGB = 30
)
$ErrorActionPreference = 'Stop'
# powershell -File gives -Names db1,db2 as one string 'db1,db2': split it; the ISO by its full path (VBoxManage)
$Names = @($Names | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
foreach ($n in $Names) { if ($n -notmatch '^[A-Za-z0-9-]+$') { throw "a name of a VM: letters, digits, - only: $n" } }
$vbox = Join-Path $env:ProgramFiles 'Oracle\VirtualBox\VBoxManage.exe'
if (-not (Test-Path $vbox)) { throw "no VBoxManage: $vbox" }
if (-not (Test-Path $Iso)) { throw "no ISO: $Iso" }
$Iso = (Resolve-Path $Iso).Path
function vb { & $vbox @args; if ($LASTEXITCODE -ne 0) { throw "VBoxManage $($args -join ' ')" } }

$existing = & $vbox list vms
foreach ($n in $Names) { if ($existing -match "`"$n`"") { throw "a VM $n exists already" } }
$folder = ((& $vbox list systemproperties) | Where-Object { $_ -like 'Default machine folder:*' }) -replace '^Default machine folder:\s*', ''

$p1 = Read-Host "Password of $User (and of root) in the VMs" -AsSecureString
$p2 = Read-Host 'Again' -AsSecureString
$s1 = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($p1))
$s2 = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($p2))
if (-not $s1 -or $s1 -ne $s2) { throw 'empty, or not the same' }
$pwFile = [IO.Path]::GetTempFileName()
try {
  [IO.File]::WriteAllText($pwFile, $s1)
  Remove-Variable s1, s2
  foreach ($n in $Names) {
    Write-Host "== $n"
    vb createvm --name $n --ostype Oracle_64 --register
    vb modifyvm $n --memory $MemoryMB --cpus $Cpus --ioapic on --pae on --nic1 bridged --bridgeadapter1 $Adapter `
       --graphicscontroller vmsvga --vram 16 --audio-driver none --usb off --boot1 disk --boot2 dvd
    $vdi = Join-Path (Join-Path $folder $n) "$n.vdi"
    vb createmedium disk --filename $vdi --size ($DiskGB * 1024) --format VDI
    vb storagectl $n --name SATA --add sata --controller IntelAhci --portcount 1
    vb storageattach $n --storagectl SATA --port 0 --device 0 --type hdd --medium $vdi
    vb storagectl $n --name IDE --add ide
    # (its output not shown: VBoxManage prints the password in it; chris in wheel: sudo)
    $out = & $vbox unattended install $n --iso=$Iso --user=$User --password-file=$pwFile --full-user-name=$User `
       --hostname="$n.home.lan" --locale=en_US --country=GR --time-zone=Europe/Athens `
       --post-install-command="usermod -aG wheel $User" --start-vm=headless 2>&1
    if ($LASTEXITCODE -ne 0) { throw "VBoxManage unattended install $n (exit $LASTEXITCODE)" }
    Remove-Variable out
    Write-Host "   installing (headless)"
  }
} finally {
  Remove-Item $pwFile -Force -ErrorAction SilentlyContinue
}
Write-Host "== the VMs install themselves (VirtualBox Manager: their console). Then on each one: k8s/node.sh"
Write-Host "== after: on each VM passwd (chris) and sudo passwd root; the VMs off, their Unattended-* files away:"
Write-Host "   docs/ODIGIES_K8S.md, 1"
