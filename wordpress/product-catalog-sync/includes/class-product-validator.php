<?php
/**
 * Strict validation and normalization for synchronization schema version 2.
 *
 * @package ProductCatalogSync
 */

namespace ProductCatalogSync;

if ( ! defined( 'ABSPATH' ) ) {
	exit;
}

final class Product_Validator {
	private const START_FIELDS = array(
		'runId',
		'schemaVersion',
		'expectedProductCount',
		'expectedBatchCount',
		'source',
		'dryRun',
	);

	private const BATCH_FIELDS = array( 'batchNumber', 'products' );

	private const PRODUCT_FIELDS = array(
		'sourceId',
		'reference',
		'name',
		'shortDescription',
		'familyCode',
		'familyLabel',
		'brand',
		'sourceUpdatedAtUtc',
		'contentHash',
	);

	/**
	 * @param mixed $payload Decoded run creation payload.
	 * @return array|\WP_Error
	 */
	public function validate_start( $payload ) {
		if ( ! is_array( $payload ) ) {
			return $this->single_type_error();
		}

		$errors = array();
		$this->validate_unknown_fields( $payload, self::START_FIELDS, '$', $errors );
		$run_id = $this->required_text( $payload, 'runId', 36, '$', false, $errors );
		if ( null !== $run_id && ! $this->is_uuid( $run_id ) ) {
			$errors[] = $this->error( 'runId', 'invalid_uuid', 'runId must be a valid UUID.' );
		}

		$schema_version = $this->required_integer(
			$payload,
			'schemaVersion',
			1,
			PHP_INT_MAX,
			'$',
			$errors
		);
		if ( null !== $schema_version && 2 !== $schema_version ) {
			$errors[] = $this->error(
				'schemaVersion',
				'invalid_schema_version',
				'schemaVersion must be the integer 2.'
			);
		}

		$expected_product_count = $this->required_integer(
			$payload,
			'expectedProductCount',
			0,
			Sync_Config::MAX_EXPECTED_PRODUCTS,
			'$',
			$errors
		);

		$expected_batch_count = 0;
		if ( array_key_exists( 'expectedBatchCount', $payload ) ) {
			$expected_batch_count = $this->required_integer(
				$payload,
				'expectedBatchCount',
				0,
				Sync_Config::MAX_EXPECTED_PRODUCTS,
				'$',
				$errors
			);
		}

		if (
			null !== $expected_product_count &&
			null !== $expected_batch_count &&
			(
				( 0 === $expected_product_count && 0 !== $expected_batch_count ) ||
				( 0 < $expected_product_count && 0 === $expected_batch_count && array_key_exists( 'expectedBatchCount', $payload ) ) ||
				$expected_batch_count > $expected_product_count
			)
		) {
			$errors[] = $this->error(
				'expectedBatchCount',
				'inconsistent_batch_count',
				'expectedBatchCount is inconsistent with expectedProductCount.'
			);
		}

		$source = $this->required_text( $payload, 'source', 100, '$', false, $errors );

		$dry_run = null;
		if ( ! array_key_exists( 'dryRun', $payload ) ) {
			$errors[] = $this->error( 'dryRun', 'required', 'dryRun is required.' );
		} elseif ( ! is_bool( $payload['dryRun'] ) ) {
			$errors[] = $this->error( 'dryRun', 'invalid_type', 'dryRun must be a boolean.' );
		} else {
			$dry_run = $payload['dryRun'];
		}

		if ( ! empty( $errors ) ) {
			return $this->validation_error( $errors );
		}

		return array(
			'run_id'                => strtolower( $run_id ),
			'schema_version'        => 2,
			'expected_product_count' => (int) $expected_product_count,
			'expected_batch_count'   => (int) $expected_batch_count,
			'source_name'            => $source,
			'dry_run'                => (bool) $dry_run,
		);
	}

	/**
	 * @param mixed $payload Decoded batch payload.
	 * @return array|\WP_Error
	 */
	public function validate_batch( $payload ) {
		if ( ! is_array( $payload ) ) {
			return $this->single_type_error();
		}

		$errors = array();
		$this->validate_unknown_fields( $payload, self::BATCH_FIELDS, '$', $errors );
		$batch_number = $this->required_integer(
			$payload,
			'batchNumber',
			1,
			Sync_Config::MAX_EXPECTED_PRODUCTS,
			'$',
			$errors
		);

		$products = array_key_exists( 'products', $payload ) ? $payload['products'] : null;
		if ( ! array_key_exists( 'products', $payload ) ) {
			$errors[] = $this->error( 'products', 'required', 'products is required.' );
		} elseif ( ! is_array( $products ) || array_values( $products ) !== $products ) {
			$errors[] = $this->error( 'products', 'invalid_type', 'products must be a JSON array.' );
		} elseif ( 0 === count( $products ) ) {
			$errors[] = $this->error( 'products', 'empty_collection', 'A batch must contain products.' );
		} elseif ( Sync_Config::max_batch_products() < count( $products ) ) {
			$errors[] = $this->error(
				'products',
				'too_many_products',
				'A batch exceeds the configured product limit.'
			);
		}

		$normalized = array();
		$seen       = array();
		if ( is_array( $products ) && array_values( $products ) === $products ) {
			foreach ( $products as $index => $product ) {
				$this->validate_product( $product, $index, $seen, $normalized, $errors );
			}
		}

		if ( ! empty( $errors ) ) {
			return $this->validation_error( $errors );
		}

		return array(
			'batch_number' => (int) $batch_number,
			'products'     => $normalized,
		);
	}

