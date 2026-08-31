# Supervision WordPress du catalogue

## Accès

La page est disponible dans **Administration WordPress → Catalogue produits**. Elle exige la capability `manage_options`, réservée par défaut aux administrateurs. Elle n'est jamais exposée sur le site public.

La page est strictement en lecture seule : elle ne contient aucun bouton de synchronisation, retry, suppression, purge, activation ou désactivation.

## Métriques et statuts

Les quatre cartes de synthèse indiquent :

- l'état global ;
- la dernière synchronisation réelle réussie ;
- le nombre de produits actifs ;
- la durée de la dernière synchronisation réelle.

L'état global suit cet ordre :

1. run `started` ou `running` récent : **Synchronisation en cours** ;
2. run actif au-delà du timeout Lot 2 : **Run potentiellement bloqué** ;
3. dernière tentative réelle postérieure à la dernière réussite et `rejected` : **Attention — dernière tentative rejetée** ;
4. dernière tentative réelle postérieure à la dernière réussite et `failed` : **Attention — dernière tentative en erreur** ;
5. aucune réussite réelle : **Aucune synchronisation réussie** ;
6. dernière réussite trop ancienne : **Synchronisation en retard** ;
7. sinon : **Opérationnel**.

Un rejet n'efface pas la dernière réussite et ne signifie pas que le catalogue existant est vide ou cassé. Son `error_message` est visible dans le détail du run.

## Fraîcheur et dry-run

La fraîcheur repose exclusivement sur un run `completed` avec `dry_run = 0`. Un dry-run terminé reste visible et porte le badge **DRY-RUN**, mais ne repousse jamais la date de fraîcheur du catalogue.

Le seuil par défaut est de 45 minutes. Il est configurable sans page Réglages :

```php
add_filter(
	'product_catalog_sync_supervision_stale_after_minutes',
	static function () {
		return 60;
	}
);
```

La détection d'un run potentiellement bloqué réutilise `product_catalog_sync_run_timeout_minutes`, soit 30 minutes par défaut. La supervision ne change jamais son statut.

## Historique et détail

L'historique charge 20 runs par page. Il affiche date, statut, durée, compteurs, mode réel/dry-run et un lien de détail.

Le détail présente le UUID, le statut, la version de schéma, la source, les dates, les compteurs, le pourcentage de désactivation et l'erreur éventuelle. Les batches sont résumés par un agrégat : nombre, premier, dernier et total de produits.

La table `catalog_sync_run_items` n'est jamais interrogée par cette page. Les lignes de batches ne sont pas chargées individuellement.

## Performance

Le compteur produits utilise `COUNT(*) WHERE is_active = 1`. L'historique utilise `LIMIT 20 OFFSET ...`, le détail cible l'index unique `run_uuid` et le résumé des batches cible l'index `run_uuid`. Le volume de 100 000 produits n'augmente donc pas la quantité de données transférée vers PHP.

## Diagnostic

Si la supervision indique une synchronisation en retard :

```text
Supervision WordPress indique un retard
        ↓
Get-Service GEHProductCatalogSync
        ↓
Consulter C:\ProgramData\GEH\ProductCatalogSync\logs
        ↓
Vérifier l'accès réseau HTTPS et WordPress
```

Commandes utiles sur le serveur Worker :

```powershell
Get-Service GEHProductCatalogSync
Get-Content 'C:\ProgramData\GEH\ProductCatalogSync\logs\catalog-sync-*.log' -Tail 100
```

Les détails de déploiement du Worker restent dans [Worker en service Windows](../deployment/windows-service.md).

## Validation locale

Avec la stack locale existante :

```powershell
.\scripts\smoke-test-ops1.ps1
```

Le contrôle utilise les données existantes, ne crée aucun run et vérifie le rendu admin, la capability, la limite de 20 lignes, le détail, les principaux états synthétiques, l'absence de formulaire de mutation et le chargement du CSS uniquement sur la page de supervision.
