<?php
/**
 * Read-only WordPress administration page for catalog supervision.
 *
 * @package ProductCatalogSync
 */

namespace ProductCatalogSync;

if ( ! defined( 'ABSPATH' ) ) {
	exit;
}

final class Catalog_Admin_Page {
	private const CAPABILITY = 'manage_options';
	private const MENU_SLUG = 'product-catalog-supervision';
	private const RUNS_PER_PAGE = 20;
	private const STYLE_HANDLE = 'product-catalog-sync-admin-supervision';

	/** @var Catalog_Admin_Repository */
	private $repository;

	/** @var string */
	private $hook_suffix = '';

	/** @param Catalog_Admin_Repository $repository Read-only repository. */
	public function __construct( Catalog_Admin_Repository $repository ) {
		$this->repository = $repository;
	}

	/** @return void */
	public function register() {
		add_action( 'admin_menu', array( $this, 'register_menu' ) );
		add_action( 'admin_enqueue_scripts', array( $this, 'enqueue_assets' ) );
	}

	/** @return void */
	public function register_menu() {
		$this->hook_suffix = add_menu_page(
			'Supervision du catalogue',
			'Catalogue produits',
			self::CAPABILITY,
			self::MENU_SLUG,
			array( $this, 'render' ),
			'dashicons-products',
			58
		);
	}

	/**
	 * @param string $hook_suffix Current admin page hook.
	 * @return void
	 */
	public function enqueue_assets( $hook_suffix ) {
		if ( $this->hook_suffix !== $hook_suffix ) {
			return;
		}

		$style_path = PRODUCT_CATALOG_SYNC_DIR . 'assets/admin-supervision.css';
		wp_enqueue_style(
			self::STYLE_HANDLE,
			plugins_url( 'assets/admin-supervision.css', PRODUCT_CATALOG_SYNC_FILE ),
			array(),
			file_exists( $style_path ) ? (string) filemtime( $style_path ) : PRODUCT_CATALOG_SYNC_VERSION
		);
	}

	/** @return void */
	public function render() {
		if ( ! current_user_can( self::CAPABILITY ) ) {
			wp_die( esc_html( 'Vous n’avez pas l’autorisation d’accéder à cette page.' ), '', array( 'response' => 403 ) );
		}

		$page = isset( $_GET['paged'] ) ? max( 1, absint( wp_unslash( $_GET['paged'] ) ) ) : 1;
		$requested_run = isset( $_GET['run'] )
			? sanitize_text_field( wp_unslash( $_GET['run'] ) )
			: '';
		if ( '' !== $requested_run && ! wp_is_uuid( $requested_run ) ) {
			$requested_run = '';
		}

		try {
			$data = $this->repository->get_dashboard_data( $page, self::RUNS_PER_PAGE );
			$detail_run = null;
			$batch_summary = null;
			if ( '' !== $requested_run ) {
				$detail_run = $this->repository->get_run( $requested_run );
				if ( is_array( $detail_run ) ) {
					$batch_summary = $this->repository->get_batch_summary( $requested_run );
				}
			}
		} catch ( \RuntimeException $exception ) {
			error_log( 'Product Catalog Sync supervision: ' . $exception->getMessage() );
			$this->render_error();
			return;
		}

		$state = $this->global_state( $data );
		?>
		<div class="wrap geh-ops-wrap">
			<h1>Supervision du catalogue</h1>
			<p class="description">État du catalogue et historique des synchronisations. Cette page est strictement en lecture seule.</p>

			<?php $this->render_summary_cards( $data, $state ); ?>

			<?php if ( '' !== $requested_run && null === $detail_run ) : ?>
				<div class="notice notice-warning inline"><p>Le run demandé est introuvable.</p></div>
			<?php elseif ( is_array( $detail_run ) ) : ?>
				<?php $this->render_run_detail( $detail_run, $batch_summary ); ?>
			<?php endif; ?>

			<?php $this->render_latest_attempt( $data['latest_run'] ); ?>
			<?php $this->render_history( $data['recent_runs'], $data['total_runs'], $page ); ?>
		</div>
		<?php
	}

	/** @return void */
	private function render_error() {
		?>
		<div class="wrap">
			<h1>Supervision du catalogue</h1>
			<div class="notice notice-error"><p>Les données de supervision ne peuvent pas être chargées actuellement.</p></div>
		</div>
		<?php
	}

