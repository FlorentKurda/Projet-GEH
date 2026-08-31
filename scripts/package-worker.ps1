[CmdletBinding()]
param(
    [string]$PublishPath,

    [ValidatePattern('^win-[A-Za-z0-9-]+$')]
    [string]$Runtime = 'win-x64',

    [string]$OutputRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'worker-deployment-common.ps1')

$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$projectFile = Join-Path $projectRoot 'src\Catalog.Sync.Worker\Catalog.Sync.Worker.csproj'
$dotnetExecutable = Get-WorkerDotNetExecutable -ProjectRoot $projectRoot
$projectVersion = Get-WorkerProjectVersion -DotNetExecutable $dotnetExecutable -ProjectFile $projectFile
if ([string]::IsNullOrWhiteSpace($PublishPath)) {
    $PublishPath = Join-Path (Join-Path (Join-Path $projectRoot 'artifacts\worker\releases') $projectVersion) $Runtime
}
if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot = Join-Path $projectRoot 'artifacts\packages'
}

$publishPathFull = Resolve-UserPath -Path $PublishPath
$outputRootFull = Resolve-UserPath -Path $OutputRoot
$publishedVersion = Test-WorkerSelfContainedPayload -Path $publishPathFull
if ((Compare-WorkerVersion -Left $publishedVersion -Right $projectVersion) -ne 0) {
    throw "La publication '$publishedVersion' ne correspond pas à la version MSBuild '$projectVersion'."
}

New-Item -ItemType Directory -Path $outputRootFull -Force | Out-Null
$packageName = "GEHProductCatalogSync-$publishedVersion-$Runtime.zip"
$packagePath = Join-Path $outputRootFull $packageName
$hashPath = "$packagePath.sha256"
$stagingPath = Join-Path $outputRootFull ('.staging-' + [Guid]::NewGuid().ToString('N'))

try {
    New-Item -ItemType Directory -Path $stagingPath | Out-Null
    Assert-NoForbiddenDeploymentFiles -Path $publishPathFull
    Copy-WorkerPayload -SourcePath $publishPathFull -DestinationPath $stagingPath
    [void](Test-WorkerSelfContainedPayload -Path $stagingPath)

    if (Test-Path -LiteralPath $packagePath) {
        Remove-Item -LiteralPath $packagePath -Force
    }
    if (Test-Path -LiteralPath $hashPath) {
        Remove-Item -LiteralPath $hashPath -Force
    }
    Compress-Archive -Path (Join-Path $stagingPath '*') -DestinationPath $packagePath -CompressionLevel Optimal
    $hash = (Get-FileHash -LiteralPath $packagePath -Algorithm SHA256).Hash.ToLowerInvariant()
    Set-Content -LiteralPath $hashPath -Value "$hash  $packageName" -Encoding ASCII

    $sizeMiB = [Math]::Round((Get-Item -LiteralPath $packagePath).Length / 1MB, 2)
    Write-Host "Version : $publishedVersion"
    Write-Host "Package : $packagePath"
    Write-Host "Taille : $sizeMiB MiB"
    Write-Host "SHA-256 : $hash"
    Write-Host "Fichier hash : $hashPath"
}
finally {
    if (Test-Path -LiteralPath $stagingPath) {
        Remove-Item -LiteralPath $stagingPath -Recurse -Force
    }
}
