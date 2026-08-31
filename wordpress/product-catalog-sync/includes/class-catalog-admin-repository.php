<?php
/**
 * Read-only persistence queries for catalog supervision.
 *
 * @package ProductCatalogSync
 */

namespace ProductCatalogSync;

if ( ! defined( 'ABSPATH' ) ) {
	exit;
}

final class Catalog_Admin_Repository {
	/** @var \wpdb */
	private $wpdb;

	/** @param \wpdb $wpdb WordPress database connection. */
	public function __construct( \wpdb $wpdb ) {
		$this->wpdb = $wpdb;
	}

	/**
	 * Returns bounded data for the supervision dashboard.
	 *
	 * @param int $page Page number.
	 * @param int $per_page Page size.
	 * @return array
	 */
	public function get_dashboard_data( $page, $per_page ) {
		return array(
			'active_product_count'  => $this->count_active_products(),
			'latest_run'            => $this->get_latest_run(),
			'latest_real_run'       => $this->get_latest_real_run(),
			'latest_successful_run' => $this->get_latest_successful_run(),
			'running_run'           => $this->get_running_run(),
			'recent_runs'           => $this->get_recent_runs( $page, $per_page ),
			'total_runs'            => $this->count_runs(),
		);
	}

	/** @return int */
	private function count_active_products() {
		$table = $this->products_table();
		$sql   = $this->wpdb->prepare(
			"SELECT COUNT(*) FROM {$table} WHERE is_active = %d",
			1
		);
		$count = $this->wpdb->get_var( $sql );
		$this->throw_on_last_error( 'Unable to count active products for supervision.' );

		return (int) $count;
	}

	/** @return array|null */
	private function get_latest_run() {
		$table   = $this->runs_table();
		$columns = $this->run_columns();
		$row   = $this->wpdb->get_row(
			"SELECT {$columns}
			FROM {$table}
			ORDER BY started_at DESC, id DESC
			LIMIT 1",
			ARRAY_A
		);
		$this->throw_on_last_error( 'Unable to read the latest synchronization run.' );

		return is_array( $row ) ? $this->normalize_run( $row ) : null;
	}

	/** @return array|null */
	private function get_latest_real_run() {
		$table   = $this->runs_table();
		$columns = $this->run_columns();
		$sql     = $this->wpdb->prepare(
			"SELECT {$columns}
			FROM {$table}
			WHERE dry_run = %d
			ORDER BY started_at DESC, id DESC
			LIMIT 1",
			0
		);
		$row = $this->wpdb->get_row( $sql, ARRAY_A );
		$this->throw_on_last_error( 'Unable to read the latest real synchronization run.' );

		return is_array( $row ) ? $this->normalize_run( $row ) : null;
	}

	/** @return array|null */
	private function get_latest_successful_run() {
		$table   = $this->runs_table();
		$columns = $this->run_columns();
		$sql   = $this->wpdb->prepare(
			"SELECT {$columns}
			FROM {$table}
			WHERE status = %s AND dry_run = %d
			ORDER BY completed_at DESC, id DESC
			LIMIT 1",
			'completed',
			0
		);
		$row = $this->wpdb->get_row( $sql, ARRAY_A );
		$this->throw_on_last_error( 'Unable to read the latest successful synchronization run.' );

		return is_array( $row ) ? $this->normalize_run( $row ) : null;
	}

	/** @return array|null */
	private function get_running_run() {
		$table   = $this->runs_table();
		$columns = $this->run_columns();
		$sql   = $this->wpdb->prepare(
			"SELECT {$columns}
			FROM {$table}
			WHERE status IN (%s, %s)
			ORDER BY started_at DESC, id DESC
			LIMIT 1",
			'started',
			'running'
		);
		$row = $this->wpdb->get_row( $sql, ARRAY_A );
		$this->throw_on_last_error( 'Unable to inspect a running synchronization.' );

		return is_array( $row ) ? $this->normalize_run( $row ) : null;
	}

