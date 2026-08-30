# Product Catalog Sync — Lot 3A

Ce dépôt implémente un miroir public WordPress alimenté par un Worker .NET 10. Le Lot 2 fiabilise la synchronisation avec un cycle explicite `start → batches → complete`. Le Lot 3A ajoute une page catalogue React/TypeScript intégrée au plugin WordPress, sans dépendance à Sage et sans serveur Node en production.

La règle de sécurité centrale est la suivante : une synchronisation vide, incomplète, en erreur ou jugée dangereuse ne désactive aucun produit. L’ERP restera à terme l’unique source de vérité ; le Lot 2 utilise toujours des fixtures JSON et ne contient aucun code Sage ou SQL Server.

## Architecture

```text
fixtures JSON
      ↓
JsonProductSource derrière IProductSource
      ↓ validation, normalisation et SHA-256
Worker .NET 10
      ↓ HTTPS sortant (HTTP local explicitement autorisé)
POST /wp-json/catalog-sync/v1/runs
      ↓
POST /wp-json/catalog-sync/v1/runs/{runId}/products
      ↓
POST /wp-json/catalog-sync/v1/runs/{runId}/complete
      ↓
Tables WordPress dédiées
      ↓
GET /wp-json/catalog/v1/products?page=1&per_page=24
      ↓
Frontend React statique chargé par [product_catalog]
```

Le futur serveur Sage restera dans le réseau interne et n’acceptera aucune connexion entrante depuis Internet. Une source Sage pourra être ajoutée derrière `IProductSource` sans exposer de noms de tables Sage au contrat public.

Le plugin ne modifie ni le cœur WordPress, ni le thème, ni `wp_posts`, ni `wp_postmeta`. Il utilise :

- `{prefix}catalog_products` pour le miroir produit ;
- `{prefix}catalog_sync_runs` pour l’historique et les compteurs ;
- `{prefix}catalog_sync_batches` pour l’idempotence de chaque batch ;
- `{prefix}catalog_sync_run_items` pour les produits vus et le delta d’un run ;
- le rôle `catalog_sync` et la capacité minimale `catalog_sync_write`.

## Cycle d’un run

```text
START
  ↓
BATCHES
  ↓
VALIDATION
  ↓
GUARDRAILS
  ↓
COMPLETE

ERROR / INTERRUPTION / SOURCE VIDE
  ↓
NO DEACTIVATION
```

### Démarrage

Le Worker génère le UUID et l’envoie à WordPress :

```http
POST /wp-json/catalog-sync/v1/runs
```

```json
{
  "runId": "71c7ea7a-55c4-4fc0-a721-6ac4cd8e3280",
  "schemaVersion": 2,
  "expectedProductCount": 60,
  "expectedBatchCount": 1,
  "source": "json-fixture",
  "dryRun": false
}
```

Un replay avec le même `runId` et les mêmes paramètres est idempotent tant que le run est `started` ou `running`. Le même UUID avec des paramètres différents répond HTTP 409. Un UUID arrivé à un état terminal (`completed`, `failed` ou `rejected`) n’est jamais réutilisé et répond HTTP 409 ; le replay du rejet initial d’une source vide reproduit le rejet HTTP 422 sans créer de second run.

WordPress refuse un second run actif. À la création suivante, un run sans activité depuis plus de 30 minutes est marqué `failed`, puis libère le passage. Le Worker possède en plus un verrou local non bloquant pour empêcher deux synchronisations dans le même processus.

### Batches idempotents

```http
POST /wp-json/catalog-sync/v1/runs/{runId}/products
```

Le Worker utilise `Sync:BatchSize`, égal à 200 par défaut et limité à 500. WordPress limite également chaque batch à 500 produits. La clé unique `(run_uuid, batch_number)` et un hash du payload permettent de rejouer exactement un batch sans réappliquer les produits ni recompter ses résultats. Le même numéro avec un contenu différent répond HTTP 409.

Les insertions et mises à jour d’un batch sont transactionnelles. Si le Worker est interrompu après quelques batches, certaines valeurs déjà reçues peuvent être visibles, mais aucune désactivation n’a lieu avant `complete`.

### Hash et produits inchangés

Le Worker calcule un SHA-256 déterministe sur :

```text
sourceId, reference, name, shortDescription,
familyCode, familyLabel, brand
```

Les dates techniques, le `runId` et `sourceUpdatedAtUtc` ne participent pas au hash. WordPress recalcule et vérifie le hash après normalisation. Si le hash stocké est identique, aucune colonne métier ni `updated_at` n’est réécrite ; seules les informations techniques de présence et de synchronisation sont actualisées, et le produit est compté comme `unchanged`.

