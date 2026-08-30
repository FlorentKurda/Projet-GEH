<?php
/**
 * Persistence boundary for products, runs, batches and run items.
 *
 * @package ProductCatalogSync
 */

namespace ProductCatalogSync;

if ( ! defined( 'ABSPATH' ) ) {
	exit;
}

final class Catalog_Repository {
	/** @var \wpdb */
	private $wpdb;

	/** @param \wpdb $wpdb WordPress database connection. */
	public function __construct( \wpdb $wpdb ) {
		$this->wpdb = $wpdb;
	}

	/**
	 * Creates a mutually exclusive run. Empty sources are journaled as rejected.
	 *
	 * @param array $request Validated start request.
	 * @return array
	 */
	public function start_run( array $request ) {
		$lock_name = $this->wpdb->prefix . 'catalog_sync_start';
		$lock_sql  = $this->wpdb->prepare( 'SELECT GET_LOCK(%s, 5)', $lock_name );
		$locked    = (int) $this->wpdb->get_var( $lock_sql );
		if ( 1 !== $locked ) {
			throw new Sync_Exception(
				'catalog_sync_lock_unavailable',
				'Unable to acquire the synchronization lock.',
				503
			);
		}

		$transaction_started = false;
		try {
			$this->begin_transaction();
			$transaction_started = true;
			$this->expire_stale_runs();
			$run_id              = $request['run_id'];
			$existing_request     = $this->get_run_for_update( $run_id );
			if ( null !== $existing_request ) {
				$same_request = 2 === (int) $existing_request['schema_version'] &&
					(int) $existing_request['expected_product_count'] === $request['expected_product_count'] &&
					(int) $existing_request['expected_batch_count'] === $request['expected_batch_count'] &&
					(int) $existing_request['dry_run'] === ( $request['dry_run'] ? 1 : 0 ) &&
					(string) $existing_request['source_name'] === $request['source_name'];
				if ( ! $same_request ) {
					throw new Sync_Exception(
						'catalog_sync_run_conflict',
						'The runId has already been used with different parameters.',
						409
					);
				}

				if ( in_array( $existing_request['status'], array( 'started', 'running' ), true ) ) {
					$this->commit_transaction();
					$transaction_started = false;
					return array( 'run_id' => $run_id, 'status' => 'started', 'message' => null );
				}
				if ( 'rejected' === $existing_request['status'] && 0 === $request['expected_product_count'] ) {
					$this->commit_transaction();
					$transaction_started = false;
					return array(
						'run_id'  => $run_id,
						'status'  => 'rejected',
						'message' => 'An empty source is rejected to protect the catalog.',
					);
				}

				throw new Sync_Exception(
					'catalog_sync_run_conflict',
					'The runId has already reached a terminal state.',
					409
				);
			}

			$runs_table = $this->runs_table();
			$active_run = $this->wpdb->get_var(
				"SELECT run_uuid FROM {$runs_table}
				WHERE status IN ('started', 'running')
				ORDER BY started_at ASC LIMIT 1 FOR UPDATE"
			);
			$this->throw_on_last_error( 'Unable to inspect active synchronization runs.' );
			if ( null !== $active_run ) {
				$this->rollback_transaction();
				$transaction_started = false;
				throw new Sync_Exception(
					'catalog_sync_already_running',
					'A synchronization run is already active.',
					409
				);
			}

			$now      = current_time( 'mysql', true );
			$is_empty = 0 === $request['expected_product_count'];
			$status   = $is_empty ? 'rejected' : 'started';
			$active_before = $this->count_active_products();
			$inserted = $this->wpdb->insert(
				$this->runs_table(),
				array(
					'run_uuid'                    => $run_id,
					'schema_version'              => $request['schema_version'],
					'status'                      => $status,
					'expected_product_count'      => $request['expected_product_count'],
					'expected_batch_count'        => $request['expected_batch_count'],
					'received_count'              => 0,
					'inserted_count'              => 0,
					'updated_count'               => 0,
					'unchanged_count'             => 0,
					'reactivated_count'           => 0,
					'deactivated_count'           => 0,
					'candidate_deactivation_count' => 0,
					'active_before_count'         => $active_before,
					'deactivation_percentage'     => 0,
					'dry_run'                     => $request['dry_run'] ? 1 : 0,
					'source_name'                 => $request['source_name'],
					'started_at'                  => $now,
					'last_activity_at'            => $now,
					'completed_at'                => $is_empty ? $now : null,
					'error_message'               => $is_empty ? 'Empty source rejected.' : null,
				)
			);
			if ( false === $inserted ) {
				throw new \RuntimeException( 'Unable to create the synchronization run.' );
			}

			$this->commit_transaction();
			$transaction_started = false;

			return array(
				'run_id'  => $run_id,
				'status'  => $status,
				'message' => $is_empty ? 'An empty source is rejected to protect the catalog.' : null,
			);
		} catch ( \Throwable $exception ) {
			if ( $transaction_started ) {
				$this->rollback_transaction();
			}
			throw $exception;
		} finally {
			$release_sql = $this->wpdb->prepare( 'SELECT RELEASE_LOCK(%s)', $lock_name );
			$this->wpdb->get_var( $release_sql );
		}
	}

