[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet(10000, 50000, 100000)]
    [int]$Count,

    [ValidateRange(1, 10)]
    [int]$HttpRepetitions = 3,

    [ValidateRange(1024, 65535)]
    [int]$WordPressPort = 18080,

    [switch]$Confirm100k,
    [switch]$KeepRunning
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Count -eq 100000 -and -not $Confirm100k) {
    throw 'Le palier 100 000 exige une confirmation explicite : -Confirm100k.'
}

$projectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$generatorScript = Join-Path $PSScriptRoot 'generate-load-fixture.ps1'
$bootstrapScript = Join-Path $PSScriptRoot 'bootstrap-local.ps1'
$workerScript = Join-Path $PSScriptRoot 'run-worker-local.ps1'
$composeFile = Join-Path $projectRoot 'docker-compose.yml'
$baselineFixture = Join-Path $projectRoot "fixtures/load/products-$Count.json"
$changedFixture = Join-Path $projectRoot "fixtures/load/products-$Count-changed.json"
$envFile = Join-Path $projectRoot ".env.benchmark-$Count.local"
$workerEnvFile = Join-Path $projectRoot ".env.worker.benchmark-$Count.local"
$resultDirectory = Join-Path $projectRoot 'artifacts/performance'
$resultPath = Join-Path $resultDirectory "catalog-$Count.json"
$composeProjectName = "product-catalog-benchmark-$Count"
$siteUrl = "http://localhost:$WordPressPort"
$apiBaseUrl = "$siteUrl/wp-json/catalog/v1"
$powerShellExecutable = if ($PSVersionTable.PSEdition -eq 'Core') {
    Join-Path $PSHOME 'pwsh.exe'
}
else {
    Join-Path $PSHOME 'powershell.exe'
}

$script:composePrefix = @(
    'compose', '--project-name', $composeProjectName,
    '--env-file', $envFile,
    '-f', $composeFile
)

function Read-EnvironmentFile {
    param([Parameter(Mandatory)][string]$Path)

    $values = @{}
    foreach ($line in Get-Content -LiteralPath $Path -Encoding UTF8) {
        $trimmed = $line.Trim()
        if ($trimmed.Length -eq 0 -or $trimmed.StartsWith('#')) { continue }
        if ($trimmed -notmatch '^([A-Za-z_][A-Za-z0-9_]*)=(.*)$') {
            throw "Ligne invalide dans '$Path' : $line"
        }
        $values[$Matches[1]] = $Matches[2].Trim().Trim('"').Trim("'")
    }
    return $values
}

function New-LocalSecret {
    param([Parameter(Mandatory)][string]$Prefix)
    return "$Prefix-$([Guid]::NewGuid().ToString('N'))-aA1!"
}

function Initialize-BenchmarkEnvironment {
    if (Test-Path -LiteralPath $envFile -PathType Leaf) {
        $existing = Read-EnvironmentFile -Path $envFile
        if ([string]$existing['WORDPRESS_PORT'] -ne [string]$WordPressPort) {
            throw "Le fichier '$envFile' utilise déjà le port $($existing['WORDPRESS_PORT'])."
        }
        return
    }

    $lines = @(
        '# Environnement synthétique local généré pour LOT PERF 1. Ne pas commiter.',
        'WORDPRESS_DB_NAME=wordpress_benchmark',
        'WORDPRESS_DB_USER=benchmark_user',
        "WORDPRESS_DB_PASSWORD=$(New-LocalSecret -Prefix 'db')",
        "MARIADB_ROOT_PASSWORD=$(New-LocalSecret -Prefix 'root')",
        "WORDPRESS_PORT=$WordPressPort",
        "WORDPRESS_SITE_URL=$siteUrl",
        "WORDPRESS_SITE_TITLE=Projet GEH Benchmark $Count",
        'WORDPRESS_ADMIN_USER=benchmark_admin',
        "WORDPRESS_ADMIN_PASSWORD=$(New-LocalSecret -Prefix 'admin')",
        'WORDPRESS_ADMIN_EMAIL=benchmark-admin@example.invalid',
        'CATALOG_SYNC_USER=benchmark_sync',
        'CATALOG_SYNC_EMAIL=benchmark-sync@example.invalid',
        'CATALOG_SYNC_DISPLAY_NAME=Benchmark Sync',
        "CATALOG_SYNC_APPLICATION_NAME=benchmark-worker-$Count"
    )
    $utf8WithoutBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllLines($envFile, $lines, $utf8WithoutBom)
}