	/**
	 * @param int $page Page number.
	 * @param int $per_page Page size.
	 * @return array
	 */
	private function get_recent_runs( $page, $per_page ) {
		$table   = $this->runs_table();
		$columns = $this->run_columns();
		$maximum_page_before_overflow = intdiv( PHP_INT_MAX, $per_page );
		$offset = $page > $maximum_page_before_overflow ? PHP_INT_MAX : ( $page - 1 ) * $per_page;
		$sql     = $this->wpdb->prepare(
			"SELECT {$columns}
			FROM {$table}
			ORDER BY started_at DESC, id DESC
			LIMIT %d OFFSET %d",
			$per_page,
			$offset
		);
		$rows = $this->wpdb->get_results( $sql, ARRAY_A );
		if ( ! is_array( $rows ) || '' !== $this->wpdb->last_error ) {
			throw new \RuntimeException( 'Unable to read synchronization history.' );
		}

		return array_map( array( $this, 'normalize_run' ), $rows );
	}

	/** @return int */
	private function count_runs() {
		$table = $this->runs_table();
		$count = $this->wpdb->get_var( "SELECT COUNT(*) FROM {$table}" );
		$this->throw_on_last_error( 'Unable to count synchronization runs.' );

		return (int) $count;
	}

	/**
	 * @param string $run_uuid Run UUID.
	 * @return array|null
	 */
	public function get_run( $run_uuid ) {
		$table   = $this->runs_table();
		$columns = $this->run_columns();
		$sql   = $this->wpdb->prepare(
			"SELECT {$columns}
			FROM {$table}
			WHERE run_uuid = %s
			LIMIT 1",
			$run_uuid
		);
		$row = $this->wpdb->get_row( $sql, ARRAY_A );
		$this->throw_on_last_error( 'Unable to read the synchronization run detail.' );

		return is_array( $row ) ? $this->normalize_run( $row ) : null;
	}

	/**
	 * Returns aggregate batch information without loading batch rows.
	 *
	 * @param string $run_uuid Run UUID.
	 * @return array
	 */
	public function get_batch_summary( $run_uuid ) {
		$table = $this->batches_table();
		$sql   = $this->wpdb->prepare(
			"SELECT COUNT(*) AS batch_count,
				COALESCE(MIN(batch_number), 0) AS first_batch,
				COALESCE(MAX(batch_number), 0) AS last_batch,
				COALESCE(SUM(product_count), 0) AS product_count
			FROM {$table}
			WHERE run_uuid = %s",
			$run_uuid
		);
		$row = $this->wpdb->get_row( $sql, ARRAY_A );
		if ( ! is_array( $row ) || '' !== $this->wpdb->last_error ) {
			throw new \RuntimeException( 'Unable to summarize synchronization batches.' );
		}

		return array(
			'batch_count'  => (int) $row['batch_count'],
			'first_batch'  => (int) $row['first_batch'],
			'last_batch'   => (int) $row['last_batch'],
			'product_count' => (int) $row['product_count'],
		);
	}

	/** @return string */
	private function run_columns() {
		return 'run_uuid, schema_version, status, expected_product_count, expected_batch_count,
			received_count, inserted_count, updated_count, unchanged_count, reactivated_count,
			deactivated_count, candidate_deactivation_count, active_before_count,
			deactivation_percentage, dry_run, source_name, started_at, last_activity_at,
			completed_at, error_message';
	}

	/**
	 * @param array $row Database row.
	 * @return array
	 */
	private function normalize_run( array $row ) {
		$integer_fields = array(
			'schema_version',
			'expected_product_count',
			'expected_batch_count',
			'received_count',
			'inserted_count',
			'updated_count',
			'unchanged_count',
			'reactivated_count',
			'deactivated_count',
			'candidate_deactivation_count',
			'active_before_count',
		);
		foreach ( $integer_fields as $field ) {
			$row[ $field ] = (int) $row[ $field ];
		}
		$row['deactivation_percentage'] = (float) $row['deactivation_percentage'];
		$row['dry_run']                = 1 === (int) $row['dry_run'];

		return $row;
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
}
