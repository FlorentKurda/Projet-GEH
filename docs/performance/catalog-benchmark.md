# LOT PERF 1 — benchmark catalogue

Mesures réalisées le 30 août 2026 avec Docker Desktop local, MariaDB 11.4.5,
WordPress 6.8.2 et le `Sync__BatchSize` courant de 200. Chaque temps HTTP est
mesuré trois fois et présenté sous la forme min / moyenne / max.

Ces résultats décrivent ce poste de développement. Ils ne constituent pas un
SLA ni une extrapolation directe de la production.

## Isolation et reproductibilité

Le catalogue principal reste dans le projet Compose `product-catalog-sync`, sur
le port 8080 et dans ses volumes habituels. Chaque palier utilise un projet et
des volumes dédiés :

- `product-catalog-benchmark-10000` ;
- `product-catalog-benchmark-50000` ;
- `product-catalog-benchmark-100000`.

Le site benchmark écoute sur le port 18080. Le script arrête ses conteneurs à la
fin mais conserve leurs volumes pour permettre l'inspection. Une nouvelle
mesure de « première synchronisation » exige donc une stack benchmark vierge ;
il faut supprimer explicitement uniquement le projet dédié concerné avant de la
rejouer.

Les fixtures générées sont écrites dans `fixtures/load/`, les rapports JSON dans
`artifacts/performance/` et les configurations locales dans
`.env.benchmark-*.local` / `.env.worker.benchmark-*.local`. Tous ces chemins sont
ignorés par Git.

## Commandes

Génération baseline :

```powershell
.\scripts\generate-load-fixture.ps1 -Count 10000
.\scripts\generate-load-fixture.ps1 -Count 50000
.\scripts\generate-load-fixture.ps1 -Count 100000
```

Variante déterministe (1 % modifié, 0,5 % retiré, 0,5 % nouveau par défaut) :

```powershell
.\scripts\generate-load-fixture.ps1 -Count 10000 -Variant Changed
```

Benchmarks exécutés :

```powershell
.\scripts\benchmark-catalog.ps1 -Count 10000
.\scripts\benchmark-catalog.ps1 -Count 50000
.\scripts\benchmark-catalog.ps1 -Count 100000 -Confirm100k
```

Le palier 100k reste volontairement bloqué sans confirmation explicite pour
toute nouvelle exécution :

```powershell
.\scripts\benchmark-catalog.ps1 -Count 100000 -Confirm100k
```

## Synthèse

| Volume | First sync | Identical sync | Search (nom) | Page 1 | Deep page | Filters (famille / marque) | Facets | DB produits |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 10k | 28,801 s | 27,700 s | 92,88 ms | 170,35 ms | p.417 : 70,25 ms | 77,30 / 62,67 ms | 73,84 ms | 7,58 MiB |
| 50k | 108,964 s | 108,940 s | 324,32 ms | 361,21 ms | p.2084 : 273,12 ms | 264,52 / 223,56 ms | 241,78 ms | 28,00 MiB |
| 100k | 219,832 s | 226,736 s | 591,53 ms | 477,22 ms | p.4167 : 458,88 ms | 302,51 / 331,81 ms | 305,60 ms | 55,94 MiB |

Les valeurs HTTP de ce tableau sont des moyennes locales.

## Synchronisations

