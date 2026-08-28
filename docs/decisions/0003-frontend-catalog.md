# ADR 0003 — Front catalogue WordPress

- Statut : accepté
- Date : 2026-08-28
- Périmètre : Lot 3A

## Contexte

Les Lots 1 et 2 alimentent une base miroir WordPress et exposent une liste publique paginée. Le Lot 3A doit proposer une expérience catalogue partageable, responsive et indépendante de Sage, sans ajouter de serveur applicatif en production.

## Décision

Le frontend utilise React, TypeScript et Vite dans `frontend/`. Vite produit `catalog.js` et `catalog.css` dans les assets statiques du plugin. React et ses dépendances sont intégrés au bundle : WordPress reste l’unique serveur de production.

Le shortcode `[product_catalog]` fournit le point de montage. Le plugin ne charge les assets que sur une page contenant ce shortcode et transmet la base REST ainsi que l’URL du placeholder avec les API WordPress. Aucun domaine n’est codé en dur et le thème n’est pas modifié.

L’état partageable repose sur `URLSearchParams`, sans routeur :

```text
?search=perceuse&family=FAM-OUT&brand=Novatool&page=2&product=42
```

Le bouton précédent du navigateur restaure la liste. La recherche est différée de 350 ms et les requêtes obsolètes sont annulées avec `AbortController`.

## API publique

La liste historique reste compatible et accepte trois paramètres supplémentaires :

```http
GET /wp-json/catalog/v1/products?page=1&per_page=24
    &search=...
    &family=...
    &brand=...
```

Les critères sont appliqués en SQL avec des requêtes préparées. La recherche porte sur la référence, le nom, la marque et le libellé de famille. Les facettes proviennent uniquement des produits actifs :

```http
GET /wp-json/catalog/v1/filters
```

Le détail utilise l’identifiant numérique de la ligne miroir :

```http
GET /wp-json/catalog/v1/products/{id}
```

Cet identifiant public est opaque, stable pendant la vie du miroir et indépendant d’un futur identifiant Sage. La référence n’est pas utilisée comme clé car elle n’est pas garantie unique. Un produit inactif répond 404.

## Images

Le contrat public et le type TypeScript prévoient `imageUrl`, actuellement toujours nul. `ProductImage` utilise un SVG local si l’URL est absente ou en erreur. Aucune image n’est synchronisée dans ce lot.

## Conséquences

Le frontend ne connaît que le contrat REST public. Le remplacement futur de `JsonProductSource` par une source Sage n’affectera pas React. Les caractéristiques techniques, pictogrammes et PDF pourront compléter la fiche plus tard sans faux contenu dans le Lot 3A.
