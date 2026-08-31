[CmdletBinding()]
param(
    [ValidatePattern('^[A-Za-z0-9_-]+$')]
    [string]$ServiceName = 'GEHProductCatalogSync',

    [string]$BackupPath,

    [string]$Version,

    [string]$InstallPath = (Join-Path $env:ProgramFiles 'GEH\ProductCatalogSync'),

    [string]$BackupRoot = (Join-Path $env:ProgramData 'GEH\ProductCatalogSync\backups'),

    [ValidateRange(5, 600)]
    [int]$HealthTimeoutSeconds = 30,

    [ValidateRange(1, 60)]
    [int]$StabilitySeconds = 5,

    [switch]$List,

    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'worker-deployment-common.ps1')

if (-not [string]::IsNullOrWhiteSpace($BackupPath) -and
    -not [string]::IsNullOrWhiteSpace($Version)) {
    throw 'Utilisez soit -BackupPath, soit -Version, jamais les deux.'
}

$lockPath = $null
$failedSnapshotPath = $null
$replacementStarted = $false

try {
    if ($env:OS -ne 'Windows_NT') {
        throw 'Ce script doit être exécuté sous Windows.'
    }
    if (-not $DryRun -and -not $List) {
        Assert-WindowsAdministrator
    }

    $service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if (-not $service) {
        throw "Le service '$ServiceName' est absent. Aucun rollback n est possible."
    }
    $wasRunning = $service.Status -eq [System.ServiceProcess.ServiceControllerStatus]::Running
    if ($service.Status -notin @(
            [System.ServiceProcess.ServiceControllerStatus]::Running,
            [System.ServiceProcess.ServiceControllerStatus]::Stopped)) {
        throw "Le service '$ServiceName' est dans l état '$($service.Status)'. Attendez un état stable avant le rollback."
    }

    $installPathFull = Resolve-UserPath -Path $InstallPath
    $backupRootFull = Resolve-UserPath -Path $BackupRoot
    $availableBackups = @()
    if (Test-Path -LiteralPath $backupRootFull -PathType Container) {
        $availableBackups = @(Get-ChildItem -LiteralPath $backupRootFull -Directory |
            Where-Object { $_.Name -match '^\d{4}-\d{2}-\d{2}_\d{6}_' } |
            Sort-Object Name -Descending)
    }

    Write-Host 'Backups disponibles :'
    if ($availableBackups.Count -eq 0) {
        Write-Host '  aucun'
    }
    else {
        foreach ($backup in $availableBackups) {
            Write-Host "  $($backup.FullName)"
        }
    }

    if ($List) {
        return
    }

    if (-not [string]::IsNullOrWhiteSpace($Version)) {
        $selected = @($availableBackups | Where-Object {
            $_.Name -like "*_$Version"
        } | Select-Object -First 1)
        if ($selected.Count -eq 0) {
            throw "Aucun backup ne correspond à la version '$Version'."
        }
        $BackupPath = $selected[0].FullName
    }
    elseif ([string]::IsNullOrWhiteSpace($BackupPath)) {
        throw 'Précisez explicitement -BackupPath ou -Version après avoir vérifié la liste.'
    }

    $backupPathFull = Resolve-UserPath -Path $BackupPath
    $backupRootPrefix = $backupRootFull.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if (-not $backupPathFull.StartsWith($backupRootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Le backup doit se trouver sous '$backupRootFull'."
    }
    $backupVersion = Test-WorkerPayload -Path $backupPathFull
    $currentVersion = Get-WorkerFileVersion -ExecutablePath (
        Join-Path $installPathFull 'Catalog.Sync.Worker.exe')
    $failedSnapshotName = New-WorkerBackupName `
        -Version $currentVersion `
        -Prefix 'failed_'
    $failedSnapshotPath = Join-Path $backupRootFull $failedSnapshotName

    Write-DeploymentStep -Message "Version installée : $currentVersion."
    Write-DeploymentStep -Message "Version de rollback : $backupVersion."

    if ($DryRun) {
        Write-Host "SAVE_FAILED: '$installPathFull' -> '$failedSnapshotPath' pour diagnostic."
        if ($wasRunning) {
            Write-Host "STOP: service '$ServiceName', attente Stopped."
        }
        else {
            Write-Host "STOP: ignoré, service '$ServiceName' déjà Stopped."
        }
        Write-Host "COPY: backup '$backupPathFull' -> '$installPathFull'."
        if ($wasRunning) {
            Write-Host "START: service '$ServiceName', attente Running."
            Write-Host "CHECK: stabilité Running pendant $StabilitySeconds seconde(s), timeout $HealthTimeoutSeconds seconde(s)."
        }
        else {
            Write-Host "START: ignoré afin de conserver l état Stopped."
            Write-Host 'CHECK: version restaurée et intégrité du payload uniquement.'
        }
        Write-Host 'DryRun terminé : aucune sauvegarde, copie, suppression ou action service effectuée.'
        return
    }

    $lockPath = New-WorkerDeploymentLock -BackupRoot $backupRootFull
    Write-DeploymentStep -Message "Verrou acquis : $lockPath."

    Assert-NoSecretConfigurationValues -Path $installPathFull
    New-Item -ItemType Directory -Path $failedSnapshotPath | Out-Null
    Copy-WorkerPayload -SourcePath $installPathFull -DestinationPath $failedSnapshotPath
    [void](Test-WorkerPayload -Path $failedSnapshotPath)
    Write-DeploymentStep -Message "Version défaillante conservée : $failedSnapshotPath."

    if ($wasRunning) {
        Stop-Service -Name $ServiceName
        Wait-WorkerServiceStatus -ServiceName $ServiceName `
            -Status ([System.ServiceProcess.ServiceControllerStatus]::Stopped) `
            -TimeoutSeconds $HealthTimeoutSeconds
    }

    $replacementStarted = $true
    Remove-WorkerPayloadFiles -Path $installPathFull
    Copy-WorkerPayload -SourcePath $backupPathFull -DestinationPath $installPathFull
    $restoredVersion = Test-WorkerPayload -Path $installPathFull -AllowPreservedLocalFiles
    if ((Compare-WorkerVersion -Left $restoredVersion -Right $backupVersion) -ne 0) {
        throw "La version restaurée '$restoredVersion' diffère du backup '$backupVersion'."
    }

    if ($wasRunning) {
        Start-Service -Name $ServiceName
        Wait-WorkerServiceStatus -ServiceName $ServiceName `
            -Status ([System.ServiceProcess.ServiceControllerStatus]::Running) `
            -TimeoutSeconds $HealthTimeoutSeconds
        Test-WorkerServiceStability -ServiceName $ServiceName -Seconds $StabilitySeconds
        Write-DeploymentStep -Message "Service '$ServiceName' Running et stable."
    }
    else {
        Write-DeploymentStep -Message "Service '$ServiceName' laissé Stopped conformément à son état initial."
    }

    Write-DeploymentStep -Message "Rollback réussi : $currentVersion -> $restoredVersion."
}
catch {
    $rollbackError = $_
    Write-Error "Rollback échoué : $($rollbackError.Exception.Message)" -ErrorAction Continue

    if (-not $DryRun -and $replacementStarted -and
        -not [string]::IsNullOrWhiteSpace($failedSnapshotPath) -and
        (Test-Path -LiteralPath $failedSnapshotPath -PathType Container)) {
        try {
            $service = Get-Service -Name $ServiceName -ErrorAction Stop
            if ($service.Status -ne [System.ServiceProcess.ServiceControllerStatus]::Stopped) {
                Stop-Service -Name $ServiceName -Force
                Wait-WorkerServiceStatus -ServiceName $ServiceName `
                    -Status ([System.ServiceProcess.ServiceControllerStatus]::Stopped) `
                    -TimeoutSeconds $HealthTimeoutSeconds
            }
            Remove-WorkerPayloadFiles -Path $installPathFull
            Copy-WorkerPayload -SourcePath $failedSnapshotPath -DestinationPath $installPathFull
            [void](Test-WorkerPayload -Path $installPathFull -AllowPreservedLocalFiles)
            if ($wasRunning) {
                Start-Service -Name $ServiceName
                Wait-WorkerServiceStatus -ServiceName $ServiceName `
                    -Status ([System.ServiceProcess.ServiceControllerStatus]::Running) `
                    -TimeoutSeconds $HealthTimeoutSeconds
            }
            Write-DeploymentStep -Message 'La version présente avant le rollback a été remise en place.'
        }
        catch {
            Write-Error "RESTAURATION DE SECOURS ÉCHOUÉE — intervention manuelle requise : $($_.Exception.Message)" -ErrorAction Continue
        }
    }

    throw $rollbackError
}
finally {
    Remove-WorkerDeploymentLock -LockPath $lockPath
}