	/**
	 * @param array $data Dashboard data.
	 * @return array
	 */
	private function global_state( array $data ) {
		$running = $data['running_run'];
		if ( is_array( $running ) ) {
			if ( $this->is_run_stale( $running ) ) {
				return array(
					'label' => 'Run potentiellement bloqué',
					'tone'  => 'warning',
					'detail' => 'La dernière activité dépasse le délai normal d’un run.',
				);
			}

			return array(
				'label' => 'Synchronisation en cours',
				'tone'  => 'info',
				'detail' => 'Le Worker transmet actuellement le catalogue.',
			);
		}

		$successful = $data['latest_successful_run'];
		if ( ! is_array( $successful ) ) {
			return array(
				'label' => 'Aucune synchronisation réussie',
				'tone'  => 'neutral',
				'detail' => 'Aucune publication complète du catalogue n’est enregistrée.',
			);
		}

		$latest_real = $data['latest_real_run'];
		if (
			is_array( $latest_real ) &&
			$this->is_attempt_after_success( $latest_real, $successful ) &&
			'rejected' === $latest_real['status']
		) {
			return array(
				'label' => 'Attention — dernière tentative rejetée',
				'tone'  => 'warning',
				'detail' => 'Le dernier catalogue valide reste disponible.',
			);
		}
		if (
			is_array( $latest_real ) &&
			$this->is_attempt_after_success( $latest_real, $successful ) &&
			'failed' === $latest_real['status']
		) {
			return array(
				'label' => 'Attention — dernière tentative en erreur',
				'tone'  => 'error',
				'detail' => 'Consultez le détail du run et les journaux du Worker.',
			);
		}

		if ( $this->is_catalog_stale( $successful ) ) {
			return array(
				'label' => 'Synchronisation en retard',
				'tone'  => 'warning',
				'detail' => 'Le catalogue reste disponible, mais sa fraîcheur doit être vérifiée.',
			);
		}

		return array(
			'label' => 'Opérationnel',
			'tone'  => 'success',
			'detail' => 'La dernière synchronisation réelle est récente.',
		);
	}

	/**
	 * @param array $data Dashboard data.
	 * @param array $state Global state.
	 * @return void
	 */
	private function render_summary_cards( array $data, array $state ) {
		$successful = $data['latest_successful_run'];
		$active_count = (int) $data['active_product_count'];
		?>
		<div class="geh-ops-cards">
			<section class="geh-ops-card geh-ops-card--<?php echo esc_attr( $state['tone'] ); ?>">
				<h2>État</h2>
				<p class="geh-ops-card__value"><?php echo esc_html( $state['label'] ); ?></p>
				<p><?php echo esc_html( $state['detail'] ); ?></p>
			</section>
			<section class="geh-ops-card">
				<h2>Dernière synchronisation réussie</h2>
				<?php if ( is_array( $successful ) ) : ?>
					<p class="geh-ops-card__value"><?php echo esc_html( $this->format_date( $successful['completed_at'] ) ); ?></p>
					<p><?php echo esc_html( $this->format_relative_date( $successful['completed_at'] ) ); ?></p>
				<?php else : ?>
					<p class="geh-ops-card__value">Aucune</p>
				<?php endif; ?>
			</section>
			<section class="geh-ops-card">
				<h2>Produits actifs</h2>
				<p class="geh-ops-card__value"><?php echo esc_html( number_format_i18n( $active_count ) ); ?></p>
				<p><?php echo 0 === $active_count ? 'Catalogue vide' : 'Produits actuellement publiés'; ?></p>
			</section>
			<section class="geh-ops-card">
				<h2>Durée dernière synchronisation</h2>
				<p class="geh-ops-card__value">
					<?php echo esc_html( is_array( $successful ) ? $this->format_duration( $successful ) : '—' ); ?>
				</p>
				<p>Dernière publication réelle</p>
			</section>
		</div>
		<?php
	}

	/**
	 * @param array|null $run Latest run.
	 * @return void
	 */
	private function render_latest_attempt( $run ) {
		?>
		<h2>Dernière tentative</h2>
		<?php if ( ! is_array( $run ) ) : ?>
			<p>Aucune synchronisation n’a encore été enregistrée.</p>
			<?php return; ?>
		<?php endif; ?>
		<div class="geh-ops-latest">
			<div><strong>Statut</strong><?php $this->render_status_badge( $run['status'] ); ?><?php $this->render_dry_run_badge( $run ); ?></div>
			<div><strong>Début</strong><?php echo esc_html( $this->format_date( $run['started_at'] ) ); ?></div>
			<div><strong>Reçus</strong><?php echo esc_html( number_format_i18n( $run['received_count'] ) ); ?></div>
			<div><strong>Modifiés</strong><?php echo esc_html( number_format_i18n( $run['updated_count'] ) ); ?></div>
			<div><a href="<?php echo esc_url( $this->run_detail_url( $run['run_uuid'] ) ); ?>">Voir le détail du run</a></div>
		</div>
		<?php
	}

