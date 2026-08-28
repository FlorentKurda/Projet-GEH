<?php
/**
 * Plugin Name: Product Catalog Sync
 * Description: Synchronise un catalogue de produits vers des tables WordPress dédiées et expose une API publique paginée.
 * Version:     0.3.0
 * Requires at least: 6.5
 * Requires PHP: 7.4
 * Author:      Product Catalog Sync
 * License:     GPL-2.0-or-later
 * Text Domain: product-catalog-sync
 */

namespace ProductCatalogSync;

if ( ! defined( 'ABSPATH' ) ) {
	exit;
}

define( 'PRODUCT_CATALOG_SYNC_VERSION', '0.3.0' );
define( 'PRODUCT_CATALOG_SYNC_FILE', __FILE__ );
define( 'PRODUCT_CATALOG_SYNC_DIR', plugin_dir_path( __FILE__ ) );

require_once PRODUCT_CATALOG_SYNC_DIR . 'includes/class-activator.php';
require_once PRODUCT_CATALOG_SYNC_DIR . 'includes/class-sync-config.php';
require_once PRODUCT_CATALOG_SYNC_DIR . 'includes/class-sync-exception.php';
require_once PRODUCT_CATALOG_SYNC_DIR . 'includes/class-product-hasher.php';
require_once PRODUCT_CATALOG_SYNC_DIR . 'includes/class-product-validator.php';
require_once PRODUCT_CATALOG_SYNC_DIR . 'includes/class-catalog-repository.php';
require_once PRODUCT_CATALOG_SYNC_DIR . 'includes/class-sync-rest-controller.php';
require_once PRODUCT_CATALOG_SYNC_DIR . 'includes/class-products-rest-controller.php';
require_once PRODUCT_CATALOG_SYNC_DIR . 'includes/class-catalog-shortcode.php';
require_once PRODUCT_CATALOG_SYNC_DIR . 'includes/class-plugin.php';

register_activation_hook( __FILE__, array( Activator::class, 'activate' ) );
add_action( 'plugins_loaded', array( Activator::class, 'maybe_upgrade' ), 5 );

Plugin::boot();
