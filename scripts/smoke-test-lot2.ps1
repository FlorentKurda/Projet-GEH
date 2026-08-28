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

function Read-ProductFixture {
    param([Parameter(Mandatory)][string]$Path)

    $fixturePath = $Path
    if (-not [System.IO.Path]::IsPathRooted($fixturePath)) {
        $fixturePath = Join-Path $projectRoot $fixturePath
    }

    $products = Get-Content -LiteralPath $fixturePath -Raw -Encoding UTF8 |
        ConvertFrom-Json

    foreach ($product in @($products)) {
        Write-Output $product
    }
}

function Get-PowerShellExecutable {
    $command = Get-Command pwsh -ErrorAction SilentlyContinue
    if (-not $command) {
        $command = Get-Command powershell -ErrorAction SilentlyContinue
    }
    if (-not $command) {
        throw 'PowerShell est introuvable pour exécuter le Worker dans un sous-processus.'
    }
    return $command.Source
}

function Invoke-WorkerFixture {
    param(
        [Parameter(Mandatory)][string]$ProductFile,
        [switch]$DryRun,
        [switch]$ExpectFailure
    )

    $arguments = @(
        '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', $runWorkerScript,
        '-RunOnce',
        '-WorkerEnvFile', $WorkerEnvFile,
        '-ProductFile', $ProductFile
    )
    if ($DryRun) {
        $arguments += '-DryRun'
    }

    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = @(& $script:powerShellExecutable @arguments 2>&1)
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }

    foreach ($line in $output) {
        Write-Host ([string]$line)
    }

    if ($ExpectFailure -and $exitCode -eq 0) {
        throw "Le Worker devait refuser '$ProductFile', mais il a réussi."
    }
    if (-not $ExpectFailure -and $exitCode -ne 0) {
        throw "Le Worker a échoué avec le code $exitCode pour '$ProductFile'."
    }

    return ($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
}

function Get-WorkerResult {
    param([Parameter(Mandatory)][string]$Output)

    $prefix = 'CATALOG_SYNC_RESULT_V1 '
    $marker = @($Output -split "`r?`n" | Where-Object { $_.StartsWith($prefix) }) |
        Select-Object -Last 1
    if ([string]::IsNullOrWhiteSpace($marker)) {
        throw 'Le Worker n''a pas emis son resultat structure CATALOG_SYNC_RESULT_V1.'
    }

    try {
        return $marker.Substring($prefix.Length) | ConvertFrom-Json
    }
    catch {
        throw "Le resultat structure du Worker est invalide : $($_.Exception.Message)"
    }
}

function Get-CatalogState {
    $first = Invoke-RestMethod -Method Get -Uri "$script:baseUrl/wp-json/catalog/v1/products?page=1&per_page=24" -TimeoutSec 30
    $items = @($first.items)
    $totalPages = [int]$first.pagination.totalPages
    if ($totalPages -gt 1) {
        for ($page = 2; $page -le $totalPages; $page++) {
            $response = Invoke-RestMethod -Method Get -Uri "$script:baseUrl/wp-json/catalog/v1/products?page=$page&per_page=24" -TimeoutSec 30
            $items += @($response.items)
        }
    }

    return [pscustomobject]@{
        Items = @($items)
        TotalItems = [int]$first.pagination.totalItems
        TotalPages = $totalPages
    }
}

function Assert-CatalogState {
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][int]$ExpectedCount
    )

    if ($State.TotalItems -ne $ExpectedCount -or @($State.Items).Count -ne $ExpectedCount) {
        throw "Le catalogue contient $(@($State.Items).Count)/$($State.TotalItems) produits au lieu de $ExpectedCount."
    }
    $distinct = @($State.Items | ForEach-Object { $_.sourceId } | Sort-Object -Unique)
    if ($distinct.Count -ne $ExpectedCount) {
        throw "Le catalogue ne contient que $($distinct.Count) sourceId distincts."
    }
}

function Get-CatalogSnapshot {
    param([Parameter(Mandatory)]$State)

    return @($State.Items | Sort-Object -Property { $_.sourceId }) |
    ConvertTo-Json -Depth 6 -Compress
}

function Assert-SourceIdPresence {
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][string]$SourceId,
        [Parameter(Mandatory)][bool]$Expected
    )

    $present = $null -ne (
    $State.Items |
    Where-Object { $_.sourceId -eq $SourceId } |
    Select-Object -First 1
)
    if ($present -ne $Expected) {
        throw "Présence inattendue pour '$SourceId' (attendu : $Expected)."
    }
}

