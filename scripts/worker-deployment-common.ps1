function Get-DeploymentFullPath {
    param([Parameter(Mandatory)][string]$Path)

    return Resolve-UserPath -Path $Path
}

function Resolve-UserPath {
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$MustExist,
        [ValidateSet('Any', 'Leaf', 'Container')]
        [string]$PathType = 'Any'
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw 'Le chemin fourni est vide.'
    }

    if ([IO.Path]::IsPathRooted($Path)) {
        $candidatePath = $Path
    }
    else {
        $location = Get-Location
        if ($location.Provider.Name -ne 'FileSystem') {
            throw "La localisation PowerShell courante '$($location.Path)' n est pas un chemin de fichiers."
        }
        $candidatePath = Join-Path -Path $location.Path -ChildPath $Path
    }

    $resolvedPath = [IO.Path]::GetFullPath($candidatePath)
    if ($MustExist) {
        $exists = switch ($PathType) {
            'Leaf' { Test-Path -LiteralPath $resolvedPath -PathType Leaf }
            'Container' { Test-Path -LiteralPath $resolvedPath -PathType Container }
            default { Test-Path -LiteralPath $resolvedPath }
        }
        if (-not $exists) {
            throw "Chemin introuvable : '$resolvedPath'."
        }
    }

    return $resolvedPath
}

function Assert-WindowsAdministrator {
    if ($env:OS -ne 'Windows_NT') {
        throw 'Cette opération doit être exécutée sous Windows.'
    }

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Ouvrez PowerShell avec Exécuter en tant qu administrateur.'
    }
}

function Get-WorkerDotNetExecutable {
    param([Parameter(Mandatory)][string]$ProjectRoot)

    $localDotnet = Join-Path $ProjectRoot '.dotnet\dotnet.exe'
    if (Test-Path -LiteralPath $localDotnet -PathType Leaf) {
        return $localDotnet
    }

    $dotnetCommand = Get-Command dotnet -ErrorAction SilentlyContinue
    if (-not $dotnetCommand) {
        throw 'Le SDK .NET est introuvable. Installez le SDK .NET 10 ou utilisez le SDK local .dotnet.'
    }

    return $dotnetCommand.Source
}

function Get-WorkerProjectVersion {
    param(
        [Parameter(Mandatory)][string]$DotNetExecutable,
        [Parameter(Mandatory)][string]$ProjectFile
    )

    $output = @(& $DotNetExecutable msbuild $ProjectFile -nologo -getProperty:Version 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "Impossible de lire la version MSBuild du Worker.`n$($output -join [Environment]::NewLine)"
    }

    $versions = @($output | ForEach-Object { $_.ToString().Trim() } | Where-Object {
        $_ -match '^\d+\.\d+\.\d+(?:\.\d+)?(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$'
    })
    if ($versions.Count -eq 0) {
        throw 'La propriété MSBuild Version du Worker est absente ou invalide.'
    }

    return $versions[$versions.Count - 1]
}

function ConvertTo-WorkerVersion {
    param([Parameter(Mandatory)][string]$Value)

    $numericValue = ($Value -split '\+', 2)[0]
    $numericValue = ($numericValue -split '-', 2)[0]
    try {
        $parsedVersion = [Version]$numericValue
        $build = if ($parsedVersion.Build -lt 0) { 0 } else { $parsedVersion.Build }
        $revision = if ($parsedVersion.Revision -lt 0) { 0 } else { $parsedVersion.Revision }
        return [Version]('{0}.{1}.{2}.{3}' -f
            $parsedVersion.Major,
            $parsedVersion.Minor,
            $build,
            $revision)
    }
    catch {
        throw "Version Worker invalide : '$Value'."
    }
}

function Compare-WorkerVersion {
    param(
        [Parameter(Mandatory)][string]$Left,
        [Parameter(Mandatory)][string]$Right
    )

    return (ConvertTo-WorkerVersion -Value $Left).CompareTo(
        (ConvertTo-WorkerVersion -Value $Right))
}

