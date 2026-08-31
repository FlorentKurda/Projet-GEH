[CmdletBinding(DefaultParameterSetName = 'Package')]
param(
    [ValidatePattern('^[A-Za-z0-9_-]+$')]
    [string]$ServiceName = 'GEHProductCatalogSync',

    [Parameter(Mandatory, ParameterSetName = 'Package')]
    [string]$PackagePath,

    [Parameter(Mandatory, ParameterSetName = 'Publish')]
    [string]$PublishPath,

    [Parameter(ParameterSetName = 'Package')]
    [string]$HashPath,

    [string]$InstallPath = (Join-Path $env:ProgramFiles 'GEH\ProductCatalogSync'),

    [string]$BackupRoot = (Join-Path $env:ProgramData 'GEH\ProductCatalogSync\backups'),

    [ValidateRange(5, 600)]
    [int]$HealthTimeoutSeconds = 30,

    [ValidateRange(1, 60)]
    [int]$StabilitySeconds = 5,

    [ValidateRange(1, 100)]
    [int]$BackupRetention = 5,

    [bool]$RollbackOnFailure = $true,

    [switch]$ValidateWithRunOnce,

    [switch]$AllowDowngrade,

    [switch]$Force,

    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'worker-deployment-common.ps1')

function Invoke-WorkerRunOnceValidation {
    param(
        [Parameter(Mandatory)][string]$ExecutablePath,
        [Parameter(Mandatory)][string]$TargetServiceName
    )

    $registryPath = "HKLM:\SYSTEM\CurrentControlSet\Services\$TargetServiceName"
    $serviceEnvironment = @()
    if (Test-Path -LiteralPath $registryPath) {
        $registryValue = Get-ItemProperty -LiteralPath $registryPath -Name Environment -ErrorAction SilentlyContinue
        if ($registryValue) {
            $serviceEnvironment = @($registryValue.Environment)
        }
    }

    $previousValues = @{}
    try {
        foreach ($entry in $serviceEnvironment) {
            if ($entry -notmatch '^([A-Za-z_][A-Za-z0-9_]*)=(.*)$') {
                continue
            }
            $name = $Matches[1]
            $previousValues[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
            [Environment]::SetEnvironmentVariable($name, $Matches[2], 'Process')
        }

        Push-Location (Split-Path -Parent $ExecutablePath)
        try {
            & $ExecutablePath --run-once --dry-run
            if ($LASTEXITCODE -ne 0) {
                throw "La validation --run-once --dry-run a échoué avec le code $LASTEXITCODE."
            }
        }
        finally {
            Pop-Location
        }
    }
    finally {
        foreach ($name in $previousValues.Keys) {
            [Environment]::SetEnvironmentVariable($name, $previousValues[$name], 'Process')
        }
    }
}

function Restore-WorkerAfterFailedDeployment {
    param(
        [Parameter(Mandatory)][string]$BackupPath,
        [Parameter(Mandatory)][string]$TargetInstallPath,
        [Parameter(Mandatory)][string]$TargetServiceName,
        [Parameter(Mandatory)][bool]$WasRunning,
        [Parameter(Mandatory)][int]$TimeoutSeconds,
        [Parameter(Mandatory)][int]$StableSeconds
    )

    $service = Get-Service -Name $TargetServiceName -ErrorAction Stop
    if ($service.Status -ne [System.ServiceProcess.ServiceControllerStatus]::Stopped) {
        Stop-Service -Name $TargetServiceName -Force
        Wait-WorkerServiceStatus -ServiceName $TargetServiceName `
            -Status ([System.ServiceProcess.ServiceControllerStatus]::Stopped) `
            -TimeoutSeconds $TimeoutSeconds
    }

    Remove-WorkerPayloadFiles -Path $TargetInstallPath
    Copy-WorkerPayload -SourcePath $BackupPath -DestinationPath $TargetInstallPath
    $restoredVersion = Test-WorkerPayload -Path $TargetInstallPath -AllowPreservedLocalFiles

    if ($WasRunning) {
        Start-Service -Name $TargetServiceName
        Wait-WorkerServiceStatus -ServiceName $TargetServiceName `
            -Status ([System.ServiceProcess.ServiceControllerStatus]::Running) `
            -TimeoutSeconds $TimeoutSeconds
        Test-WorkerServiceStability -ServiceName $TargetServiceName -Seconds $StableSeconds
    }

    return $restoredVersion
}

$temporaryPaths = New-Object System.Collections.Generic.List[string]
$lockPath = $null
$backupPath = $null
$replacementStarted = $false

try {
    if ($env:OS -ne 'Windows_NT') {
        throw 'Ce script doit être exécuté sous Windows.'
    }
    if (-not $DryRun) {
        Assert-WindowsAdministrator
    }

    $service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if (-not $service) {
        throw "Le service '$ServiceName' est absent. Utilisez install-worker-service.ps1 pour une première installation."
    }
    $wasRunning = $service.Status -eq [System.ServiceProcess.ServiceControllerStatus]::Running
    if ($service.Status -notin @(
            [System.ServiceProcess.ServiceControllerStatus]::Running,
            [System.ServiceProcess.ServiceControllerStatus]::Stopped)) {
        throw "Le service '$ServiceName' est dans l état '$($service.Status)'. Attendez un état stable avant la mise à jour."
    }

    $installPathFull = Resolve-UserPath -Path $InstallPath
    $backupRootFull = Resolve-UserPath -Path $BackupRoot
    $installedExecutable = Join-Path $installPathFull 'Catalog.Sync.Worker.exe'
    $currentVersion = Get-WorkerFileVersion -ExecutablePath $installedExecutable

    if ($PSCmdlet.ParameterSetName -eq 'Package') {
        $packagePathFull = Resolve-UserPath -Path $PackagePath
        if (-not (Test-Path -LiteralPath $packagePathFull -PathType Leaf)) {
            throw "Package Worker introuvable : '$packagePathFull'."
        }
        [void](Test-WorkerPackageHash -PackagePath $packagePathFull -HashPath $HashPath)
        $expandedPath = Join-Path ([IO.Path]::GetTempPath()) ('GEHWorkerPackage-' + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $expandedPath | Out-Null
        $temporaryPaths.Add($expandedPath)
        Expand-Archive -LiteralPath $packagePathFull -DestinationPath $expandedPath
        $sourcePath = $expandedPath
    }
    else {
        $sourcePath = Resolve-UserPath -Path $PublishPath
        if (-not (Test-Path -LiteralPath $sourcePath -PathType Container)) {
            throw "Publication Worker introuvable : '$sourcePath'."
        }
    }

    Assert-NoForbiddenDeploymentFiles -Path $sourcePath
    if ($DryRun) {
        $stagingPath = Join-Path ([IO.Path]::GetTempPath()) ('GEHWorkerStaging-' + [Guid]::NewGuid().ToString('N'))
    }
    else {
        $stagingPath = "$installPathFull.staging-$([Guid]::NewGuid().ToString('N'))"
    }
    New-Item -ItemType Directory -Path $stagingPath | Out-Null
    $temporaryPaths.Add($stagingPath)
    Copy-WorkerPayload -SourcePath $sourcePath -DestinationPath $stagingPath
    $newVersion = Test-WorkerPayload -Path $stagingPath

    $comparison = Compare-WorkerVersion -Left $newVersion -Right $currentVersion
    if ($comparison -eq 0 -and -not $Force) {
        Write-Host "Version $newVersion déjà installée. Utilisez -Force pour redéployer explicitement."
        return
    }
    if ($comparison -lt 0 -and -not $AllowDowngrade) {
        throw "La version proposée '$newVersion' est antérieure à la version installée '$currentVersion'. Utilisez le rollback dédié ou -AllowDowngrade."
    }

    Write-DeploymentStep -Message "Ancienne version : $currentVersion."
    Write-DeploymentStep -Message "Nouvelle version : $newVersion."
    Write-DeploymentStep -Message "État initial du service : $($service.Status)."

    $backupName = New-WorkerBackupName -Version $currentVersion
    $backupPath = Join-Path $backupRootFull $backupName
    if ($DryRun) {
        Write-Host "BACKUP: '$installPathFull' -> '$backupPath' (binaires et configuration versionnée uniquement)."
        if ($wasRunning) {
            Write-Host "STOP: service '$ServiceName', attente Stopped."
        }
        else {
            Write-Host "STOP: ignoré, service '$ServiceName' déjà Stopped."
        }
        if ($ValidateWithRunOnce) {
            Write-Host "VALIDATE: '$stagingPath\Catalog.Sync.Worker.exe' --run-once --dry-run avec l environnement du service."
        }
        Write-Host "COPY: payload validé '$stagingPath' -> '$installPathFull'."
        if ($wasRunning) {
            Write-Host "START: service '$ServiceName', attente Running."
            Write-Host "CHECK: stabilité Running pendant $StabilitySeconds seconde(s), timeout $HealthTimeoutSeconds seconde(s)."
        }
        else {
            Write-Host "START: ignoré afin de conserver l état Stopped."
            Write-Host 'CHECK: version installée et intégrité du payload uniquement.'
        }
        Write-Host "RETENTION: conserver les $BackupRetention derniers backups après succès."
        Write-Host 'DryRun terminé : aucune sauvegarde, copie, suppression ou action service effectuée.'
        return
    }

    $lockPath = New-WorkerDeploymentLock -BackupRoot $backupRootFull
    Write-DeploymentStep -Message "Verrou acquis : $lockPath."

    Assert-NoSecretConfigurationValues -Path $installPathFull
    New-Item -ItemType Directory -Path $backupPath | Out-Null
    Copy-WorkerPayload -SourcePath $installPathFull -DestinationPath $backupPath
    $backupVersion = Test-WorkerPayload -Path $backupPath
    if ((Compare-WorkerVersion -Left $backupVersion -Right $currentVersion) -ne 0) {
        throw "La sauvegarde '$backupPath' ne correspond pas à la version installée."
    }
    Write-DeploymentStep -Message "Backup créé : $backupPath."

    if ($wasRunning) {
        Write-DeploymentStep -Message "Arrêt du service '$ServiceName'."
        Stop-Service -Name $ServiceName
        Wait-WorkerServiceStatus -ServiceName $ServiceName `
            -Status ([System.ServiceProcess.ServiceControllerStatus]::Stopped) `
            -TimeoutSeconds $HealthTimeoutSeconds
    }
    else {
        Write-DeploymentStep -Message "Service '$ServiceName' déjà arrêté ; cet état sera conservé."
    }

    if ($ValidateWithRunOnce) {
        Write-DeploymentStep -Message 'Validation optionnelle --run-once --dry-run demandée.'
        try {
            Invoke-WorkerRunOnceValidation `
                -ExecutablePath (Join-Path $stagingPath 'Catalog.Sync.Worker.exe') `
                -TargetServiceName $ServiceName
        }
        catch {
            $validationError = $_
            if ($wasRunning) {
                Start-Service -Name $ServiceName
                Wait-WorkerServiceStatus -ServiceName $ServiceName `
                    -Status ([System.ServiceProcess.ServiceControllerStatus]::Running) `
                    -TimeoutSeconds $HealthTimeoutSeconds
                Test-WorkerServiceStability -ServiceName $ServiceName -Seconds $StabilitySeconds
            }
            throw $validationError
        }
    }

    $replacementStarted = $true
    Remove-WorkerPayloadFiles -Path $installPathFull
    Copy-WorkerPayload -SourcePath $stagingPath -DestinationPath $installPathFull
    $installedVersion = Test-WorkerPayload -Path $installPathFull -AllowPreservedLocalFiles
    if ((Compare-WorkerVersion -Left $installedVersion -Right $newVersion) -ne 0) {
        throw "La version copiée '$installedVersion' diffère de la version attendue '$newVersion'."
    }
    Write-DeploymentStep -Message "Binaires $installedVersion déployés."

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

    foreach ($oldBackup in Get-WorkerBackupsToRemove `
            -BackupRoot $backupRootFull `
            -Keep $BackupRetention `
            -ProtectedPath $backupPath) {
        Remove-Item -LiteralPath $oldBackup.FullName -Recurse -Force
        Write-DeploymentStep -Message "Ancien backup supprimé par rétention : $($oldBackup.Name)."
    }

    Write-DeploymentStep -Message "Déploiement validé : $currentVersion -> $newVersion."
}
catch {
    $deploymentError = $_
    Write-Error "Déploiement échoué : $($deploymentError.Exception.Message)" -ErrorAction Continue

    if (-not $DryRun -and $replacementStarted -and $RollbackOnFailure -and
        -not [string]::IsNullOrWhiteSpace($backupPath) -and
        (Test-Path -LiteralPath $backupPath -PathType Container)) {
        try {
            $rollbackVersion = Get-WorkerFileVersion -ExecutablePath (
                Join-Path $backupPath 'Catalog.Sync.Worker.exe')
            Write-DeploymentStep -Message "Rollback vers version $rollbackVersion."
            $restoredVersion = Restore-WorkerAfterFailedDeployment `
                -BackupPath $backupPath `
                -TargetInstallPath $installPathFull `
                -TargetServiceName $ServiceName `
                -WasRunning $wasRunning `
                -TimeoutSeconds $HealthTimeoutSeconds `
                -StableSeconds $StabilitySeconds
            Write-DeploymentStep -Message "Rollback réussi vers version $restoredVersion."
        }
        catch {
            Write-Error "ROLLBACK ÉCHOUÉ — intervention manuelle requise : $($_.Exception.Message)" -ErrorAction Continue
        }
    }

    throw $deploymentError
}
finally {
    Remove-WorkerDeploymentLock -LockPath $lockPath
    foreach ($temporaryPath in $temporaryPaths) {
        if (Test-Path -LiteralPath $temporaryPath -PathType Container) {
            Remove-Item -LiteralPath $temporaryPath -Recurse -Force
        }
    }
}