	/**
	 * Applies or analyzes one batch atomically. A replay with the same payload
	 * returns the stored counters and never processes products twice.
	 *
	 * @param string $run_id Run UUID.
	 * @param array  $batch Validated batch.
	 * @return array
	 */
	public function process_batch( $run_id, array $batch ) {
		$encoded = wp_json_encode( $batch['products'], JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES );
		if ( ! is_string( $encoded ) ) {
			throw new \RuntimeException( 'Unable to fingerprint the synchronization batch.' );
		}
		$payload_hash       = hash( 'sha256', $encoded );
		$transaction_started = false;

		try {
			$this->begin_transaction();
			$transaction_started = true;
			$run                 = $this->get_run_for_update( $run_id );
			if ( null === $run ) {
				throw new Sync_Exception( 'catalog_sync_run_not_found', 'The run does not exist.', 404 );
			}
			if ( ! in_array( $run['status'], array( 'started', 'running' ), true ) ) {
				throw new Sync_Exception(
					'catalog_sync_run_not_writable',
					'The run no longer accepts batches.',
					409
				);
			}
			if (
				0 < (int) $run['expected_batch_count'] &&
				$batch['batch_number'] > (int) $run['expected_batch_count']
			) {
				throw new Sync_Exception(
					'catalog_sync_unexpected_batch',
					'The batch number exceeds the expected batch count.',
					400
				);
			}

			$existing_batch = $this->get_batch_for_update( $run_id, $batch['batch_number'] );
			if ( null !== $existing_batch ) {
				if ( ! hash_equals( $existing_batch['payload_hash'], $payload_hash ) ) {
					throw new Sync_Exception(
						'catalog_sync_batch_conflict',
						'The batch number has already been used with different content.',
						409
					);
				}

				$this->commit_transaction();
				$transaction_started = false;
				return $this->batch_result( $run_id, $existing_batch, true );
			}

			$product_count = count( $batch['products'] );
			if ( (int) $run['received_count'] + $product_count > (int) $run['expected_product_count'] ) {
				throw new Sync_Exception(
					'catalog_sync_product_count_exceeded',
					'The run received more products than declared.',
					400
				);
			}

			$counters = array(
				'inserted_count'    => 0,
				'updated_count'     => 0,
				'unchanged_count'   => 0,
				'reactivated_count' => 0,
			);
			$now = current_time( 'mysql', true );
			foreach ( $batch['products'] as $product ) {
				$action = $this->process_product(
					$run_id,
					$product,
					$now,
					1 === (int) $run['dry_run']
				);
				++$counters[ $action . '_count' ];

				$seen = $this->wpdb->insert(
					$this->run_items_table(),
					array(
						'run_uuid'    => $run_id,
						'source_id'   => $product['source_id'],
						'content_hash' => $product['content_hash'],
						'action'      => $action,
					),
					array( '%s', '%s', '%s', '%s' )
				);
				if ( false === $seen ) {
					throw new Sync_Exception(
						'catalog_sync_duplicate_source_id',
						'A sourceId was sent in more than one batch.',
						400
					);
				}
			}

			$batch_row = array(
				'run_uuid'          => $run_id,
				'batch_number'      => $batch['batch_number'],
				'payload_hash'      => $payload_hash,
				'product_count'     => $product_count,
				'inserted_count'    => $counters['inserted_count'],
				'updated_count'     => $counters['updated_count'],
				'unchanged_count'   => $counters['unchanged_count'],
				'reactivated_count' => $counters['reactivated_count'],
				'processed_at'      => $now,
			);
			if ( false === $this->wpdb->insert( $this->batches_table(), $batch_row ) ) {
				throw new \RuntimeException( 'Unable to record the synchronization batch.' );
			}

			$run_updated = $this->wpdb->update(
				$this->runs_table(),
				array(
					'status'              => 'running',
					'received_count'      => (int) $run['received_count'] + $product_count,
					'inserted_count'      => (int) $run['inserted_count'] + $counters['inserted_count'],
					'updated_count'       => (int) $run['updated_count'] + $counters['updated_count'],
					'unchanged_count'     => (int) $run['unchanged_count'] + $counters['unchanged_count'],
					'reactivated_count'   => (int) $run['reactivated_count'] + $counters['reactivated_count'],
					'last_activity_at'    => $now,
				),
				array( 'run_uuid' => $run_id )
			);
			if ( false === $run_updated || 1 !== $run_updated ) {
				throw new \RuntimeException( 'Unable to update synchronization run counters.' );
			}

			$this->commit_transaction();
			$transaction_started = false;
			return $this->batch_result( $run_id, $batch_row, false );
		} catch ( \Throwable $exception ) {
			if ( $transaction_started ) {
				$this->rollback_transaction();
			}
			throw $exception;
		}
	}