	/**
	 * @param mixed $product Product payload.
	 * @param int   $index Product index.
	 * @param array $seen Seen source IDs.
	 * @param array $normalized Normalized products.
	 * @param array $errors Errors.
	 * @return void
	 */
	private function validate_product( $product, $index, array &$seen, array &$normalized, array &$errors ) {
		$path = 'products[' . $index . ']';
		if ( ! is_array( $product ) ) {
			$errors[] = $this->error( $path, 'invalid_type', 'Each product must be a JSON object.' );
			return;
		}

		$this->validate_unknown_fields( $product, self::PRODUCT_FIELDS, $path, $errors );
		$source_id = $this->required_text( $product, 'sourceId', 100, $path, false, $errors );
		$reference = $this->required_text( $product, 'reference', 100, $path, false, $errors );
		$name      = $this->required_text( $product, 'name', 255, $path, false, $errors );

		$short_description = $this->optional_text( $product, 'shortDescription', 2000, $path, true, $errors );
		$family_code       = $this->optional_text( $product, 'familyCode', 100, $path, false, $errors );
		$family_label      = $this->optional_text( $product, 'familyLabel', 255, $path, false, $errors );
		$brand             = $this->optional_text( $product, 'brand', 255, $path, false, $errors );
		$source_updated_at = $this->optional_date( $product, 'sourceUpdatedAtUtc', $path, $errors );
		$content_hash      = $this->required_text( $product, 'contentHash', 64, $path, false, $errors );

		if ( null !== $content_hash ) {
			$content_hash = strtolower( $content_hash );
			if ( 1 !== preg_match( '/\A[0-9a-f]{64}\z/', $content_hash ) ) {
				$errors[] = $this->error(
					$path . '.contentHash',
					'invalid_hash',
					'contentHash must be a SHA-256 value.'
				);
			}
		}

		if ( null !== $source_id ) {
			$key = function_exists( 'mb_strtolower' )
				? mb_strtolower( $source_id, 'UTF-8' )
				: strtolower( $source_id );
			if ( isset( $seen[ $key ] ) ) {
				$errors[] = $this->error(
					$path . '.sourceId',
					'duplicate_source_id',
					'sourceId must be unique within a batch.'
				);
			} else {
				$seen[ $key ] = true;
			}
		}

		$normalized_product = array(
			'source_id'         => $source_id,
			'reference'         => $reference,
			'name'              => $name,
			'short_description' => $short_description,
			'family_code'       => $family_code,
			'family_label'      => $family_label,
			'brand'             => $brand,
			'source_updated_at' => $source_updated_at,
			'content_hash'      => $content_hash,
		);

		if ( null !== $source_id && null !== $reference && null !== $name && null !== $content_hash ) {
			$calculated = Product_Hasher::hash_product( $normalized_product );
			if ( ! hash_equals( $calculated, $content_hash ) ) {
				$errors[] = $this->error(
					$path . '.contentHash',
					'hash_mismatch',
					'contentHash does not match the normalized product.'
				);
			}
		}

		$normalized[] = $normalized_product;
	}

	/**
	 * @param array  $value Input object.
	 * @param array  $allowed Allowed fields.
	 * @param string $path JSON path.
	 * @param array  $errors Errors.
	 * @return void
	 */
	private function validate_unknown_fields( array $value, array $allowed, $path, array &$errors ) {
		foreach ( array_keys( $value ) as $field ) {
			if ( ! is_string( $field ) || ! in_array( $field, $allowed, true ) ) {
				$errors[] = $this->error(
					$path . '.' . (string) $field,
					'unknown_field',
					'The field is not part of schema version 2.'
				);
			}
		}
	}

	/** @return int|null */
	private function required_integer( array $value, $field, $minimum, $maximum, $path, array &$errors ) {
		$field_path = '$' === $path ? $field : $path . '.' . $field;
		if ( ! array_key_exists( $field, $value ) ) {
			$errors[] = $this->error( $field_path, 'required', $field . ' is required.' );
			return null;
		}
		if ( ! is_int( $value[ $field ] ) ) {
			$errors[] = $this->error( $field_path, 'invalid_type', $field . ' must be an integer.' );
			return null;
		}
		if ( $value[ $field ] < $minimum || $value[ $field ] > $maximum ) {
			$errors[] = $this->error( $field_path, 'out_of_range', $field . ' is outside its allowed range.' );
			return null;
		}

		return $value[ $field ];
	}