function Get-WorkerFileVersion {
    param([Parameter(Mandatory)][string]$ExecutablePath)

    $resolvedPath = Get-DeploymentFullPath -Path $ExecutablePath
    if (-not (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) {
        throw "Exécutable Worker introuvable : '$resolvedPath'."
    }

    $versionInfo = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($resolvedPath)
    $displayVersion = $versionInfo.ProductVersion
    if ([string]::IsNullOrWhiteSpace($displayVersion)) {
        $displayVersion = $versionInfo.FileVersion
    }
    if ([string]::IsNullOrWhiteSpace($displayVersion)) {
        throw "La version de '$resolvedPath' est illisible."
    }

    $displayVersion = ($displayVersion -split '\+', 2)[0]
    [void](ConvertTo-WorkerVersion -Value $displayVersion)
    return $displayVersion
}

function Get-WorkerRelativePath {
    param(
        [Parameter(Mandatory)][string]$RootPath,
        [Parameter(Mandatory)][string]$ChildPath
    )

    $root = (Get-DeploymentFullPath -Path $RootPath).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    $child = Get-DeploymentFullPath -Path $ChildPath
    if (-not $child.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Le chemin '$child' se trouve hors de '$root'."
    }

    return $child.Substring($root.Length)
}

function Test-IsWorkerPayloadFile {
    param([Parameter(Mandatory)][string]$RelativePath)

    $extension = [IO.Path]::GetExtension($RelativePath).ToLowerInvariant()
    return $extension -in @('.exe', '.dll', '.json')
}

function Assert-NoSecretConfigurationValue {
    param(
        [Parameter(Mandatory)]$Value,
        [Parameter(Mandatory)][string]$PropertyPath
    )

    if ($null -eq $Value) {
        return
    }
    if ($Value -is [System.Collections.IEnumerable] -and
        $Value -isnot [string] -and
        $Value -isnot [PSCustomObject]) {
        foreach ($item in $Value) {
            Assert-NoSecretConfigurationValue -Value $item -PropertyPath $PropertyPath
        }
        return
    }

    foreach ($property in $Value.PSObject.Properties) {
        $childPath = "$PropertyPath.$($property.Name)"
        if ($property.Name -match '(?i)(password|secret|token|username|connectionstring)$' -and
            $null -ne $property.Value -and
            -not [string]::IsNullOrWhiteSpace($property.Value.ToString())) {
            throw "Valeur sensible interdite dans la configuration déployable : '$childPath'."
        }
        if ($property.Value -is [PSCustomObject] -or
            ($property.Value -is [System.Collections.IEnumerable] -and
                $property.Value -isnot [string])) {
            Assert-NoSecretConfigurationValue -Value $property.Value -PropertyPath $childPath
        }
    }
}

function Assert-NoSecretConfigurationValues {
    param([Parameter(Mandatory)][string]$Path)

    foreach ($settingsFile in Get-ChildItem -LiteralPath $Path -File -Filter 'appsettings*.json' |
            Where-Object { $_.Name -notlike '*.local.json' }) {
        try {
            $settings = Get-Content -LiteralPath $settingsFile.FullName -Raw -Encoding UTF8 |
                ConvertFrom-Json
        }
        catch {
            throw "Configuration JSON invalide : '$($settingsFile.FullName)'."
        }
        Assert-NoSecretConfigurationValue -Value $settings -PropertyPath $settingsFile.Name
    }
}

function Test-IsPreservedWorkerLocalFile {
    param([Parameter(Mandatory)][string]$RelativePath)

    $normalized = $RelativePath.Replace('/', '\')
    $name = [IO.Path]::GetFileName($normalized)
    $extension = [IO.Path]::GetExtension($name).ToLowerInvariant()
    return (
        $name -eq '.env' -or
        $name.StartsWith('.env.', [StringComparison]::OrdinalIgnoreCase) -or
        $name -like '*.local.json' -or
        $name -like '*.local.config' -or
        $name -like '*.log' -or
        ($extension -notin @('.exe', '.dll') -and
            $name -match '(?i)(credential|secret|password|token)') -or
        $normalized -match '(^|\\)logs?(\\|$)'
    )
}

function Assert-NoForbiddenDeploymentFiles {
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$AllowPreservedLocalFiles
    )

    $root = Get-DeploymentFullPath -Path $Path
    foreach ($file in Get-ChildItem -LiteralPath $root -Recurse -File -Force) {
        $relativePath = Get-WorkerRelativePath -RootPath $root -ChildPath $file.FullName
        $normalized = $relativePath.Replace('/', '\')
        $name = $file.Name
        $extension = [IO.Path]::GetExtension($name).ToLowerInvariant()
        if ($AllowPreservedLocalFiles -and
            (Test-IsPreservedWorkerLocalFile -RelativePath $relativePath)) {
            continue
        }
        $forbidden =
            $name -eq '.env' -or
            $name.StartsWith('.env.', [StringComparison]::OrdinalIgnoreCase) -or
            $name -like '*.local.json' -or
            $name -like '*.log' -or
            ($extension -eq '.json' -and $name -match '(?i)(credential|secret|password|token)') -or
            $normalized -match '(^|\\)(logs?|artifacts?|tests?|src)(\\|$)'

        if ($forbidden -or $extension -in @('.cs', '.csproj', '.sln', '.ps1')) {
            throw "Fichier interdit dans le payload Worker : '$relativePath'."
        }
        if ($normalized -match '^fixtures\\' -and $normalized -ne 'fixtures\products.json') {
            throw "Fixture non autorisée dans le payload Worker : '$relativePath'."
        }
    }

    Assert-NoSecretConfigurationValues -Path $root
}

function Get-WorkerPayloadFiles {
    param([Parameter(Mandatory)][string]$Path)

    $root = Get-DeploymentFullPath -Path $Path
    return @(Get-ChildItem -LiteralPath $root -Recurse -File -Force | Where-Object {
        $relativePath = Get-WorkerRelativePath -RootPath $root -ChildPath $_.FullName
        (Test-IsWorkerPayloadFile -RelativePath $relativePath) -and
            -not (Test-IsPreservedWorkerLocalFile -RelativePath $relativePath)
    })
}

function Test-WorkerPayload {
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$AllowPreservedLocalFiles
    )

    $root = Get-DeploymentFullPath -Path $Path
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        throw "Payload Worker introuvable : '$root'."
    }

    Assert-NoForbiddenDeploymentFiles -Path $root -AllowPreservedLocalFiles:$AllowPreservedLocalFiles
    $requiredFiles = @(
        'Catalog.Sync.Worker.exe',
        'Catalog.Sync.Worker.dll',
        'Catalog.Sync.Worker.deps.json',
        'Catalog.Sync.Worker.runtimeconfig.json',
        'appsettings.json'
    )
    foreach ($requiredFile in $requiredFiles) {
        $requiredPath = Join-Path $root $requiredFile
        if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
            throw "Payload Worker incomplet : '$requiredFile' est absent."
        }
    }

    return Get-WorkerFileVersion -ExecutablePath (Join-Path $root 'Catalog.Sync.Worker.exe')
}