function Invoke-PowerShellScript {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string[]]$Arguments
    )

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        # Windows PowerShell transforme le stderr natif redirigé en ErrorRecord.
        # Docker Compose utilise stderr pour sa progression même lorsque la commande réussit.
        $ErrorActionPreference = 'Continue'
        $output = @(& $powerShellExecutable -NoProfile -ExecutionPolicy Bypass -File $Path @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    return [pscustomobject]@{ ExitCode = $exitCode; Output = $output }
}

function Invoke-MeasuredSync {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Fixture,
        [switch]$DryRun
    )

    Write-Host "Synchronisation : $Name"
    $arguments = @(
        '-RunOnce',
        '-ProductFile', $Fixture,
        '-WorkerEnvFile', $workerEnvFile
    )
    if ($DryRun) { $arguments += '-DryRun' }

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $process = Invoke-PowerShellScript -Path $workerScript -Arguments $arguments
    $stopwatch.Stop()
    if ($process.ExitCode -ne 0) {
        $tail = @($process.Output | Select-Object -Last 20) -join [Environment]::NewLine
        throw "La synchronisation '$Name' a échoué.`n$tail"
    }

    $markerLine = @($process.Output | ForEach-Object { [string]$_ } | Where-Object {
        $_.StartsWith('CATALOG_SYNC_RESULT_V1 ')
    } | Select-Object -Last 1)
    if ($markerLine.Count -ne 1) {
        throw "La synchronisation '$Name' n'a pas produit de marqueur CATALOG_SYNC_RESULT_V1."
    }
    $payload = ConvertFrom-Json -InputObject $markerLine[0].Substring('CATALOG_SYNC_RESULT_V1 '.Length)

    return [pscustomobject]@{
        Name = $Name
        DurationSeconds = [Math]::Round($stopwatch.Elapsed.TotalSeconds, 3)
        RunId = $payload.runId
        Status = $payload.status
        DryRun = [bool]$payload.dryRun
        Received = [int]$payload.received
        Batches = [int][Math]::Ceiling([int]$payload.received / $script:batchSize)
        Inserted = [int]$payload.inserted
        Updated = [int]$payload.updated
        Unchanged = [int]$payload.unchanged
        Reactivated = [int]$payload.reactivated
        Deactivated = [int]$payload.deactivated
        Candidates = [int]$payload.candidates
        Guardrail = [string]$payload.guardrail
    }
}

function Measure-Endpoint {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Url
    )

    $durations = @()
    $bytes = 0
    for ($iteration = 1; $iteration -le $HttpRepetitions; $iteration++) {
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $response = Invoke-WebRequest -UseBasicParsing -Uri $Url -Headers @{ Accept = 'application/json' }
        $stopwatch.Stop()
        if ($response.StatusCode -ne 200) {
            throw "L'endpoint '$Name' a répondu HTTP $($response.StatusCode)."
        }
        $durations += $stopwatch.Elapsed.TotalMilliseconds
        $bytes = [int64]$response.RawContentLength
    }

    $measure = $durations | Measure-Object -Minimum -Maximum -Average
    return [pscustomobject]@{
        Name = $Name
        Repetitions = $HttpRepetitions
        MinMs = [Math]::Round([double]$measure.Minimum, 2)
        AverageMs = [Math]::Round([double]$measure.Average, 2)
        MaxMs = [Math]::Round([double]$measure.Maximum, 2)
        ResponseBytes = $bytes
        Url = $Url
    }
}

