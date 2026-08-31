<?php
/**
 * Plugin composition root.
 *
 * @package ProductCatalogSync
 */

namespace ProductCatalogSync;

if ( ! defined( 'ABSPATH' ) ) {
	exit;
}

/**
 * Wires the controllers to the WordPress REST lifecycle.
 */
final class Plugin {
	/**
	 * @var bool
	 */
	private static $booted = false;

	/**
	 * @return void
	 */
	public static function boot() {
		if ( self::$booted ) {
			return;
		}
		self::$booted = true;

		global $wpdb;

		$repository        = new Catalog_Repository( $wpdb );
		$admin_repository  = new Catalog_Admin_Repository( $wpdb );
		$validator         = new Product_Validator();
		$sync_controller   = new Sync_REST_Controller( $repository, $validator );
		$public_controller = new Products_REST_Controller( $repository );
		$admin_page        = new Catalog_Admin_Page( $admin_repository );

		add_action( 'rest_api_init', array( $sync_controller, 'register_routes' ) );
		add_action( 'rest_api_init', array( $public_controller, 'register_routes' ) );
		Catalog_Shortcode::register();
		$admin_page->register();
	}
}