	/**
	 * @param array      $run Run data.
	 * @param array|null $batch_summary Aggregate batch data.
	 * @return void
	 */
	private function render_run_detail( array $run, $batch_summary ) {
		?>
		<section class="geh-ops-detail" aria-labelledby="geh-ops-detail-title">
			<div class="geh-ops-section-heading">
				<h2 id="geh-ops-detail-title">Détail du run</h2>
				<a href="<?php echo esc_url( $this->supervision_url() ); ?>">Fermer le détail</a>
			</div>
			<?php if ( ! empty( $run['error_message'] ) ) : ?>
				<div class="notice notice-error inline"><p><?php echo esc_html( $run['error_message'] ); ?></p></div>
			<?php endif; ?>
			<table class="widefat striped geh-ops-detail-table">
				<tbody>
					<?php $this->detail_row( 'Run UUID', $run['run_uuid'] ); ?>
					<?php $this->detail_status_row( $run ); ?>
					<?php $this->detail_row( 'Version de schéma', number_format_i18n( $run['schema_version'] ) ); ?>
					<?php $this->detail_row( 'Source', $run['source_name'] ? $run['source_name'] : '—' ); ?>
					<?php $this->detail_row( 'Début', $this->format_date( $run['started_at'] ) ); ?>
					<?php $this->detail_row( 'Fin', $this->format_date( $run['completed_at'] ) ); ?>
					<?php $this->detail_row( 'Dernière activité', $this->format_date( $run['last_activity_at'] ) ); ?>
					<?php $this->detail_row( 'Durée', $this->format_duration( $run ) ); ?>
					<?php $this->detail_row( 'Produits attendus', number_format_i18n( $run['expected_product_count'] ) ); ?>
					<?php $this->detail_row( 'Batches attendus', number_format_i18n( $run['expected_batch_count'] ) ); ?>
					<?php $this->detail_row( 'Produits reçus', number_format_i18n( $run['received_count'] ) ); ?>
					<?php $this->detail_row( 'Ajoutés', number_format_i18n( $run['inserted_count'] ) ); ?>
					<?php $this->detail_row( 'Modifiés', number_format_i18n( $run['updated_count'] ) ); ?>
					<?php $this->detail_row( 'Inchangés', number_format_i18n( $run['unchanged_count'] ) ); ?>
					<?php $this->detail_row( 'Réactivés', number_format_i18n( $run['reactivated_count'] ) ); ?>
					<?php $this->detail_row( 'Désactivés', number_format_i18n( $run['deactivated_count'] ) ); ?>
					<?php $this->detail_row( 'Candidats à la désactivation', number_format_i18n( $run['candidate_deactivation_count'] ) ); ?>
					<?php $this->detail_row( 'Produits actifs avant run', number_format_i18n( $run['active_before_count'] ) ); ?>
					<?php $this->detail_row( 'Pourcentage de désactivation', number_format_i18n( $run['deactivation_percentage'], 2 ) . ' %' ); ?>
					<?php $this->detail_row( 'Mode', $run['dry_run'] ? 'DRY-RUN — aucune publication' : 'Synchronisation réelle' ); ?>
				</tbody>
			</table>

			<h3>Résumé des batches</h3>
			<?php if ( is_array( $batch_summary ) && 0 < $batch_summary['batch_count'] ) : ?>
				<p>
					<?php
					echo esc_html(
						sprintf(
							'%1$s batches, du n° %2$s au n° %3$s, %4$s produits au total.',
							number_format_i18n( $batch_summary['batch_count'] ),
							number_format_i18n( $batch_summary['first_batch'] ),
							number_format_i18n( $batch_summary['last_batch'] ),
							number_format_i18n( $batch_summary['product_count'] )
						)
					);
					?>
				</p>
			<?php else : ?>
				<p>Aucun batch enregistré pour ce run.</p>
			<?php endif; ?>
			<p class="description">Les éléments individuels du run ne sont pas chargés par cette page.</p>
		</section>
		<?php
	}

