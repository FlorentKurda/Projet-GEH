<?php
/**
 * Database access for synchronized products and synchronization runs.
 *
 * @package ProductCatalogSync
 */

namespace ProductCatalogSync;

if ( ! defined( 'ABSPATH' ) ) {
	exit;
}

/**
 * Keeps every SQL operation in one small, testable boundary.
 */
final class Catalog_Repository {
	/**
	 * WordPress database connection.
	 *
	 * @var \wpdb
	 */
	private $wpdb;

	/**
	 * @param \wpdb $wpdb WordPress database connection.
	 */
	public function __construct( \wpdb $wpdb ) {
		$this->wpdb = $wpdb;
	}

	/**
	 * Returns a previously recorded run, if any.
	 *
	 * @param string $run_id Validated run UUID.
	 * @return array|null
	 * @throws \RuntimeException When the query fails.
	 */
	public function get_sync_run( $run_id ) {
		$table = $this->runs_table();
		$sql   = $this->wpdb->prepare(
			"SELECT run_uuid, status, received_count, inserted_count, updated_count
			FROM {$table}
			WHERE run_uuid = %s
			LIMIT 1",
			$run_id
		);

		$row = $this->wpdb->get_row( $sql, ARRAY_A );
		if ( '' !== $this->wpdb->last_error ) {
			throw new \RuntimeException( 'Unable to read the synchronization journal.' );
		}

		return is_array( $row ) ? $row : null;
	}

	/**
	 * Atomically records the run and upserts every validated product.
	 *
	 * @param array $payload Normalized payload returned by Product_Validator.
	 * @return array Synchronization counters.
	 * @throws \RuntimeException When no complete transaction can be persisted.
	 */
	public function synchronize( array $payload ) {
		$run_id              = $payload['run_id'];
		$received_count      = count( $payload['products'] );
		$started_at          = current_time( 'mysql', true );
		$transaction_started = false;
		$inserted_count      = 0;
		$updated_count       = 0;

		try {
			if ( false === $this->wpdb->query( 'START TRANSACTION' ) ) {
				throw new \RuntimeException( 'Unable to start the synchronization transaction.' );
			}
			$transaction_started = true;

			$run_inserted = $this->wpdb->insert(
				$this->runs_table(),
				array(
					'run_uuid'       => $run_id,
					'schema_version' => $payload['schema_version'],
					'status'         => 'running',
					'received_count' => $received_count,
					'inserted_count' => 0,
					'updated_count'  => 0,
					'started_at'     => $started_at,
					'completed_at'   => null,
					'error_message'  => null,
				),
				array( '%s', '%d', '%s', '%d', '%d', '%d', '%s', '%s', '%s' )
			);

			if ( false === $run_inserted ) {
				throw new \RuntimeException( 'Unable to create the synchronization journal entry.' );
			}

			$synchronized_at = current_time( 'mysql', true );
			foreach ( $payload['products'] as $product ) {
				if ( $this->upsert_product( $product, $synchronized_at ) ) {
					++$inserted_count;
				} else {
					++$updated_count;
				}
			}

			$completed_at = current_time( 'mysql', true );
			$run_updated  = $this->wpdb->update(
				$this->runs_table(),
				array(
					'status'         => 'success',
					'inserted_count' => $inserted_count,
					'updated_count'  => $updated_count,
					'completed_at'   => $completed_at,
					'error_message'  => null,
				),
				array(
					'run_uuid' => $run_id,
				),
				array( '%s', '%d', '%d', '%s', '%s' ),
				array( '%s' )
			);

			if ( false === $run_updated || 1 !== $run_updated ) {
				throw new \RuntimeException( 'Unable to complete the synchronization journal entry.' );
			}

			if ( false === $this->wpdb->query( 'COMMIT' ) ) {
				throw new \RuntimeException( 'Unable to commit the synchronization transaction.' );
			}
			$transaction_started = false;

			return array(
				'run_id'          => $run_id,
				'status'          => 'success',
				'received_count'  => $received_count,
				'inserted_count'  => $inserted_count,
				'updated_count'   => $updated_count,
			);
		} catch ( \Throwable $exception ) {
			if ( $transaction_started ) {
				$this->wpdb->query( 'ROLLBACK' );
			}

			$this->record_failed_run(
				$payload,
				$started_at,
				'The synchronization transaction failed.'
			);

			throw $exception;
		}
	}