	/**
	 * Finalizes a complete run. Only this method can deactivate products.
	 *
	 * @param string $run_id Run UUID.
	 * @return array
	 */
	public function complete_run( $run_id ) {
		$transaction_started = false;
		try {
			$this->begin_transaction();
			$transaction_started = true;
			$run                 = $this->get_run_for_update( $run_id );
			if ( null === $run ) {
				throw new Sync_Exception( 'catalog_sync_run_not_found', 'The run does not exist.', 404 );
			}
			if ( 'completed' === $run['status'] ) {
				$this->commit_transaction();
				$transaction_started = false;
				return $this->run_result( $run );
			}
			if ( ! in_array( $run['status'], array( 'started', 'running' ), true ) ) {
				throw new Sync_Exception(
					'catalog_sync_run_not_completable',
					'The run cannot be completed.',
					409
				);
			}

			$batch_stats = $this->batch_stats( $run_id );
			$item_count  = $this->count_run_items( $run_id );
			if ( ! $this->is_run_complete( $run, $batch_stats, $item_count ) ) {
				$this->finish_run_with_error(
					$run_id,
					'failed',
					'The received products or batches do not match the declared run.'
				);
				$this->commit_transaction();
				$transaction_started = false;
				throw new Sync_Exception(
					'catalog_sync_incomplete_run',
					'The run is incomplete; no product was deactivated.',
					422
				);
			}

			$active_before = (int) $run['active_before_count'];
			$candidates    = $this->count_deactivation_candidates( $run_id );
			$percentage    = 0 === $active_before
				? 0.0
				: ( $candidates * 100.0 ) / $active_before;
			$rounded       = round( $percentage, 2 );

			if ( $percentage > Sync_Config::max_deactivation_percentage() ) {
				$this->finish_run_with_error(
					$run_id,
					'rejected',
					'The mass-deactivation guardrail rejected the run.',
					$active_before,
					$candidates,
					$rounded
				);
				$this->commit_transaction();
				$transaction_started = false;
				throw new Sync_Exception(
					'catalog_sync_deactivation_guardrail',
					'The run was rejected by the mass-deactivation guardrail; the catalog remains active.',
					422
				);
			}

			$deactivated = 0;
			$completed_at = current_time( 'mysql', true );
			if ( 0 === (int) $run['dry_run'] && 0 < $candidates ) {
				$products_table  = $this->products_table();
				$run_items_table = $this->run_items_table();
				$sql = $this->wpdb->prepare(
					"UPDATE {$products_table} product
					LEFT JOIN {$run_items_table} item
						ON item.run_uuid = %s AND item.source_id = product.source_id
					SET product.is_active = 0, product.updated_at = %s
					WHERE product.is_active = 1 AND item.id IS NULL",
					$run_id,
					$completed_at
				);
				$deactivated = $this->wpdb->query( $sql );
				if ( false === $deactivated ) {
					throw new \RuntimeException( 'Unable to deactivate products absent from the run.' );
				}
			}

			$updated = $this->wpdb->update(
				$this->runs_table(),
				array(
					'status'                       => 'completed',
					'deactivated_count'            => (int) $deactivated,
					'candidate_deactivation_count' => $candidates,
					'active_before_count'          => $active_before,
					'deactivation_percentage'      => $rounded,
					'last_activity_at'             => $completed_at,
					'completed_at'                 => $completed_at,
					'error_message'                => null,
				),
				array( 'run_uuid' => $run_id )
			);
			if ( false === $updated || 1 !== $updated ) {
				throw new \RuntimeException( 'Unable to finalize the synchronization run.' );
			}

			$this->commit_transaction();
			$transaction_started = false;
			$run['status']                       = 'completed';
			$run['deactivated_count']            = (int) $deactivated;
			$run['candidate_deactivation_count'] = $candidates;
			$run['active_before_count']          = $active_before;
			$run['deactivation_percentage']      = $rounded;
			$this->cleanup_history();

			return $this->run_result( $run );
		} catch ( \Throwable $exception ) {
			if ( $transaction_started ) {
				$this->rollback_transaction();
			}
			throw $exception;
		}
	}