| Volume | Run | Durée | Batches | Inserted | Updated | Unchanged | Reactivated | Deactivated | Statut / garde-fou |
|---:|---|---:|---:|---:|---:|---:|---:|---:|---|
| 10k | Initial | 28,801 s | 50 | 10 000 | 0 | 0 | 0 | 0 | completed / ok |
| 10k | Identique | 27,700 s | 50 | 0 | 0 | 10 000 | 0 | 0 | completed / ok |
| 10k | Changements | 29,188 s | 50 | 50 | 100 | 9 850 | 0 | 50 | completed / ok |
| 10k | Dry-run retour baseline | 20,903 s | 50 | 0 | 100 | 9 850 | 50 | 0 | completed / ok |
| 10k | Restauration baseline | 30,799 s | 50 | 0 | 100 | 9 850 | 50 | 50 | completed / ok |
| 50k | Initial | 108,964 s | 250 | 50 000 | 0 | 0 | 0 | 0 | completed / ok |
| 50k | Identique | 108,940 s | 250 | 0 | 0 | 50 000 | 0 | 0 | completed / ok |
| 50k | Changements | 123,832 s | 250 | 250 | 500 | 49 250 | 0 | 250 | completed / ok |
| 50k | Dry-run retour baseline | 85,363 s | 250 | 0 | 500 | 49 250 | 250 | 0 | completed / ok |
| 50k | Restauration baseline | 121,320 s | 250 | 0 | 500 | 49 250 | 250 | 250 | completed / ok |
| 100k | Initial | 219,832 s | 500 | 100 000 | 0 | 0 | 0 | 0 | completed / ok |
| 100k | Identique | 226,736 s | 500 | 0 | 0 | 100 000 | 0 | 0 | completed / ok |
| 100k | Changements | 227,788 s | 500 | 500 | 1 000 | 98 500 | 0 | 500 | completed / ok |
| 100k | Dry-run retour baseline | 162,328 s | 500 | 0 | 1 000 | 98 500 | 500 | 0 | completed / ok |
| 100k | Restauration baseline | 228,181 s | 500 | 0 | 1 000 | 98 500 | 500 | 500 | completed / ok |

La fixture baseline 100k pèse 34 705 005 octets et a été générée en 45,305 s.
La variante pèse 34 729 005 octets et a été générée en 44,010 s, avec 1 000
produits modifiés, 500 retirés et 500 nouveaux. La taille moyenne estimée des
données JSON par batch reste proche de 69 410 octets ; aucun payload géant ni
timeout bloquant n'a été observé.

## API REST

### Pagination (ms, min / moyenne / max)

| Volume | Page 1 | Page 100 | Page 500 | Page 1000 | Dernière page |
|---:|---:|---:|---:|---:|---:|
| 10k | 62,78 / 170,35 / 353,04 | 76,84 / 100,21 / 113,21 | — | — | p.417 : 67,66 / 70,25 / 72,02 |
| 50k | 267,47 / 361,21 / 472,52 | 221,55 / 236,13 / 248,66 | 147,99 / 203,83 / 264,77 | 158,98 / 198,35 / 257,19 | p.2084 : 250,97 / 273,12 / 315,51 |
| 100k | 328,38 / 477,22 / 692,60 | 423,87 / 499,91 / 576,51 | 222,77 / 271,34 / 310,75 | 280,23 / 304,49 / 351,39 | p.4167 : 447,57 / 458,88 / 476,82 |

La page 4000 n'existe pas à 50k (2 084 pages de 24). À 100k, elle répond en
487,24 / 540,35 / 598,77 ms.

### Recherche, filtres et facettes (ms, min / moyenne / max)