function Test-WorkerSelfContainedPayload {
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$AllowPreservedLocalFiles
    )

    $root = Get-DeploymentFullPath -Path $Path
    $version = Test-WorkerPayload -Path $root -AllowPreservedLocalFiles:$AllowPreservedLocalFiles
    $runtimeConfigPath = Join-Path $root 'Catalog.Sync.Worker.runtimeconfig.json'
    try {
        $runtimeConfig = Get-Content -LiteralPath $runtimeConfigPath -Raw -Encoding UTF8 |
            ConvertFrom-Json
    }
    catch {
        throw "Runtimeconfig JSON invalide : '$runtimeConfigPath'."
    }

    $includedFrameworksProperty = $runtimeConfig.runtimeOptions.PSObject.Properties['includedFrameworks']
    if ($null -eq $includedFrameworksProperty -or
        @($includedFrameworksProperty.Value | Where-Object { $null -ne $_ }).Count -eq 0) {
        throw "La publication '$root' est framework-dependent ; le package client doit être self-contained."
    }

    foreach ($runtimeFile in @('coreclr.dll', 'hostfxr.dll', 'hostpolicy.dll', 'System.Private.CoreLib.dll')) {
        if (-not (Test-Path -LiteralPath (Join-Path $root $runtimeFile) -PathType Leaf)) {
            throw "Runtime .NET incomplet dans la publication self-contained : '$runtimeFile' est absent."
        }
    }

    return $version
}

