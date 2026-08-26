<?php
/**
 * Plugin activation tasks.
 *
 * @package ProductCatalogSync
 */

namespace ProductCatalogSync;

if ( ! defined( 'ABSPATH' ) ) {
	exit;
}

/**
 * Creates the database schema and the narrowly scoped synchronization role.
 */
final class Activator {
	public const CAPABILITY = 'catalog_sync_write';
	public const ROLE       = 'catalog_sync';

	/**
	 * Runs when the plugin is activated.
	 *
	 * @return void
	 */
	public static function activate() {
		self::create_tables();
		self::create_role_and_capabilities();

		update_option( 'product_catalog_sync_db_version', PRODUCT_CATALOG_SYNC_VERSION );
	}

	/**
	 * Creates or updates the plugin-owned tables with WordPress dbDelta.
	 *
	 * @return void
	 */
	private static function create_tables() {
		global $wpdb;

		$products_table = $wpdb->prefix . 'catalog_products';
		$runs_table     = $wpdb->prefix . 'catalog_sync_runs';
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
			source_updated_at datetime NULL,
			last_synced_at datetime NOT NULL,
			created_at datetime NOT NULL,
			updated_at datetime NOT NULL,
			PRIMARY KEY  (id),
			UNIQUE KEY source_id (source_id),
			KEY reference (reference),
			KEY active_name (is_active,name(191))
		) ENGINE=InnoDB {$charset_collate};";

		$runs_sql = "CREATE TABLE {$runs_table} (
			id bigint(20) unsigned NOT NULL AUTO_INCREMENT,
			run_uuid char(36) NOT NULL,
			schema_version smallint(5) unsigned NOT NULL,
			status varchar(20) NOT NULL,
			received_count int(10) unsigned NOT NULL DEFAULT 0,
			inserted_count int(10) unsigned NOT NULL DEFAULT 0,
			updated_count int(10) unsigned NOT NULL DEFAULT 0,
			started_at datetime NOT NULL,
			completed_at datetime NULL,
			error_message text NULL,
			PRIMARY KEY  (id),
			UNIQUE KEY run_uuid (run_uuid),
			KEY status_started (status,started_at)
		) ENGINE=InnoDB {$charset_collate};";

		require_once ABSPATH . 'wp-admin/includes/upgrade.php';

		dbDelta( $products_sql );
		dbDelta( $runs_sql );
	}

	/**
	 * Adds only the synchronization capability to the technical role.
	 * Administrators also receive it to simplify local verification.
	 *
	 * @return void
	 */
	private static function create_role_and_capabilities() {
		$role = get_role( self::ROLE );

		if ( null === $role ) {
			$role = add_role(
				self::ROLE,
				'Catalog Sync',
				array(
					self::CAPABILITY => true,
				)
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