	/**
	 * @param array $runs Recent runs.
	 * @param int   $total_runs Total rows.
	 * @param int   $page Current page.
	 * @return void
	 */
	private function render_history( array $runs, $total_runs, $page ) {
		?>
		<div class="geh-ops-section-heading">
			<h2>Historique des synchronisations</h2>
			<span><?php echo esc_html( number_format_i18n( $total_runs ) ); ?> run(s)</span>
		</div>
		<?php if ( empty( $runs ) ) : ?>
			<p>Aucune synchronisation n’a encore été enregistrée.</p>
			<?php return; ?>
		<?php endif; ?>
		<div class="geh-ops-table-scroll">
			<table class="widefat striped">
				<thead>
					<tr>
						<th>Date</th><th>Statut</th><th>Durée</th><th>Reçus</th><th>Ajoutés</th>
						<th>Modifiés</th><th>Inchangés</th><th>Réactivés</th><th>Désactivés</th>
						<th>Mode</th><th>Détails</th>
					</tr>
				</thead>
				<tbody>
					<?php foreach ( $runs as $run ) : ?>
						<tr>
							<td><?php echo esc_html( $this->format_date( $run['started_at'] ) ); ?></td>
							<td><?php $this->render_status_badge( $run['status'] ); ?></td>
							<td><?php echo esc_html( $this->format_duration( $run ) ); ?></td>
							<td><?php echo esc_html( number_format_i18n( $run['received_count'] ) ); ?></td>
							<td><?php echo esc_html( number_format_i18n( $run['inserted_count'] ) ); ?></td>
							<td><?php echo esc_html( number_format_i18n( $run['updated_count'] ) ); ?></td>
							<td><?php echo esc_html( number_format_i18n( $run['unchanged_count'] ) ); ?></td>
							<td><?php echo esc_html( number_format_i18n( $run['reactivated_count'] ) ); ?></td>
							<td><?php echo esc_html( number_format_i18n( $run['deactivated_count'] ) ); ?></td>
							<td><?php $this->render_dry_run_badge( $run ); ?></td>
							<td><a href="<?php echo esc_url( $this->run_detail_url( $run['run_uuid'], $page ) ); ?>">Ouvrir</a></td>
						</tr>
					<?php endforeach; ?>
				</tbody>
			</table>
		</div>
		<?php $this->render_pagination( $total_runs, $page ); ?>
		<?php
	}

	/**
	 * @param int $total_runs Total rows.
	 * @param int $page Current page.
	 * @return void
	 */
	private function render_pagination( $total_runs, $page ) {
		$total_pages = (int) ceil( $total_runs / self::RUNS_PER_PAGE );
		if ( $total_pages <= 1 ) {
			return;
		}

		$links = paginate_links(
			array(
				'base'      => add_query_arg( 'paged', '%#%', $this->supervision_url() ),
				'format'    => '',
				'current'   => min( $page, $total_pages ),
				'total'     => $total_pages,
				'prev_text' => '‹ Précédent',
				'next_text' => 'Suivant ›',
				'type'      => 'list',
			)
		);
		if ( is_string( $links ) ) {
			echo '<nav class="geh-ops-pagination" aria-label="Pagination des runs">' . wp_kses_post( $links ) . '</nav>';
		}
	}

	/** @param string $status Run status. @return void */
	private function render_status_badge( $status ) {
		$statuses = array(
			'completed' => array( 'Terminé', 'success' ),
			'success'   => array( 'Terminé (historique)', 'success' ),
			'rejected'  => array( 'Rejeté', 'warning' ),
			'failed'    => array( 'Échec', 'error' ),
			'started'   => array( 'Démarré', 'info' ),
			'running'   => array( 'En cours', 'info' ),
		);
		$presentation = isset( $statuses[ $status ] )
			? $statuses[ $status ]
			: array( ucfirst( (string) $status ), 'neutral' );
		echo '<span class="geh-ops-badge geh-ops-badge--' . esc_attr( $presentation[1] ) . '">' .
			esc_html( $presentation[0] ) . '</span>';
	}

	/** @param array $run Run data. @return void */
	private function render_dry_run_badge( array $run ) {
		if ( $run['dry_run'] ) {
			echo '<span class="geh-ops-badge geh-ops-badge--neutral">DRY-RUN</span>';
		} else {
			echo '<span class="geh-ops-mode">Réel</span>';
		}
	}

	/** @param string $label Label. @param string $value Value. @return void */
	private function detail_row( $label, $value ) {
		echo '<tr><th scope="row">' . esc_html( $label ) . '</th><td>' . esc_html( $value ) . '</td></tr>';
	}

	/** @param array $run Run data. @return void */
	private function detail_status_row( array $run ) {
		echo '<tr><th scope="row">Statut</th><td>';
		$this->render_status_badge( $run['status'] );
		$this->render_dry_run_badge( $run );
		if ( in_array( $run['status'], array( 'started', 'running' ), true ) && $this->is_run_stale( $run ) ) {
			echo '<span class="geh-ops-badge geh-ops-badge--warning">Potentiellement bloqué</span>';
		}
		echo '</td></tr>';
	}