function Copy-WorkerPayload {
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$DestinationPath
    )

    $source = Get-DeploymentFullPath -Path $SourcePath
    $destination = Get-DeploymentFullPath -Path $DestinationPath
    New-Item -ItemType Directory -Path $destination -Force | Out-Null

    foreach ($file in Get-WorkerPayloadFiles -Path $source) {
        $relativePath = Get-WorkerRelativePath -RootPath $source -ChildPath $file.FullName
        $destinationFile = Join-Path $destination $relativePath
        $destinationDirectory = Split-Path -Parent $destinationFile
        New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null
        Copy-Item -LiteralPath $file.FullName -Destination $destinationFile -Force
    }
}

function Remove-WorkerPayloadFiles {
    param([Parameter(Mandatory)][string]$Path)

    $root = Get-DeploymentFullPath -Path $Path
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        return
    }

    foreach ($file in Get-ChildItem -LiteralPath $root -Recurse -File -Force) {
        $relativePath = Get-WorkerRelativePath -RootPath $root -ChildPath $file.FullName
        if (-not (Test-IsPreservedWorkerLocalFile -RelativePath $relativePath)) {
            Remove-Item -LiteralPath $file.FullName -Force
        }
    }

    $directories = @(Get-ChildItem -LiteralPath $root -Recurse -Directory -Force |
        Sort-Object { $_.FullName.Length } -Descending)
    foreach ($directory in $directories) {
        if (@(Get-ChildItem -LiteralPath $directory.FullName -Force).Count -eq 0) {
            Remove-Item -LiteralPath $directory.FullName -Force
        }
    }
}

function New-WorkerBackupName {
    param(
        [Parameter(Mandatory)][string]$Version,
        [DateTime]$Timestamp = [DateTime]::Now,
        [string]$Prefix = ''
    )

    $safeVersion = $Version -replace '[^0-9A-Za-z._-]', '_'
    return '{0}{1}_{2}' -f $Prefix, $Timestamp.ToString('yyyy-MM-dd_HHmmss'), $safeVersion
}

function Get-WorkerBackupsToRemove {
    param(
        [Parameter(Mandatory)][string]$BackupRoot,
        [ValidateRange(1, 100)][int]$Keep = 5,
        [string]$ProtectedPath
    )

    if (-not (Test-Path -LiteralPath $BackupRoot -PathType Container)) {
        return @()
    }

    $protectedFullPath = $null
    if (-not [string]::IsNullOrWhiteSpace($ProtectedPath)) {
        $protectedFullPath = Get-DeploymentFullPath -Path $ProtectedPath
    }
    $backups = @(Get-ChildItem -LiteralPath $BackupRoot -Directory |
        Where-Object { $_.Name -match '^\d{4}-\d{2}-\d{2}_\d{6}_' } |
        Sort-Object Name -Descending)
    $retained = @($backups | Select-Object -First $Keep)

    return @($backups | Where-Object {
        $candidate = $_
        -not ($retained | Where-Object { $_.FullName -eq $candidate.FullName }) -and
            ($null -eq $protectedFullPath -or $_.FullName -ne $protectedFullPath)
    })
}

