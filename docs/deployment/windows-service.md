# Worker en service Windows

## Objectif et architecture

`Catalog.Sync.Worker` utilise le Generic Host .NET et le même service de synchronisation dans ses trois modes :

```text
Console / Service Control Manager
        ↓
Generic Host
        ↓
SynchronizationScheduler
        ↓
CatalogSynchronizationService
        ↓
JsonProductSource → WordPressCatalogClient
```

- `--run-once` exécute une synchronisation puis quitte ; `--dry-run` reste réservé à ce mode.
- Sans `--run-once`, le `SynchronizationScheduler` reste vivant. Il lance éventuellement une synchronisation au démarrage, puis utilise un `PeriodicTimer`.
- Le scheduler ne duplique aucune règle de synchronisation et ignore un cycle si le précédent est encore actif.
- Une erreur temporaire est journalisée et le prochain cycle reste planifié. Une configuration invalide empêche le démarrage.
- L'arrêt du Generic Host ou du Service Control Manager propage le `CancellationToken` à la synchronisation en cours.

Le même exécutable est utilisable en console et comme service Windows. Le programme ne crée et n'enregistre jamais lui-même un service.

## Prérequis

- Windows Server moderne x64 compatible avec le Worker ;
- aucun runtime .NET, SDK, Visual Studio, Git, Node ou Docker requis sur le serveur pour le package de production autonome ;
- PowerShell exécuté en administrateur uniquement pour installer ou désinstaller le service ;
- compte de service disposant uniquement des droits locaux et réseau nécessaires ;
- accès HTTPS sortant au WordPress cible depuis ce compte ;
- accès réseau SQL Server à prévoir lorsque la source Sage sera définie, sans configuration Sage dans ce lot.

## Configuration

Les valeurs non sensibles par défaut sont dans `appsettings.json` :

```json
{
  "Sync": {
    "IntervalMinutes": 15,
    "RunOnStartup": true,
    "BatchSize": 200
  },
  "FileLogging": {
    "Enabled": true,
    "DirectoryPath": "logs",
    "RetentionDays": 30
  },
  "ProductSource": {
    "JsonFilePath": "fixtures/products.json"
  }
}
```

`Sync:IntervalMinutes` doit être compris entre 1 et 1440. `FileLogging:RetentionDays` doit être compris entre 1 et 3650. Les validations sont exécutées au démarrage.

La configuration de production et les secrets sont fournis par variables d'environnement .NET :

```text
DOTNET_ENVIRONMENT=Production
WordPress__BaseUrl=https://catalogue.example.invalid
WordPress__Username=<compte technique>
WordPress__ApplicationPassword=<secret>
Sync__IntervalMinutes=15
Sync__RunOnStartup=true
FileLogging__Enabled=true
FileLogging__DirectoryPath=logs
FileLogging__RetentionDays=30
```

Les fichiers `.env` servent uniquement au développement et ne sont pas chargés automatiquement par l'application. Pour un test local, le script d'installation peut lire un fichier ignoré avec `-EnvironmentFile` et enregistrer les valeurs comme environnement propre au service, sans les afficher. En production, préparer ce fichier hors du dossier publié, limiter ses ACL au personnel d'exploitation, puis le conserver ou le supprimer selon la politique de secrets du client. Aucun secret ne doit être copié dans `appsettings.json`.

Les variables de service restent protégées par les ACL administratives de Windows mais ne constituent pas un coffre-fort. Cette stratégie volontairement simple pourra évoluer si le client choisit ultérieurement un gestionnaire de secrets.

## Publication

Depuis la racine du dépôt :

```powershell
dotnet publish .\src\Catalog.Sync.Worker\Catalog.Sync.Worker.csproj `
  -c Release `
  -r win-x64 `
  --self-contained true `
  -o .\artifacts\worker\win-x64
```

La commande recommandée reste `.\scripts\publish-worker.ps1`, qui applique ces valeurs par défaut et produit une sortie versionnée. Le package Windows de production est self-contained : il inclut le runtime .NET nécessaire et n'impose aucune installation .NET sur le serveur cible. La sortie contient l'exécutable, les DLL applicatives et runtime, `appsettings.json` et la petite fixture de démonstration sous `fixtures/`. `artifacts/` n'est pas versionné.

Copier ensuite la sortie validée, avec des droits administrateur, vers :

```text
C:\Program Files\GEH\ProductCatalogSync\
```

Le compte de service a uniquement besoin de lecture/exécution sur ces binaires. Le script d'installation crée :

```text
C:\ProgramData\GEH\ProductCatalogSync\logs\
```

et accorde à `LocalService` le droit de modification sur ce dossier de journaux seulement.

