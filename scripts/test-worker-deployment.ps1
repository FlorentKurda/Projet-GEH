[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'worker-deployment-common.ps1')

function Assert-DeploymentTest {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('GEHWorkerDeploymentTest-' + [Guid]::NewGuid().ToString('N'))
$installedPath = Join-Path $testRoot 'installed-v1'
$newPath = Join-Path $testRoot 'new-v2'
$backupPath = Join-Path $testRoot 'backup'
$originalPowerShellLocation = (Get-Location).Path
$originalDotNetCurrentDirectory = [Environment]::CurrentDirectory

try {
    foreach ($path in @($installedPath, $newPath)) {
        New-Item -ItemType Directory -Path $path -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $path 'fixtures') -Force | Out-Null
        foreach ($name in @(
                'Catalog.Sync.Worker.exe',
                'Catalog.Sync.Worker.dll',
                'Catalog.Sync.Worker.deps.json',
                'Catalog.Sync.Worker.runtimeconfig.json',
                'appsettings.json')) {
            Set-Content -LiteralPath (Join-Path $path $name) -Value 'payload' -Encoding ASCII
        }
        Set-Content -LiteralPath (Join-Path $path 'fixtures\products.json') -Value '[]' -Encoding ASCII
    }
    Set-Content -LiteralPath (Join-Path $installedPath 'Catalog.Sync.Worker.dll') -Value 'installed-v1' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $installedPath 'obsolete-runtime.dll') -Value 'old-runtime' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $newPath 'Catalog.Sync.Worker.dll') -Value 'new-v2' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $installedPath '.env.worker.service.local') -Value 'SECRET=preserve' -Encoding ASCII

    $powerShellLocation = Join-Path $testRoot 'PowerShell location with spaces'
    $dotNetLocation = Join-Path $testRoot 'different-dotnet-current-directory'
    New-Item -ItemType Directory -Path $powerShellLocation,$dotNetLocation -Force | Out-Null
    try {
        Set-Location -LiteralPath $powerShellLocation
        [Environment]::CurrentDirectory = $dotNetLocation

        $observedPowerShellLocation = (Get-Location).Path
        $relativeInput = '.\artifacts\packages\foo.zip'
        $relativeExpected = [IO.Path]::GetFullPath((Join-Path $observedPowerShellLocation $relativeInput))
        Assert-DeploymentTest `
            -Condition ((Resolve-UserPath -Path $relativeInput) -eq $relativeExpected) `
            -Message 'Le chemin relatif n est pas résolu depuis la localisation PowerShell.'

        $absoluteInput = Join-Path $testRoot 'absolute\foo.zip'
        Assert-DeploymentTest `
            -Condition ((Resolve-UserPath -Path $absoluteInput) -eq [IO.Path]::GetFullPath($absoluteInput)) `
            -Message 'Le chemin absolu a été modifié.'

        $spaceInput = '.\folder with spaces\package file.zip'
        $spaceExpected = [IO.Path]::GetFullPath((Join-Path $observedPowerShellLocation $spaceInput))
        Assert-DeploymentTest `
            -Condition ((Resolve-UserPath -Path $spaceInput) -eq $spaceExpected) `
            -Message 'Le chemin contenant des espaces est incorrect.'
        Assert-DeploymentTest `
            -Condition (-not (Test-Path -LiteralPath $spaceExpected)) `
            -Message 'Le test de chemin inexistant utilise un fichier déjà présent.'

        $childLocation = Join-Path $powerShellLocation 'child'
        New-Item -ItemType Directory -Path $childLocation | Out-Null
        Set-Location -LiteralPath $childLocation
        [Environment]::CurrentDirectory = $dotNetLocation
        $observedChildLocation = (Get-Location).Path
        $parentExpected = [IO.Path]::GetFullPath((Join-Path $observedChildLocation '..\backups\v1'))
        Assert-DeploymentTest `
            -Condition ((Resolve-UserPath -Path '..\backups\v1') -eq $parentExpected) `
            -Message 'Le chemin contenant .. est incorrect.'

        $environmentExpected = [IO.Path]::GetFullPath((Join-Path $observedChildLocation '.\.env.worker.service.local'))
        Assert-DeploymentTest `
            -Condition ((Resolve-UserPath -Path '.\.env.worker.service.local') -eq $environmentExpected) `
            -Message 'Le chemin EnvironmentFile relatif est incorrect.'

        $backupExpected = [IO.Path]::GetFullPath((Join-Path $observedChildLocation '.\backups\2026-08-31_1.0.0'))
        Assert-DeploymentTest `
            -Condition ((Resolve-UserPath -Path '.\backups\2026-08-31_1.0.0') -eq $backupExpected) `
            -Message 'Le chemin BackupPath relatif est incorrect.'
    }
    finally {
        Set-Location -LiteralPath $originalPowerShellLocation
        [Environment]::CurrentDirectory = $originalDotNetCurrentDirectory
    }

    Assert-DeploymentTest `
        -Condition ((Compare-WorkerVersion -Left '2.0.0' -Right '1.9.9') -gt 0) `
        -Message 'La comparaison de versions est incorrecte.'
    Assert-DeploymentTest `
        -Condition ((Compare-WorkerVersion -Left '1.0.0' -Right '1.0.0.0') -eq 0) `
        -Message 'Les versions équivalentes à trois et quatre segments diffèrent.'
    $backupName = New-WorkerBackupName `
        -Version '1.0.0' `
        -Timestamp ([DateTime]'2026-08-31T10:15:00')
    Assert-DeploymentTest `
        -Condition ($backupName -eq '2026-08-31_101500_1.0.0') `
        -Message 'Le nom de backup est incorrect.'

    Copy-WorkerPayload -SourcePath $installedPath -DestinationPath $backupPath
    Assert-DeploymentTest `
        -Condition (-not (Test-Path -LiteralPath (Join-Path $backupPath '.env.worker.service.local'))) `
        -Message 'Un secret local a été copié dans le backup.'

    Remove-WorkerPayloadFiles -Path $installedPath
    Copy-WorkerPayload -SourcePath $newPath -DestinationPath $installedPath
    $deployedContent = Get-Content -LiteralPath (Join-Path $installedPath 'Catalog.Sync.Worker.dll') -Raw
    Assert-DeploymentTest `
        -Condition ($deployedContent.Trim() -eq 'new-v2') `
        -Message 'La copie du nouveau payload a échoué.'
    Assert-DeploymentTest `
        -Condition (Test-Path -LiteralPath (Join-Path $installedPath '.env.worker.service.local')) `
        -Message 'La configuration locale n a pas été préservée.'
    Assert-DeploymentTest `
        -Condition (-not (Test-Path -LiteralPath (Join-Path $installedPath 'obsolete-runtime.dll'))) `
        -Message 'Un ancien fichier runtime absent de la nouvelle release a été conservé.'

    Remove-WorkerPayloadFiles -Path $installedPath
    Copy-WorkerPayload -SourcePath $backupPath -DestinationPath $installedPath
    $restoredContent = Get-Content -LiteralPath (Join-Path $installedPath 'Catalog.Sync.Worker.dll') -Raw
    Assert-DeploymentTest `
        -Condition ($restoredContent.Trim() -eq 'installed-v1') `
        -Message 'La restauration du backup a échoué.'

    $retentionRoot = Join-Path $testRoot 'retention'
    New-Item -ItemType Directory -Path $retentionRoot | Out-Null
    1..7 | ForEach-Object {
        $name = '2026-08-{0:00}_101500_1.0.{1}' -f $_, $_
        New-Item -ItemType Directory -Path (Join-Path $retentionRoot $name) | Out-Null
    }
    $toRemove = @(Get-WorkerBackupsToRemove -BackupRoot $retentionRoot -Keep 5)
    Assert-DeploymentTest `
        -Condition ($toRemove.Count -eq 2) `
        -Message 'La sélection de rétention des backups est incorrecte.'

    $secretSettingsPath = Join-Path $testRoot 'secret-settings'
    New-Item -ItemType Directory -Path $secretSettingsPath | Out-Null
    Set-Content `
        -LiteralPath (Join-Path $secretSettingsPath 'appsettings.json') `
        -Value '{"WordPress":{"ApplicationPassword":"forbidden-example"}}' `
        -Encoding ASCII
    $secretRejected = $false
    try {
        Assert-NoSecretConfigurationValues -Path $secretSettingsPath
    }
    catch {
        $secretRejected = $true
    }
    Assert-DeploymentTest `
        -Condition $secretRejected `
        -Message 'Une configuration contenant un credential n a pas été rejetée.'

    Write-Host 'Tests synthétiques réussis : chemins, version, package, backup, copie, préservation, rollback et rétention.'
}
finally {
    Set-Location -LiteralPath $originalPowerShellLocation
    [Environment]::CurrentDirectory = $originalDotNetCurrentDirectory
    if (Test-Path -LiteralPath $testRoot -PathType Container) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