function New-WorkerDeploymentLock {
    param(
        [Parameter(Mandatory)][string]$BackupRoot,
        [ValidateRange(1, 1440)][int]$StaleAfterMinutes = 120
    )

    $root = Get-DeploymentFullPath -Path $BackupRoot
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    $lockPath = Join-Path $root 'deployment.lock'
    if (Test-Path -LiteralPath $lockPath -PathType Leaf) {
        $lockAge = [DateTimeOffset]::UtcNow - (Get-Item -LiteralPath $lockPath).LastWriteTimeUtc
        if ($lockAge.TotalMinutes -lt $StaleAfterMinutes) {
            throw "Un autre déploiement semble actif : '$lockPath'."
        }
        Remove-Item -LiteralPath $lockPath -Force
    }

    try {
        $stream = New-Object IO.FileStream(
            $lockPath,
            [IO.FileMode]::CreateNew,
            [IO.FileAccess]::Write,
            [IO.FileShare]::None)
        try {
            $content = [Text.Encoding]::UTF8.GetBytes(
                ('PID={0};UTC={1:o}' -f $PID, [DateTimeOffset]::UtcNow))
            $stream.Write($content, 0, $content.Length)
        }
        finally {
            $stream.Dispose()
        }
    }
    catch {
        throw "Impossible d acquérir le verrou de déploiement '$lockPath'."
    }

    return $lockPath
}

function Remove-WorkerDeploymentLock {
    param([string]$LockPath)

    if (-not [string]::IsNullOrWhiteSpace($LockPath) -and
        (Test-Path -LiteralPath $LockPath -PathType Leaf)) {
        Remove-Item -LiteralPath $LockPath -Force
    }
}

function Test-WorkerPackageHash {
    param(
        [Parameter(Mandatory)][string]$PackagePath,
        [string]$HashPath
    )

    $package = Resolve-UserPath -Path $PackagePath
    if ([string]::IsNullOrWhiteSpace($HashPath)) {
        $candidate = "$package.sha256"
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            $HashPath = $candidate
        }
        else {
            Write-Warning 'Aucun fichier SHA-256 fourni ; le contenu sera validé mais son transfert ne pourra pas être authentifié par hash.'
            return $false
        }
    }

    $resolvedHashPath = Resolve-UserPath -Path $HashPath
    if (-not (Test-Path -LiteralPath $resolvedHashPath -PathType Leaf)) {
        throw "Fichier SHA-256 introuvable : '$resolvedHashPath'."
    }
    $hashLine = (Get-Content -LiteralPath $resolvedHashPath -Encoding ASCII | Select-Object -First 1).Trim()
    if ($hashLine -notmatch '^([0-9A-Fa-f]{64})(?:\s+.+)?$') {
        throw "Format SHA-256 invalide dans '$resolvedHashPath'."
    }

    $expectedHash = $Matches[1].ToLowerInvariant()
    $actualHash = (Get-FileHash -LiteralPath $package -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -ne $expectedHash) {
        throw "SHA-256 invalide pour '$package'. Attendu=$expectedHash; obtenu=$actualHash."
    }

    Write-DeploymentStep -Message "SHA-256 vérifié : $actualHash."
    return $true
}

function Wait-WorkerServiceStatus {
    param(
        [Parameter(Mandatory)][string]$ServiceName,
        [Parameter(Mandatory)][System.ServiceProcess.ServiceControllerStatus]$Status,
        [ValidateRange(1, 3600)][int]$TimeoutSeconds
    )

    $service = Get-Service -Name $ServiceName -ErrorAction Stop
    $service.WaitForStatus($Status, [TimeSpan]::FromSeconds($TimeoutSeconds))
    $service.Refresh()
    if ($service.Status -ne $Status) {
        throw "Le service '$ServiceName' n a pas atteint l état '$Status'."
    }
}

function Test-WorkerServiceStability {
    param(
        [Parameter(Mandatory)][string]$ServiceName,
        [ValidateRange(1, 300)][int]$Seconds = 5
    )

    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($Seconds)
    do {
        $service = Get-Service -Name $ServiceName -ErrorAction Stop
        if ($service.Status -ne [System.ServiceProcess.ServiceControllerStatus]::Running) {
            throw "Le service '$ServiceName' ne reste pas Running pendant le contrôle de santé."
        }
        Start-Sleep -Seconds 1
    } while ([DateTimeOffset]::UtcNow -lt $deadline)
}

function Write-DeploymentStep {
    param([Parameter(Mandatory)][string]$Message)

    Write-Host ('[{0}] {1}' -f [DateTimeOffset]::Now.ToString('yyyy-MM-dd HH:mm:ss zzz'), $Message)
}
