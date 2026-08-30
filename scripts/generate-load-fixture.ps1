[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateRange(1, 1000000)]
    [int]$Count,

    [ValidateSet('Baseline', 'Changed')]
    [string]$Variant = 'Baseline',

    [ValidateRange(0, 100)]
    [double]$ModifiedPercent = 1.0,

    [ValidateRange(0, 100)]
    [double]$RemovedPercent = 0.5,

    [ValidateRange(0, 100)]
    [double]$NewPercent = 0.5,

    [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$variantSuffix = if ($Variant -eq 'Changed') { '-changed' } else { '' }
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $projectRoot "fixtures/load/products-$Count$variantSuffix.json"
}
elseif (-not [System.IO.Path]::IsPathRooted($OutputPath)) {
    $OutputPath = Join-Path $projectRoot $OutputPath
}
$OutputPath = [System.IO.Path]::GetFullPath($OutputPath)

$familyThemes = @(
    'Outillage à main', 'Outillage électroportatif', 'Mesure et contrôle',
    'Protection individuelle', 'Rangement atelier', 'Entretien des surfaces',
    'Manutention légère', 'Fixation et assemblage', 'Coupe et perçage',
    'Éclairage professionnel'
)
$productNames = @(
    'Perceuse sans fil', 'Gants de protection', 'Armoire atelier',
    'Mètre ruban', 'Nettoyant pour surfaces', 'Visseuse compacte',
    'Caisse à outils', 'Lunettes de sécurité', 'Raclette de sol',
    'Pince multiprise', 'Lampe rechargeable', 'Bac de rangement',
    'Niveau magnétique', 'Marteau de mécanicien', 'Chariot de manutention',
    'Serre-joint à vis', 'Aspirateur atelier', 'Clé mixte',
    'Télémètre laser', 'Étagère métallique'
)
$brandPrefixes = @('Atlas', 'Boréal', 'Cobalt', 'Delta', 'Équinoxe', 'Forge', 'Hexa', 'Industria', 'Jura', 'Kappa')
$brandSuffixes = @('Atelier', 'Industrie', 'Pro', 'Technique', 'Équipement')

function ConvertTo-JsonString {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)

    $escaped = $Value.Replace('\', '\\').Replace('"', '\"')
    $escaped = $escaped.Replace("`r", '\r').Replace("`n", '\n').Replace("`t", '\t')
    return '"' + $escaped + '"'
}

function Get-ProductJson {
    param(
        [Parameter(Mandatory)][int]$ProductNumber,
        [Parameter(Mandatory)][bool]$Modified
    )

    $familyNumber = (($ProductNumber - 1) % 40) + 1
    $familyTheme = $familyThemes[($familyNumber - 1) % $familyThemes.Count]
    $brandNumber = (($ProductNumber * 7 - 1) % 50) + 1
    $brandPrefix = $brandPrefixes[($brandNumber - 1) % $brandPrefixes.Count]
    $brandSuffix = $brandSuffixes[[Math]::Floor(($brandNumber - 1) / $brandPrefixes.Count)]
    $baseName = $productNames[($ProductNumber - 1) % $productNames.Count]
    $revisionSuffix = if ($Modified) { ' révision B' } else { '' }
    $sourceId = 'MOCKLOAD-{0:D6}' -f $ProductNumber
    $reference = 'LOAD-{0:D6}' -f $ProductNumber
    $name = '{0} série {1:D6}{2}' -f $baseName, $ProductNumber, $revisionSuffix
    $lotNumber = [int]([Math]::Floor(($ProductNumber - 1) / 100) + 1)
    $description = 'Produit synthétique déterministe pour test de charge, famille {0:D2}, lot {1:D4}{2}.' -f $familyNumber, $lotNumber, $revisionSuffix
    $familyCode = 'LOAD-FAM-{0:D2}' -f $familyNumber
    $familyLabel = '{0} — gamme {1:D2}' -f $familyTheme, $familyNumber
    $brand = "$brandPrefix $brandSuffix"
    $day = (($ProductNumber - 1) % 28) + 1
    $hour = ($ProductNumber - 1) % 24
    $month = if ($Modified) { 2 } else { 1 }
    $sourceUpdatedAtUtc = '2026-{0:D2}-{1:D2}T{2:D2}:00:00Z' -f $month, $day, $hour

    return '{' +
        '"sourceId":' + (ConvertTo-JsonString $sourceId) + ',' +
        '"reference":' + (ConvertTo-JsonString $reference) + ',' +
        '"name":' + (ConvertTo-JsonString $name) + ',' +
        '"shortDescription":' + (ConvertTo-JsonString $description) + ',' +
        '"familyCode":' + (ConvertTo-JsonString $familyCode) + ',' +
        '"familyLabel":' + (ConvertTo-JsonString $familyLabel) + ',' +
        '"brand":' + (ConvertTo-JsonString $brand) + ',' +
        '"sourceUpdatedAtUtc":' + (ConvertTo-JsonString $sourceUpdatedAtUtc) +
        '}'
}

$modifiedCount = 0
$removedCount = 0
$newCount = 0
if ($Variant -eq 'Changed') {
    $modifiedCount = [int][Math]::Floor($Count * $ModifiedPercent / 100)
    $removedCount = [int][Math]::Floor($Count * $RemovedPercent / 100)
    $newCount = [int][Math]::Floor($Count * $NewPercent / 100)
}

$lastBaselineProduct = $Count - $removedCount
$outputProductCount = $lastBaselineProduct + $newCount
$outputDirectory = Split-Path -Parent $OutputPath
if (-not (Test-Path -LiteralPath $outputDirectory -PathType Container)) {
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
}

$utf8WithoutBom = New-Object System.Text.UTF8Encoding($false)
$writer = New-Object System.IO.StreamWriter($OutputPath, $false, $utf8WithoutBom, 1048576)
$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
try {
    $writer.WriteLine('[')
    $written = 0
    for ($productNumber = 1; $productNumber -le $lastBaselineProduct; $productNumber++) {
        if ($written -gt 0) { $writer.WriteLine(',') }
        $writer.Write((Get-ProductJson -ProductNumber $productNumber -Modified ($productNumber -le $modifiedCount)))
        $written++
    }
    for ($productNumber = $Count + 1; $productNumber -le $Count + $newCount; $productNumber++) {
        if ($written -gt 0) { $writer.WriteLine(',') }
        $writer.Write((Get-ProductJson -ProductNumber $productNumber -Modified $false))
        $written++
    }
    $writer.WriteLine()
    $writer.WriteLine(']')
}
finally {
    $writer.Dispose()
    $stopwatch.Stop()
}

$file = Get-Item -LiteralPath $OutputPath
[pscustomobject]@{
    Count = $Count
    Variant = $Variant
    OutputProducts = $outputProductCount
    Modified = $modifiedCount
    Removed = $removedCount
    New = $newCount
    Bytes = $file.Length
    DurationSeconds = [Math]::Round($stopwatch.Elapsed.TotalSeconds, 3)
    Path = $file.FullName
} | Format-List