| Volume | Scénario | Min | Moyenne | Max |
|---:|---|---:|---:|---:|
| 10k | Référence exacte | 77,75 | 93,97 | 116,59 |
| 10k | Nom partiel | 88,00 | 92,88 | 97,24 |
| 10k | Marque en recherche | 108,26 | 120,84 | 128,89 |
| 10k | Famille en recherche | 83,47 | 90,97 | 102,27 |
| 10k | Mot absent | 89,15 | 110,27 | 141,17 |
| 10k | Filtre famille | 61,67 | 77,30 | 89,22 |
| 10k | Filtre marque | 51,18 | 62,67 | 78,30 |
| 10k | Recherche + filtres | 92,45 | 102,73 | 108,40 |
| 10k | Facettes | 67,99 | 73,84 | 81,83 |
| 50k | Référence exacte | 262,12 | 333,41 | 376,93 |
| 50k | Nom partiel | 296,20 | 324,32 | 361,04 |
| 50k | Marque en recherche | 347,60 | 400,35 | 428,11 |
| 50k | Famille en recherche | 383,36 | 456,17 | 524,18 |
| 50k | Mot absent | 405,50 | 446,73 | 500,89 |
| 50k | Filtre famille | 178,80 | 264,52 | 379,06 |
| 50k | Filtre marque | 201,50 | 223,56 | 267,10 |
| 50k | Recherche + filtres | 331,60 | 370,91 | 393,34 |
| 50k | Facettes | 170,87 | 241,78 | 333,39 |
| 100k | Référence exacte | 693,07 | 809,57 | 943,89 |
| 100k | Nom partiel | 533,54 | 591,53 | 639,12 |
| 100k | Marque en recherche | 582,90 | 614,04 | 646,62 |
| 100k | Famille en recherche | 537,34 | 639,08 | 698,13 |
| 100k | Mot absent | 538,83 | 579,59 | 612,86 |
| 100k | Filtre famille | 286,63 | 302,51 | 312,31 |
| 100k | Filtre marque | 274,57 | 331,81 | 425,35 |
| 100k | Recherche + filtres | 530,25 | 573,30 | 614,61 |
| 100k | Facettes | 272,38 | 305,60 | 352,02 |

Selon les seuils indicatifs du lot, le 10k est bon et le 50k acceptable en
moyenne. À 100k avant optimisation, la pagination et les filtres restent
acceptables, tandis que les recherches textuelles sont à surveiller
(0,58–0,81 s). Aucun scénario moyen ne dépasse une seconde.

## Base et historique

| Volume | Table | Lignes exactes | Données | Index | Total |
|---:|---|---:|---:|---:|---:|
| 10k | `wp_catalog_products` | 10 050 | 4 734 976 o | 3 211 264 o | 7 946 240 o |
| 10k | `wp_catalog_sync_runs` | 5 | 16 384 o | 49 152 o | 65 536 o |
| 10k | `wp_catalog_sync_batches` | 250 | 81 920 o | 32 768 o | 114 688 o |
| 10k | `wp_catalog_sync_run_items` | 50 000 | 8 929 280 o | 6 324 224 o | 15 253 504 o |
| 50k | `wp_catalog_products` | 50 250 | 19 447 808 o | 9 912 320 o | 29 360 128 o |
| 50k | `wp_catalog_sync_runs` | 5 | 16 384 o | 49 152 o | 65 536 o |
| 50k | `wp_catalog_sync_batches` | 1 250 | 245 760 o | 229 376 o | 475 136 o |
| 50k | `wp_catalog_sync_run_items` | 250 000 | 38 338 560 o | 30 605 312 o | 68 943 872 o |
| 100k | `wp_catalog_products` | 100 500 | 39 403 520 o | 19 251 200 o | 58 654 720 o |
| 100k | `wp_catalog_sync_runs` | 5 | 16 384 o | 49 152 o | 65 536 o |
| 100k | `wp_catalog_sync_batches` | 2 500 | 442 368 o | 393 216 o | 835 584 o |
| 100k | `wp_catalog_sync_run_items` | 500 000 | 76 136 448 o | 57 982 976 o | 134 119 424 o |

Les 50/250 lignes physiques supplémentaires dans `wp_catalog_products` sont
les nouveaux produits de la variante, désactivés lors de la restauration. Le
nombre actif revient respectivement à 10 000 et 50 000. L'historique des cinq
runs 50k atteint environ 66,3 MiB. À 100k, les tables d'historique atteignent
128,8 MiB, contre 55,9 MiB pour la table produits avant ajout d'index : c'est la
croissance la plus nette à surveiller sur des exécutions répétées.