## Test console avant installation

Utiliser exclusivement une cible locale autorisée :

```powershell
$env:DOTNET_ENVIRONMENT = 'Development'
$env:WordPress__BaseUrl = 'http://localhost:8080'
$env:WordPress__Username = '<utilisateur local>'
$env:WordPress__ApplicationPassword = '<application password local>'
.\artifacts\worker\win-x64\Catalog.Sync.Worker.exe --run-once --dry-run
```

Ne copiez pas les secrets locaux dans l'historique PowerShell partagé ni dans un fichier versionné.

## Installation

Le script utilise les conventions suivantes :

```text
ServiceName : GEHProductCatalogSync
DisplayName : GEH Product Catalog Sync
Description : Service de synchronisation du catalogue produits vers WordPress.
Startup     : Automatic
Compte      : NT AUTHORITY\LocalService
```

Dans un PowerShell administrateur, après avoir copié la publication :

```powershell
.\scripts\install-worker-service.ps1 `
  -PublishPath 'C:\Program Files\GEH\ProductCatalogSync' `
  -EnvironmentFile '.\.env.worker.service.local' `
  -Start
```

Cette commande suppose que la localisation PowerShell courante est la racine du dépôt. Les chemins relatifs fournis à `-PublishPath` ou `-EnvironmentFile` sont résolus depuis cette localisation, jamais depuis le dossier `scripts` ni depuis le répertoire courant implicite de .NET.

Le script refuse un service déjà présent. `-Force` demande explicitement sa recréation. `-EnvironmentFile` accepte uniquement les sections de configuration connues (`WordPress__`, `ProductSource__`, `Sync__`, `FileLogging__`, futur `Sql__`) et ne journalise aucune valeur. Il configure le recovery SCM après crash : 60 secondes au premier échec, 300 au deuxième, puis 900 pour les suivants. Une erreur de synchronisation normale ne fait pas crasher le processus et attend le cycle suivant. Le script tente également d'enregistrer la source `Catalog.Sync.Worker` dans le journal Application ; un refus de cette opération ne bloque pas l'installation ni les journaux fichiers.

## Exploitation et diagnostic

```powershell
Get-Service GEHProductCatalogSync
Start-Service GEHProductCatalogSync
Stop-Service GEHProductCatalogSync
Restart-Service GEHProductCatalogSync
Get-Content 'C:\ProgramData\GEH\ProductCatalogSync\logs\catalog-sync-*.log' -Tail 100
Get-WinEvent -LogName Application -MaxEvents 100 |
  Where-Object ProviderName -Like '*Catalog.Sync.Worker*'
```

Les fichiers `catalog-sync-YYYY-MM-DD.log` constituent le diagnostic principal. Ils sont écrits en UTF-8, changent quotidiennement et les fichiers dont la dernière écriture dépasse `RetentionDays` sont supprimés lors du démarrage ou d'une rotation. En console, un chemin relatif part du `ContentRoot`; sous le SCM, il part de `C:\ProgramData\GEH\ProductCatalogSync`.

`AddWindowsService` permet aussi la remontée des événements Windows via les mécanismes standards du host. Le service ne dépend toutefois pas de l'Event Viewer : les fichiers restent disponibles si le journal Windows est restreint.

Le Worker journalise l'environnement, le mode, l'URL de base WordPress, le type de source et la cadence. Il ne journalise jamais le nom d'utilisateur, l'Application Password ni l'en-tête `Authorization`.

## Mise à jour

La publication versionnée, le package SHA-256, la sauvegarde, la mise à jour sûre et le rollback sont détaillés dans [Mise à jour et rollback du Worker](worker-update.md). Les scripts OPS 2 remplacent la procédure manuelle de copie ; ils ne constituent pas un auto-updater et restent déclenchés explicitement par un administrateur.

## Désinstallation

Dans un PowerShell administrateur :

```powershell
.\scripts\uninstall-worker-service.ps1
```

Le script arrête puis supprime uniquement le service. Les binaires, le fichier d'environnement source et les journaux sont conservés pour permettre un diagnostic ou une réinstallation. La copie des variables attachée à l'enregistrement Windows disparaît avec le service.

## Compte de service, gMSA et futur Sage

`LocalService` suffit à tester la source JSON et un WordPress accessible en HTTPS. Pour le déploiement client, l'administrateur choisira un compte Windows dédié ou, si Active Directory le permet, un gMSA. Aucun identifiant Windows n'est codé dans l'application.

Lors de l'arrivée de Sage, les droits SQL minimaux seront accordés à cette identité. Ce lot n'ajoute ni `SqlProductSource`, ni requête SQL Server, ni credential Sage.