	/**
	 * Reads one public page directly in SQL.
	 *
	 * @param int $page Page.
	 * @param int $per_page Page size.
	 * @return array
	 */
	public function get_active_products( $page, $per_page, $search = '', $family = '', $brand = '' ) {
		$table                    = $this->products_table();
		$exact_reference          = '' !== $search && $this->has_active_exact_reference( $search );
		$filters                  = $this->build_public_product_filters(
			$search,
			$family,
			$brand,
			$exact_reference
		);
		$where_sql                = implode( ' AND ', $filters['clauses'] );
		$count_sql                = $this->wpdb->prepare(
			"SELECT COUNT(*) FROM {$table} WHERE {$where_sql}",
			$filters['parameters']
		);
		$total                    = $this->wpdb->get_var( $count_sql );
		$this->throw_on_last_error( 'Unable to count catalog products.' );

		$maximum_page_before_overflow = intdiv( PHP_INT_MAX, $per_page );
		$offset = $page > $maximum_page_before_overflow ? PHP_INT_MAX : ( $page - 1 ) * $per_page;
		$query_parameters = array_merge( $filters['parameters'], array( $per_page, $offset ) );
		$sql    = $this->wpdb->prepare(
			"SELECT id, source_id, reference, name, short_description, family_code,
				family_label, brand, source_updated_at
			FROM {$table}
			WHERE {$where_sql}
			ORDER BY name ASC, reference ASC, source_id ASC
			LIMIT %d OFFSET %d",
			$query_parameters
		);
		$rows = $this->wpdb->get_results( $sql, ARRAY_A );
		if ( '' !== $this->wpdb->last_error || ! is_array( $rows ) ) {
			throw new \RuntimeException( 'Unable to read catalog products.' );
		}

		$items = array();
		foreach ( $rows as $row ) {
			$items[] = $this->public_product( $row );
		}

		return array( 'items' => $items, 'total_items' => (int) $total );
	}

	/**
	 * Returns the active public product identified by its mirror ID.
	 *
	 * @param int $product_id Product mirror ID.
	 * @return array|null
	 */
	public function get_active_product( $product_id ) {
		$table = $this->products_table();
		$sql   = $this->wpdb->prepare(
			"SELECT id, source_id, reference, name, short_description, family_code,
				family_label, brand, source_updated_at
			FROM {$table}
			WHERE id = %d AND is_active = %d
			LIMIT 1",
			$product_id,
			1
		);
		$row = $this->wpdb->get_row( $sql, ARRAY_A );
		$this->throw_on_last_error( 'Unable to read the catalog product.' );

		return is_array( $row ) ? $this->public_product( $row ) : null;
	}