function Invoke-BenchmarkSql {
    param([Parameter(Mandatory)][string]$Sql)

    $settings = Read-EnvironmentFile -Path $envFile
    $mariaArguments = @(
        $script:composePrefix +
        @(
            'exec', '-T', '-e', "MYSQL_PWD=$($settings['WORDPRESS_DB_PASSWORD'])",
            'db', 'mariadb',
            "--user=$($settings['WORDPRESS_DB_USER'])",
            "--database=$($settings['WORDPRESS_DB_NAME'])",
            '--batch', '--raw', '--silent', '--skip-column-names', "--execute=$Sql"
        )
    )
    $output = @(& docker @mariaArguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "La requête MariaDB a échoué : $($output -join [Environment]::NewLine)"
    }
    return @($output | ForEach-Object { [string]$_ })
}

function Get-DatabaseSnapshot {
    $productsTableLines = @(Invoke-BenchmarkSql -Sql "SELECT TABLE_NAME FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME LIKE '%catalog_products' LIMIT 1;")
    $productsTable = $productsTableLines[0].Trim()
    if ([string]::IsNullOrWhiteSpace($productsTable)) {
        throw 'La table catalogue benchmark est introuvable.'
    }
    $prefix = $productsTable.Substring(0, $productsTable.Length - 'catalog_products'.Length)
    $tableNames = @(
        "${prefix}catalog_products",
        "${prefix}catalog_sync_runs",
        "${prefix}catalog_sync_batches",
        "${prefix}catalog_sync_run_items"
    )
    $quotedTables = ($tableNames | ForEach-Object { "'$_'" }) -join ','
    $sizeLines = Invoke-BenchmarkSql -Sql "SELECT TABLE_NAME,TABLE_ROWS,DATA_LENGTH,INDEX_LENGTH,DATA_LENGTH+INDEX_LENGTH FROM information_schema.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME IN ($quotedTables) ORDER BY TABLE_NAME;"
    $sizes = @($sizeLines | ForEach-Object {
        $parts = $_ -split "`t"
        [pscustomobject]@{
            Table = $parts[0]
            ApproxRows = [int64]$parts[1]
            DataBytes = [int64]$parts[2]
            IndexBytes = [int64]$parts[3]
            TotalBytes = [int64]$parts[4]
        }
    })
    $counts = @()
    foreach ($table in $tableNames) {
        $countLines = @(Invoke-BenchmarkSql -Sql "SELECT COUNT(*) FROM $table;")
        $count = [int64]$countLines[0]
        $counts += [pscustomobject]@{ Table = $table; ExactRows = $count }
    }
    $indexes = @(Invoke-BenchmarkSql -Sql "SELECT INDEX_NAME,SEQ_IN_INDEX,COLUMN_NAME,CARDINALITY FROM information_schema.STATISTICS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='$productsTable' ORDER BY INDEX_NAME,SEQ_IN_INDEX;" | ForEach-Object {
        $parts = $_ -split "`t"
        [pscustomobject]@{
            Index = $parts[0]
            Sequence = [int]$parts[1]
            Column = $parts[2]
            Cardinality = [int64]$parts[3]
        }
    })

    return [pscustomobject]@{
        Prefix = $prefix
        ProductsTable = $productsTable
        Sizes = $sizes
        Counts = $counts
        Indexes = $indexes
    }
}

