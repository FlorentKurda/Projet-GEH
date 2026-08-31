# Mise à jour et rollback du Worker

## Périmètre et prérequis

Cette procédure complète l'[installation du Worker en service Windows](windows-service.md). Elle ne crée pas le service et ne lance aucune mise à jour automatiquement. Une première installation utilise toujours `install-worker-service.ps1`.

Prérequis :

- poste de publication équipé du SDK .NET 10 et de Windows PowerShell 5.1 ou ultérieur ;
- serveur Windows x64 compatible ; aucun runtime .NET, SDK, Visual Studio, Git, Node ou Docker n'est requis pour exécuter le package de production ;
- PowerShell administrateur sur le serveur pour une mise à jour ou un rollback réel ;
- package transféré par un canal approuvé par le SI client : copie manuelle, SFTP, partage sécurisé ou outil d'entreprise.

Les scripts n'automatisent ni FTP, ni SFTP, ni signature Authenticode.

Les exemples ci-dessous sont exécutés depuis la racine du dépôt. Tout chemin relatif fourni explicitement à un paramètre (`PackagePath`, `PublishPath`, `OutputRoot`, `InstallPath`, `BackupRoot`, `BackupPath` ou `HashPath`) est résolu depuis la localisation PowerShell courante retournée par `Get-Location`, et non depuis le dossier du script ou le répertoire courant implicite du processus .NET.

## Version

La source unique de version est la propriété `<Version>` de `src/Catalog.Sync.Worker/Catalog.Sync.Worker.csproj`. La version implicite précédente était `1.0.0`; OPS 2 l'explicite et l'incrémente à `1.1.0`. Pour publier la suivante, modifier cette valeur une seule fois, par exemple vers `1.2.0`, puis exécuter les tests et la publication.

MSBuild génère `AssemblyVersion`, `FileVersion` et `AssemblyInformationalVersion`. Au démarrage, le Worker écrit notamment :

```text
Démarrage Worker. Catalog.Sync.Worker version 1.1.0
```

Les scripts lisent la version MSBuild pendant la publication et `FileVersionInfo` sur l'exécutable publié ou installé. Aucun `version.txt` ni `deployment.json` ne duplique cette source de vérité.

## Publication

Depuis la racine du dépôt :

```powershell
.\scripts\publish-worker.ps1
```

Valeurs par défaut : `Release`, `win-x64`, self-contained (`SelfContained = true`). Le package Windows de production embarque le runtime .NET nécessaire : aucun runtime .NET n'est à installer sur le serveur cible. La sortie est :

```text
artifacts\worker\releases\<version>\win-x64\
```

Le script vérifie le SDK, lit la version MSBuild, nettoie uniquement le dossier exact de cette version/runtime, exécute `dotnet publish`, valide l'exécutable, puis affiche version, chemin et taille. Il ne lit et ne copie aucun fichier `.env`.

Pour un diagnostic volontairement framework-dependent, `publish-worker.ps1 -SelfContained:$false` produit un dossier séparé `win-x64-framework-dependent` afin de ne pas écraser la publication autonome. Le packager de production refuse cette variante.

`PublishSingleFile` et `PublishTrimmed` restent désactivés. Le format multi-fichiers est plus transparent pour les contrôles, sauvegardes et rollbacks, et le trimming n'est pas activé sans campagne de compatibilité démontrant que les bibliothèques du Worker le supportent.

Mesure de référence pour la version `1.1.0` en `Release/win-x64` : la publication framework-dependent contient 41 fichiers et occupe 2,57 MiB ; la publication self-contained contient 228 fichiers, PDB compris, et occupe 79,06 MiB. Le surcoût décompressé est de 76,49 MiB. Après exclusion des deux PDB, le ZIP de production contient 226 fichiers et occupe 34,80 MiB. Ces valeurs pourront varier avec les versions du runtime .NET.

## Package et SHA-256

Créer l'archive après publication :

```powershell
.\scripts\package-worker.ps1
```

Sorties :

```text
artifacts\packages\GEHProductCatalogSync-<version>-win-x64.zip
artifacts\packages\GEHProductCatalogSync-<version>-win-x64.zip.sha256
```

Le ZIP autonome contient uniquement l'exécutable, les DLL applicatives et runtime, les JSON nécessaires, `appsettings.json`, les fichiers `deps`/`runtimeconfig` et `fixtures\products.json`. Les PDB, sources, tests, logs, archives, fixtures de charge et configurations locales sont exclus.

