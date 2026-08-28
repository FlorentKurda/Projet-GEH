[CmdletBinding()]
param(
    [switch]$RunOnce,
    [switch]$DryRun,
    [string]$ProductFile,
    [string]$WorkerEnvFile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$projectFile = Join-Path $projectRoot 'src/Catalog.Sync.Worker/Catalog.Sync.Worker.csproj'

if ([string]::IsNullOrWhiteSpace($WorkerEnvFile)) {
    $WorkerEnvFile = Join-Path $projectRoot '.env.worker.local'
}
elseif (-not [System.IO.Path]::IsPathRooted($WorkerEnvFile)) {
    $WorkerEnvFile = Join-Path $projectRoot $WorkerEnvFile
}

try {
    $localDotnet = Join-Path $projectRoot '.dotnet/dotnet.exe'
    if (Test-Path -LiteralPath $localDotnet -PathType Leaf) {
        $dotnetExecutable = $localDotnet
        $env:DOTNET_ROOT = Split-Path -Parent $localDotnet
    }
    else {
        $dotnetCommand = Get-Command dotnet -ErrorAction SilentlyContinue
        if (-not $dotnetCommand) {
            throw 'Le SDK .NET est introuvable. Installez le SDK .NET 10 ou placez-le dans .dotnet à la racine du dépôt.'
        }
        $dotnetExecutable = $dotnetCommand.Source
    }

    $installedSdks = @(& $dotnetExecutable --list-sdks)
    if ($LASTEXITCODE -ne 0 -or -not ($installedSdks | Where-Object { $_ -match '^10\.0\.' })) {
        throw "Le SDK .NET 10 est requis, mais il n'est pas disponible via '$dotnetExecutable'."
    }

    if (-not (Test-Path -LiteralPath $WorkerEnvFile -PathType Leaf)) {
        throw "Le fichier '$WorkerEnvFile' est absent. Exécutez d’abord .\scripts\bootstrap-local.ps1."
    }

    if (-not (Test-Path -LiteralPath $projectFile -PathType Leaf)) {
        throw "Le projet Worker est introuvable : '$projectFile'."
    }

    foreach ($line in Get-Content -LiteralPath $WorkerEnvFile -Encoding UTF8) {
        $trimmedLine = $line.Trim()
        if ($trimmedLine.Length -eq 0 -or $trimmedLine.StartsWith('#')) {
            continue
        }

        if ($trimmedLine -notmatch '^([A-Za-z_][A-Za-z0-9_]*)=(.*)$') {
            throw "Ligne invalide dans '$WorkerEnvFile' : $line"
        }

        $name = $Matches[1]
        $value = $Matches[2].Trim()
        if ($value.Length -ge 2) {
            $isDoubleQuoted = $value.StartsWith('"') -and $value.EndsWith('"')
            $isSingleQuoted = $value.StartsWith("'") -and $value.EndsWith("'")
            if ($isDoubleQuoted -or $isSingleQuoted) {
                $value = $value.Substring(1, $value.Length - 2)
            }
        }

        Set-Item -LiteralPath "Env:$name" -Value $value
    }

    $env:DOTNET_ENVIRONMENT = 'Development'

    if ($DryRun -and -not $RunOnce) {
        throw 'Le paramètre -DryRun doit être utilisé avec -RunOnce.'
    }

    if (-not [string]::IsNullOrWhiteSpace($ProductFile)) {
        if (-not [System.IO.Path]::IsPathRooted($ProductFile)) {
            $ProductFile = Join-Path $projectRoot $ProductFile
        }
        $ProductFile = [System.IO.Path]::GetFullPath($ProductFile)
        if (-not (Test-Path -LiteralPath $ProductFile -PathType Leaf)) {
            throw "La fixture de produits est introuvable : '$ProductFile'."
        }
        $env:ProductSource__JsonFilePath = $ProductFile
    }

    $workerArguments = @()
    if ($RunOnce) {
        $workerArguments += '--run-once'
    }
    if ($DryRun) {
        $workerArguments += '--dry-run'
    }

    & $dotnetExecutable run --project $projectFile -- @workerArguments

    $workerExitCode = $LASTEXITCODE
    if ($workerExitCode -ne 0) {
        Write-Error "Le Worker s’est terminé avec le code $workerExitCode."
    }
    exit $workerExitCode
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
