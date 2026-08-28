<?php
/**
 * Authenticated synchronization run protocol.
 *
 * @package ProductCatalogSync
 */

namespace ProductCatalogSync;

if ( ! defined( 'ABSPATH' ) ) {
	exit;
}

final class Sync_REST_Controller {
	/** @var Catalog_Repository */
	private $repository;

	/** @var Product_Validator */
	private $validator;

	/** @param Catalog_Repository $repository Persistence. @param Product_Validator $validator Validation. */
	public function __construct( Catalog_Repository $repository, Product_Validator $validator ) {
		$this->repository = $repository;
		$this->validator  = $validator;
	}

	/** @return void */
	public function register_routes() {
		$permission = array( $this, 'check_permission' );
		$run_args   = array(
			'run_id' => array(
				'type'              => 'string',
				'validate_callback' => array( $this, 'validate_run_id' ),
			),
		);

		register_rest_route(
			'catalog-sync/v1',
			'/runs',
			array(
				'methods'             => \WP_REST_Server::CREATABLE,
				'callback'            => array( $this, 'start_run' ),
				'permission_callback' => $permission,
			)
		);
		register_rest_route(
			'catalog-sync/v1',
			'/runs/(?P<run_id>[0-9a-fA-F-]{36})/products',
			array(
				'methods'             => \WP_REST_Server::CREATABLE,
				'callback'            => array( $this, 'send_batch' ),
				'permission_callback' => $permission,
				'args'                => $run_args,
			)
		);
		register_rest_route(
			'catalog-sync/v1',
			'/runs/(?P<run_id>[0-9a-fA-F-]{36})/complete',
			array(
				'methods'             => \WP_REST_Server::CREATABLE,
				'callback'            => array( $this, 'complete_run' ),
				'permission_callback' => $permission,
				'args'                => $run_args,
			)
		);
	}

	/** @return true|\WP_Error */
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

	/** @param mixed $value UUID candidate. @return bool */
	public function validate_run_id( $value ) {
		return is_string( $value ) && 1 === preg_match(
			'/\A[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/i',
			$value
		);
	}

	/** @param \WP_REST_Request $request Request. @return \WP_REST_Response|\WP_Error */
	public function start_run( \WP_REST_Request $request ) {
		$payload = $this->validator->validate_start( $request->get_json_params() );
		if ( is_wp_error( $payload ) ) {
			return $payload;
		}

		try {
			$result = $this->repository->start_run( $payload );
			$status = 'rejected' === $result['status'] ? 422 : 201;
			$data   = array( 'runId' => $result['run_id'], 'status' => $result['status'] );
			if ( null !== $result['message'] ) {
				$data['message'] = $result['message'];
			}

			return new \WP_REST_Response( $data, $status );
		} catch ( \Throwable $exception ) {
			return $this->handle_exception( $exception, null );
		}
	}

	/** @param \WP_REST_Request $request Request. @return \WP_REST_Response|\WP_Error */
	public function send_batch( \WP_REST_Request $request ) {
		$run_id  = strtolower( (string) $request->get_param( 'run_id' ) );
		$payload = $this->validator->validate_batch( $request->get_json_params() );
		if ( is_wp_error( $payload ) ) {
			return $payload;
		}

		try {
			$result = $this->repository->process_batch( $run_id, $payload );

			return new \WP_REST_Response(
				array(
					'runId'            => $result['run_id'],
					'batchNumber'      => $result['batch_number'],
					'status'           => $result['status'],
					'replayed'         => $result['replayed'],
					'receivedCount'    => $result['received_count'],
					'insertedCount'    => $result['inserted_count'],
					'updatedCount'     => $result['updated_count'],
					'unchangedCount'   => $result['unchanged_count'],
					'reactivatedCount' => $result['reactivated_count'],
				),
				200
			);
		} catch ( \Throwable $exception ) {
			return $this->handle_exception( $exception, $run_id );
		}
	}

	/** @param \WP_REST_Request $request Request. @return \WP_REST_Response|\WP_Error */
	public function complete_run( \WP_REST_Request $request ) {
		$run_id = strtolower( (string) $request->get_param( 'run_id' ) );
		try {
			$result = $this->repository->complete_run( $run_id );

			return new \WP_REST_Response(
				array(
					'runId'                       => $result['run_id'],
					'status'                      => $result['status'],
					'receivedCount'               => $result['received_count'],
					'insertedCount'               => $result['inserted_count'],
					'updatedCount'                => $result['updated_count'],
					'unchangedCount'              => $result['unchanged_count'],
					'reactivatedCount'            => $result['reactivated_count'],
					'deactivatedCount'            => $result['deactivated_count'],
					'candidateDeactivationCount'  => $result['candidate_deactivation_count'],
					'activeBeforeCount'           => $result['active_before_count'],
					'deactivationPercentage'      => $result['deactivation_percentage'],
					'guardrailStatus'             => $result['guardrail_status'],
					'dryRun'                      => $result['dry_run'],
				),
				200
			);
		} catch ( \Throwable $exception ) {
			return $this->handle_exception( $exception, $run_id );
		}
	}

	/** @return \WP_Error */
	private function handle_exception( \Throwable $exception, $run_id ) {
		if ( $exception instanceof Sync_Exception ) {
			$data = array( 'status' => $exception->get_http_status() );
			if ( null !== $run_id ) {
				$data['runId'] = $run_id;
			}

			return new \WP_Error(
				$exception->get_rest_code(),
				$exception->getMessage(),
				$data
			);
		}

		error_log(
			sprintf(
				'[Product Catalog Sync] Run %s failed (%s).',
				null === $run_id ? 'not-created' : $run_id,
				get_class( $exception )
			)
		);

		return new \WP_Error(
			'catalog_sync_persistence_error',
			'The synchronization request could not be persisted safely.',
			array( 'status' => 500 )
		);
	}
}