function Get-ExplainPlans {
    param(
        [Parameter(Mandatory)][string]$ProductsTable,
        [Parameter(Mandatory)][int]$DeepPage
    )

    $offset = ($DeepPage - 1) * 24
    $selectColumns = 'id,source_id,reference,name,family_code,family_label,brand'
    return @(
        [pscustomobject]@{
            Name = 'Pagination profonde'
            Lines = @(Invoke-BenchmarkSql -Sql "EXPLAIN SELECT $selectColumns FROM $ProductsTable WHERE is_active=1 ORDER BY name ASC,reference ASC,source_id ASC LIMIT 24 OFFSET $offset;")
        },
        [pscustomobject]@{
            Name = 'Recherche partielle'
            Lines = @(Invoke-BenchmarkSql -Sql "EXPLAIN SELECT $selectColumns FROM $ProductsTable WHERE is_active=1 AND (reference LIKE '%perceuse%' OR name LIKE '%perceuse%' OR brand LIKE '%perceuse%' OR family_label LIKE '%perceuse%') ORDER BY name ASC,reference ASC,source_id ASC LIMIT 24;")
        },
        [pscustomobject]@{
            Name = 'Filtre famille'
            Lines = @(Invoke-BenchmarkSql -Sql "EXPLAIN SELECT $selectColumns FROM $ProductsTable WHERE is_active=1 AND family_code='LOAD-FAM-01' ORDER BY name ASC,reference ASC,source_id ASC LIMIT 24;")
        },
        [pscustomobject]@{
            Name = 'Filtre marque'
            Lines = @(Invoke-BenchmarkSql -Sql "EXPLAIN SELECT $selectColumns FROM $ProductsTable WHERE is_active=1 AND brand='Atlas Atelier' ORDER BY name ASC,reference ASC,source_id ASC LIMIT 24;")
        },
        [pscustomobject]@{
            Name = 'Facettes familles'
            Lines = @(Invoke-BenchmarkSql -Sql "EXPLAIN SELECT family_code,MAX(NULLIF(family_label,'')) FROM $ProductsTable WHERE is_active=1 AND family_code IS NOT NULL AND family_code<>'' GROUP BY family_code;")
        }
    )
}

function Get-DockerStats {
    $containerIds = @(& docker @script:composePrefix ps -q db wordpress 2>$null | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    if ($LASTEXITCODE -ne 0 -or $containerIds.Count -eq 0) { return @() }
    $lines = @(& docker stats --no-stream --format '{{json .}}' @containerIds 2>$null)
    if ($LASTEXITCODE -ne 0) { return @() }
    return @($lines | ForEach-Object { ConvertFrom-Json -InputObject $_ })
}

function Get-PageNumbers {
    $totalPages = [int][Math]::Ceiling($Count / 24.0)
    $pages = @(1, 100, 500, 1000, 4000, $totalPages) | Where-Object { $_ -ge 1 -and $_ -le $totalPages } | Sort-Object -Unique
    return @($pages)
}

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    throw 'Docker est requis pour le benchmark catalogue.'
}
if (-not (Test-Path -LiteralPath $powerShellExecutable -PathType Leaf)) {
    throw "PowerShell est introuvable : '$powerShellExecutable'."
}

