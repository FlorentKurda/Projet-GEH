<?php
/**
 * Deterministic product content hashing shared by validation and persistence.
 *
 * @package ProductCatalogSync
 */

namespace ProductCatalogSync;

if ( ! defined( 'ABSPATH' ) ) {
	exit;
}

final class Product_Hasher {
	/**
	 * Hashes only public business fields, never run identifiers or sync dates.
	 *
	 * @param array $product Product using database-style field names.
	 * @return string Lower-case SHA-256.
	 */
	public static function hash_product( array $product ) {
		$values = array(
			$product['source_id'],
			$product['reference'],
			$product['name'],
			$product['short_description'],
			$product['family_code'],
			$product['family_label'],
			$product['brand'],
		);

		$canonical = '';
		foreach ( $values as $value ) {
			if ( null === $value ) {
				$canonical .= "-1:\n";
			} else {
				$value      = (string) $value;
				$canonical .= strlen( $value ) . ':' . $value . "\n";
			}
		}

		return hash( 'sha256', $canonical );
	}
}