	/** @return string|null */
	private function required_text( array $value, $field, $maximum_length, $path, $multiline, array &$errors ) {
		$field_path = '$' === $path ? $field : $path . '.' . $field;
		if ( ! array_key_exists( $field, $value ) ) {
			$errors[] = $this->error( $field_path, 'required', $field . ' is required.' );
			return null;
		}
		if ( ! is_string( $value[ $field ] ) ) {
			$errors[] = $this->error( $field_path, 'invalid_type', $field . ' must be a string.' );
			return null;
		}

		$text = $this->trim_unicode( $value[ $field ] );
		if ( '' === $text ) {
			$errors[] = $this->error( $field_path, 'empty_value', $field . ' must not be empty.' );
			return null;
		}
		if ( $this->text_length( $text ) > $maximum_length ) {
			$errors[] = $this->error( $field_path, 'max_length', $field . ' is too long.' );
			return null;
		}

		$text = $multiline ? sanitize_textarea_field( $text ) : sanitize_text_field( $text );
		$text = $this->trim_unicode( $text );
		if ( '' === $text ) {
			$errors[] = $this->error( $field_path, 'empty_value', $field . ' must not be empty.' );
			return null;
		}

		return $text;
	}

	/** @return string|null */
	private function optional_text( array $value, $field, $maximum_length, $path, $multiline, array &$errors ) {
		if ( ! array_key_exists( $field, $value ) || null === $value[ $field ] ) {
			return null;
		}
		if ( ! is_string( $value[ $field ] ) ) {
			$errors[] = $this->error( $path . '.' . $field, 'invalid_type', $field . ' must be null or a string.' );
			return null;
		}

		$text = $this->trim_unicode( $value[ $field ] );
		if ( '' === $text ) {
			return null;
		}
		if ( $this->text_length( $text ) > $maximum_length ) {
			$errors[] = $this->error( $path . '.' . $field, 'max_length', $field . ' is too long.' );
			return null;
		}

		$text = $multiline ? sanitize_textarea_field( $text ) : sanitize_text_field( $text );
		$text = $this->trim_unicode( $text );

		return '' === $text ? null : $text;
	}

	/** @return string|null */
	private function optional_date( array $value, $field, $path, array &$errors ) {
		if ( ! array_key_exists( $field, $value ) || null === $value[ $field ] ) {
			return null;
		}
		if ( ! is_string( $value[ $field ] ) ) {
			$errors[] = $this->error( $path . '.' . $field, 'invalid_type', $field . ' must be null or an ISO 8601 string.' );
			return null;
		}

		$parsed = $this->parse_iso8601( $this->trim_unicode( $value[ $field ] ) );
		if ( null === $parsed ) {
			$errors[] = $this->error( $path . '.' . $field, 'invalid_date', $field . ' must include a valid time zone.' );
			return null;
		}

		return $parsed->setTimezone( new \DateTimeZone( 'UTC' ) )->format( 'Y-m-d H:i:s' );
	}

	/** @return \DateTimeImmutable|null */
	private function parse_iso8601( $value ) {
		$pattern = '/\A(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,7}))?(Z|[+-](?:(?:0\d|1[0-3]):[0-5]\d|14:00))\z/i';
		if ( 1 !== preg_match( $pattern, $value, $matches ) ) {
			return null;
		}
		if (
			! checkdate( (int) $matches[2], (int) $matches[3], (int) $matches[1] ) ||
			(int) $matches[4] > 23 || (int) $matches[5] > 59 || (int) $matches[6] > 59
		) {
			return null;
		}

		$parseable = preg_replace( '/(\.\d{6})\d(?=Z|[+-])/i', '$1', $value );
		try {
			return new \DateTimeImmutable( $parseable );
		} catch ( \Exception $exception ) {
			return null;
		}
	}

	/** @return bool */
	private function is_uuid( $value ) {
		return 1 === preg_match(
			'/\A[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/i',
			$value
		);
	}

	/** @return string */
	private function trim_unicode( $value ) {
		$trimmed = trim( $value );
		$result  = preg_replace( '/\A[\p{Z}\s]+|[\p{Z}\s]+\z/u', '', $trimmed );

		return is_string( $result ) ? $result : $trimmed;
	}

	/** @return int */
	private function text_length( $value ) {
		if ( function_exists( 'mb_strlen' ) ) {
			return mb_strlen( $value, 'UTF-8' );
		}
		$length = preg_match_all( '/./us', $value, $characters );

		return false === $length ? strlen( $value ) : $length;
	}

	/** @return array */
	private function error( $path, $code, $message ) {
		return array( 'path' => $path, 'code' => $code, 'message' => $message );
	}

	/** @return \WP_Error */
	private function validation_error( array $errors ) {
		return new \WP_Error(
			'catalog_sync_invalid_payload',
			'The synchronization payload is invalid.',
			array( 'status' => 400, 'errors' => $errors )
		);
	}

	/** @return \WP_Error */
	private function single_type_error() {
		return $this->validation_error(
			array( $this->error( '$', 'invalid_type', 'The request body must be a JSON object.' ) )
		);
	}
}
