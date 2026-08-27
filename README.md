# Product Catalog Sync — Lot 1

Ce dépôt implémente une première chaîne fonctionnelle de synchronisation de produits fictifs vers WordPress. Le but du Lot 1 est de valider le contrat produit, l’envoi authentifié, l’upsert dans des tables dédiées et la lecture publique paginée, sans connexion à Sage et sans frontend.

## Architecture

```text
fixtures/products.json (60 produits déterministes)
        ↓
JsonProductSource derrière IProductSource
        ↓
Worker .NET 10 (ponctuel ou continu)
        ↓ Basic Auth + Application Password
POST /wp-json/catalog-sync/v1/products
        ↓
Plugin Product Catalog Sync
        ↓
wp_catalog_products + wp_catalog_sync_runs
        ↓
GET /wp-json/catalog/v1/products?page=1&per_page=24
```

WordPress est un miroir public. L’ERP restera la source de vérité. Dans l’architecture cible, le Worker sera installé dans le réseau interne et n’effectuera que des connexions HTTPS sortantes. Aucune connexion entrante vers le futur serveur Sage n’est prévue.

Le Worker s’appuie sur `IProductSource`. Le Lot 1 fournit `JsonProductSource`; une source Sage pourra être ajoutée plus tard sans modifier la validation, l’orchestration ou le client WordPress.

Le plugin n’utilise ni `wp_posts`, ni `wp_postmeta`, ni le thème. Il crée :

- `{prefix}catalog_products`, avec un identifiant source unique et les index nécessaires à la liste publique ;
- `{prefix}catalog_sync_runs`, pour le résultat de chaque synchronisation acceptée ;
- le rôle technique `catalog_sync` et la capacité minimale `catalog_sync_write`.

La route privée exige une authentification WordPress valide et cette capacité. La route de lecture est publique, limitée à 24 produits par page et ordonnée par nom puis référence.

## Prérequis

- Windows avec PowerShell 5.1 ou PowerShell 7 ;
- Docker Desktop démarré, avec Docker Compose v2 ;
- SDK .NET 10 pour construire, tester et exécuter le Worker ;
- le port local `8080` disponible, ou un autre port configuré de façon cohérente dans `.env`.