Le packaging refuse également les fichiers de credential et toute valeur non vide associée à un nom de propriété sensible (`Password`, `Secret`, `Token`, `Username` ou `ConnectionString`) dans `appsettings*.json`.

Le fichier `.sha256` est généré avec SHA-256. `update-worker-service.ps1` le vérifie automatiquement s'il accompagne le ZIP, ou via `-HashPath`. Sans fichier hash, le script avertit explicitement avant de continuer ; pour une intervention client, transférer toujours les deux fichiers.

`artifacts/` est ignoré par Git : ni le ZIP ni son hash ne doivent être commités.

## Dossiers de production

```text
C:\Program Files\GEH\ProductCatalogSync\
    binaires et configuration versionnée

C:\ProgramData\GEH\ProductCatalogSync\
    logs\
    backups\
    deployment.lock (uniquement pendant une opération)
```

Les journaux et backups ne sont jamais placés dans le package. Les variables d'environnement du service restent dans la configuration Windows du service et ne sont ni copiées ni affichées.

## Simulation de mise à jour

Depuis la racine du dépôt, dans un PowerShell normal ou administrateur :

```powershell
.\scripts\update-worker-service.ps1 `
  -PackagePath '.\artifacts\packages\GEHProductCatalogSync-1.1.0-win-x64.zip' `
  -DryRun
```

Le DryRun exige que le service, l'installation et le package existent. Il vérifie le hash, le payload et les versions, puis affiche `BACKUP`, `STOP`, `COPY`, `START`, `CHECK` et `RETENTION`. Les extractions temporaires sont supprimées ; aucun backup, verrou, remplacement ou appel à `Stop-Service`/`Start-Service` n'est effectué.

## Mise à jour réelle

Dans un PowerShell administrateur :

```powershell
.\scripts\update-worker-service.ps1 `
  -PackagePath 'C:\Transfert\GEHProductCatalogSync-1.1.0-win-x64.zip'
```

Le processus est strictement le suivant :

1. vérifier Windows, les droits administrateur et l'existence du service ;
2. vérifier package, SHA-256, contenu et exécutable ;
3. lire ancienne et nouvelle versions ;
4. refuser une version identique, sauf `-Force` ;
5. refuser une version plus ancienne, sauf `-AllowDowngrade` ;
6. préparer et valider un staging filtré ;
7. acquérir `deployment.lock` pour empêcher deux opérations simultanées ;
8. sauvegarder les fichiers déployables dans un backup horodaté ;
9. arrêter le service s'il était Running et attendre Stopped ;
10. si demandé, exécuter la validation `--run-once --dry-run` pendant que le service normal est arrêté ;
11. supprimer uniquement les anciens fichiers déployables, puis copier le staging ;
12. relire la version installée et valider le payload ;
13. redémarrer uniquement si le service était initialement Running ;
14. attendre Running puis vérifier sa stabilité pendant 5 secondes ;
15. valider le déploiement, puis appliquer la rétention des backups ;
16. libérer le verrou et supprimer le staging.

Une mise à jour directe depuis une publication est aussi possible avec `-PublishPath`, mais le ZIP et son SHA-256 sont recommandés pour tout transfert.

Si le service était Stopped, il reste Stopped. Dans ce cas, le contrôle porte sur l'intégrité et la version des fichiers ; le démarrage sera effectué ultérieurement par l'exploitant.

## Validation run-once optionnelle

`-ValidateWithRunOnce` lance le nouvel exécutable avant installation avec `--run-once --dry-run` et l'environnement attaché au service. Le service normal est alors arrêté pour éviter deux exécutions concurrentes ; si la validation échoue, la version installée n'est pas remplacée et l'état initial du service est restauré. Cette option n'est jamais active par défaut, car elle contacte le WordPress configuré. Ne l'utiliser qu'après autorisation explicite sur la cible concernée :

```powershell
.\scripts\update-worker-service.ps1 `
  -PackagePath 'C:\Transfert\GEHProductCatalogSync-1.1.0-win-x64.zip' `
  -ValidateWithRunOnce
