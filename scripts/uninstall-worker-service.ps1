[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidatePattern('^[A-Za-z0-9_-]+$')]
    [string]$ServiceName = 'GEHProductCatalogSync'
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

$service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if (-not $service) {
    Write-Host "Le service '$ServiceName' est deja absent. Aucun fichier ni journal n a ete supprime."
    return
}

if ($PSCmdlet.ShouldProcess($ServiceName, 'Arreter et supprimer le service Windows')) {
    if ($service.Status -ne [System.ServiceProcess.ServiceControllerStatus]::Stopped) {
        Stop-Service -Name $ServiceName
        $service.WaitForStatus(
            [System.ServiceProcess.ServiceControllerStatus]::Stopped,
            [TimeSpan]::FromSeconds(30))
    }

    & "$env:SystemRoot\System32\sc.exe" delete $ServiceName
    if ($LASTEXITCODE -ne 0) {
        throw "La suppression du service '$ServiceName' a echoue avec le code $LASTEXITCODE."
    }
}

Write-Host 'Le service a ete supprime. Les binaires, la configuration et les journaux sont conserves.'