Instantané Docker après les mesures 100k : MariaDB environ 301 MiB de mémoire et
3,54 % CPU ; WordPress environ 111 MiB et 0,01 % CPU. Il s'agit d'un instantané,
pas d'une série temporelle.

## SQL et index

Index présents avant LOT PERF 1.1 sur `wp_catalog_products` :

- clé primaire `PRIMARY (id)` ;
- unicité `source_id (source_id)` ;
- `reference (reference)` ;
- `active_name (is_active, name)` ;
- `last_seen_run (last_seen_run_uuid)`.

À 100k avant optimisation, les EXPLAIN estiment environ 98 196 lignes
examinées :

- pagination profonde : scan complet, `Using where; Using filesort` ;
- recherche, y compris une référence exacte : scan complet pour le `COUNT`,
  puis parcours de `active_name` et filesort pour la page ;
- filtres famille/marque : scan complet pour le `COUNT`, puis parcours large et
  filesort ;
- facettes : scan complet, avec table temporaire et filesort ;
- détail produit : accès `const` par la clé primaire, une ligne estimée.

La cause de la recherche référence à 809,57 ms était le prédicat unique
`reference LIKE '%terme%' OR name LIKE ...`, qui neutralisait l'index
`reference`.

## Optimisations 100k

La migration 0.3.1 ajoute :

- `active_family (is_active, family_code, family_label)` : le troisième champ
  couvre également le `MAX(family_label)` de la facette ;
- `active_brand (is_active, brand)` : filtre et facette marque couverts.

La recherche publique effectue désormais une pré-détection indexée
`reference = ?`. Si une référence active correspond exactement, le `COUNT` et
la page utilisent également `reference = ?`. Sans correspondance exacte, le
prédicat partiel historique est conservé, sans changement de contrat REST.

Mesure contrôlée sur la même stack chaude, trois répétitions avant et après :

| Endpoint | Avant | Après | Gain |
|---|---:|---:|---:|
| Référence exacte | 808,34 ms | 38,09 ms | 95,3 % |
| Filtre famille | 368,77 ms | 49,14 ms | 86,7 % |
| Filtre marque | 387,72 ms | 47,96 ms | 87,6 % |
| Recherche + filtres | 593,18 ms | 57,54 ms | 90,3 % |
| Facettes | 379,31 ms | 160,25 ms | 57,8 % |
| Page 4000 | 609,26 ms | 527,33 ms | 13,4 % (non ciblé) |
| Recherche textuelle | 690,32 ms | 545,37 ms | 21,0 % (variabilité/cache) |

Les empreintes et tailles des huit réponses contrôlées sont identiques avant et
après. Une recherche de référence partielle continue à utiliser la recherche
générale et a retourné les neuf correspondances attendues.

Après optimisation, les plans deviennent :

- référence exacte : type `ref`, clé `reference`, une ligne estimée ;
- filtre famille : type `ref`, clé `active_family`, 2 500 lignes estimées,
  `Using index` pour le `COUNT` ;
- filtre marque : type `ref`, clé `active_brand`, 2 000 lignes estimées,
  `Using index` pour le `COUNT` ;
- recherche + filtres : `index_merge` des deux index, environ 50 lignes ;
- facette famille : clé couvrante `active_family`, table temporaire/filesort
  maintenus sur les 40 groupes ;
- facette marque : clé couvrante `active_brand`, `Using index`.

Les index ajoutent 11,05 MiB à 100k : la partie index passe de 18,36 à
29,41 MiB (+60,2 %), et la table complète de 55,94 à 66,98 MiB (+19,7 %).
Ce coût est retenu au regard des gains mesurés sur les filtres et facettes.

Un index de tri supplémentaire a été rejeté : il dupliquerait largement
`active_name`, augmenterait encore le coût d'écriture et ne supprimerait pas le
coût intrinsèque d'OFFSET. La page 4000 reste sous une seconde. Aucun moteur de
recherche externe ni pagination par curseur n'est justifié par ces mesures.

## Rétention de l'historique

