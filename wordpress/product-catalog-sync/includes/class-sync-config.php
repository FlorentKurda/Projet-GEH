<?php
/**
 * Centralized Lot 2 safety settings.
 *
 * @package ProductCatalogSync
 */

namespace ProductCatalogSync;

if ( ! defined( 'ABSPATH' ) ) {
	exit;
}

final class Sync_Config {
	public const DEFAULT_MAX_BATCH_PRODUCTS              = 500;
	public const DEFAULT_MAX_DEACTIVATION_PERCENTAGE     = 30.0;
	public const DEFAULT_RUN_TIMEOUT_MINUTES             = 30;
	public const DEFAULT_HISTORY_RETENTION_DAYS          = 90;
	public const DEFAULT_SUPERVISION_STALE_AFTER_MINUTES = 45;
	public const MAX_EXPECTED_PRODUCTS                   = 1000000;

	/** @return int */
	public static function max_batch_products() {
		$value = (int) apply_filters(
			'product_catalog_sync_max_batch_products',
			self::DEFAULT_MAX_BATCH_PRODUCTS
		);

		return max( 1, min( self::DEFAULT_MAX_BATCH_PRODUCTS, $value ) );
	}

	/** @return float */
	public static function max_deactivation_percentage() {
		$value = (float) apply_filters(
			'product_catalog_sync_max_deactivation_percentage',
			self::DEFAULT_MAX_DEACTIVATION_PERCENTAGE
		);

		return max( 0.0, min( 100.0, $value ) );
	}

	/** @return int */
	public static function run_timeout_minutes() {
		$value = (int) apply_filters(
			'product_catalog_sync_run_timeout_minutes',
			self::DEFAULT_RUN_TIMEOUT_MINUTES
		);

		return max( 1, min( 1440, $value ) );
	}

	/** @return int */
	public static function history_retention_days() {
		$value = (int) apply_filters(
			'product_catalog_sync_history_retention_days',
			self::DEFAULT_HISTORY_RETENTION_DAYS
		);

		return max( 1, min( 3650, $value ) );
	}

	/** @return int */
	public static function supervision_stale_after_minutes() {
		$value = (int) apply_filters(
			'product_catalog_sync_supervision_stale_after_minutes',
			self::DEFAULT_SUPERVISION_STALE_AFTER_MINUTES
		);

		return max( 1, min( 10080, $value ) );
	}
}
