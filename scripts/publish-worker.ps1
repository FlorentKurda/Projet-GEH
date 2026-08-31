[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release',

    [ValidatePattern('^win-[A-Za-z0-9-]+$')]
    [string]$Runtime = 'win-x64',

    [bool]$SelfContained = $true,

    [string]$OutputRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'worker-deployment-common.ps1')

$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$projectFile = Join-Path $projectRoot 'src\Catalog.Sync.Worker\Catalog.Sync.Worker.csproj'
if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot = Join-Path $projectRoot 'artifacts\worker\releases'
}
$outputRootFullPath = Resolve-UserPath -Path $OutputRoot
$dotnetExecutable = Get-WorkerDotNetExecutable -ProjectRoot $projectRoot
$version = Get-WorkerProjectVersion -DotNetExecutable $dotnetExecutable -ProjectFile $projectFile
$publishDirectoryName = if ($SelfContained) { $Runtime } else { "$Runtime-framework-dependent" }
$targetPath = Join-Path (Join-Path $outputRootFullPath $version) $publishDirectoryName

if (Test-Path -LiteralPath $targetPath) {
    $expectedRoot = $outputRootFullPath.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    $resolvedTarget = Get-DeploymentFullPath -Path $targetPath
    if (-not $resolvedTarget.StartsWith($expectedRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refus de nettoyer un dossier hors de '$outputRootFullPath'."
    }
    Remove-Item -LiteralPath $resolvedTarget -Recurse -Force
}
New-Item -ItemType Directory -Path $targetPath -Force | Out-Null

Write-DeploymentStep -Message "Publication du Worker $version ($Configuration, $Runtime, SelfContained=$SelfContained)."
& $dotnetExecutable publish $projectFile `
    -c $Configuration `
    -r $Runtime `
    --self-contained $SelfContained.ToString().ToLowerInvariant() `
    -p:PublishSingleFile=false `
    -p:PublishTrimmed=false `
    -o $targetPath
if ($LASTEXITCODE -ne 0) {
    throw "dotnet publish a échoué avec le code $LASTEXITCODE."
}

$workerExecutable = Join-Path $targetPath 'Catalog.Sync.Worker.exe'
$publishedVersion = Test-WorkerPayload -Path $targetPath
if ((Compare-WorkerVersion -Left $publishedVersion -Right $version) -ne 0) {
    throw "La version publiée '$publishedVersion' diffère de la version MSBuild '$version'."
}
$sizeBytes = (Get-ChildItem -LiteralPath $targetPath -Recurse -File |
    Measure-Object -Property Length -Sum).Sum
$sizeMiB = [Math]::Round($sizeBytes / 1MB, 2)

Write-Host "Version : $publishedVersion"
Write-Host "Exécutable : $workerExecutable"
Write-Host "Publication : $targetPath"
Write-Host "Taille approximative : $sizeMiB MiB"