	/**
	 * Returns active family and brand facets without loading products in PHP.
	 *
	 * @return array
	 */
	public function get_active_product_filters() {
		$table = $this->products_table();
		$families = $this->wpdb->get_results(
			"SELECT family_code, MAX(NULLIF(family_label, '')) AS family_label
			FROM {$table}
			WHERE is_active = 1 AND family_code IS NOT NULL AND family_code <> ''
			GROUP BY family_code
			ORDER BY COALESCE(MAX(NULLIF(family_label, '')), family_code) ASC, family_code ASC",
			ARRAY_A
		);
		if ( '' !== $this->wpdb->last_error || ! is_array( $families ) ) {
			throw new \RuntimeException( 'Unable to read catalog family filters.' );
		}

		$brands = $this->wpdb->get_col(
			"SELECT DISTINCT brand FROM {$table}
			WHERE is_active = 1 AND brand IS NOT NULL AND brand <> ''
			ORDER BY brand ASC"
		);
		if ( '' !== $this->wpdb->last_error || ! is_array( $brands ) ) {
			throw new \RuntimeException( 'Unable to read catalog brand filters.' );
		}

		return array(
			'families' => array_map(
				static function ( array $family ) {
					return array(
						'code'  => $family['family_code'],
						'label' => empty( $family['family_label'] )
							? $family['family_code']
							: $family['family_label'],
					);
				},
				$families
			),
			'brands'   => array_values( $brands ),
		);
	}

	/** @return array */
	private function build_public_product_filters( $search, $family, $brand, $exact_reference = false ) {
		$clauses    = array( 'is_active = %d' );
		$parameters = array( 1 );

		if ( '' !== $search ) {
			if ( $exact_reference ) {
				$clauses[]    = 'reference = %s';
				$parameters[] = $search;
			} else {
				$like       = '%' . $this->wpdb->esc_like( $search ) . '%';
				$clauses[]  = '(reference LIKE %s OR name LIKE %s OR brand LIKE %s OR family_label LIKE %s)';
				$parameters = array_merge( $parameters, array( $like, $like, $like, $like ) );
			}
		}
		if ( '' !== $family ) {
			$clauses[]    = 'family_code = %s';
			$parameters[] = $family;
		}
		if ( '' !== $brand ) {
			$clauses[]    = 'brand = %s';
			$parameters[] = $brand;
		}

		return array( 'clauses' => $clauses, 'parameters' => $parameters );
	}

	/** @return bool */
	private function has_active_exact_reference( $reference ) {
		$table = $this->products_table();
		$sql   = $this->wpdb->prepare(
			"SELECT 1 FROM {$table} WHERE reference = %s AND is_active = %d LIMIT 1",
			$reference,
			1
		);
		$exists = $this->wpdb->get_var( $sql );
		$this->throw_on_last_error( 'Unable to inspect an exact catalog reference.' );

		return null !== $exists;
	}

	/** @return array */
	private function public_product( array $row ) {
		return array(
			'id'                 => (int) $row['id'],
			'sourceId'           => $row['source_id'],
			'reference'          => $row['reference'],
			'name'               => $row['name'],
			'shortDescription'   => $row['short_description'],
			'familyCode'         => $row['family_code'],
			'familyLabel'        => $row['family_label'],
			'brand'              => $row['brand'],
			'imageUrl'           => null,
			'sourceUpdatedAtUtc' => null === $row['source_updated_at']
				? null
				: str_replace( ' ', 'T', $row['source_updated_at'] ) . 'Z',
		);
	}