	/** @param array $run Run data. @return bool */
	private function is_run_stale( array $run ) {
		$activity = $run['last_activity_at'] ? $run['last_activity_at'] : $run['started_at'];
		$timestamp = $this->mysql_utc_timestamp( $activity );

		return null !== $timestamp &&
			( time() - $timestamp ) > ( Sync_Config::run_timeout_minutes() * MINUTE_IN_SECONDS );
	}

	/** @param array $run Successful real run. @return bool */
	private function is_catalog_stale( array $run ) {
		$timestamp = $this->mysql_utc_timestamp( $run['completed_at'] );

		return null === $timestamp ||
			( time() - $timestamp ) > ( Sync_Config::supervision_stale_after_minutes() * MINUTE_IN_SECONDS );
	}

	/** @param array $attempt Real attempt. @param array $successful Successful real run. @return bool */
	private function is_attempt_after_success( array $attempt, array $successful ) {
		$attempt_date = $attempt['completed_at'] ? $attempt['completed_at'] : $attempt['last_activity_at'];
		$attempt_date = $attempt_date ? $attempt_date : $attempt['started_at'];
		$attempt_timestamp = $this->mysql_utc_timestamp( $attempt_date );
		$success_timestamp = $this->mysql_utc_timestamp( $successful['completed_at'] );

		return null !== $attempt_timestamp &&
			null !== $success_timestamp &&
			$attempt_timestamp > $success_timestamp;
	}

	/** @param array $run Run data. @return string */
	private function format_duration( array $run ) {
		$start = $this->mysql_utc_timestamp( $run['started_at'] );
		$end_value = $run['completed_at'] ? $run['completed_at'] : $run['last_activity_at'];
		$end = $this->mysql_utc_timestamp( $end_value );
		if ( null === $start || null === $end || $end < $start ) {
			return '—';
		}

		$seconds = $end - $start;
		if ( $seconds < MINUTE_IN_SECONDS ) {
			return number_format_i18n( $seconds ) . ' s';
		}
		if ( $seconds < HOUR_IN_SECONDS ) {
			$minutes = (int) floor( $seconds / MINUTE_IN_SECONDS );
			$remaining = $seconds % MINUTE_IN_SECONDS;
			return 0 === $remaining
				? sprintf( '%s min', number_format_i18n( $minutes ) )
				: sprintf( '%s min %s s', number_format_i18n( $minutes ), number_format_i18n( $remaining ) );
		}

		$hours = (int) floor( $seconds / HOUR_IN_SECONDS );
		$minutes = (int) floor( ( $seconds % HOUR_IN_SECONDS ) / MINUTE_IN_SECONDS );
		return 0 === $minutes
			? sprintf( '%s h', number_format_i18n( $hours ) )
			: sprintf( '%s h %s min', number_format_i18n( $hours ), number_format_i18n( $minutes ) );
	}

	/** @param string|null $value UTC MySQL date. @return string */
	private function format_date( $value ) {
		$timestamp = $this->mysql_utc_timestamp( $value );
		if ( null === $timestamp ) {
			return '—';
		}

		return wp_date(
			get_option( 'date_format' ) . ' ' . get_option( 'time_format' ),
			$timestamp,
			wp_timezone()
		);
	}

	/** @param string|null $value UTC MySQL date. @return string */
	private function format_relative_date( $value ) {
		$timestamp = $this->mysql_utc_timestamp( $value );
		return null === $timestamp ? '—' : 'Il y a ' . human_time_diff( $timestamp, time() );
	}

	/** @param string|null $value UTC MySQL date. @return int|null */
	private function mysql_utc_timestamp( $value ) {
		if ( ! is_string( $value ) || '' === $value ) {
			return null;
		}

		$date = \DateTimeImmutable::createFromFormat(
			'!Y-m-d H:i:s',
			$value,
			new \DateTimeZone( 'UTC' )
		);

		return false === $date ? null : $date->getTimestamp();
	}

	/** @param string $run_uuid Run UUID. @param int $page Optional history page. @return string */
	private function run_detail_url( $run_uuid, $page = 1 ) {
		$arguments = array(
			'page' => self::MENU_SLUG,
			'run'  => $run_uuid,
		);
		if ( $page > 1 ) {
			$arguments['paged'] = $page;
		}

		return add_query_arg( $arguments, admin_url( 'admin.php' ) );
	}

	/** @return string */
	private function supervision_url() {
		return add_query_arg( 'page', self::MENU_SLUG, admin_url( 'admin.php' ) );
	}
}