	/**
	 * Reads one public page directly in SQL.
	 *
	 * @param int $page One-based page number.
	 * @param int $per_page Page size, already validated as 1..24.
	 * @return array{items: array, total_items: int}
	 * @throws \RuntimeException When a database query fails.
	 */
	public function get_active_products( $page, $per_page ) {
		$table = $this->products_table();
		$total = $this->wpdb->get_var( "SELECT COUNT(*) FROM {$table} WHERE is_active = 1" );

		if ( '' !== $this->wpdb->last_error ) {
			throw new \RuntimeException( 'Unable to count catalog products.' );
		}

		$maximum_page_before_overflow = intdiv( PHP_INT_MAX, $per_page );
		$offset = $page > $maximum_page_before_overflow
			? PHP_INT_MAX
			: ( $page - 1 ) * $per_page;

		$sql = $this->wpdb->prepare(
			"SELECT source_id, reference, name, short_description, family_code,
				family_label, brand, source_updated_at
			FROM {$table}
			WHERE is_active = %d
			ORDER BY name ASC, reference ASC, source_id ASC
			LIMIT %d OFFSET %d",
			1,
			$per_page,
			$offset
		);

		$rows = $this->wpdb->get_results( $sql, ARRAY_A );
		if ( '' !== $this->wpdb->last_error || ! is_array( $rows ) ) {
			throw new \RuntimeException( 'Unable to read catalog products.' );
		}

		$items = array();
		foreach ( $rows as $row ) {
			$items[] = array(
				'sourceId'          => $row['source_id'],
				'reference'         => $row['reference'],
				'name'              => $row['name'],
				'shortDescription'  => $row['short_description'],
				'familyCode'        => $row['family_code'],
				'familyLabel'       => $row['family_label'],
				'brand'             => $row['brand'],
				'sourceUpdatedAtUtc' => null === $row['source_updated_at']
					? null
					: str_replace( ' ', 'T', $row['source_updated_at'] ) . 'Z',
			);
		}

		return array(
			'items'       => $items,
			'total_items' => (int) $total,
		);
	}

	/**
	 * Inserts a product or updates the row selected by source_id.
	 *
	 * @param array $product Validated product values with database field names.
	 * @param string $synchronized_at UTC MySQL timestamp shared by this run.
	 * @return bool True for an insert, false for an update.
	 * @throws \RuntimeException When a database query fails.
	 */
	private function upsert_product( array $product, $synchronized_at ) {
		$table = $this->products_table();
		$sql   = $this->wpdb->prepare(
			"SELECT id FROM {$table} WHERE source_id = %s LIMIT 1 FOR UPDATE",
			$product['source_id']
		);

		$existing_id = $this->wpdb->get_var( $sql );
		if ( '' !== $this->wpdb->last_error ) {
			throw new \RuntimeException( 'Unable to locate a synchronized product.' );
		}

		$data = array(
			'reference'          => $product['reference'],
			'name'               => $product['name'],
			'short_description'  => $product['short_description'],
			'family_code'        => $product['family_code'],
			'family_label'       => $product['family_label'],
			'brand'              => $product['brand'],
			'is_active'          => 1,
			'source_updated_at'  => $product['source_updated_at'],
			'last_synced_at'     => $synchronized_at,
			'updated_at'         => $synchronized_at,
		);
		$formats = array( '%s', '%s', '%s', '%s', '%s', '%s', '%d', '%s', '%s', '%s' );

		if ( null !== $existing_id ) {
			$updated = $this->wpdb->update(
				$table,
				$data,
				array( 'id' => (int) $existing_id ),
				$formats,
				array( '%d' )
			);

			if ( false === $updated ) {
				throw new \RuntimeException( 'Unable to update a synchronized product.' );
			}

			return false;
		}

		$data = array_merge(
			array(
				'source_id' => $product['source_id'],
			),
			$data,
			array(
				'created_at' => $synchronized_at,
			)
		);
		$formats = array_merge( array( '%s' ), $formats, array( '%s' ) );

		$inserted = $this->wpdb->insert( $table, $data, $formats );
		if ( false === $inserted ) {
			throw new \RuntimeException( 'Unable to insert a synchronized product.' );
		}

		return true;
	}

	/**
	 * Records a failed, fully rolled-back synchronization when possible. A
	 * duplicate UUID is deliberately not overwritten because it may belong to a
	 * concurrent request that completed successfully.
	 *
	 * @param array $payload Validated payload.
	 * @param string $started_at UTC MySQL timestamp.
	 * @param string $message Safe error message (never credentials or SQL values).
	 * @return void
	 */
	private function record_failed_run( array $payload, $started_at, $message ) {
		$this->wpdb->insert(
			$this->runs_table(),
			array(
				'run_uuid'       => $payload['run_id'],
				'schema_version' => $payload['schema_version'],
				'status'         => 'failed',
				'received_count' => count( $payload['products'] ),
				'inserted_count' => 0,
				'updated_count'  => 0,
				'started_at'     => $started_at,
				'completed_at'   => current_time( 'mysql', true ),
				'error_message'  => $message,
			),
			array( '%s', '%d', '%s', '%d', '%d', '%d', '%s', '%s', '%s' )
		);
	}

	/**
	 * @return string
	 */
	private function products_table() {
		return $this->wpdb->prefix . 'catalog_products';
	}

	/**
	 * @return string
	 */
	private function runs_table() {
		return $this->wpdb->prefix . 'catalog_sync_runs';
	}
}