$stackStarted = $false
try {
    Initialize-BenchmarkEnvironment

    Write-Host "Génération déterministe des fixtures $Count…"
    & $generatorScript -Count $Count -Variant Baseline -OutputPath $baselineFixture | Out-Host
    & $generatorScript -Count $Count -Variant Changed -OutputPath $changedFixture | Out-Host

    Write-Host "Préparation de la stack isolée '$composeProjectName'…"
    $bootstrap = Invoke-PowerShellScript -Path $bootstrapScript -Arguments @(
        '-EnvFile', $envFile,
        '-WorkerEnvFile', $workerEnvFile,
        '-ComposeProjectName', $composeProjectName
    )
    if ($bootstrap.ExitCode -ne 0) {
        throw "Le bootstrap benchmark a échoué.`n$($bootstrap.Output -join [Environment]::NewLine)"
    }
    $stackStarted = $true
    $workerSettings = Read-EnvironmentFile -Path $workerEnvFile
    $script:batchSize = [int]$workerSettings['Sync__BatchSize']

    $syncResults = @(
        (Invoke-MeasuredSync -Name 'Initial' -Fixture $baselineFixture),
        (Invoke-MeasuredSync -Name 'Identique' -Fixture $baselineFixture),
        (Invoke-MeasuredSync -Name 'Changements' -Fixture $changedFixture),
        (Invoke-MeasuredSync -Name 'Dry-run retour baseline' -Fixture $baselineFixture -DryRun),
        (Invoke-MeasuredSync -Name 'Restauration baseline' -Fixture $baselineFixture)
    )

    $pageNumbers = Get-PageNumbers
    $apiResults = @()
    foreach ($page in $pageNumbers) {
        $apiResults += Measure-Endpoint -Name "Page $page" -Url "$apiBaseUrl/products?page=$page&per_page=24"
    }
    $apiResults += Measure-Endpoint -Name 'Référence exacte' -Url "$apiBaseUrl/products?page=1&per_page=24&search=LOAD-000001"
    $apiResults += Measure-Endpoint -Name 'Nom partiel' -Url "$apiBaseUrl/products?page=1&per_page=24&search=perceuse"
    $apiResults += Measure-Endpoint -Name 'Marque en recherche' -Url "$apiBaseUrl/products?page=1&per_page=24&search=Atlas%20Atelier"
    $apiResults += Measure-Endpoint -Name 'Famille en recherche' -Url "$apiBaseUrl/products?page=1&per_page=24&search=Outillage"
    $apiResults += Measure-Endpoint -Name 'Mot absent' -Url "$apiBaseUrl/products?page=1&per_page=24&search=abcdefxyz"
    $apiResults += Measure-Endpoint -Name 'Filtre famille' -Url "$apiBaseUrl/products?page=1&per_page=24&family=LOAD-FAM-01"
    $apiResults += Measure-Endpoint -Name 'Filtre marque' -Url "$apiBaseUrl/products?page=1&per_page=24&brand=Atlas%20Atelier"
    $apiResults += Measure-Endpoint -Name 'Recherche et filtres' -Url "$apiBaseUrl/products?page=1&per_page=24&search=perceuse&family=LOAD-FAM-01&brand=Atlas%20Atelier"
    $apiResults += Measure-Endpoint -Name 'Facettes' -Url "$apiBaseUrl/filters"

    $database = Get-DatabaseSnapshot
    $deepPage = [int]($pageNumbers | Select-Object -Last 1)
    $explainPlans = Get-ExplainPlans -ProductsTable $database.ProductsTable -DeepPage $deepPage
    $dockerStats = Get-DockerStats
    $fixtureFile = Get-Item -LiteralPath $baselineFixture
    $batchCount = [int][Math]::Ceiling($Count / $script:batchSize)

    $result = [pscustomobject]@{
        GeneratedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
        Environment = [pscustomobject]@{
            ComposeProject = $composeProjectName
            SiteUrl = $siteUrl
            IsolatedVolumes = $true
            BatchSize = $script:batchSize
            HttpRepetitions = $HttpRepetitions
        }
        Volume = $Count
        Fixture = [pscustomobject]@{
            Path = $baselineFixture
            Bytes = $fixtureFile.Length
            ApproxBytesPerBatch = [Math]::Round($fixtureFile.Length / [double]$batchCount, 2)
        }
        Syncs = $syncResults
        Api = $apiResults
        Database = $database
        Explain = $explainPlans
        DockerStats = $dockerStats
    }

    if (-not (Test-Path -LiteralPath $resultDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $resultDirectory -Force | Out-Null
    }
    $utf8WithoutBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText(
        $resultPath,
        (($result | ConvertTo-Json -Depth 12) + [Environment]::NewLine),
        $utf8WithoutBom
    )

    Write-Host ''
    Write-Host "Résultats synchronisation — $Count produits" -ForegroundColor Green
    $syncResults | Format-Table Name,DurationSeconds,Batches,Inserted,Updated,Unchanged,Reactivated,Deactivated -AutoSize
    Write-Host 'Résultats API (ms)'
    $apiResults | Format-Table Name,MinMs,AverageMs,MaxMs,ResponseBytes -AutoSize
    Write-Host 'Taille des tables'
    $database.Sizes | Format-Table Table,ApproxRows,DataBytes,IndexBytes,TotalBytes -AutoSize
    Write-Host "Rapport JSON local : $resultPath"
}
finally {
    if ($stackStarted -and -not $KeepRunning) {
        Write-Host "Arrêt de la stack benchmark '$composeProjectName' sans suppression des volumes…"
        & docker @script:composePrefix stop wordpress db | Out-Host
    }
}
