[CmdletBinding()]
param(
    [ValidatePattern('^[A-Za-z0-9_-]+$')]
    [string]$ServiceName = 'GEHProductCatalogSync',

    [string]$InstallPath = (Join-Path $env:ProgramFiles 'GEH\ProductCatalogSync'),

    [string]$DataPath = (Join-Path $env:ProgramData 'GEH\ProductCatalogSync')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'worker-deployment-common.ps1')

$installPathFull = Resolve-UserPath -Path $InstallPath
$dataPathFull = Resolve-UserPath -Path $DataPath
$workerExecutable = Join-Path $installPathFull 'Catalog.Sync.Worker.exe'
$backupRoot = Join-Path $dataPathFull 'backups'
$logRoot = Join-Path $dataPathFull 'logs'
$service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue

$installedVersion = 'absente'
if (Test-Path -LiteralPath $workerExecutable -PathType Leaf) {
    $installedVersion = Get-WorkerFileVersion -ExecutablePath $workerExecutable
}
$latestBackup = Get-ChildItem -LiteralPath $backupRoot -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match '^\d{4}-\d{2}-\d{2}_\d{6}_' } |
    Sort-Object Name -Descending |
    Select-Object -First 1
$latestLog = Get-ChildItem -LiteralPath $logRoot -File -Filter 'catalog-sync-*.log' -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTimeUtc -Descending |
    Select-Object -First 1

[PSCustomObject]@{
    ServiceName = $ServiceName
    ServiceStatus = if ($service) { $service.Status } else { 'Absent' }
    InstalledVersion = $installedVersion
    InstallPath = $installPathFull
    LatestBackup = if ($latestBackup) { $latestBackup.FullName } else { 'Aucun' }
    LatestWorkerLog = if ($latestLog) { $latestLog.FullName } else { 'Aucun' }
}
