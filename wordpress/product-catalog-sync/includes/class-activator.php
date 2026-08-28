<?php
/**
 * Plugin activation and non-destructive schema upgrades.
 *
 * @package ProductCatalogSync
 */

namespace ProductCatalogSync;

if ( ! defined( 'ABSPATH' ) ) {
	exit;
}

final class Activator {
	public const CAPABILITY = 'catalog_sync_write';
	public const ROLE       = 'catalog_sync';
	private const DB_OPTION = 'product_catalog_sync_db_version';

	/** @return void */
	public static function activate() {
		self::create_tables();
		self::create_role_and_capabilities();
		update_option( self::DB_OPTION, PRODUCT_CATALOG_SYNC_VERSION );
	}

	/**
	 * Upgrades an already active Lot 1 installation without requiring a
	 * deactivate/reactivate cycle and without deleting existing rows.
	 *
	 * @return void
	 */
	public static function maybe_upgrade() {
		if ( PRODUCT_CATALOG_SYNC_VERSION === get_option( self::DB_OPTION ) ) {
			return;
		}

		self::create_tables();
		self::create_role_and_capabilities();
		update_option( self::DB_OPTION, PRODUCT_CATALOG_SYNC_VERSION );
	}

	/** @return void */
	private static function create_tables() {
		global $wpdb;

		$products_table  = $wpdb->prefix . 'catalog_products';
		$runs_table      = $wpdb->prefix . 'catalog_sync_runs';
		$batches_table   = $wpdb->prefix . 'catalog_sync_batches';
		$run_items_table = $wpdb->prefix . 'catalog_sync_run_items';
		$charset_collate = $wpdb->get_charset_collate();

		$products_sql = "CREATE TABLE {$products_table} (
			id bigint(20) unsigned NOT NULL AUTO_INCREMENT,
			source_id varchar(100) NOT NULL,
			reference varchar(100) NOT NULL,
			name varchar(255) NOT NULL,
			short_description text NULL,
			family_code varchar(100) NULL,
			family_label varchar(255) NULL,
			brand varchar(255) NULL,
			is_active tinyint(1) NOT NULL DEFAULT 1,
			content_hash char(64) NULL,
			last_seen_run_uuid char(36) NULL,
			source_updated_at datetime NULL,
			last_synced_at datetime NOT NULL,
			created_at datetime NOT NULL,
			updated_at datetime NOT NULL,
			PRIMARY KEY  (id),
			UNIQUE KEY source_id (source_id),
			KEY reference (reference),
			KEY active_name (is_active,name(191)),
			KEY last_seen_run (last_seen_run_uuid)
		) ENGINE=InnoDB {$charset_collate};";

		$runs_sql = "CREATE TABLE {$runs_table} (
			id bigint(20) unsigned NOT NULL AUTO_INCREMENT,
			run_uuid char(36) NOT NULL,
			schema_version smallint(5) unsigned NOT NULL,
			status varchar(20) NOT NULL,
			expected_product_count int(10) unsigned NOT NULL DEFAULT 0,
			expected_batch_count int(10) unsigned NOT NULL DEFAULT 0,
			received_count int(10) unsigned NOT NULL DEFAULT 0,
			inserted_count int(10) unsigned NOT NULL DEFAULT 0,
			updated_count int(10) unsigned NOT NULL DEFAULT 0,
			unchanged_count int(10) unsigned NOT NULL DEFAULT 0,
			reactivated_count int(10) unsigned NOT NULL DEFAULT 0,
			deactivated_count int(10) unsigned NOT NULL DEFAULT 0,
			candidate_deactivation_count int(10) unsigned NOT NULL DEFAULT 0,
			active_before_count int(10) unsigned NOT NULL DEFAULT 0,
			deactivation_percentage decimal(7,2) unsigned NOT NULL DEFAULT 0.00,
			dry_run tinyint(1) NOT NULL DEFAULT 0,
			source_name varchar(100) NULL,
			started_at datetime NOT NULL,
			last_activity_at datetime NULL,
			completed_at datetime NULL,
			error_message text NULL,
			PRIMARY KEY  (id),
			UNIQUE KEY run_uuid (run_uuid),
			KEY status_started (status,started_at),
			KEY completed_at (completed_at)
		) ENGINE=InnoDB {$charset_collate};";

		$batches_sql = "CREATE TABLE {$batches_table} (
			id bigint(20) unsigned NOT NULL AUTO_INCREMENT,
			run_uuid char(36) NOT NULL,
			batch_number int(10) unsigned NOT NULL,
			payload_hash char(64) NOT NULL,
			product_count int(10) unsigned NOT NULL,
			inserted_count int(10) unsigned NOT NULL DEFAULT 0,
			updated_count int(10) unsigned NOT NULL DEFAULT 0,
			unchanged_count int(10) unsigned NOT NULL DEFAULT 0,
			reactivated_count int(10) unsigned NOT NULL DEFAULT 0,
			processed_at datetime NOT NULL,
			PRIMARY KEY  (id),
			UNIQUE KEY run_batch (run_uuid,batch_number),
			KEY run_uuid (run_uuid)
		) ENGINE=InnoDB {$charset_collate};";

		$run_items_sql = "CREATE TABLE {$run_items_table} (
			id bigint(20) unsigned NOT NULL AUTO_INCREMENT,
			run_uuid char(36) NOT NULL,
			source_id varchar(100) NOT NULL,
			content_hash char(64) NOT NULL,
			action varchar(20) NOT NULL,
			PRIMARY KEY  (id),
			UNIQUE KEY run_product (run_uuid,source_id),
			KEY run_uuid (run_uuid)
		) ENGINE=InnoDB {$charset_collate};";

		require_once ABSPATH . 'wp-admin/includes/upgrade.php';
		dbDelta( $products_sql );
		dbDelta( $runs_sql );
		dbDelta( $batches_sql );
		dbDelta( $run_items_sql );
	}

	/** @return void */
	private static function create_role_and_capabilities() {
		$role = get_role( self::ROLE );
		if ( null === $role ) {
			$role = add_role(
				self::ROLE,
				'Catalog Sync',
				array( self::CAPABILITY => true )
			);
		}

		if ( $role instanceof \WP_Role ) {
			$role->add_cap( self::CAPABILITY );
		}

		$administrator = get_role( 'administrator' );
		if ( $administrator instanceof \WP_Role ) {
			$administrator->add_cap( self::CAPABILITY );
		}
	}
}
