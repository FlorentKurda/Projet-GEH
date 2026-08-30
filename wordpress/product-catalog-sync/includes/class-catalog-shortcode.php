<?php
/**
 * Public catalog shortcode and conditional frontend assets.
 *
 * @package ProductCatalogSync
 */

namespace ProductCatalogSync;

if ( ! defined( 'ABSPATH' ) ) {
	exit;
}

final class Catalog_Shortcode {
	public const SHORTCODE = 'product_catalog';
	private const SCRIPT_HANDLE = 'product-catalog-sync-frontend';
	private const STYLE_HANDLE  = 'product-catalog-sync-frontend';

	/** @var bool */
	private static $configured = false;

	/** @return void */
	public static function register() {
		add_shortcode( self::SHORTCODE, array( self::class, 'render' ) );
		add_action( 'wp_enqueue_scripts', array( self::class, 'enqueue_when_needed' ) );
		add_filter( 'body_class', array( self::class, 'add_catalog_body_class' ) );
	}

	/** @return void */
	public static function enqueue_when_needed() {
		if ( ! self::is_catalog_page() ) {
			return;
		}

		self::enqueue_assets();
	}

	/**
	 * @param string[] $classes Existing body classes.
	 * @return string[]
	 */
	public static function add_catalog_body_class( $classes ) {
		if ( self::is_catalog_page() ) {
			$classes[] = 'product-catalog-sync-page';
		}

		return $classes;
	}

	/** @return string */
	public static function render() {
		self::enqueue_assets();

		return '<div id="product-catalog-root" class="geh-catalog-root"></div>';
	}

	/** @return void */
	private static function enqueue_assets() {
		$script_path = PRODUCT_CATALOG_SYNC_DIR . 'assets/dist/catalog.js';
		$style_path  = PRODUCT_CATALOG_SYNC_DIR . 'assets/dist/catalog.css';
		$script_url  = plugins_url( 'assets/dist/catalog.js', PRODUCT_CATALOG_SYNC_FILE );
		$style_url   = plugins_url( 'assets/dist/catalog.css', PRODUCT_CATALOG_SYNC_FILE );

		wp_enqueue_style(
			self::STYLE_HANDLE,
			$style_url,
			array(),
			file_exists( $style_path ) ? (string) filemtime( $style_path ) : PRODUCT_CATALOG_SYNC_VERSION
		);
		wp_enqueue_script(
			self::SCRIPT_HANDLE,
			$script_url,
			array(),
			file_exists( $script_path ) ? (string) filemtime( $script_path ) : PRODUCT_CATALOG_SYNC_VERSION,
			true
		);

		if ( self::$configured ) {
			return;
		}

		wp_add_inline_style(
			self::STYLE_HANDLE,
			'body.product-catalog-sync-page .wp-block-post-title,' .
			'body.product-catalog-sync-page h1.entry-title,' .
			'body.product-catalog-sync-page h1.page-title{display:none!important;}'
		);

		$config = array(
			'restBaseUrl'   => untrailingslashit( rest_url( 'catalog/v1' ) ),
			'placeholderUrl' => plugins_url(
				'assets/images/product-placeholder.svg',
				PRODUCT_CATALOG_SYNC_FILE
			),
			'perPage'       => Products_REST_Controller::DEFAULT_PER_PAGE,
		);
		$encoded = wp_json_encode(
			$config,
			JSON_HEX_TAG | JSON_HEX_AMP | JSON_HEX_APOS | JSON_HEX_QUOT
		);
		if ( is_string( $encoded ) ) {
			wp_add_inline_script(
				self::SCRIPT_HANDLE,
				'window.GEH_CATALOG_CONFIG = ' . $encoded . ';',
				'before'
			);
		}

		self::$configured = true;
	}

	/** @return bool */
	private static function is_catalog_page() {
		global $post;

		return is_singular()
			&& $post instanceof \WP_Post
			&& has_shortcode( $post->post_content, self::SHORTCODE );
	}
}
