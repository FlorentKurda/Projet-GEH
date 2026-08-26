<?php
/**
 * Public paginated product REST endpoint.
 *
 * @package ProductCatalogSync
 */

namespace ProductCatalogSync;

if ( ! defined( 'ABSPATH' ) ) {
	exit;
}

/**
 * Handles GET /wp-json/catalog/v1/products.
 */
final class Products_REST_Controller {
	public const DEFAULT_PER_PAGE = 24;
	public const MAX_PER_PAGE     = 24;

	/**
	 * @var Catalog_Repository
	 */
	private $repository;

	/**
	 * @param Catalog_Repository $repository Catalog persistence.
	 */
	public function __construct( Catalog_Repository $repository ) {
		$this->repository = $repository;
	}

	/**
	 * @return void
	 */
	public function register_routes() {
		register_rest_route(
			'catalog/v1',
			'/products',
			array(
				'methods'             => \WP_REST_Server::READABLE,
				'callback'            => array( $this, 'get_products' ),
				'permission_callback' => '__return_true',
				'args'                => array(
					'page'     => array(
						'type'              => 'integer',
						'minimum'           => 1,
						'default'           => 1,
						'sanitize_callback' => 'absint',
						'validate_callback' => array( $this, 'validate_page' ),
					),
					'per_page' => array(
						'type'              => 'integer',
						'minimum'           => 1,
						'maximum'           => self::MAX_PER_PAGE,
						'default'           => self::DEFAULT_PER_PAGE,
						'sanitize_callback' => 'absint',
						'validate_callback' => array( $this, 'validate_per_page' ),
					),
				),
			)
		);
	}

	/**
	 * @param mixed $value Request value.
	 * @return bool
	 */
	public function validate_page( $value ) {
		$integer = $this->parse_positive_integer( $value );

		return null !== $integer && $integer >= 1;
	}

	/**
	 * @param mixed $value Request value.
	 * @return bool
	 */
	public function validate_per_page( $value ) {
		$integer = $this->parse_positive_integer( $value );

		return null !== $integer && $integer >= 1 && $integer <= self::MAX_PER_PAGE;
	}

	/**
	 * @param \WP_REST_Request $request REST request.
	 * @return \WP_REST_Response|\WP_Error
	 */
	public function get_products( \WP_REST_Request $request ) {
		$page     = (int) $request->get_param( 'page' );
		$per_page = (int) $request->get_param( 'per_page' );

		try {
			$result = $this->repository->get_active_products( $page, $per_page );
		} catch ( \Throwable $exception ) {
			error_log(
				sprintf(
					'[Product Catalog Sync] Public catalog query failed (%s).',
					get_class( $exception )
				)
			);

			return new \WP_Error(
				'catalog_products_query_error',
				'The product catalog is temporarily unavailable.',
				array( 'status' => 500 )
			);
		}

		$total_items = $result['total_items'];
		$total_pages = 0 === $total_items ? 0 : (int) ceil( $total_items / $per_page );

		return new \WP_REST_Response(
			array(
				'items'      => $result['items'],
				'pagination' => array(
					'page'       => $page,
					'perPage'    => $per_page,
					'totalItems' => $total_items,
					'totalPages' => $total_pages,
				),
			),
			200
		);
	}

	/**
	 * @param mixed $value Candidate query parameter.
	 * @return int|null
	 */
	private function parse_positive_integer( $value ) {
		if ( is_int( $value ) ) {
			return $value >= 0 ? $value : null;
		}

		if ( ! is_string( $value ) || 1 !== preg_match( '/\A\d+\z/', $value ) ) {
			return null;
		}

		$validated = filter_var( $value, FILTER_VALIDATE_INT );

		return false === $validated ? null : $validated;
	}
}