function Get-ProductContentHash {
    param([Parameter(Mandatory)]$Product)

    $values = @(
        $Product.sourceId,
        $Product.reference,
        $Product.name,
        $Product.shortDescription,
        $Product.familyCode,
        $Product.familyLabel,
        $Product.brand
    )
    $canonical = New-Object Text.StringBuilder
    foreach ($value in $values) {
        if ($null -eq $value) {
            $null = $canonical.Append("-1:`n")
        }
        else {
            $text = [string]$value
            $byteCount = [Text.Encoding]::UTF8.GetByteCount($text)
            $null = $canonical.Append($byteCount).Append(':').Append($text).Append("`n")
        }
    }

    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($canonical.ToString())
        $hash = $algorithm.ComputeHash($bytes)
        return ([BitConverter]::ToString($hash) -replace '-', '').ToLowerInvariant()
    }
    finally {
        $algorithm.Dispose()
    }
}

function Get-HttpErrorStatus {
    param([Parameter(Mandatory)]$ErrorRecord)

    if ($null -eq $ErrorRecord.Exception.Response) {
        throw $ErrorRecord
    }
    return [int]$ErrorRecord.Exception.Response.StatusCode
}

try {
    if (-not (Test-Path -LiteralPath $WorkerEnvFile -PathType Leaf)) {
        throw "Le fichier '$WorkerEnvFile' est absent."
    }

    $script:powerShellExecutable = Get-PowerShellExecutable
    $script:baseUrl = (Read-WorkerSetting -Path $WorkerEnvFile -Name 'WordPress__BaseUrl').TrimEnd('/')
    $username = Read-WorkerSetting -Path $WorkerEnvFile -Name 'WordPress__Username'
    $applicationPassword = Read-WorkerSetting -Path $WorkerEnvFile -Name 'WordPress__ApplicationPassword'
    $encodedCredentials = [Convert]::ToBase64String(
        [Text.Encoding]::UTF8.GetBytes("${username}:$applicationPassword"))
    $privateHeaders = @{ Authorization = "Basic $encodedCredentials" }

    Write-Host '[1/9] État initial : synchronisation de products.json...'
    $initialResult = Get-WorkerResult -Output (Invoke-WorkerFixture -ProductFile 'fixtures/products.json')
    if ([int]$initialResult.received -ne 60 -or [bool]$initialResult.dryRun) {
        throw 'La synchronisation initiale ne confirme pas 60 produits recus.'
    }
    $state = Get-CatalogState
    Assert-CatalogState -State $state -ExpectedCount 60

    Write-Host '[2/9] Synchronisation identique : 60 produits inchangés...'
    $identicalOutput = Invoke-WorkerFixture -ProductFile 'fixtures/products.json'
    $identicalResult = Get-WorkerResult -Output $identicalOutput
    if ([int]$identicalResult.received -ne 60 -or
        [int]$identicalResult.inserted -ne 0 -or
        [int]$identicalResult.updated -ne 0 -or
        [int]$identicalResult.unchanged -ne 60 -or
        [int]$identicalResult.reactivated -ne 0 -or
        [int]$identicalResult.deactivated -ne 0) {
        throw 'La synchronisation identique ne correspond pas au delta attendu.'
    }
    Assert-CatalogState -State (Get-CatalogState) -ExpectedCount 60

    Write-Host '[3/9] Variations : 2 absents, 2 ajouts, 3 modifications...'
    $updateOutput = Invoke-WorkerFixture -ProductFile 'fixtures/products-update.json'
    $updateResult = Get-WorkerResult -Output $updateOutput
    if ([int]$updateResult.received -ne 60 -or
        [int]$updateResult.updated -ne 3 -or
        [int]$updateResult.unchanged -ne 55 -or
        [int]$updateResult.deactivated -ne 2 -or
        ([int]$updateResult.inserted + [int]$updateResult.reactivated) -ne 2) {
        throw 'La synchronisation de variations ne correspond pas au delta attendu.'
    }
    $state = Get-CatalogState
    Assert-CatalogState -State $state -ExpectedCount 60
    Assert-SourceIdPresence -State $state -SourceId 'MOCK-0001' -Expected $false
    Assert-SourceIdPresence -State $state -SourceId 'MOCK-0002' -Expected $false
    Assert-SourceIdPresence -State $state -SourceId 'MOCK-0061' -Expected $true
    Assert-SourceIdPresence -State $state -SourceId 'MOCK-0062' -Expected $true
    $modified = $state.Items |
    Where-Object { $_.sourceId -eq 'MOCK-0003' } |
    Select-Object -First 1
	$expectedModified = Read-ProductFixture -Path 'fixtures/products-update.json' |
		Where-Object { $_.sourceId -eq 'MOCK-0003' } |
		Select-Object -First 1
    if ($null -eq $modified -or $null -eq $expectedModified -or
        $modified.name -cne $expectedModified.name) {
        throw 'La modification métier de MOCK-0003 n''est pas publiée.'
    }

    Write-Host '[4/9] Réactivation des deux produits revenus...'
    $reactivationOutput = Invoke-WorkerFixture -ProductFile 'fixtures/products-reactivation.json'
    $reactivationResult = Get-WorkerResult -Output $reactivationOutput
    if ([int]$reactivationResult.received -ne 62 -or
        [int]$reactivationResult.inserted -ne 0 -or
        [int]$reactivationResult.updated -ne 0 -or
        [int]$reactivationResult.unchanged -ne 60 -or
        [int]$reactivationResult.reactivated -ne 2 -or
        [int]$reactivationResult.deactivated -ne 0) {
        throw 'La synchronisation de reactivation ne correspond pas au delta attendu.'
    }
    $state = Get-CatalogState
    Assert-CatalogState -State $state -ExpectedCount 62
    Assert-SourceIdPresence -State $state -SourceId 'MOCK-0001' -Expected $true
    Assert-SourceIdPresence -State $state -SourceId 'MOCK-0002' -Expected $true

    Write-Host '[5/9] Garde-fou : rejet de la fixture dangereuse...'
    $beforeDanger = Get-CatalogSnapshot -State $state
    $null = Invoke-WorkerFixture -ProductFile 'fixtures/products-dangerous.json' -ExpectFailure
    $afterDangerState = Get-CatalogState
    Assert-CatalogState -State $afterDangerState -ExpectedCount 62
    if ((Get-CatalogSnapshot -State $afterDangerState) -ne $beforeDanger) {
        throw 'La fixture dangereuse a modifié le catalogue public.'
    }

    Write-Host '[6/9] Source vide : rejet sans désactivation...'
    $null = Invoke-WorkerFixture -ProductFile 'fixtures/products-empty.json' -ExpectFailure
    $afterEmptyState = Get-CatalogState
    Assert-CatalogState -State $afterEmptyState -ExpectedCount 62
    if ((Get-CatalogSnapshot -State $afterEmptyState) -ne $beforeDanger) {
        throw 'La source vide a modifié le catalogue public.'
    }

    Write-Host '[7/9] SourceId dupliqué : échec avant envoi...'
    $null = Invoke-WorkerFixture -ProductFile 'fixtures/products-duplicate-source-id.json' -ExpectFailure
    $afterDuplicateState = Get-CatalogState
    Assert-CatalogState -State $afterDuplicateState -ExpectedCount 62
    if ((Get-CatalogSnapshot -State $afterDuplicateState) -ne $beforeDanger) {
        throw 'La fixture avec doublon a modifié le catalogue public.'
    }

    Write-Host '[8/9] Dry-run Worker : delta calculé sans écriture...'
    $beforeDryRun = Get-CatalogSnapshot -State $afterDuplicateState
    $dryRunOutput = Invoke-WorkerFixture -ProductFile 'fixtures/products-update.json' -DryRun
    $dryRunResult = Get-WorkerResult -Output $dryRunOutput
    if (-not [bool]$dryRunResult.dryRun -or
        [int]$dryRunResult.received -ne 60 -or
        [int]$dryRunResult.candidates -ne 2 -or
        [int]$dryRunResult.deactivated -ne 0) {
        throw 'Le dry-run ne correspond pas au delta attendu.'
    }
    $afterDryRunState = Get-CatalogState
    if ((Get-CatalogSnapshot -State $afterDryRunState) -ne $beforeDryRun) {
        throw 'Le dry-run Worker a modifié le catalogue public.'
    }

        Write-Host '[9/9] Idempotence de POST /runs et conflit de paramètres...'

    $runId = [Guid]::NewGuid().ToString()

    $startPayload = [ordered]@{
        runId = $runId
        schemaVersion = 2
        expectedProductCount = $afterDryRunState.TotalItems
        expectedBatchCount = 1
        source = 'smoke-start-idempotency'
        dryRun = $true
    }

    $startJson = $startPayload | ConvertTo-Json -Compress
    $startBytes = [Text.Encoding]::UTF8.GetBytes($startJson)

    $startUri = "$script:baseUrl/wp-json/catalog-sync/v1/runs"

    # Premier démarrage
    $firstStart = Invoke-RestMethod `
        -Method Post `
        -Uri $startUri `
        -Headers $privateHeaders `
        -ContentType 'application/json; charset=utf-8' `
        -Body $startBytes `
        -TimeoutSec 30

    # Replay exact du même démarrage
    $replayedStart = Invoke-RestMethod `
        -Method Post `
        -Uri $startUri `
        -Headers $privateHeaders `
        -ContentType 'application/json; charset=utf-8' `
        -Body $startBytes `
        -TimeoutSec 30

    if ($firstStart.runId -ne $runId -or $replayedStart.runId -ne $runId) {
        throw 'Le replay de POST /runs n''a pas conservé le runId fourni.'
    }

    # Même runId mais paramètres différents -> 409
    $conflictingPayload = [ordered]@{
        runId = $runId
        schemaVersion = 2
        expectedProductCount = $afterDryRunState.TotalItems - 1
        expectedBatchCount = 1
        source = 'smoke-start-idempotency'
        dryRun = $true
    }

    $conflictingJson = $conflictingPayload | ConvertTo-Json -Compress
    $conflictingBytes = [Text.Encoding]::UTF8.GetBytes($conflictingJson)

    $conflictStatus = $null

    try {
        $null = Invoke-RestMethod `
            -Method Post `
            -Uri $startUri `
            -Headers $privateHeaders `
            -ContentType 'application/json; charset=utf-8' `
            -Body $conflictingBytes `
            -TimeoutSec 30

        $conflictStatus = 200
    }
    catch {
        $conflictStatus = Get-HttpErrorStatus -ErrorRecord $_
    }

    if ($conflictStatus -ne 409) {
        throw "Le même runId avec d'autres paramètres a répondu $conflictStatus au lieu de 409."
    }

    # Construction du batch depuis l'état public actuel
    $privateProducts = @(
        $afterDryRunState.Items | ForEach-Object {
            [ordered]@{
                sourceId = $_.sourceId
                reference = $_.reference
                name = $_.name
                shortDescription = $_.shortDescription
                familyCode = $_.familyCode
                familyLabel = $_.familyLabel
                brand = $_.brand

                sourceUpdatedAtUtc = if ($null -eq $_.sourceUpdatedAtUtc) {
                    $null
                }
                else {
                    ([DateTimeOffset]::Parse(
                        [string]$_.sourceUpdatedAtUtc
                    )).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
                }

                contentHash = Get-ProductContentHash -Product $_
            }
        }
    )

    $batchBody = [ordered]@{
        batchNumber = 1
        products = $privateProducts
    } | ConvertTo-Json -Depth 8 -Compress

    # Important sous Windows PowerShell 5.1 :
    # envoyer explicitement les octets UTF-8.
    $batchBytes = [Text.Encoding]::UTF8.GetBytes($batchBody)

    # Premier batch
    $firstBatch = Invoke-RestMethod `
        -Method Post `
        -Uri "$startUri/$runId/products" `
        -Headers $privateHeaders `
        -ContentType 'application/json; charset=utf-8' `
        -Body $batchBytes `
        -TimeoutSec 60

    # Replay du même batch
    $replayedBatch = Invoke-RestMethod `
        -Method Post `
        -Uri "$startUri/$runId/products" `
        -Headers $privateHeaders `
        -ContentType 'application/json; charset=utf-8' `
        -Body $batchBytes `
        -TimeoutSec 60

    if ([bool]$firstBatch.replayed -or -not [bool]$replayedBatch.replayed) {
        throw 'Le replay du même batch n''a pas été reconnu comme idempotent.'
    }

    # Complete n'attend pas de body JSON.
    $completed = Invoke-RestMethod `
        -Method Post `
        -Uri "$startUri/$runId/complete" `
        -Headers $privateHeaders `
        -ContentType 'application/json; charset=utf-8' `
        -TimeoutSec 30

    if ($completed.status -ne 'completed' -or -not [bool]$completed.dryRun) {
        throw 'Le run idempotent de contrôle ne s''est pas terminé en dry-run.'
    }

    # Un run terminé ne doit pas pouvoir être redémarré.
    $terminalReplayStatus = $null

    try {
        $null = Invoke-RestMethod `
            -Method Post `
            -Uri $startUri `
            -Headers $privateHeaders `
            -ContentType 'application/json; charset=utf-8' `
            -Body $startBytes `
            -TimeoutSec 30

        $terminalReplayStatus = 200
    }
    catch {
        $terminalReplayStatus = Get-HttpErrorStatus -ErrorRecord $_
    }

    if ($terminalReplayStatus -ne 409) {
        throw "Le replay d'un run completed a répondu $terminalReplayStatus au lieu de 409."
    }

    if ((Get-CatalogSnapshot -State (Get-CatalogState)) -ne $beforeDryRun) {
        throw 'Le contrôle idempotent en dry-run a modifié le catalogue.'
    }
    Write-Host 'Smoke test Lot 2 réussi : runs/batches, variations, garde-fous, dry-run et idempotence validés.' -ForegroundColor Green
    exit 0
}
catch {
    Write-Error "Smoke test Lot 2 en échec : $($_.Exception.Message)"
    exit 1
}