	/** @return string Action: inserted, updated, unchanged or reactivated. */
	private function process_product( $run_id, array $product, $now, $dry_run ) {
		$products_table = $this->products_table();
		$sql      = $this->wpdb->prepare(
			"SELECT * FROM {$products_table} WHERE source_id = %s LIMIT 1 FOR UPDATE",
			$product['source_id']
		);
		$existing = $this->wpdb->get_row( $sql, ARRAY_A );
		$this->throw_on_last_error( 'Unable to inspect a synchronized product.' );

		if ( ! is_array( $existing ) ) {
			if ( ! $dry_run ) {
				$this->insert_product( $run_id, $product, $now );
			}
			return 'inserted';
		}

		$stored_hash = $existing['content_hash'];
		if ( null === $stored_hash || '' === $stored_hash ) {
			$stored_hash = Product_Hasher::hash_product( $existing );
		}
		$is_reactivation = 0 === (int) $existing['is_active'];
		$is_unchanged    = hash_equals( $stored_hash, $product['content_hash'] );
		$action          = $is_reactivation ? 'reactivated' : ( $is_unchanged ? 'unchanged' : 'updated' );

		if ( ! $dry_run ) {
			$this->update_product( (int) $existing['id'], $run_id, $product, $now, $action );
		}

		return $action;
	}

	/** @return void */
	private function insert_product( $run_id, array $product, $now ) {
		$data = array(
			'source_id'          => $product['source_id'],
			'reference'          => $product['reference'],
			'name'               => $product['name'],
			'short_description'  => $product['short_description'],
			'family_code'        => $product['family_code'],
			'family_label'       => $product['family_label'],
			'brand'              => $product['brand'],
			'is_active'          => 1,
			'content_hash'       => $product['content_hash'],
			'last_seen_run_uuid' => $run_id,
			'source_updated_at'  => $product['source_updated_at'],
			'last_synced_at'     => $now,
			'created_at'         => $now,
			'updated_at'         => $now,
		);
		if ( false === $this->wpdb->insert( $this->products_table(), $data ) ) {
			throw new \RuntimeException( 'Unable to insert a synchronized product.' );
		}
	}

	/** @return void */
	private function update_product( $id, $run_id, array $product, $now, $action ) {
		if ( 'unchanged' === $action ) {
			$data = array(
				'content_hash'       => $product['content_hash'],
				'last_seen_run_uuid' => $run_id,
				'last_synced_at'     => $now,
			);
		} else {
			$data = array(
				'reference'          => $product['reference'],
				'name'               => $product['name'],
				'short_description'  => $product['short_description'],
				'family_code'        => $product['family_code'],
				'family_label'       => $product['family_label'],
				'brand'              => $product['brand'],
				'is_active'          => 1,
				'content_hash'       => $product['content_hash'],
				'last_seen_run_uuid' => $run_id,
				'source_updated_at'  => $product['source_updated_at'],
				'last_synced_at'     => $now,
				'updated_at'         => $now,
			);
		}

		if ( false === $this->wpdb->update( $this->products_table(), $data, array( 'id' => $id ) ) ) {
			throw new \RuntimeException( 'Unable to update a synchronized product.' );
		}
	}

	/** @return array|null */
	private function get_run_for_update( $run_id ) {
		$runs_table = $this->runs_table();
		$sql = $this->wpdb->prepare(
			"SELECT * FROM {$runs_table} WHERE run_uuid = %s LIMIT 1 FOR UPDATE",
			$run_id
		);
		$row = $this->wpdb->get_row( $sql, ARRAY_A );
		$this->throw_on_last_error( 'Unable to read the synchronization run.' );

		return is_array( $row ) ? $row : null;
	}

	/** @return array|null */
	private function get_batch_for_update( $run_id, $batch_number ) {
		$batches_table = $this->batches_table();
		$sql = $this->wpdb->prepare(
			"SELECT * FROM {$batches_table}
			WHERE run_uuid = %s AND batch_number = %d LIMIT 1 FOR UPDATE",
			$run_id,
			$batch_number
		);
		$row = $this->wpdb->get_row( $sql, ARRAY_A );
		$this->throw_on_last_error( 'Unable to inspect the synchronization batch.' );

		return is_array( $row ) ? $row : null;
	}