La politique Lot 2 est bien active. Après chaque finalisation réussie,
`cleanup_history()` sélectionne au plus 500 runs terminaux âgés de plus de 90
jours, puis supprime leurs `run_items`, batches et enfin le run. Les index
commençant par `run_uuid` couvrent ces suppressions. Les produits ne sont jamais
touchés. La durée est ajustable par le filtre
`product_catalog_sync_history_retention_days` entre 1 et 3 650 jours.

La croissance n'est donc pas infinie, mais la fenêtre par défaut est coûteuse à
100k : cinq runs occupent déjà 128,8 MiB. Une fréquence quotidienne représenterait
environ 9 millions de `run_items` dans la fenêtre de 90 jours ; une fréquence de
15 minutes pourrait théoriquement en produire 864 millions. La rétention doit
être configurée selon le besoin réel de diagnostic. La purge opportuniste de
500 runs peut aussi rendre la première purge après une longue interruption
lourde ; aucune purge n'a été déclenchée sur les runs benchmark récents.

## Synchronisation identique

Le run identique 100k dure 226,736 s car il évite les changements métier, mais
pas le travail de protocole : lecture et hash des 100 000 produits, transfert et
validation de 500 batches, `SELECT ... FOR UPDATE` par produit, mise à jour de
`last_seen_run_uuid`/`last_synced_at`, insertion de 100 000 `run_items`, compteurs
et contrôles de finalisation.

Des manifestes de source, un mode différentiel ou un journal moins fin pourraient
réduire ce coût, mais modifieraient les garanties Lot 2. Ils doivent faire
l'objet d'un lot distinct ; aucune réarchitecture n'est introduite ici.

## Limites connues

- La recherche générale `LIKE '%terme%'` reste un scan structurel et se situe
  autour de 0,55–0,64 s à 100k.
- La pagination `LIMIT/OFFSET` effectue un scan/filesort sur les pages profondes,
  mais reste sous une seconde jusqu'au volume mesuré.
- La synchronisation identique reste linéaire et presque aussi coûteuse que
  l'initiale.
- L'historique domine le stockage ; la rétention à 90 jours doit être alignée
  sur la fréquence réelle des runs.

## Conclusion d'architecture

- 10k : architecture confortable ;
- 50k : architecture confortable pour le catalogue paginé ;
- 100k : architecture viable après les index ciblés, recherche générale et
  historique à surveiller ;
- au-delà : aucune limite absolue n'est déduite sans nouvelle mesure.

## Retour au catalogue de démonstration

Les données de charge n'ont jamais été écrites dans la stack principale. Pour
revenir à l'environnement normal et, si souhaité, réaligner explicitement le
catalogue sur les 60 produits de `fixtures/products.json` :

```powershell
docker compose --env-file .env -f .\docker-compose.yml up -d db wordpress
.\scripts\run-worker-local.ps1 -RunOnce -ProductFile .\fixtures\products.json
```

Cette synchronisation concerne seulement la stack principale et conserve le
garde-fou normal. Ne jamais utiliser cette commande avec une configuration
Worker pointant vers une stack benchmark de 50k/100k.

Les stacks de charge peuvent ensuite être supprimées explicitement, sans toucher
aux volumes principaux :

```powershell
docker compose --project-name product-catalog-benchmark-10000 --env-file .env.benchmark-10000.local -f .\docker-compose.yml down --volumes
docker compose --project-name product-catalog-benchmark-50000 --env-file .env.benchmark-50000.local -f .\docker-compose.yml down --volumes
docker compose --project-name product-catalog-benchmark-100000 --env-file .env.benchmark-100000.local -f .\docker-compose.yml down --volumes
```

Les JSON ignorés dans `fixtures/load/` et `artifacts/performance/` peuvent être
conservés pour audit ou supprimés séparément. Aucun reset WordPress/MariaDB de la
stack principale n'est nécessaire.
