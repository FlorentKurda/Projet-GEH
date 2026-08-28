[CmdletBinding()]
param(
    [string]$WorkerEnvFile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
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

function New-CatalogUri {
    param(
        [Parameter(Mandatory)][string]$Path,
        [hashtable]$Parameters = @{}
    )

    $pairs = @($Parameters.GetEnumerator() | Sort-Object -Property Key | ForEach-Object {
        '{0}={1}' -f [Uri]::EscapeDataString([string]$_.Key), [Uri]::EscapeDataString([string]$_.Value)
    })
    $query = if ($pairs.Count -gt 0) { '?' + ($pairs -join '&') } else { '' }
    return "$script:apiBase/$Path$query"
}

function Invoke-CatalogGet {
    param(
        [Parameter(Mandatory)][string]$Path,
        [hashtable]$Parameters = @{}
    )

    return Invoke-RestMethod -Method Get -Uri (New-CatalogUri -Path $Path -Parameters $Parameters) -TimeoutSec 30
}

function Assert-ItemsMatch {
    param(
        [Parameter(Mandatory)][object[]]$Items,
        [Parameter(Mandatory)][scriptblock]$Predicate,
        [Parameter(Mandatory)][string]$Description
    )

    if ($Items.Count -eq 0) {
        throw "Le filtre ne retourne aucun résultat : $Description."
    }
    $invalid = @($Items | Where-Object { -not (& $Predicate $_) })
    if ($invalid.Count -gt 0) {
        throw "Des résultats ne respectent pas le filtre : $Description."
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

    $baseUrl = (Read-WorkerSetting -Path $WorkerEnvFile -Name 'WordPress__BaseUrl').TrimEnd('/')
    $script:apiBase = "$baseUrl/wp-json/catalog/v1"

    Write-Host '[1/8] Liste publique et pagination serveur...'
    $page1 = Invoke-CatalogGet -Path 'products' -Parameters @{ page = 1; per_page = 24 }
    $page1Items = @($page1.items)
    if ($page1Items.Count -lt 1 -or $page1Items.Count -gt 24) {
        throw "La page 1 contient $($page1Items.Count) produits."
    }
    if ([int]$page1.pagination.perPage -ne 24 -or [int]$page1.pagination.totalItems -lt $page1Items.Count) {
        throw 'Les métadonnées de pagination sont incohérentes.'
    }
    if ([int]$page1.pagination.totalPages -gt 1) {
        $page2 = Invoke-CatalogGet -Path 'products' -Parameters @{ page = 2; per_page = 24 }
        $overlap = @($page1Items | Where-Object { $page2.items.id -contains $_.id })
        if ($overlap.Count -gt 0) {
            throw 'Les pages 1 et 2 contiennent des produits identiques.'
        }
    }

    Write-Host '[2/8] Facettes famille et marque...'
    $filters = Invoke-CatalogGet -Path 'filters'
    if (@($filters.families).Count -lt 1 -or @($filters.brands).Count -lt 1) {
        throw 'Les facettes actives sont vides.'
    }

    $seed = $page1Items |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_.familyCode) -and -not [string]::IsNullOrWhiteSpace($_.brand) } |
        Select-Object -First 1
    if ($null -eq $seed) {
        throw 'Aucun produit de référence ne possède à la fois une famille et une marque.'
    }

    Write-Host '[3/8] Recherche serveur sur la référence...'
    $search = Invoke-CatalogGet -Path 'products' -Parameters @{ search = $seed.reference; page = 1; per_page = 24 }
    if ($null -eq (@($search.items) | Where-Object { $_.id -eq $seed.id } | Select-Object -First 1)) {
        throw 'La recherche par référence ne retourne pas le produit attendu.'
    }

    Write-Host '[4/8] Filtre famille...'
    $family = Invoke-CatalogGet -Path 'products' -Parameters @{ family = $seed.familyCode; page = 1; per_page = 24 }
    Assert-ItemsMatch -Items @($family.items) -Description 'famille' -Predicate {
        param($product)
        $product.familyCode -eq $seed.familyCode
    }

    Write-Host '[5/8] Filtre marque...'
    $brand = Invoke-CatalogGet -Path 'products' -Parameters @{ brand = $seed.brand; page = 1; per_page = 24 }
    Assert-ItemsMatch -Items @($brand.items) -Description 'marque' -Predicate {
        param($product)
        $product.brand -eq $seed.brand
    }

    Write-Host '[6/8] Recherche et filtres combinés...'
    $combined = Invoke-CatalogGet -Path 'products' -Parameters @{
        search = $seed.reference
        family = $seed.familyCode
        brand = $seed.brand
        page = 1
        per_page = 24
    }
    if ($null -eq (@($combined.items) | Where-Object { $_.id -eq $seed.id } | Select-Object -First 1)) {
        throw 'La combinaison recherche, famille et marque ne retourne pas le produit attendu.'
    }

    Write-Host '[7/8] Détail public...'
    $detail = Invoke-CatalogGet -Path "products/$($seed.id)"
    if ($detail.id -ne $seed.id -or $detail.reference -ne $seed.reference -or $detail.name -ne $seed.name) {
        throw 'Le détail public ne correspond pas au produit de la liste.'
    }

    Write-Host '[8/8] Produit inexistant et recherche surdimensionnée...'
    $notFoundStatus = $null
    try {
        $null = Invoke-CatalogGet -Path 'products/2147483647'
        $notFoundStatus = 200
    }
    catch {
        $notFoundStatus = Get-HttpErrorStatus -ErrorRecord $_
    }
    if ($notFoundStatus -ne 404) {
        throw "Le produit inexistant a répondu $notFoundStatus au lieu de 404."
    }

    $oversizedStatus = $null
    try {
        $null = Invoke-CatalogGet -Path 'products' -Parameters @{ search = ('x' * 101) }
        $oversizedStatus = 200
    }
    catch {
        $oversizedStatus = Get-HttpErrorStatus -ErrorRecord $_
    }
    if ($oversizedStatus -ne 400) {
        throw "La recherche surdimensionnée a répondu $oversizedStatus au lieu de 400."
    }

    Write-Host 'Smoke test Lot 3A réussi : liste, recherche, filtres, pagination et détail validés.' -ForegroundColor Green
    exit 0
}
catch {
    Write-Error "Smoke test Lot 3A en échec : $($_.Exception.Message)"
    exit 1
}