Installez le SDK .NET 10 depuis la [page officielle .NET](https://dotnet.microsoft.com/download/dotnet/10.0), puis vérifiez sa présence :

```powershell
dotnet --list-sdks
```

La liste doit contenir au moins une version `10.0.x`.

PHP et MariaDB n’ont pas besoin d’être installés sur l’hôte : Docker fournit WordPress, MariaDB et WP-CLI. Un binaire PHP local reste utile, mais facultatif, pour lancer directement `php -l`.

`run-worker-local.ps1` préfère une installation locale dans `.dotnet/dotnet.exe` à la racine du dépôt, puis utilise `dotnet` dans `PATH`. Dans les deux cas, il vérifie qu’un SDK .NET 10 est disponible. Le répertoire `.dotnet` est ignoré par Git.

## Structure du dépôt

```text
ProductCatalogSync.sln
├── fixtures/products.json                 # 60 produits fictifs
├── src/Catalog.Contracts                  # contrat JSON indépendant de Sage
├── src/Catalog.Sync.Worker                # source JSON, validation et client HTTP
├── tests/Catalog.Sync.Worker.Tests        # tests xUnit déterministes
├── wordpress/product-catalog-sync         # plugin autonome
├── scripts/bootstrap-local.ps1            # installation locale idempotente
├── scripts/run-worker-local.ps1           # exécution avec la configuration locale
├── scripts/smoke-test.ps1                  # contrôle de bout en bout
├── docker-compose.yml
└── docs/decisions/0001-lot-1-architecture.md
```

## Démarrage local avec Docker

Depuis la racine du dépôt, créez d’abord la configuration Docker locale :

```powershell
Copy-Item .env.example .env
notepad .env
```

Les valeurs de `.env.example` ne sont que des exemples destinés à une machine locale. `.env` est ignoré par Git.

Lancez ensuite le bootstrap :

```powershell
.\scripts\bootstrap-local.ps1
```

Si `.env` est absent, le script le crée automatiquement depuis `.env.example`. Le bootstrap :

1. vérifie Docker et Docker Compose ;
2. démarre MariaDB et WordPress et attend leurs healthchecks ;
3. installe WordPress si nécessaire ;
4. active le plugin monté depuis `wordpress/product-catalog-sync` ;
5. crée ou remet à jour l’utilisateur technique `catalog_sync` ;
6. crée une Application Password dédiée au Worker ;
7. écrit `.env.worker.local` sans afficher le secret.

Le script est conçu pour être relancé. Tant que `.env.worker.local` et l’Application Password correspondante existent, il conserve le secret déjà créé.

Le service Compose `wpcli` fixe explicitement son entrypoint à `wp`. Cette correction évite que `docker compose run ... wpcli core ...` tente d’exécuter directement une commande nommée `core`. Elle n’a pas été validée sur une installation WordPress vierge afin de préserver les volumes locaux fonctionnels.

Si le bootstrap s’interrompt néanmoins après le démarrage des conteneurs, terminez l’installation avec l’assistant à <http://localhost:8080>, activez **Product Catalog Sync** dans l’administration, puis créez l’utilisateur technique avec le rôle `catalog_sync` et son Application Password depuis l’interface WordPress. Reportez uniquement ces valeurs dans `.env.worker.local`, qui est ignoré par Git. Ne placez aucun secret dans le README ou dans un fichier suivi.

Le montage du plugin est direct : une modification PHP locale est visible dans le conteneur sans reconstruire d’image. Les volumes `wordpress_data` et `mariadb_data` conservent les données entre les redémarrages.

Pour consulter l’état ou les journaux :

```powershell
docker compose --env-file .env ps
docker compose --env-file .env logs -f wordpress db
```

WordPress est disponible sur <http://localhost:8080> avec les valeurs d’exemple.

## Exécution du Worker

Une seule synchronisation :

```powershell
.\scripts\run-worker-local.ps1 -RunOnce
```

Mode continu, avec une première synchronisation immédiate puis une attente de 15 minutes par défaut :

```powershell
.\scripts\run-worker-local.ps1
```

Le script charge `.env.worker.local` dans les variables d’environnement .NET puis exécute le projet. `Ctrl+C` demande un arrêt propre en mode continu.

Après avoir positionné vous-même les variables nécessaires, la commande directe équivalente est :

```powershell
dotnet run --project .\src\Catalog.Sync.Worker -- --run-once
```

Les paramètres peuvent être surchargés avec la convention .NET :

```text
WordPress__BaseUrl
WordPress__SyncEndpoint
WordPress__Username
WordPress__ApplicationPassword
WordPress__RequestTimeoutSeconds
WordPress__AllowInsecureHttpForLocalDevelopment
ProductSource__JsonFilePath
Sync__IntervalMinutes
```

Le Worker refuse une URL HTTP hors du développement local explicitement autorisé. Il ne journalise ni l’Application Password, ni l’en-tête `Authorization`, ni les identifiants complets.

## API publique

La première synchronisation doit produire trois pages : 24, 24 et 12 produits.

PowerShell :

```powershell
$page1 = Invoke-RestMethod 'http://localhost:8080/wp-json/catalog/v1/products?page=1&per_page=24'
$page1.items.Count
$page1.pagination
```

Avec curl :

```powershell
curl.exe "http://localhost:8080/wp-json/catalog/v1/products?page=1&per_page=24"
```

La réponse contient `items` et :

```json
{
  "pagination": {
    "page": 1,
    "perPage": 24,
    "totalItems": 60,
    "totalPages": 3
  }
}
```

`page` doit être supérieur ou égal à 1. `per_page` vaut 24 par défaut et ne peut pas dépasser 24. Une page au-delà de la dernière retourne HTTP 200 avec `items: []` et les totaux corrects.

La route privée est :

```text
POST /wp-json/catalog-sync/v1/products
```

Un appel anonyme reçoit 401 ou 403. Pour éviter d’exposer l’Application Password dans l’historique du terminal, utilisez le Worker plutôt qu’une commande curl contenant le secret.

## Build et tests .NET

```powershell
dotnet restore .\ProductCatalogSync.sln
dotnet build .\ProductCatalogSync.sln --no-restore
dotnet test .\ProductCatalogSync.sln --no-build
```

Les tests xUnit ne dépendent pas de Docker. Ils couvrent la source JSON, la validation, le client HTTP avec un faux `HttpMessageHandler` et le mode `--run-once`.

## Vérification PHP

Avec PHP installé sur l’hôte :

```powershell
Get-ChildItem .\wordpress\product-catalog-sync -Recurse -Filter *.php |
    ForEach-Object { php -l $_.FullName }
```

Ou dans le conteneur WP-CLI, après le bootstrap :

```powershell
docker compose --env-file .env --profile tools run --rm --no-deps --entrypoint php wpcli `
    -l /var/www/html/wp-content/plugins/product-catalog-sync/product-catalog-sync.php
```

## Smoke test de bout en bout

Une fois Docker démarré et le bootstrap terminé :

```powershell
.\scripts\smoke-test.ps1
```

Le script :

- vérifie que WordPress répond ;
- exige le refus du POST anonyme ;
- synchronise les 60 produits ;
- vérifie les pages de 24, 24 et 12 éléments, `totalItems = 60` et `totalPages = 3` ;
- vérifie que les 60 identifiants source sont distincts ;
- relance la synchronisation et confirme que le total reste égal à 60.

Toute erreur produit un message indiquant l’étape concernée et un code de sortie non nul.

## Arrêt et réinitialisation

Arrêter les conteneurs sans perdre les données :

```powershell
docker compose --env-file .env down
```

La commande suivante supprime volontairement la base et les fichiers WordPress persistés :

```powershell
docker compose --env-file .env down --volumes
Remove-Item .env.worker.local -ErrorAction SilentlyContinue
.\scripts\bootstrap-local.ps1
```

Conservez `.env` si vous souhaitez réutiliser les mêmes paramètres locaux. Après la suppression des volumes, supprimez aussi `.env.worker.local` afin que le bootstrap crée une Application Password correspondant à la nouvelle installation.

## Problèmes fréquents

### Docker Desktop ne répond pas

Le bootstrap s’arrête sur `docker info`. Démarrez Docker Desktop, attendez que le moteur soit prêt, puis relancez le script.

### Le port 8080 est occupé

Modifiez ensemble `WORDPRESS_PORT` et `WORDPRESS_SITE_URL` dans `.env`, par exemple `8081` et `http://localhost:8081`, puis réinitialisez l’installation si WordPress avait déjà enregistré l’ancienne URL.

### WordPress reste indisponible

Inspectez les services et leurs journaux :

```powershell
docker compose --env-file .env ps
docker compose --env-file .env logs wordpress db
```

Un premier téléchargement d’images peut prendre plusieurs minutes. Vérifiez aussi que Docker Desktop autorise le partage du lecteur contenant le dépôt, nécessaire au montage du plugin.

### L’Application Password est refusée en HTTP local

Le Compose définit `WP_ENVIRONMENT_TYPE` à `local`, ce qui autorise les Application Passwords sur `http://localhost`. Cette tolérance ne doit jamais être reproduite en production : utilisez HTTPS et désactivez `AllowInsecureHttpForLocalDevelopment`.

### Le Worker ne trouve pas `products.json`

Relancez `bootstrap-local.ps1`. Il écrit un chemin absolu vers `fixtures/products.json` dans `.env.worker.local`. N’utilisez jamais un chemin interne ou réseau dans un payload public.

### Le secret local ne correspond plus à WordPress

Cela peut arriver après une réinitialisation des volumes. Supprimez `.env.worker.local`, puis relancez le bootstrap pour générer une nouvelle Application Password.

### Une modification de schéma du plugin n’apparaît pas

La simple modification d’un fichier PHP est immédiatement montée. Pour rejouer l’activation et `dbDelta` :

```powershell
docker compose --env-file .env run --rm wpcli plugin deactivate product-catalog-sync
docker compose --env-file .env run --rm wpcli plugin activate product-catalog-sync
```

La désactivation ne supprime aucune donnée.

## Gestion des secrets

Les fichiers `.env` et `.env.worker.local` sont ignorés par Git. `.env.example` ne contient que des valeurs d’exemple locales. Ne commitez jamais :

- mot de passe MariaDB ou WordPress réel ;
- Application Password ;
- en-tête HTTP `Authorization` ;
- identifiant ou chemin du réseau interne.

En production, fournissez les paramètres par le mécanisme sécurisé de la plateforme d’exécution et utilisez exclusivement HTTPS. Le fichier JSON de ce lot ne contient ni prix, ni stock, ni donnée sensible.

Avant tout partage du dépôt, un contrôle simple des fichiers suivis est recommandé :

```powershell
git status --short
git grep -n -I -E "ApplicationPassword|Authorization|password"
```

Les mentions de configuration ou les valeurs factices de `.env.example` sont attendues ; tout secret réel doit être retiré et révoqué.

## Limites volontaires du Lot 1

Ce lot ne fournit pas :

- de connexion Sage ou SQL Server, ni de schéma Sage supposé ;
- d’installation en service Windows, de gMSA ou de stratégie de redémarrage ;
- de frontend React ou de page visuelle WordPress ;
- de recherche, filtre, tri configurable ou route de détail ;
- d’image, miniature, pictogramme, PDF ou fiche technique ;
- de prix, stock ou donnée confidentielle ;
- de synchronisation par lots ou différentielle, de mode `dry-run` ou de file de commandes ;
- de désactivation des produits absents, de nettoyage ou d’administration éditoriale ;
- de SEO ou de multilingue.

Le Lot 1 envoie au maximum 500 produits dans une requête et ne désactive pas ceux qui sont absents du payload.

## Lots suivants

Les évolutions prévues pourront ajouter, sans modifier le contrat public :

- une implémentation Sage de `IProductSource` dans le réseau interne ;
- l’hébergement du Worker comme service Windows avec HTTPS sortant uniquement ;
- la synchronisation par lots, différentielle et les reprises contrôlées ;
- la désactivation des produits absents ;
- le frontend React, puis la recherche, les filtres, les images et les fiches techniques selon les lots validés.

La décision d’architecture est détaillée dans [docs/decisions/0001-lot-1-architecture.md](docs/decisions/0001-lot-1-architecture.md).
