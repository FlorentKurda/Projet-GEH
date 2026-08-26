# ADR 0001 — Architecture du Lot 1

- Statut : accepté
- Date : 2026-08-26
- Périmètre : synchronisation minimale d’un catalogue vers WordPress

## Contexte

Le catalogue public doit, à terme, refléter une sélection de produits issue d’un ERP Sage installé dans le réseau interne d’une petite entreprise. Le serveur ERP ne doit pas être exposé à Internet et aucune donnée commerciale sensible ne doit être publiée.

Le Lot 1 doit valider la chaîne technique sans accès à Sage : une source JSON déterministe remplace temporairement l’ERP, un Worker .NET envoie les produits, et un plugin WordPress les conserve dans des tables dédiées avant de les exposer par une API publique paginée.

## Décision

L’architecture retenue est la suivante :

```text
Lot 1
fixtures/products.json
        ↓
IProductSource / JsonProductSource
        ↓
Worker .NET 10
        ↓ HTTP local ou HTTPS hors environnement local
POST /wp-json/catalog-sync/v1/products
        ↓
Tables WordPress dédiées
        ↓
GET /wp-json/catalog/v1/products
```

L’architecture cible remplacera uniquement la source :

```text
Sage / SQL Server interne
        ↓
Implémentation future de IProductSource
        ↓
Service Windows .NET
        ↓ HTTPS sortant uniquement
WordPress public
```

Les décisions structurantes sont :

1. WordPress constitue une base miroir publique et non une nouvelle source de vérité.
2. L’ERP restera maître des données produit.
3. Le futur serveur Sage n’acceptera aucune connexion entrante depuis Internet.
4. Le Worker réalisera uniquement des connexions HTTPS sortantes vers WordPress. Le HTTP n’est toléré que pour le développement local explicitement configuré.
5. La connexion Sage sera ajoutée derrière `IProductSource`. Le pipeline de validation et d’envoi ne dépend pas de noms de tables ou de colonnes Sage.
6. Les produits et les journaux de synchronisation sont stockés dans des tables WordPress dédiées. `wp_posts`, `wp_postmeta`, le thème et le cœur WordPress ne sont pas modifiés.
7. La route d’écriture est protégée par une Application Password WordPress et la capacité minimale `catalog_sync_write`.
8. La route de lecture publique ne publie ni prix, ni stock, ni donnée confidentielle.
9. Le frontend React sera ajouté dans un lot ultérieur et consommera le contrat public, jamais un schéma Sage.

## Conséquences

Cette séparation permet de tester le transport, l’authentification, l’upsert idempotent et la pagination sans dépendre du réseau interne ni de Sage. Elle limite aussi la surface exposée : WordPress ne peut pas initier de connexion vers l’ERP.

Le miroir WordPress peut être momentanément en retard sur l’ERP. Le Lot 1 envoie tous les produits dans une requête et ne désactive pas les produits absents. La synchronisation différentielle, les lots, les reprises avancées et la désactivation seront traités plus tard.

Le Lot 1 ne contient ni connexion Sage ou SQL Server, ni frontend, ni image, ni prix, ni stock, ni PDF, ni recherche, ni filtre, ni route de détail.
