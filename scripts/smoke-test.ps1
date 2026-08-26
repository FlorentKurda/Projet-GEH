[CmdletBinding()]
param(
    [string]$WorkerEnvFile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$runWorkerScript = Join-Path $PSScriptRoot 'run-worker-local.ps1'

if ([string]::IsNullOrWhiteSpace($WorkerEnvFile)) {
    $WorkerEnvFile = Join-Path $projectRoot '.env.worker.local'
}
elseif (-not [System.IO.Path]::IsPathRooted($WorkerEnvFile)) {
    $WorkerEnvFile = Join-Path $projectRoot $WorkerEnvFile
}

function Read-WorkerSetting {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name
    )

    foreach ($line in Get-Content -LiteralPath $Path -Encoding UTF8) {
        if ($line -match '^([A-Za-z_][A-Za-z0-9_]*)=(.*)$' -and $Matches[1] -eq $Name) {
            return $Matches[2].Trim().Trim('"').Trim("'")
        }
    }

    throw "La variable '$Name' est absente de '$Path'."
}

function Invoke-WorkerOnce {
    param([Parameter(Mandatory)][string]$ConfigurationFile)

    $powerShellCommand = Get-Command pwsh -ErrorAction SilentlyContinue
    if (-not $powerShellCommand) {
        $powerShellCommand = Get-Command powershell -ErrorAction SilentlyContinue
    }
    if (-not $powerShellCommand) {
        throw 'PowerShell est introuvable pour exécuter le Worker dans un sous-processus.'
    }

    & $powerShellCommand.Source -NoLogo -NoProfile -ExecutionPolicy Bypass -File $runWorkerScript -RunOnce -WorkerEnvFile $ConfigurationFile
    if ($LASTEXITCODE -ne 0) {
        throw "Le Worker a échoué avec le code $LASTEXITCODE."
    }
}

function Get-CatalogPage {
    param(
        [Parameter(Mandatory)][string]$BaseUrl,
        [Parameter(Mandatory)][int]$Page
    )

    $uri = "$BaseUrl/wp-json/catalog/v1/products?page=$Page&per_page=24"
    return Invoke-RestMethod -Method Get -Uri $uri -TimeoutSec 30
}

function Assert-CatalogPage {
    param(
        [Parameter(Mandatory)]$Response,
        [Parameter(Mandatory)][int]$ExpectedPage,
        [Parameter(Mandatory)][int]$ExpectedItemCount
    )

    $actualCount = @($Response.items).Count
    if ($actualCount -ne $ExpectedItemCount) {
        throw "La page $ExpectedPage contient $actualCount produits au lieu de $ExpectedItemCount."
    }
    if ([int]$Response.pagination.page -ne $ExpectedPage) {
        throw "La pagination indique la page '$($Response.pagination.page)' au lieu de '$ExpectedPage'."
    }
    if ([int]$Response.pagination.perPage -ne 24) {
        throw "La pagination indique perPage=$($Response.pagination.perPage) au lieu de 24."
    }
    if ([int]$Response.pagination.totalItems -ne 60) {
        throw "La pagination indique totalItems=$($Response.pagination.totalItems) au lieu de 60."
    }
    if ([int]$Response.pagination.totalPages -ne 3) {
        throw "La pagination indique totalPages=$($Response.pagination.totalPages) au lieu de 3."
    }
}

try {
    if (-not (Test-Path -LiteralPath $WorkerEnvFile -PathType Leaf)) {
        throw "Le fichier '$WorkerEnvFile' est absent. Exécutez d’abord .\scripts\bootstrap-local.ps1."
    }

    $baseUrl = (Read-WorkerSetting -Path $WorkerEnvFile -Name 'WordPress__BaseUrl').TrimEnd('/')

    Write-Host '[1/8] Vérification de WordPress…'
    $wordpressResponse = Invoke-WebRequest -UseBasicParsing -Method Get -Uri $baseUrl -TimeoutSec 30
    if ([int]$wordpressResponse.StatusCode -lt 200 -or [int]$wordpressResponse.StatusCode -ge 400) {
        throw "WordPress a répondu avec le code $($wordpressResponse.StatusCode)."
    }

    Write-Host '[2/8] Vérification du refus d’un POST anonyme…'
    $anonymousStatusCode = $null
    try {
        $anonymousResponse = Invoke-WebRequest `
            -UseBasicParsing `
            -Method Post `
            -Uri "$baseUrl/wp-json/catalog-sync/v1/products" `
            -ContentType 'application/json' `
            -Body '{}' `
            -TimeoutSec 30
        $anonymousStatusCode = [int]$anonymousResponse.StatusCode
    }
    catch {
        if ($null -eq $_.Exception.Response) {
            throw
        }
        $anonymousStatusCode = [int]$_.Exception.Response.StatusCode
    }
    if ($anonymousStatusCode -notin @(401, 403)) {
        throw "Le POST anonyme a répondu avec le code $anonymousStatusCode au lieu de 401 ou 403."
    }

    Write-Host '[3/8] Première synchronisation des 60 produits…'
    Invoke-WorkerOnce -ConfigurationFile $WorkerEnvFile

    Write-Host '[4/8] Vérification de la page 1…'
    $page1 = Get-CatalogPage -BaseUrl $baseUrl -Page 1
    Assert-CatalogPage -Response $page1 -ExpectedPage 1 -ExpectedItemCount 24

    Write-Host '[5/8] Vérification de la page 2…'
    $page2 = Get-CatalogPage -BaseUrl $baseUrl -Page 2
    Assert-CatalogPage -Response $page2 -ExpectedPage 2 -ExpectedItemCount 24

    Write-Host '[6/8] Vérification de la page 3…'
    $page3 = Get-CatalogPage -BaseUrl $baseUrl -Page 3
    Assert-CatalogPage -Response $page3 -ExpectedPage 3 -ExpectedItemCount 12

    $allSourceIds = @($page1.items) + @($page2.items) + @($page3.items) |
        ForEach-Object { $_.sourceId } |
        Sort-Object -Unique
    if (@($allSourceIds).Count -ne 60) {
        throw "Les trois pages ne contiennent que $(@($allSourceIds).Count) identifiants source distincts."
    }

    Write-Host '[7/8] Deuxième synchronisation pour contrôler l’idempotence…'
    Invoke-WorkerOnce -ConfigurationFile $WorkerEnvFile

    Write-Host '[8/8] Vérification du total après la seconde synchronisation…'
    $pageAfterSecondRun = Get-CatalogPage -BaseUrl $baseUrl -Page 1
    Assert-CatalogPage -Response $pageAfterSecondRun -ExpectedPage 1 -ExpectedItemCount 24

    Write-Host 'Smoke test réussi : 60 produits, pagination 24/24/12 et aucune duplication.' -ForegroundColor Green
    exit 0
}
catch {
    Write-Error "Smoke test en échec : $($_.Exception.Message)"
    exit 1
}
