# ADR 0002 — Fiabilité et garde-fous de synchronisation

- Statut : accepté
- Date : 2026-08-27
- Périmètre : Lot 2

## Contexte

Le Lot 1 envoyait les produits en une requête transactionnelle. Il validait le transport et le miroir public, mais ne permettait ni de découper un catalogue important, ni de distinguer les produits inchangés, ni de désactiver sûrement les absents.

Le risque principal est une source vide, tronquée ou interrompue qui ferait disparaître une part importante du catalogue. En cas de doute, le miroir WordPress doit conserver son état actif antérieur.

## Décision

Une synchronisation utilise le protocole suivant :

```text
START
  ↓
BATCHES
  ↓
VALIDATION DE COMPLÉTUDE
  ↓
GARDE-FOU DE DÉSACTIVATION
  ↓
COMPLETE

ERROR / INTERRUPTION
  ↓
NO DEACTIVATION
```

### Identité et états du run

Le Worker génère un UUID avant `POST /runs`. WordPress persiste et renvoie exactement cet UUID. Cela rend un retry de création identifiable.

Les états sont `started`, `running`, `completed`, `failed` et `rejected` :

- un replay avec le même UUID et les mêmes paramètres retourne le même run tant qu’il est actif ;
- un UUID actif avec des paramètres différents répond HTTP 409 ;
- un UUID terminal n’est jamais transformé en nouveau run et répond HTTP 409 ;
- le rejet initial d’une source vide est rejouable comme le même rejet HTTP 422.

Un verrou nommé MariaDB sérialise les créations de runs. Les runs sans activité depuis 30 minutes sont marqués `failed` lors d’une nouvelle création. Le Worker possède aussi un verrou local non bloquant.

### Batches et idempotence

Le Worker découpe la source en batches de 200 produits par défaut. Le Worker et WordPress imposent une limite maximale de 500 par batch.

`catalog_sync_batches` possède une unicité sur `(run_uuid, batch_number)` et conserve le SHA-256 du payload normalisé. Un replay identique retourne les compteurs enregistrés. Un contenu différent pour le même numéro répond HTTP 409. Chaque batch est traité dans une transaction.

`catalog_sync_run_items` possède une unicité sur `(run_uuid, source_id)`. Cette table identifie les produits vus, détecte un `sourceId` envoyé dans plusieurs batches et permet de calculer les absents sans modifier la table produit en dry-run.

### Hash métier et delta

Le SHA-256 porte sur les sept champs publiables stables : identifiant source, référence, nom, description courte, code et libellé famille, marque. Les timestamps, le run et `sourceUpdatedAtUtc` sont exclus.

Le Worker calcule le hash ; WordPress le recalcule après validation et normalisation. Un hash identique produit l’action `unchanged` et évite l’UPDATE métier. Un produit inactif revu produit l’action `reactivated`. Les quatre catégories reçues sont exclusives : `inserted`, `updated`, `unchanged`, `reactivated`.

Les lignes migrées du Lot 1 ont initialement un hash nul. WordPress recalcule leur hash stocké avant comparaison, sans imposer une fausse mise à jour métier.

### Finalisation et désactivation

Seul `POST /runs/{runId}/complete` peut désactiver des produits. Avant cette opération, WordPress vérifie :

- le total reçu par rapport au total déclaré ;
- le nombre attendu de batches lorsqu’il est fourni ;
- une numérotation contiguë commençant à 1 ;
- le total des lignes de batch et des produits vus ;
- l’absence d’état terminal ou d’erreur préalable.

Un run incomplet devient `failed` et ne désactive rien. Une source vide devient `rejected` dès le démarrage.

Le nombre de produits actifs est figé au démarrage. À la finalisation, le nombre d’actifs absents est comparé à cette valeur. Au-delà de 30 %, le run devient `rejected` et aucune désactivation n’est exécutée. Sous le seuil, les absents passent à `is_active = 0` sans suppression physique. Leur retour les réactive automatiquement.

### Dry-run

Un dry-run persiste uniquement son journal, ses batches et ses éléments de run. Il lit `catalog_products` pour calculer les actions, les absents et le pourcentage, mais n’écrit aucune ligne ou colonne produit. Il passe par les mêmes validations de complétude et le même garde-fou.

### Réseau et reprise

Le Worker retente au maximum trois fois les erreurs réseau, timeouts et HTTP 408, 429, 500, 502, 503 ou 504, avec un délai croissant. Les erreurs client permanentes ne sont pas retentées. Les requêtes recréées conservent leur UUID et leur numéro de batch.

Une interruption peut laisser visibles les insertions ou modifications des batches déjà validés. Ce compromis évite une table complète de staging. La garantie retenue est stricte sur le risque principal : aucune désactivation ne se produit avant une finalisation complète et acceptée.

### Migration et rétention

La version 0.2.0 du plugin exécute `dbDelta` au chargement si la version de schéma diffère. La migration ajoute `content_hash`, `last_seen_run_uuid`, les compteurs de run et les deux tables Lot 2. Elle ne supprime ni ne renomme aucune donnée Lot 1.

Après une finalisation réussie, le plugin nettoie opportunément jusqu’à 500 runs terminaux âgés de plus de 90 jours, ainsi que leurs batches et éléments. Les produits ne sont jamais inclus dans ce nettoyage.

## Conséquences

Le protocole privé Lot 1 `POST /catalog-sync/v1/products` est remplacé. L’API publique `/catalog/v1/products` conserve son contrat et continue de paginer directement en SQL avec 24 éléments au maximum.

La solution reste proportionnée à un Worker et un WordPress : aucune file, aucun broker, aucun cache distribué et aucun framework de workflow ne sont ajoutés.

Le Lot 2 ne change pas l’architecture de confiance : WordPress reste un miroir public, l’ERP restera maître, et le futur Worker Sage effectuera uniquement des connexions HTTPS sortantes.