Lors de la première synchronisation après migration du Lot 1, les anciens produits sans `content_hash` sont comparés avec un hash recalculé depuis leur contenu. Une fixture identique peut donc être comptée immédiatement comme inchangée.

### Finalisation et garde-fou

```http
POST /wp-json/catalog-sync/v1/runs/{runId}/complete
```

La finalisation vérifie le nombre déclaré, le total reçu, le nombre et la continuité des batches, ainsi que l’unicité des produits vus. Un run incomplet devient `failed` et ne désactive rien.

Pour un run complet, WordPress calcule les produits actifs absents. Le nombre d’actifs de référence est figé au démarrage du run. Si le pourcentage de désactivation dépasse 30 % par défaut, le run devient `rejected` et aucune désactivation n’est appliquée. Une source de zéro produit est rejetée dès le démarrage. Les seuils sont centralisés dans `Sync_Config` et peuvent être adaptés par filtres WordPress :

```text
product_catalog_sync_max_batch_products
product_catalog_sync_max_deactivation_percentage
product_catalog_sync_run_timeout_minutes
product_catalog_sync_history_retention_days
```

Un produit absent est conservé avec `is_active = 0`. S’il revient dans un run ultérieur, il est automatiquement réactivé et compté dans `reactivated_count`.

### Dry-run

Le dry-run crée un journal, des batches et des éléments de run afin de calculer le delta avec les données WordPress actuelles. Il n’écrit aucune colonne de `catalog_products` : aucune insertion, mise à jour, activation ou désactivation n’est appliquée.

Le résultat indique les nouveaux, modifiés, inchangés, à réactiver, à désactiver, le pourcentage et l’état du garde-fou.

### Retries et historique

Le client HTTP effectue au plus trois tentatives avec un délai croissant sur les erreurs réseau, timeouts, et HTTP 408, 429, 500, 502, 503 ou 504. Il ne retente pas les erreurs 400, 401, 403 ou 404. Chaque tentative reconstruit la requête avec le même `runId` ou le même batch, ce qui rend un accusé de réception perdu rejouable.

Les runs terminaux de plus de 90 jours sont nettoyés opportunément, par groupes bornés, après une finalisation réussie. Ce nettoyage ne touche jamais aux produits.

## Prérequis

- Windows avec PowerShell 5.1 ou PowerShell 7 ;
- Docker Desktop et Docker Compose v2 ;
- SDK .NET 10 ;
- port `8080` disponible, sauf configuration locale cohérente différente.