```

Aucun mot de passe n'est passé sur la ligne de commande ou affiché.

## Backup et rétention

Avant remplacement, le script crée :

```text
C:\ProgramData\GEH\ProductCatalogSync\backups\yyyy-MM-dd_HHmmss_<version>\
```

Le backup contient les binaires et la configuration versionnée nécessaires au rollback. Il exclut `.env*`, `*.local.json`, logs, sources et tests. Les secrets externes ne sont donc pas dupliqués.

Après un déploiement réussi seulement, les 5 derniers backups sont conservés par défaut. `-BackupRetention` ajuste cette valeur. Le backup de l'opération courante est protégé pendant le nettoyage. Les dossiers `failed_*`, créés pour diagnostic lors d'un rollback manuel, ne sont pas supprimés par cette rétention.

## Rollback automatique

`RollbackOnFailure` vaut `true` par défaut. Si la copie, la validation de version, le démarrage ou la stabilité échoue après le début du remplacement, le script :

1. arrête le service si nécessaire ;
2. restaure le backup créé juste avant la mise à jour ;
3. restaure l'état initial Running ou Stopped ;
4. affiche clairement le résultat.

Exemples de console :

```text
Déploiement échoué.
Rollback vers version 1.0.0.
Rollback réussi vers version 1.0.0.
```

Un échec de rollback affiche `ROLLBACK ÉCHOUÉ — intervention manuelle requise` et l'erreur initiale reste en échec non zéro.

## Rollback manuel

Lister les backups sans modifier le système :

```powershell
.\scripts\rollback-worker-service.ps1 -List
```

Simuler un rollback :

```powershell
.\scripts\rollback-worker-service.ps1 `
  -Version '1.0.0' `
  -DryRun
```

Exécuter le rollback dans un PowerShell administrateur :

```powershell
.\scripts\rollback-worker-service.ps1 -Version '1.0.0'
```

`-BackupPath` permet de choisir exactement un dossier sous le répertoire des backups. Avant restauration, le script conserve la version actuellement installée sous `failed_yyyy-MM-dd_HHmmss_<version>` pour diagnostic. Les logs, variables du service et fichiers locaux sensibles sont préservés.

## Configuration remplacée et préservée

Remplacé par le package :

- exécutables et DLL ;
- `deps.json` et `runtimeconfig.json` ;
- `appsettings.json` et autres JSON versionnés non locaux ;
- fixture de démonstration incluse.

Préservé :

- variables machine et variables attachées au service, y compris les futures sections Sage/SQL ;
- fichiers `.env*` et `*.local.json` éventuellement présents ;
- `C:\ProgramData\GEH\ProductCatalogSync\logs` ;
- backups existants hors rétention post-succès.

La liste des variables d'environnement n'est pas figée par les scripts de mise à jour. Aucun développement Sage n'est inclus.

## Santé, statut et diagnostic

Le health check ne lance aucune synchronisation. Pour un service initialement Running, il attend `Running`, puis vérifie que cet état reste stable quelques secondes. Le timeout se règle avec `-HealthTimeoutSeconds`.

Afficher le statut, la version, le dernier backup et le dernier log :

```powershell
.\scripts\get-worker-deployment-status.ps1
```

Diagnostic complémentaire :

```powershell
Get-Service GEHProductCatalogSync
Get-Content 'C:\ProgramData\GEH\ProductCatalogSync\logs\catalog-sync-*.log' -Tail 100
```

Les scripts journalisent uniquement en console : heure, versions, chemins, backup et transitions du service. Ils n'écrivent aucun secret dans une commande ou un journal de déploiement.

## Échec et intervention

- service absent : utiliser `install-worker-service.ps1`, jamais le script de mise à jour ;
- version identique : utiliser `-Force` uniquement pour une réinstallation volontaire ;
- downgrade : préférer le rollback ; `-AllowDowngrade` exige une décision explicite ;
- lock récent : vérifier qu'aucun autre administrateur ne déploie ; un lock âgé de plus de deux heures est considéré comme abandonné ;
- échec de copie : ne pas démarrer l'installation partielle ; le rollback automatique restaure le backup si activé ;
- échec de démarrage ou de santé : consulter les logs Worker, puis utiliser le rollback automatique ou manuel.

## Désinstallation

La désinstallation reste volontairement séparée :

```powershell
.\scripts\uninstall-worker-service.ps1
```

Elle supprime l'enregistrement du service mais conserve binaires, configuration et logs conformément à la documentation d'installation.

## Pipeline manuel futur

```text
POSTE DEV
git pull
dotnet restore / build / test
publish-worker.ps1
package-worker.ps1 + SHA-256
        ↓ transfert sécurisé choisi par le SI
SERVEUR CLIENT
update-worker-service.ps1 -DryRun
        ↓
backup → stop → copie → start → health
        ↓
OK, ou rollback automatique
```
