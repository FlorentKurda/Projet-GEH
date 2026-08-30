[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidatePattern('^[A-Za-z0-9_-]+$')]
    [string]$ServiceName = 'GEHProductCatalogSync',

    [string]$DisplayName = 'GEH Product Catalog Sync',

    [string]$PublishPath = (Join-Path $env:ProgramFiles 'GEH\ProductCatalogSync'),

    [string]$EnvironmentFile,

    [switch]$Start,

    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($env:OS -ne 'Windows_NT') {
    throw 'Ce script doit etre execute sous Windows.'
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Ouvrez PowerShell avec Executer en tant qu administrateur.'
}

$resolvedPublishPath = [System.IO.Path]::GetFullPath($PublishPath)
$workerExecutable = Join-Path $resolvedPublishPath 'Catalog.Sync.Worker.exe'
if (-not (Test-Path -LiteralPath $workerExecutable -PathType Leaf)) {
    throw "Executable introuvable : '$workerExecutable'. Publiez le Worker avant l installation."
}

function Invoke-ScCommand {
    param([Parameter(Mandatory)][string[]]$ArgumentList)

    $scExecutable = "$env:SystemRoot\System32\sc.exe"
    & $scExecutable @ArgumentList
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        $subcommand = if ($ArgumentList.Count -gt 0) { $ArgumentList[0] } else { '<absente>' }
        throw "sc.exe a echoue avec le code $exitCode pendant la commande '$subcommand'."
    }
}

function Read-ServiceEnvironmentFile {
    param([Parameter(Mandatory)][string]$Path)

    $resolvedPath = [System.IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) {
        throw "Fichier d environnement introuvable : '$resolvedPath'."
    }

    $allowedName = '^(DOTNET_ENVIRONMENT|WordPress__.+|ProductSource__.+|Sync__.+|FileLogging__.+|Sql__.+)$'
    $values = [System.Collections.Generic.List[string]]::new()
    foreach ($line in Get-Content -LiteralPath $resolvedPath -Encoding UTF8) {
        $trimmedLine = $line.Trim()
        if ($trimmedLine.Length -eq 0 -or $trimmedLine.StartsWith('#')) {
            continue
        }

        if ($trimmedLine -notmatch '^([A-Za-z_][A-Za-z0-9_]*)=(.*)$') {
            throw "Ligne invalide dans '$resolvedPath'."
        }

        $name = $Matches[1]
        $value = $Matches[2].Trim()
        if ($name -notmatch $allowedName) {
            throw "Variable '$name' non autorisee dans la configuration du service."
        }

        if ($value.Length -ge 2) {
            $isDoubleQuoted = $value.StartsWith('"') -and $value.EndsWith('"')
            $isSingleQuoted = $value.StartsWith("'") -and $value.EndsWith("'")
            if ($isDoubleQuoted -or $isSingleQuoted) {
                $value = $value.Substring(1, $value.Length - 2)
            }
        }

        if ($value.Contains([char]0) -or $value.Contains("`r") -or $value.Contains("`n")) {
            throw "Valeur invalide pour '$name'."
        }

        $values.Add("$name=$value")
    }

    return $values.ToArray()
}

$serviceEnvironment = @()
if (-not [string]::IsNullOrWhiteSpace($EnvironmentFile)) {
    $serviceEnvironment = @(Read-ServiceEnvironmentFile -Path $EnvironmentFile)
}

$existingService = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($existingService) {
    if (-not $Force) {
        throw "Le service '$ServiceName' existe deja. Utilisez -Force pour le recreer explicitement."
    }

    if ($PSCmdlet.ShouldProcess($ServiceName, 'Arreter et supprimer le service existant')) {
        if ($existingService.Status -ne [System.ServiceProcess.ServiceControllerStatus]::Stopped) {
            Stop-Service -Name $ServiceName -Force
            $existingService.WaitForStatus(
                [System.ServiceProcess.ServiceControllerStatus]::Stopped,
                [TimeSpan]::FromSeconds(30))
        }

        Invoke-ScCommand -ArgumentList @('delete', $ServiceName)
        $deadline = [DateTimeOffset]::UtcNow.AddSeconds(30)
        do {
            Start-Sleep -Milliseconds 250
            $existingService = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
        } while ($existingService -and [DateTimeOffset]::UtcNow -lt $deadline)

        if ($existingService) {
            throw "Le service '$ServiceName' est encore en cours de suppression. Reessayez apres fermeture des consoles de gestion des services."
        }
    }
}

$logPath = Join-Path $env:ProgramData 'GEH\ProductCatalogSync\logs'
if ($PSCmdlet.ShouldProcess($ServiceName, 'Creer et configurer le service Windows')) {
    New-Item -ItemType Directory -Path $logPath -Force | Out-Null
    & "$env:SystemRoot\System32\icacls.exe" $logPath '/grant' '*S-1-5-19:(OI)(CI)M' '/T' '/Q' | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Impossible d accorder au compte LocalService le droit d ecriture dans '$logPath'."
    }

    # sc.exe exige un argument 'option=' suivi d'un argument valeur distinct.
    # Les guillemets font partie de BinaryPathName pour securiser le chemin avec espaces.
    $binaryPathValue = '"{0}"' -f $workerExecutable
    Invoke-ScCommand -ArgumentList @(
        'create',
        $ServiceName,
        'binPath=',
        $binaryPathValue,
        'start=',
        'auto',
        'obj=',
        'NT AUTHORITY\LocalService',
        'DisplayName=',
        $DisplayName
    )
    Invoke-ScCommand -ArgumentList @(
        'description',
        $ServiceName,
        'Service de synchronisation du catalogue produits vers WordPress.'
    )
    Invoke-ScCommand -ArgumentList @(
        'failure',
        $ServiceName,
        'reset=',
        '86400',
        'actions=',
        'restart/60000/restart/300000/restart/900000'
    )
    Invoke-ScCommand -ArgumentList @('failureflag', $ServiceName, '1')

    if ($serviceEnvironment.Count -gt 0) {
        $serviceRegistryPath = "HKLM:\SYSTEM\CurrentControlSet\Services\$ServiceName"
        New-ItemProperty `
            -Path $serviceRegistryPath `
            -Name 'Environment' `
            -PropertyType MultiString `
            -Value $serviceEnvironment `
            -Force | Out-Null
    }
    elseif ($Start) {
        Write-Warning 'Aucun -EnvironmentFile fourni. Verifiez les variables machine avant le demarrage.'
    }

    try {
        if (-not [System.Diagnostics.EventLog]::SourceExists('Catalog.Sync.Worker')) {
            New-EventLog -LogName Application -Source 'Catalog.Sync.Worker'
        }
    }
    catch {
        Write-Warning 'La source Event Log n a pas pu etre creee. Les journaux fichiers restent disponibles.'
    }

    if ($Start) {
        Start-Service -Name $ServiceName
    }
}

Get-Service -Name $ServiceName | Format-List Name, DisplayName, Status, StartType
Write-Host "Journaux : $logPath"
