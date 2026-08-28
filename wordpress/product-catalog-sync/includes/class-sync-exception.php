<?php
/**
 * Safe domain error returned by the private REST API.
 *
 * @package ProductCatalogSync
 */

namespace ProductCatalogSync;

if ( ! defined( 'ABSPATH' ) ) {
	exit;
}

final class Sync_Exception extends \RuntimeException {
	/** @var string */
	private $rest_code;

	/** @var int */
	private $http_status;

	/**
	 * @param string $rest_code Stable REST error code.
	 * @param string $message Safe public message.
	 * @param int    $http_status HTTP response status.
	 */
	public function __construct( $rest_code, $message, $http_status ) {
		parent::__construct( $message );
		$this->rest_code   = $rest_code;
		$this->http_status = (int) $http_status;
	}

	/** @return string */
	public function get_rest_code() {
		return $this->rest_code;
	}

	/** @return int */
	public function get_http_status() {
		return $this->http_status;
	}
}
