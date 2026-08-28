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
	public const MAX_SEARCH_LENGTH = 100;

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
					'search'   => array(
						'type'              => 'string',
						'default'           => '',
						'sanitize_callback' => array( $this, 'sanitize_public_text' ),
						'validate_callback' => array( $this, 'validate_search' ),
					),
					'family'   => array(
						'type'              => 'string',
						'default'           => '',
						'sanitize_callback' => array( $this, 'sanitize_public_text' ),
						'validate_callback' => array( $this, 'validate_family' ),
					),
					'brand'    => array(
						'type'              => 'string',
						'default'           => '',
						'sanitize_callback' => array( $this, 'sanitize_public_text' ),
						'validate_callback' => array( $this, 'validate_brand' ),
					),
				),
			)
		);

		register_rest_route(
			'catalog/v1',
			'/products/(?P<id>\d+)',
			array(
				'methods'             => \WP_REST_Server::READABLE,
				'callback'            => array( $this, 'get_product' ),
				'permission_callback' => '__return_true',
				'args'                => array(
					'id' => array(
						'type'              => 'integer',
						'minimum'           => 1,
						'sanitize_callback' => 'absint',
						'validate_callback' => array( $this, 'validate_page' ),
					),
				),
			)
		);

		register_rest_route(
			'catalog/v1',
			'/filters',
			array(
				'methods'             => \WP_REST_Server::READABLE,
				'callback'            => array( $this, 'get_filters' ),
				'permission_callback' => '__return_true',
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

	/** @param mixed $value Search candidate. @return bool */
	public function validate_search( $value ) {
		return $this->validate_optional_text( $value, self::MAX_SEARCH_LENGTH );
	}

	/** @param mixed $value Family candidate. @return bool */
	public function validate_family( $value ) {
		return $this->validate_optional_text( $value, 100 );
	}

	/** @param mixed $value Brand candidate. @return bool */
	public function validate_brand( $value ) {
		return $this->validate_optional_text( $value, 255 );
	}

	/** @param mixed $value Public query text. @return string */
	public function sanitize_public_text( $value ) {
		return is_string( $value )
			? $this->trim_public_text( sanitize_text_field( $value ) )
			: '';
	}

	/**
	 * @param \WP_REST_Request $request REST request.
	 * @return \WP_REST_Response|\WP_Error
	 */
	public function get_products( \WP_REST_Request $request ) {
		$page     = (int) $request->get_param( 'page' );
		$per_page = (int) $request->get_param( 'per_page' );
		$search   = (string) $request->get_param( 'search' );
		$family   = (string) $request->get_param( 'family' );
		$brand    = (string) $request->get_param( 'brand' );

		try {
			$result = $this->repository->get_active_products(
				$page,
				$per_page,
				$search,
				$family,
				$brand
			);
		} catch ( \Throwable $exception ) {
			return $this->query_error( $exception );
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

	/** @param \WP_REST_Request $request REST request. @return \WP_REST_Response|\WP_Error */
	public function get_product( \WP_REST_Request $request ) {
		try {
			$product = $this->repository->get_active_product( (int) $request->get_param( 'id' ) );
		} catch ( \Throwable $exception ) {
			return $this->query_error( $exception );
		}

		if ( null === $product ) {
			return new \WP_Error(
				'catalog_product_not_found',
				'The product does not exist or is not active.',
				array( 'status' => 404 )
			);
		}

		return new \WP_REST_Response( $product, 200 );
	}

	/** @return \WP_REST_Response|\WP_Error */
	public function get_filters() {
		try {
			return new \WP_REST_Response( $this->repository->get_active_product_filters(), 200 );
		} catch ( \Throwable $exception ) {
			return $this->query_error( $exception );
		}
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

	/** @param mixed $value Text candidate. @param int $maximum_length Maximum Unicode length. @return bool */
	private function validate_optional_text( $value, $maximum_length ) {
		if ( ! is_string( $value ) ) {
			return false;
		}

		$text = $this->trim_public_text( $value );
		if ( function_exists( 'mb_strlen' ) ) {
			return mb_strlen( $text, 'UTF-8' ) <= $maximum_length;
		}

		$length = preg_match_all( '/./us', $text, $characters );
		return false !== $length && $length <= $maximum_length;
	}

	/** @return string */
	private function trim_public_text( $value ) {
		$trimmed = trim( $value );
		$result  = preg_replace( '/\A[\p{Z}\s]+|[\p{Z}\s]+\z/u', '', $trimmed );

		return is_string( $result ) ? $result : $trimmed;
	}

	/** @return \WP_Error */
	private function query_error( \Throwable $exception ) {
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
}
