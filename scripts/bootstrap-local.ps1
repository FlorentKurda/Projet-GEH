[CmdletBinding()]
param(
    [string]$EnvFile,
    [string]$WorkerEnvFile,
    [ValidatePattern('^[a-z0-9][a-z0-9_-]*$')]
    [string]$ComposeProjectName
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$composeFile = Join-Path $projectRoot 'docker-compose.yml'
$exampleEnvFile = Join-Path $projectRoot '.env.example'

if ([string]::IsNullOrWhiteSpace($EnvFile)) {
    $EnvFile = Join-Path $projectRoot '.env'
}
elseif (-not [System.IO.Path]::IsPathRooted($EnvFile)) {
    $EnvFile = Join-Path $projectRoot $EnvFile
}

if ([string]::IsNullOrWhiteSpace($WorkerEnvFile)) {
    $WorkerEnvFile = Join-Path $projectRoot '.env.worker.local'
}
elseif (-not [System.IO.Path]::IsPathRooted($WorkerEnvFile)) {
    $WorkerEnvFile = Join-Path $projectRoot $WorkerEnvFile
}

function Read-EnvironmentFile {
    param([Parameter(Mandatory)][string]$Path)

    $values = @{}
    foreach ($line in Get-Content -LiteralPath $Path -Encoding UTF8) {
        $trimmedLine = $line.Trim()
        if ($trimmedLine.Length -eq 0 -or $trimmedLine.StartsWith('#')) {
            continue
        }

        if ($trimmedLine -notmatch '^([A-Za-z_][A-Za-z0-9_]*)=(.*)$') {
            throw "Ligne invalide dans '$Path' : $line"
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

        $values[$name] = $value
    }

    return $values
}

function Get-RequiredSetting {
    param(
        [Parameter(Mandatory)][hashtable]$Settings,
        [Parameter(Mandatory)][string]$Name
    )

    if (-not $Settings.ContainsKey($Name) -or [string]::IsNullOrWhiteSpace([string]$Settings[$Name])) {
        throw "La variable '$Name' doit être renseignée dans '$EnvFile'."
    }

    return [string]$Settings[$Name]
}

function Wait-DockerServiceHealthy {
    param(
        [Parameter(Mandatory)][string]$Service,
        [int]$TimeoutSeconds = 180
    )

    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        $containerIdOutput = & docker @script:composePrefix ps -q $Service 2>$null
        if ($LASTEXITCODE -eq 0) {
            $containerId = [string]($containerIdOutput | Select-Object -First 1)
            if (-not [string]::IsNullOrWhiteSpace($containerId)) {
                $statusOutput = & docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' $containerId 2>$null
                if ($LASTEXITCODE -eq 0) {
                    $status = ([string]($statusOutput | Select-Object -First 1)).Trim()
                    if ($status -eq 'healthy' -or $status -eq 'running') {
                        Write-Host "Le service '$Service' est prêt."
                        return
                    }

                    if ($status -eq 'unhealthy' -or $status -eq 'exited' -or $status -eq 'dead') {
                        throw "Le service Docker '$Service' est dans l'état '$status'. Consultez : docker compose logs $Service"
                    }
                }
            }
        }

        Start-Sleep -Seconds 2
    }

    throw "Le service Docker '$Service' n'est pas devenu prêt en $TimeoutSeconds secondes."
}

function Invoke-WpCli {
    param([Parameter(Mandatory)][string[]]$WpArguments)

    $output = & docker @script:composePrefix run --rm --no-deps wpcli @WpArguments
    if ($LASTEXITCODE -ne 0) {
        throw "WP-CLI a échoué pour la commande '$($WpArguments[0..([Math]::Min(1, $WpArguments.Count - 1))] -join ' ')'."
    }

    return $output
}

function Test-WpCli {
    param([Parameter(Mandatory)][string[]]$WpArguments)

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        # Docker Compose écrit sa progression sur stderr même en cas de succès.
        $ErrorActionPreference = 'Continue'
        & docker @script:composePrefix run --rm --no-deps wpcli @WpArguments *> $null
        $succeeded = $LASTEXITCODE -eq 0
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    return $succeeded
}

try {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        throw 'Docker est introuvable. Installez Docker Desktop et vérifiez que docker.exe est dans PATH.'
    }

    & docker info --format '{{.ServerVersion}}' | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw 'Docker Desktop ne répond pas. Démarrez Docker Desktop puis relancez ce script.'
    }

    & docker compose version | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw 'Le sous-commande « docker compose » est indisponible.'
    }

    if (-not (Test-Path -LiteralPath $EnvFile -PathType Leaf)) {
        Copy-Item -LiteralPath $exampleEnvFile -Destination $EnvFile
        Write-Host "Le fichier local '$EnvFile' a été créé à partir de .env.example."
        Write-Warning 'Les identifiants fournis sont uniquement des exemples locaux. Modifiez-les si nécessaire avant tout usage partagé.'
    }

    $settings = Read-EnvironmentFile -Path $EnvFile
    $siteUrl = (Get-RequiredSetting -Settings $settings -Name 'WORDPRESS_SITE_URL').TrimEnd('/')
    $siteTitle = Get-RequiredSetting -Settings $settings -Name 'WORDPRESS_SITE_TITLE'
    $adminUser = Get-RequiredSetting -Settings $settings -Name 'WORDPRESS_ADMIN_USER'
    $adminPassword = Get-RequiredSetting -Settings $settings -Name 'WORDPRESS_ADMIN_PASSWORD'
    $adminEmail = Get-RequiredSetting -Settings $settings -Name 'WORDPRESS_ADMIN_EMAIL'
    $syncUser = Get-RequiredSetting -Settings $settings -Name 'CATALOG_SYNC_USER'
    $syncEmail = Get-RequiredSetting -Settings $settings -Name 'CATALOG_SYNC_EMAIL'
    $syncDisplayName = Get-RequiredSetting -Settings $settings -Name 'CATALOG_SYNC_DISPLAY_NAME'
    $applicationName = Get-RequiredSetting -Settings $settings -Name 'CATALOG_SYNC_APPLICATION_NAME'

    $requiredComposeVariables = @(
        'WORDPRESS_DB_NAME',
        'WORDPRESS_DB_USER',
        'WORDPRESS_DB_PASSWORD',
        'MARIADB_ROOT_PASSWORD'
    )
    foreach ($variableName in $requiredComposeVariables) {
        $null = Get-RequiredSetting -Settings $settings -Name $variableName
    }

    $script:composePrefix = @('compose')
    if (-not [string]::IsNullOrWhiteSpace($ComposeProjectName)) {
        $script:composePrefix += @('--project-name', $ComposeProjectName)
    }
    $script:composePrefix += @('--env-file', $EnvFile, '-f', $composeFile)

    Write-Host 'Démarrage de MariaDB et WordPress…'
    & docker @composePrefix up -d db wordpress
    if ($LASTEXITCODE -ne 0) {
        throw "Docker Compose n’a pas pu démarrer MariaDB et WordPress."
    }

    Wait-DockerServiceHealthy -Service 'db'
    Wait-DockerServiceHealthy -Service 'wordpress'

    $wordpressInstalled = Test-WpCli -WpArguments @('core', 'is-installed')

    if (-not $wordpressInstalled) {
        Write-Host 'Installation de WordPress…'
        $null = Invoke-WpCli -WpArguments @(
            'core',
            'install',
            "--url=$siteUrl",
            "--title=$siteTitle",
            "--admin_user=$adminUser",
            "--admin_password=$adminPassword",
            "--admin_email=$adminEmail",
            '--skip-email'
        )
    }
    else {
        Write-Host 'WordPress est déjà installé.'
    }

    Write-Host 'Activation du plugin Product Catalog Sync…'
    $null = Invoke-WpCli -WpArguments @('plugin', 'activate', 'product-catalog-sync')

    Write-Host 'Configuration des permaliens pour les routes REST…'
    $null = Invoke-WpCli -WpArguments @('rewrite', 'structure', '/%postname%/', '--hard')

    $syncUserExists = Test-WpCli -WpArguments @('user', 'get', $syncUser, '--field=ID')

    if (-not $syncUserExists) {
        Write-Host "Création de l’utilisateur technique '$syncUser'…"
        $temporaryPassword = "$([Guid]::NewGuid().ToString('N'))aA1!"
        $null = Invoke-WpCli -WpArguments @(
            'user',
            'create',
            $syncUser,
            $syncEmail,
            '--role=catalog_sync',
            "--display_name=$syncDisplayName",
            "--user_pass=$temporaryPassword"
        )
    }
    else {
        Write-Host "L’utilisateur technique '$syncUser' existe déjà."
        $null = Invoke-WpCli -WpArguments @('user', 'set-role', $syncUser, 'catalog_sync')
    }

    $applicationPasswordListOutput = Invoke-WpCli -WpArguments @(
        'user',
        'application-password',
        'list',
        $syncUser,
        '--fields=uuid,name',
        '--format=json'
    )
    $applicationPasswords = @()
    $applicationPasswordListJson = ($applicationPasswordListOutput -join [Environment]::NewLine).Trim()
    if (-not [string]::IsNullOrWhiteSpace($applicationPasswordListJson)) {
        $applicationPasswords = ConvertFrom-Json -InputObject $applicationPasswordListJson
    }
    $matchingApplicationPasswords = @($applicationPasswords | Where-Object { $_.name -eq $applicationName })

    $existingWorkerSettings = @{}
    if (Test-Path -LiteralPath $WorkerEnvFile -PathType Leaf) {
        $existingWorkerSettings = Read-EnvironmentFile -Path $WorkerEnvFile
    }

    $applicationPassword = ''
    if ($existingWorkerSettings.ContainsKey('WordPress__ApplicationPassword')) {
        $applicationPassword = [string]$existingWorkerSettings['WordPress__ApplicationPassword']
    }

    if ([string]::IsNullOrWhiteSpace($applicationPassword) -or $matchingApplicationPasswords.Count -eq 0) {
        foreach ($existingPassword in $matchingApplicationPasswords) {
            $null = Invoke-WpCli -WpArguments @(
                'user',
                'application-password',
                'delete',
                $syncUser,
                [string]$existingPassword.uuid
            )
        }

        Write-Host "Création d’un Application Password dédié au Worker…"
        $createdPasswordOutput = Invoke-WpCli -WpArguments @(
            'user',
            'application-password',
            'create',
            $syncUser,
            $applicationName,
            '--porcelain'
        )
        $createdPasswordLines = @($createdPasswordOutput | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_.Length -gt 0 })
        if ($createdPasswordLines.Count -eq 0) {
            throw "WP-CLI n’a retourné aucun Application Password."
        }
        $applicationPassword = $createdPasswordLines[-1]
    }
    else {
        Write-Host "L’Application Password local existant est conservé."
    }

    $fixturePath = [System.IO.Path]::GetFullPath((Join-Path $projectRoot 'fixtures/products.json'))
    $workerConfigLines = @(
        '# Généré par scripts/bootstrap-local.ps1. Ne pas commiter.',
        "DOTNET_ENVIRONMENT=Development",
        "WordPress__BaseUrl=$siteUrl",
        'WordPress__RunsEndpoint=/wp-json/catalog-sync/v1/runs',
        "WordPress__Username=$syncUser",
        "WordPress__ApplicationPassword=$applicationPassword",
        'WordPress__RequestTimeoutSeconds=60',
        'WordPress__AllowInsecureHttpForLocalDevelopment=true',
        "ProductSource__JsonFilePath=$fixturePath",
        'Sync__IntervalMinutes=15',
        'Sync__RunOnStartup=true',
        'Sync__BatchSize=200',
        'FileLogging__Enabled=true',
        'FileLogging__DirectoryPath=logs',
        'FileLogging__RetentionDays=30'
    )
    $utf8WithoutBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllLines($WorkerEnvFile, $workerConfigLines, $utf8WithoutBom)

    Write-Host ''
    Write-Host 'Environnement local prêt.' -ForegroundColor Green
    Write-Host "WordPress : $siteUrl"
    Write-Host "Configuration Worker : $WorkerEnvFile"
    Write-Host "Le secret n’est pas affiché et ces deux fichiers locaux sont ignorés par Git."
    Write-Host ''
    Write-Host 'Prochaines commandes :'
    Write-Host '  .\scripts\run-worker-local.ps1 -RunOnce'
    Write-Host '  .\scripts\smoke-test.ps1'
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
