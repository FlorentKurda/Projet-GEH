<?php
/**
 * Authenticated product synchronization REST endpoint.
 *
 * @package ProductCatalogSync
 */

namespace ProductCatalogSync;

if ( ! defined( 'ABSPATH' ) ) {
	exit;
}

/**
 * Handles POST /wp-json/catalog-sync/v1/products.
 */
final class Sync_REST_Controller {
	/**
	 * @var Catalog_Repository
	 */
	private $repository;

	/**
	 * @var Product_Validator
	 */
	private $validator;

	/**
	 * @param Catalog_Repository $repository Catalog persistence.
	 * @param Product_Validator $validator Request validator.
	 */
	public function __construct( Catalog_Repository $repository, Product_Validator $validator ) {
		$this->repository = $repository;
		$this->validator  = $validator;
	}

	/**
	 * @return void
	 */
	public function register_routes() {
		register_rest_route(
			'catalog-sync/v1',
			'/products',
			array(
				'methods'             => \WP_REST_Server::CREATABLE,
				'callback'            => array( $this, 'synchronize' ),
				'permission_callback' => array( $this, 'check_permission' ),
			)
		);
	}

	/**
	 * Application Password authentication is performed by WordPress before this
	 * capability check. Anonymous users and unrelated roles cannot write.
	 *
	 * @return true|\WP_Error
	 */
	public function check_permission() {
		if ( current_user_can( Activator::CAPABILITY ) ) {
			return true;
		}

		return new \WP_Error(
			'catalog_sync_forbidden',
			'Authentication with the catalog synchronization capability is required.',
			array( 'status' => rest_authorization_required_code() )
		);
	}

	/**
	 * @param \WP_REST_Request $request REST request.
	 * @return \WP_REST_Response|\WP_Error
	 */
	public function synchronize( \WP_REST_Request $request ) {
		$payload = $this->validator->validate( $request->get_json_params() );
		if ( is_wp_error( $payload ) ) {
			return $payload;
		}

		$run_id = $payload['run_id'];

		try {
			$existing_run = $this->repository->get_sync_run( $run_id );
			if ( null !== $existing_run ) {
				if ( 'success' === $existing_run['status'] ) {
					return $this->success_response(
						array(
							'run_id'         => $existing_run['run_uuid'],
							'status'         => 'success',
							'received_count' => (int) $existing_run['received_count'],
							'inserted_count' => (int) $existing_run['inserted_count'],
							'updated_count'  => (int) $existing_run['updated_count'],
						)
					);
				}

				return new \WP_Error(
					'catalog_sync_run_conflict',
					'This runId has already been used by an incomplete or failed synchronization.',
					array(
						'status' => 409,
						'runId'  => $run_id,
					)
				);
			}

			$result = $this->repository->synchronize( $payload );

			return $this->success_response( $result );
		} catch ( \Throwable $exception ) {
			// The class name is diagnostic enough and cannot contain request secrets.
			error_log(
				sprintf(
					'[Product Catalog Sync] Synchronization run %s failed (%s).',
					$run_id,
					get_class( $exception )
				)
			);

			return new \WP_Error(
				'catalog_sync_persistence_error',
				'The synchronization could not be completed. No product change was committed.',
				array(
					'status' => 500,
					'runId'  => $run_id,
				)
			);
		}
	}

	/**
	 * @param array $result Repository counters.
	 * @return \WP_REST_Response
	 */
	private function success_response( array $result ) {
		return new \WP_REST_Response(
			array(
				'runId'         => $result['run_id'],
				'status'        => $result['status'],
				'receivedCount' => (int) $result['received_count'],
				'insertedCount' => (int) $result['inserted_count'],
				'updatedCount'  => (int) $result['updated_count'],
			),
			200
		);
	}
}