	/** @return array */
	private function batch_result( $run_id, array $row, $replayed ) {
		return array(
			'run_id'             => $run_id,
			'batch_number'       => (int) $row['batch_number'],
			'status'             => 'running',
			'replayed'           => (bool) $replayed,
			'received_count'     => (int) $row['product_count'],
			'inserted_count'     => (int) $row['inserted_count'],
			'updated_count'      => (int) $row['updated_count'],
			'unchanged_count'    => (int) $row['unchanged_count'],
			'reactivated_count'  => (int) $row['reactivated_count'],
		);
	}

	/** @return array */
	private function run_result( array $row ) {
		return array(
			'run_id'                         => $row['run_uuid'],
			'status'                         => $row['status'],
			'received_count'                 => (int) $row['received_count'],
			'inserted_count'                 => (int) $row['inserted_count'],
			'updated_count'                  => (int) $row['updated_count'],
			'unchanged_count'                => (int) $row['unchanged_count'],
			'reactivated_count'              => (int) $row['reactivated_count'],
			'deactivated_count'              => (int) $row['deactivated_count'],
			'candidate_deactivation_count'   => (int) $row['candidate_deactivation_count'],
			'active_before_count'            => (int) $row['active_before_count'],
			'deactivation_percentage'        => (float) $row['deactivation_percentage'],
			'guardrail_status'               => 'completed' === $row['status'] ? 'ok' : 'blocked',
			'dry_run'                        => 1 === (int) $row['dry_run'],
		);
	}

	/** @return array */
	private function batch_stats( $run_id ) {
		$batches_table = $this->batches_table();
		$sql = $this->wpdb->prepare(
			"SELECT COUNT(*) AS batch_count, COALESCE(SUM(product_count), 0) AS product_count,
				COALESCE(MIN(batch_number), 0) AS minimum_batch,
				COALESCE(MAX(batch_number), 0) AS maximum_batch
			FROM {$batches_table} WHERE run_uuid = %s",
			$run_id
		);
		$row = $this->wpdb->get_row( $sql, ARRAY_A );
		if ( ! is_array( $row ) || '' !== $this->wpdb->last_error ) {
			throw new \RuntimeException( 'Unable to validate synchronization batches.' );
		}

		return array_map( 'intval', $row );
	}

	/** @return int */
	private function count_run_items( $run_id ) {
		$run_items_table = $this->run_items_table();
		$sql   = $this->wpdb->prepare(
			"SELECT COUNT(*) FROM {$run_items_table} WHERE run_uuid = %s",
			$run_id
		);
		$count = $this->wpdb->get_var( $sql );
		$this->throw_on_last_error( 'Unable to count run products.' );

		return (int) $count;
	}

	/** @return bool */
	private function is_run_complete( array $run, array $stats, $item_count ) {
		$expected_products = (int) $run['expected_product_count'];
		$expected_batches  = (int) $run['expected_batch_count'];
		$batches_contiguous = 0 < $stats['batch_count'] &&
			1 === $stats['minimum_batch'] &&
			$stats['batch_count'] === $stats['maximum_batch'];

		return 0 < $expected_products &&
			(int) $run['received_count'] === $expected_products &&
			$stats['product_count'] === $expected_products &&
			$item_count === $expected_products &&
			$batches_contiguous &&
			( 0 === $expected_batches || $stats['batch_count'] === $expected_batches );
	}

	/** @return int */
	private function count_active_products() {
		$products_table = $this->products_table();
		$count = $this->wpdb->get_var(
			"SELECT COUNT(*) FROM {$products_table} WHERE is_active = 1"
		);
		$this->throw_on_last_error( 'Unable to count active products.' );

		return (int) $count;
	}

	/** @return int */
	private function count_deactivation_candidates( $run_id ) {
		$products_table  = $this->products_table();
		$run_items_table = $this->run_items_table();
		$sql = $this->wpdb->prepare(
			"SELECT COUNT(*) FROM {$products_table} product
			LEFT JOIN {$run_items_table} item
				ON item.run_uuid = %s AND item.source_id = product.source_id
			WHERE product.is_active = 1 AND item.id IS NULL",
			$run_id
		);
		$count = $this->wpdb->get_var( $sql );
		$this->throw_on_last_error( 'Unable to calculate absent products.' );

		return (int) $count;
	}

