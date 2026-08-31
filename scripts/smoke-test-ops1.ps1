[CmdletBinding()]
param(
    [string]$EnvFile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if ([string]::IsNullOrWhiteSpace($EnvFile)) {
    $EnvFile = Join-Path $projectRoot '.env'
}
elseif (-not [System.IO.Path]::IsPathRooted($EnvFile)) {
    $EnvFile = Join-Path $projectRoot $EnvFile
}

$composeFile = Join-Path $projectRoot 'docker-compose.yml'
$verificationFile = Join-Path $PSScriptRoot 'verify-catalog-supervision.php'
$adminRepository = Join-Path $projectRoot 'wordpress/product-catalog-sync/includes/class-catalog-admin-repository.php'

try {
    if (-not (Test-Path -LiteralPath $EnvFile -PathType Leaf)) {
        throw "Le fichier d environnement '$EnvFile' est absent."
    }
    if (-not (Test-Path -LiteralPath $verificationFile -PathType Leaf)) {
        throw "Le controle PHP est introuvable : '$verificationFile'."
    }
    if (Select-String -LiteralPath $adminRepository -SimpleMatch 'catalog_sync_run_items' -Quiet) {
        throw 'Le repository admin ne doit jamais interroger catalog_sync_run_items.'
    }

    $composeArguments = @(
        'compose',
        '--env-file', $EnvFile,
        '-f', $composeFile,
        'run',
        '--rm',
        '--no-deps',
        '--volume', "${PSScriptRoot}:/workspace/scripts:ro",
        'wpcli',
        'eval-file',
        '/workspace/scripts/verify-catalog-supervision.php'
    )

    & docker @composeArguments
    if ($LASTEXITCODE -ne 0) {
        throw "Le controle de supervision a echoue avec le code $LASTEXITCODE."
    }

    Write-Host 'Smoke test OPS 1 reussi : page admin, permission, etats, CSS, historique et detail valides.' -ForegroundColor Green
    exit 0
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
