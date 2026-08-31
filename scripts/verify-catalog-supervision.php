<?php
/**
 * Read-only WP-CLI assertions for the catalog supervision admin page.
 */

if ( ! defined( 'WP_CLI' ) || ! WP_CLI ) {
	exit( 1 );
}

/**
 * @param bool   $condition Assertion result.
 * @param string $message Failure message.
 * @return void
 */
function geh_ops_assert( $condition, $message ) {
	if ( ! $condition ) {
		WP_CLI::error( $message );
	}
}

global $wpdb, $menu, $submenu, $_registered_pages, $_parent_pages;

$repository = new \ProductCatalogSync\Catalog_Admin_Repository( $wpdb );
$data       = $repository->get_dashboard_data( 1, 20 );

geh_ops_assert( is_int( $data['active_product_count'] ), 'Le compteur de produits actifs est invalide.' );
geh_ops_assert( is_int( $data['total_runs'] ), 'Le compteur de runs est invalide.' );
geh_ops_assert( count( $data['recent_runs'] ) <= 20, 'Le repository charge plus de 20 runs.' );
geh_ops_assert( $data['total_runs'] >= count( $data['recent_runs'] ), 'La pagination des runs est incoherente.' );

if ( is_array( $data['latest_run'] ) ) {
	$run = $repository->get_run( $data['latest_run']['run_uuid'] );
	geh_ops_assert( is_array( $run ), 'Le detail du dernier run est introuvable.' );
	$batches = $repository->get_batch_summary( $run['run_uuid'] );
	geh_ops_assert( is_int( $batches['batch_count'] ), 'Le resume des batches est invalide.' );
}

$administrators = get_users(
	array(
		'role'   => 'administrator',
		'number' => 1,
		'fields' => 'ids',
	)
);
geh_ops_assert( ! empty( $administrators ), 'Aucun administrateur local ne permet de verifier la page.' );

wp_set_current_user( (int) $administrators[0] );
geh_ops_assert( current_user_can( 'manage_options' ), 'L administrateur ne possede pas manage_options.' );

if ( ! function_exists( 'add_menu_page' ) ) {
	require_once ABSPATH . 'wp-admin/includes/plugin.php';
}
$menu              = array();
$submenu           = array();
$_registered_pages = array();
$_parent_pages     = array();
do_action( 'admin_menu' );

$hook = get_plugin_page_hookname( 'product-catalog-supervision', '' );
geh_ops_assert( isset( $_registered_pages[ $hook ] ), 'La page de supervision n est pas enregistree.' );

do_action( 'admin_enqueue_scripts', 'index.php' );
geh_ops_assert(
	! wp_style_is( 'product-catalog-sync-admin-supervision', 'enqueued' ),
	'Le style de supervision ne doit pas affecter le tableau de bord WordPress.'
);
do_action( 'admin_enqueue_scripts', $hook );
geh_ops_assert(
	wp_style_is( 'product-catalog-sync-admin-supervision', 'enqueued' ),
	'Le style de supervision n est pas charge sur sa page.'
);

$_GET = array( 'page' => 'product-catalog-supervision' );
ob_start();
do_action( $hook );
$html = ob_get_clean();

geh_ops_assert( false !== strpos( $html, 'Supervision du catalogue' ), 'Le titre de supervision est absent.' );
geh_ops_assert( false !== strpos( $html, 'Produits actifs' ), 'La synthese des produits est absente.' );
geh_ops_assert( false !== strpos( $html, 'Historique des synchronisations' ), 'L historique est absent.' );
geh_ops_assert( false === strpos( $html, '<form' ), 'La page ne doit contenir aucun formulaire de mutation.' );

$visible_statuses = array_column( $data['recent_runs'], 'status' );
$visible_dry_runs = array_filter(
	$data['recent_runs'],
	static function ( array $run ) {
		return $run['dry_run'];
	}
);
if ( in_array( 'completed', $visible_statuses, true ) ) {
	geh_ops_assert( false !== strpos( $html, 'Terminé' ), 'Le badge completed est absent.' );
}
if ( in_array( 'rejected', $visible_statuses, true ) ) {
	geh_ops_assert( false !== strpos( $html, 'Rejeté' ), 'Le badge rejected est absent.' );
}
if ( ! empty( $visible_dry_runs ) ) {
	geh_ops_assert( false !== strpos( $html, 'DRY-RUN' ), 'Le badge dry-run est absent.' );
}