	/** @return void */
	private function finish_run_with_error(
		$run_id,
		$status,
		$message,
		$active_before = 0,
		$candidates = 0,
		$percentage = 0.0
	) {
		$now     = current_time( 'mysql', true );
		$updated = $this->wpdb->update(
			$this->runs_table(),
			array(
				'status'                       => $status,
				'active_before_count'          => $active_before,
				'candidate_deactivation_count' => $candidates,
				'deactivation_percentage'      => $percentage,
				'last_activity_at'             => $now,
				'completed_at'                 => $now,
				'error_message'                => $message,
			),
			array( 'run_uuid' => $run_id )
		);
		if ( false === $updated || 1 !== $updated ) {
			throw new \RuntimeException( 'Unable to record the rejected synchronization run.' );
		}
	}

	/** @return void */
	private function expire_stale_runs() {
		$runs_table = $this->runs_table();
		$cutoff = gmdate(
			'Y-m-d H:i:s',
			time() - ( Sync_Config::run_timeout_minutes() * MINUTE_IN_SECONDS )
		);
		$now = current_time( 'mysql', true );
		$sql = $this->wpdb->prepare(
			"UPDATE {$runs_table}
			SET status = 'failed', completed_at = %s, last_activity_at = %s,
				error_message = 'Run expired before completion.'
			WHERE status IN ('started', 'running')
				AND COALESCE(last_activity_at, started_at) < %s",
			$now,
			$now,
			$cutoff
		);
		if ( false === $this->wpdb->query( $sql ) ) {
			throw new \RuntimeException( 'Unable to expire stale synchronization runs.' );
		}
	}

	/** Opportunistic, bounded cleanup; products are never touched. @return void */
	private function cleanup_history() {
		$runs_table = $this->runs_table();
		$cutoff = gmdate(
			'Y-m-d H:i:s',
			time() - ( Sync_Config::history_retention_days() * DAY_IN_SECONDS )
		);
		$sql = $this->wpdb->prepare(
			"SELECT run_uuid FROM {$runs_table}
			WHERE completed_at IS NOT NULL AND completed_at < %s
				AND status NOT IN ('started', 'running')
			ORDER BY completed_at ASC LIMIT 500",
			$cutoff
		);
		$run_ids = $this->wpdb->get_col( $sql );
		if ( ! is_array( $run_ids ) || '' !== $this->wpdb->last_error ) {
			return;
		}

		foreach ( $run_ids as $old_run_id ) {
			$this->wpdb->delete( $this->run_items_table(), array( 'run_uuid' => $old_run_id ), array( '%s' ) );
			$this->wpdb->delete( $this->batches_table(), array( 'run_uuid' => $old_run_id ), array( '%s' ) );
			$this->wpdb->delete( $this->runs_table(), array( 'run_uuid' => $old_run_id ), array( '%s' ) );
		}
	}

	/** @return void */
	private function begin_transaction() {
		if ( false === $this->wpdb->query( 'START TRANSACTION' ) ) {
			throw new \RuntimeException( 'Unable to start a database transaction.' );
		}
	}

	/** @return void */
	private function commit_transaction() {
		if ( false === $this->wpdb->query( 'COMMIT' ) ) {
			throw new \RuntimeException( 'Unable to commit a database transaction.' );
		}
	}

	/** @return void */
	private function rollback_transaction() {
		$this->wpdb->query( 'ROLLBACK' );
	}

	/** @return void */
	private function throw_on_last_error( $message ) {
		if ( '' !== $this->wpdb->last_error ) {
			throw new \RuntimeException( $message );
		}
	}

	/** @return string */
	private function products_table() {
		return $this->wpdb->prefix . 'catalog_products';
	}

	/** @return string */
	private function runs_table() {
		return $this->wpdb->prefix . 'catalog_sync_runs';
	}

	/** @return string */
	private function batches_table() {
		return $this->wpdb->prefix . 'catalog_sync_batches';
	}

	/** @return string */
	private function run_items_table() {
		return $this->wpdb->prefix . 'catalog_sync_run_items';
	}
}