Installez .NET 10 depuis la [page officielle .NET](https://dotnet.microsoft.com/download/dotnet/10.0), puis vérifiez :

```powershell
dotnet --list-sdks
```

PHP et MariaDB sont fournis par Docker. Aucun Composer ni framework PHP supplémentaire n’est nécessaire.

## Structure

```text
ProductCatalogSync.sln
├── fixtures/
│   ├── products.json
│   ├── products-update.json
│   ├── products-reactivation.json
│   ├── products-dangerous.json
│   ├── products-empty.json
│   └── products-duplicate-source-id.json
├── src/Catalog.Contracts
├── src/Catalog.Sync.Worker
├── tests/Catalog.Sync.Worker.Tests
├── frontend                             # React, TypeScript, Vite et tests Vitest
├── wordpress/product-catalog-sync
├── scripts/bootstrap-local.ps1
├── scripts/run-worker-local.ps1
├── scripts/smoke-test.ps1
├── scripts/smoke-test-lot2.ps1
├── scripts/smoke-test-lot3a.ps1
└── docs/decisions/
```

## Démarrage local

Créez la configuration locale Docker :

```powershell
Copy-Item .env.example .env
notepad .env
```

`.env.example` contient uniquement des valeurs fictives locales. `.env` et `.env.worker.local` sont ignorés par Git.

Lancez ensuite :

```powershell
.\scripts\bootstrap-local.ps1
```

Le bootstrap démarre MariaDB et WordPress, installe WordPress si nécessaire, active le plugin, crée l’utilisateur technique et son Application Password, puis génère `.env.worker.local` sans afficher le secret. Il est conçu pour conserver un secret local déjà valide lors d’une relance.

Le service `wpcli` possède l’entrypoint explicite `wp`. Si le bootstrap échoue après le démarrage, l’installation peut être terminée depuis <http://localhost:8080> : activez **Product Catalog Sync**, créez un utilisateur au rôle `catalog_sync`, créez son Application Password, puis renseignez uniquement `.env.worker.local`.

Le plugin est monté directement dans WordPress ; aucune image Docker ne doit être reconstruite. Les volumes Docker conservent WordPress et MariaDB entre les redémarrages.

## Migration Lot 1 vers Lot 2

Le plugin porte une version de schéma interne. Au premier chargement de la version 0.2.0, `dbDelta` ajoute les colonnes et tables du Lot 2 à l’installation active. La migration ne supprime, ne renomme et ne tronque aucune table ou ligne du Lot 1. Il n’est pas nécessaire de désactiver le plugin ni de réinstaller WordPress.

## Exécuter le Worker

Fixture par défaut, une seule fois :

```powershell
.\scripts\run-worker-local.ps1 -RunOnce
```

Choisir une fixture :

```powershell
.\scripts\run-worker-local.ps1 -RunOnce -ProductFile .\fixtures\products-update.json
```

Dry-run utilisant les données WordPress actuelles :

```powershell
.\scripts\run-worker-local.ps1 -RunOnce -DryRun -ProductFile .\fixtures\products-update.json
```

Mode continu, première synchronisation immédiate puis toutes les 15 minutes :

```powershell
.\scripts\run-worker-local.ps1
```

Commande .NET directe, après avoir fourni les variables d’environnement :

```powershell
dotnet run --project .\src\Catalog.Sync.Worker -- --run-once
dotnet run --project .\src\Catalog.Sync.Worker -- --run-once --dry-run
```

Principales surcharges de configuration :

```text
WordPress__BaseUrl
WordPress__RunsEndpoint
WordPress__Username
WordPress__ApplicationPassword
WordPress__RequestTimeoutSeconds
WordPress__MaxRetryAttempts
WordPress__RetryBaseDelayMilliseconds
WordPress__AllowInsecureHttpForLocalDevelopment
ProductSource__JsonFilePath
Sync__IntervalMinutes
Sync__BatchSize
```

`WordPress__SyncEndpoint`, utilisé par le Lot 1, reste toléré dans un ancien fichier local mais n’est plus utilisé. Le Worker refuse HTTP hors d’une URL loopback explicitement autorisée et ne journalise jamais les secrets ou l’en-tête `Authorization`.

## Fixtures Lot 2

| Fixture | Résultat prévu depuis l’étape précédente |
|---|---|
| `products.json` | 60 produits actifs |
| `products-update.json` | 2 absents, 2 ajouts, 3 modifiés, 55 inchangés, toujours 60 actifs |
| `products-reactivation.json` | 2 réactivés, 60 inchangés, 62 actifs |
| `products-dangerous.json` | 5 produits seulement, rejet du garde-fou, 62 actifs conservés |
| `products-empty.json` | rejet immédiat, catalogue conservé |
| `products-duplicate-source-id.json` | doublon détecté avant l’appel WordPress |

Lors d’une seconde exécution complète du smoke test, les identifiants `MOCK-0061` et `MOCK-0062` existent déjà dans l’historique et sont réactivés plutôt qu’insérés ; le catalogue public attendu reste identique.

## API publique

```http
GET /wp-json/catalog/v1/products?page=1&per_page=24&search=outil&family=FAM-OUT&brand=Novatool
GET /wp-json/catalog/v1/filters
GET /wp-json/catalog/v1/products/{id}
```

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

`page` commence à 1, `per_page` vaut 24 par défaut et ne dépasse jamais 24. La pagination reste réalisée en SQL. `search` est limité à 100 caractères et recherche dans la référence, le nom, la marque et le libellé de famille. `family` filtre exactement le code famille et `brand` la marque ; les trois critères sont combinables.

`filters` retourne les familles et marques distinctes des seuls produits actifs. Le détail utilise l’ID opaque de la ligne miroir, indépendant de Sage. Les produits `is_active = 0` ne sont retournés ni par la liste, ni par les facettes, ni par le détail. Une page hors limites répond HTTP 200 avec `items: []` et les totaux corrects ; un détail absent ou inactif répond HTTP 404.

Les trois routes d’écriture privées exigent une Application Password valide et `catalog_sync_write`. Un appel anonyme reçoit 401 ou 403. Aucun CORS permissif n’est ajouté.

## Frontend catalogue

Le code source se trouve dans `frontend/`. Le build Vite produit deux fichiers statiques déterministes dans `wordpress/product-catalog-sync/assets/dist/` :

```text
catalog.js
catalog.css
```

React est monté par le shortcode WordPress suivant :

```text
[product_catalog]
```

Les assets ne sont chargés que sur une page contenant le shortcode. WordPress transmet au bundle la base REST et l’URL du placeholder local ; aucun domaine localhost, préproduction ou production n’est compilé dans le frontend.

Le catalogue propose les cartes, la recherche différée de 350 ms, les filtres famille/marque, une pagination condensée, le détail produit, le retour à la liste et les états loading/error/empty. Les critères sont conservés dans l’URL :

```text
?search=perceuse&family=FAM-OUT&brand=Novatool&page=2&product=42
```

Les anciennes requêtes sont annulées avec `AbortController`. Le CSS est encapsulé sous `geh-catalog-*`, utilise des variables de thème et adapte la grille à quatre, trois, deux puis une colonne. Le type frontend prévoit `imageUrl`; tant qu’aucune image n’est synchronisée, un SVG local est affiché sur la carte et la fiche.

### Développement et build frontend

Node.js 22.12 ou 24 et npm sont recommandés. Depuis la racine :

```powershell
Set-Location .\frontend
npm install
npm run test
npm run build
```

`npm run dev` démarre le serveur de développement Vite et relaie localement `/wp-json` et le placeholder vers WordPress sur `http://localhost:8080`. WordPress utilise toujours les assets générés par `npm run build`; aucun serveur Node n’est nécessaire en production.

### Archive installable du plugin

Le ZIP WordPress est un artefact généré et n’est pas versionné. Après le build frontend, reconstruisez-le depuis la racine avec :

```powershell
Compress-Archive -Path .\wordpress\product-catalog-sync -DestinationPath .\wordpress\product-catalog-sync.zip -Force
```

## Build, tests et lint

```powershell
dotnet restore .\ProductCatalogSync.sln
dotnet build .\ProductCatalogSync.sln --no-restore
dotnet test .\ProductCatalogSync.sln --no-build
```

Les tests xUnit sont déterministes et n’utilisent pas Docker. Ils couvrent notamment validation, source vide, doublons, batching, hash, dry-run, interruption, concurrence locale, sérialisation du `runId`, retries temporaires et absence de retry sur les erreurs client.

Tests et build du frontend :

```powershell
Set-Location .\frontend
npm run test
npm run build
Set-Location ..
```

Les tests Vitest couvrent la lecture et la construction de l’état URL ainsi que la pagination condensée. Le build exécute aussi le contrôle TypeScript strict.

Lint PHP depuis l’hôte, si PHP est installé :

```powershell
Get-ChildItem .\wordpress\product-catalog-sync -Recurse -Filter *.php |
    ForEach-Object { php -l $_.FullName }
```

Ou sans installation locale, avec le conteneur WordPress déjà actif :

```powershell
docker compose exec -T wordpress sh -c "find /var/www/html/wp-content/plugins/product-catalog-sync -name '*.php' -type f -exec php -l {} \;"
```

## Smoke tests

Le contrôle historique du Lot 1 reste disponible :

```powershell
.\scripts\smoke-test.ps1
```

Le scénario Lot 2 modifie volontairement l’état du miroir selon les fixtures, puis termine avec 62 produits actifs. Lancez-le uniquement sur l’environnement local de test :

```powershell
.\scripts\smoke-test-lot2.ps1
```

Il vérifie le run initial, une synchronisation identique, les modifications/désactivations, la réactivation, les rejets dangereux/vide/doublon, le dry-run, le replay de `POST /runs`, le conflit de paramètres et le refus de réutiliser un UUID terminé. Il ne supprime aucune donnée ni aucun volume.

Le smoke test Lot 3A est entièrement public et ne modifie aucune donnée :

```powershell
.\scripts\smoke-test-lot3a.ps1
```

Il vérifie la liste, la pagination serveur, les facettes, la recherche, les filtres famille/marque, leur combinaison, le détail, la réponse 404 et la limite de taille de recherche.

## Validation visuelle du shortcode

1. Dans l’administration WordPress, créez une page intitulée « Catalogue ».
2. Ajoutez un bloc Shortcode contenant `[product_catalog]`, puis publiez ou prévisualisez la page.
3. Vérifiez que 24 produits au maximum apparaissent avec leur référence, nom, marque/famille disponibles et le placeholder.
4. Recherchez un nom ou une référence, puis attendez la fin du debounce.
5. Sélectionnez une famille et une marque, puis vérifiez que l’URL reflète les critères.
6. Changez de page et utilisez le bouton précédent du navigateur.
7. Ouvrez une fiche avec « Voir le produit », puis revenez à la liste.
8. Réduisez la fenêtre aux largeurs tablette et mobile et vérifiez la navigation clavier ainsi que le focus visible.
9. Vérifiez une carte sans marque ou famille et un produit sans description : aucun espace ou contrôle fictif ne doit apparaître.
10. Ouvrez une carte puis sa fiche et vérifiez que le placeholder local est utilisé aux deux tailles.

### UTF-8 sous Windows PowerShell 5.1

Les scripts PowerShell contenant des caractères non ASCII sont enregistrés en UTF-8 avec BOM pour rester correctement interprétés par Windows PowerShell 5.1. Le smoke test Lot 2 lit les fixtures avec `Get-Content -Raw -Encoding UTF8` et énumère explicitement le tableau renvoyé par `ConvertFrom-Json` avant tout filtre ou tri.

Pour les appels REST privés construits directement par le smoke test, le JSON est converti en octets avec `[Text.Encoding]::UTF8.GetBytes(...)` et envoyé avec `application/json; charset=utf-8`. Les assertions sur le résultat du Worker utilisent la ligne structurée ASCII `CATALOG_SYNC_RESULT_V1` et ne dépendent donc pas de l’encodage visuel des logs localisés. Sous certaines configurations de console anciennes, les accents des logs humains peuvent encore être mal affichés sans affecter les validations ni la synchronisation.

## Docker : arrêt et reprise

État et journaux :

```powershell
docker compose --env-file .env ps
docker compose --env-file .env logs -f wordpress db
```

Arrêt sans perte de données, puis redémarrage :

```powershell
docker compose --env-file .env stop
docker compose --env-file .env start
```

Une réinitialisation avec `down --volumes` détruit volontairement WordPress et MariaDB. Elle n’est pas nécessaire pour la migration Lot 2 et ne doit être utilisée qu’après sauvegarde et décision explicite.

## Problèmes fréquents

### Un run est déjà actif

WordPress répond HTTP 409. Attendez la fin du Worker actif. Un run réellement interrompu est déclaré périmé lors d’un nouveau démarrage après 30 minutes ; aucune désactivation n’a lieu pour ce run.

### Le garde-fou rejette une fixture attendue

Le seuil compare les absents au nombre d’actifs figé au démarrage. Utilisez d’abord `-DryRun` pour voir le delta. Ne relevez pas le seuil sans comprendre la différence de source.

### L’Application Password est refusée en HTTP local

Compose définit `WP_ENVIRONMENT_TYPE` à `local`. En production, utilisez exclusivement HTTPS et désactivez `AllowInsecureHttpForLocalDevelopment`.

### Le Worker ne trouve pas une fixture

`-ProductFile` accepte un chemin absolu ou relatif à la racine du dépôt. Sans ce paramètre, `.env.worker.local` fournit normalement le chemin absolu de `products.json`.

### La migration ne semble pas appliquée

Chargez une fois WordPress ou son API. Le hook `plugins_loaded` compare la version de schéma et exécute la migration additive automatiquement. Consultez ensuite les logs WordPress ; ne réinstallez pas WordPress et ne supprimez pas les volumes.

## Gestion des secrets

`.env`, `.env.worker.local`, les variantes locales d’`appsettings` et `Mdp.txt` sont ignorés par Git. `.env.example` ne contient que des valeurs fictives. Ne commitez jamais :

- un mot de passe MariaDB ou WordPress réel ;
- une Application Password ;
- un en-tête `Authorization` ;
- un chemin ou identifiant du réseau interne.

Contrôles recommandés avant partage :

```powershell
git status --short
git ls-files .env .env.worker.local
```

Les fixtures ne contiennent ni prix, ni stock, ni donnée confidentielle.

## Limites volontaires du Lot 3A

Le Lot 3A ne fournit pas de connexion Sage ou SQL Server, gMSA, service Windows, synchronisation d’image, image réelle, PDF, fiche technique, pictogramme, panier, commande, espace client, SEO avancé ou multilingue. Il ne fournit pas non plus de synchronisation différentielle ni de file de commandes WordPress vers le Worker.

Les mises à jour déjà validées par un batch peuvent devenir visibles avant `complete`; la garantie stricte est qu’aucun produit absent n’est désactivé avant une finalisation complète et acceptée.

Les décisions sont détaillées dans [ADR 0001](docs/decisions/0001-lot-1-architecture.md), [ADR 0002](docs/decisions/0002-sync-reliability.md) et [ADR 0003](docs/decisions/0003-frontend-catalog.md).