if ( is_array( $data['latest_successful_run'] ) ) {
	geh_ops_assert( ! $data['latest_successful_run']['dry_run'], 'Un dry-run ne doit pas definir la fraicheur.' );
}

$page = new \ProductCatalogSync\Catalog_Admin_Page( $repository );
$state_method = new ReflectionMethod( $page, 'global_state' );
$state_method->setAccessible( true );
$now = gmdate( 'Y-m-d H:i:s' );
$successful_completed_at = gmdate( 'Y-m-d H:i:s', time() - ( 2 * MINUTE_IN_SECONDS ) );
$successful_run = array(
	'status'           => 'completed',
	'dry_run'          => false,
	'started_at'       => gmdate( 'Y-m-d H:i:s', time() - ( 3 * MINUTE_IN_SECONDS ) ),
	'last_activity_at' => $successful_completed_at,
	'completed_at'     => $successful_completed_at,
);
$state_data = array(
	'running_run'          => null,
	'latest_run'           => $successful_run,
	'latest_real_run'      => $successful_run,
	'latest_successful_run' => $successful_run,
);
$state = $state_method->invoke( $page, $state_data );
geh_ops_assert( 'Opérationnel' === $state['label'], 'L etat completed est incorrect.' );

$state_data['running_run'] = array(
	'status'           => 'running',
	'started_at'       => $now,
	'last_activity_at' => $now,
);
$state = $state_method->invoke( $page, $state_data );
geh_ops_assert( 'Synchronisation en cours' === $state['label'], 'L etat running est incorrect.' );

$stale = gmdate(
	'Y-m-d H:i:s',
	time() - ( ( \ProductCatalogSync\Sync_Config::run_timeout_minutes() + 1 ) * MINUTE_IN_SECONDS )
);
$state_data['running_run']['started_at']       = $stale;
$state_data['running_run']['last_activity_at'] = $stale;
$state = $state_method->invoke( $page, $state_data );
geh_ops_assert( 'Run potentiellement bloqué' === $state['label'], 'L etat stale running est incorrect.' );

$state_data['running_run'] = null;
$state_data['latest_run'] = array(
	'status'  => 'completed',
	'dry_run' => true,
);
$state_data['latest_real_run'] = $successful_run;
$state_data['latest_successful_run']['completed_at'] = gmdate(
	'Y-m-d H:i:s',
	time() - ( ( ProductCatalogSync\Sync_Config::supervision_stale_after_minutes() + 1 ) * MINUTE_IN_SECONDS )
);
$state = $state_method->invoke( $page, $state_data );
geh_ops_assert( 'Synchronisation en retard' === $state['label'], 'Un dry-run completed ne doit pas rafraichir le catalogue.' );

$state_data['latest_successful_run'] = $successful_run;
$state_data['latest_real_run'] = array(
	'status'           => 'rejected',
	'started_at'       => $now,
	'last_activity_at' => $now,
	'completed_at'     => $now,
);
$state = $state_method->invoke( $page, $state_data );
geh_ops_assert( false !== strpos( $state['label'], 'rejetée' ), 'L etat rejected est incorrect.' );

$state_data['latest_run'] = null;
$state_data['latest_real_run'] = null;
$state_data['latest_successful_run'] = null;
$state = $state_method->invoke( $page, $state_data );
geh_ops_assert( 'Aucune synchronisation réussie' === $state['label'], 'L etat sans run est incorrect.' );

if ( is_array( $data['latest_run'] ) ) {
	$_GET['run'] = $data['latest_run']['run_uuid'];
	ob_start();
	do_action( $hook );
	$detail_html = ob_get_clean();
	geh_ops_assert( false !== strpos( $detail_html, 'Détail du run' ), 'Le detail de run ne peut pas etre rendu.' );
	geh_ops_assert( false !== strpos( $detail_html, esc_html( $data['latest_run']['run_uuid'] ) ), 'Le UUID du run est absent.' );
}

wp_set_current_user( 0 );
geh_ops_assert( ! current_user_can( 'manage_options' ), 'Un visiteur ne doit pas acceder a la supervision.' );

WP_CLI::success(
	sprintf(
		'Supervision validee en lecture seule : %d produits actifs, %d runs, %d lignes chargees.',
		$data['active_product_count'],
		$data['total_runs'],
		count( $data['recent_runs'] )
	)
);
