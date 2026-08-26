<?php
/**
 * Validation and normalization of incoming synchronization payloads.
 *
 * @package ProductCatalogSync
 */

namespace ProductCatalogSync;

if ( ! defined( 'ABSPATH' ) ) {
	exit;
}

/**
 * Validates the complete request before any database write is attempted.
 */
final class Product_Validator {
	public const MAX_PRODUCTS = 500;

	private const TOP_LEVEL_FIELDS = array(
		'schemaVersion',
		'runId',
		'sentAtUtc',
		'products',
	);

	private const PRODUCT_FIELDS = array(
		'sourceId',
		'reference',
		'name',
		'shortDescription',
		'familyCode',
		'familyLabel',
		'brand',
		'sourceUpdatedAtUtc',
	);

	/**
	 * Validates and normalizes a decoded JSON payload.
	 *
	 * @param mixed $payload Decoded request JSON.
	 * @return array|\WP_Error Normalized payload or a REST-ready validation error.
	 */
	public function validate( $payload ) {
		if ( ! is_array( $payload ) ) {
			return $this->validation_error(
				array(
					$this->error( '$', 'invalid_type', 'The request body must be a JSON object.' ),
				)
			);
		}

		$errors = array();
		$this->validate_unknown_fields( $payload, self::TOP_LEVEL_FIELDS, '$', $errors );

		$schema_version = null;
		if ( ! array_key_exists( 'schemaVersion', $payload ) ) {
			$errors[] = $this->error( 'schemaVersion', 'required', 'schemaVersion is required.' );
		} elseif ( ! is_int( $payload['schemaVersion'] ) || 1 !== $payload['schemaVersion'] ) {
			$errors[] = $this->error( 'schemaVersion', 'invalid_schema_version', 'schemaVersion must be the integer 1.' );
		} else {
			$schema_version = 1;
		}

		$run_id = null;
		if ( ! array_key_exists( 'runId', $payload ) ) {
			$errors[] = $this->error( 'runId', 'required', 'runId is required.' );
		} elseif ( ! is_string( $payload['runId'] ) ) {
			$errors[] = $this->error( 'runId', 'invalid_type', 'runId must be a string.' );
		} else {
			$run_id = $this->trim_unicode( $payload['runId'] );
			if ( ! $this->is_uuid( $run_id ) ) {
				$errors[] = $this->error( 'runId', 'invalid_uuid', 'runId must be a valid UUID.' );
			}
		}

		$sent_at_utc = null;
		if ( ! array_key_exists( 'sentAtUtc', $payload ) ) {
			$errors[] = $this->error( 'sentAtUtc', 'required', 'sentAtUtc is required.' );
		} elseif ( ! is_string( $payload['sentAtUtc'] ) ) {
			$errors[] = $this->error( 'sentAtUtc', 'invalid_type', 'sentAtUtc must be an ISO 8601 string.' );
		} else {
			$sent_at = $this->parse_iso8601( $this->trim_unicode( $payload['sentAtUtc'] ) );
			if ( null === $sent_at ) {
				$errors[] = $this->error( 'sentAtUtc', 'invalid_date', 'sentAtUtc must be a valid ISO 8601 timestamp with a time zone.' );
			} else {
				$sent_at_utc = $sent_at->setTimezone( new \DateTimeZone( 'UTC' ) )->format( 'Y-m-d\TH:i:s\Z' );
			}
		}

		$normalized_products = array();
		$seen_source_ids     = array();
		$products            = isset( $payload['products'] ) ? $payload['products'] : null;
		$can_validate_items  = true;

		if ( ! array_key_exists( 'products', $payload ) ) {
			$errors[]          = $this->error( 'products', 'required', 'products is required.' );
			$can_validate_items = false;
		} elseif ( ! is_array( $products ) || array_values( $products ) !== $products ) {
			$errors[]          = $this->error( 'products', 'invalid_type', 'products must be a JSON array.' );
			$can_validate_items = false;
		} elseif ( 0 === count( $products ) ) {
			$errors[]          = $this->error( 'products', 'empty_collection', 'products must contain at least one product.' );
			$can_validate_items = false;
		} elseif ( self::MAX_PRODUCTS < count( $products ) ) {
			$errors[]          = $this->error(
				'products',
				'too_many_products',
				sprintf( 'products must not contain more than %d items.', self::MAX_PRODUCTS )
			);
			$can_validate_items = false;
		}

		if ( $can_validate_items ) {
			foreach ( $products as $index => $product ) {
				$path = 'products[' . $index . ']';

				if ( ! is_array( $product ) ) {
					$errors[] = $this->error( $path, 'invalid_type', 'Each product must be a JSON object.' );
					continue;
				}

				$this->validate_unknown_fields( $product, self::PRODUCT_FIELDS, $path, $errors );

				$source_id = $this->required_text( $product, 'sourceId', 100, $path, false, $errors );
				$reference = $this->required_text( $product, 'reference', 100, $path, false, $errors );
				$name      = $this->required_text( $product, 'name', 255, $path, false, $errors );

				$short_description = $this->optional_text( $product, 'shortDescription', 2000, $path, true, $errors );
				$family_code       = $this->optional_text( $product, 'familyCode', 100, $path, false, $errors );
				$family_label      = $this->optional_text( $product, 'familyLabel', 255, $path, false, $errors );
				$brand             = $this->optional_text( $product, 'brand', 255, $path, false, $errors );

				$source_updated_at = null;
				if ( array_key_exists( 'sourceUpdatedAtUtc', $product ) && null !== $product['sourceUpdatedAtUtc'] ) {
					if ( ! is_string( $product['sourceUpdatedAtUtc'] ) ) {
						$errors[] = $this->error(
							$path . '.sourceUpdatedAtUtc',
							'invalid_type',
							'sourceUpdatedAtUtc must be null or an ISO 8601 string.'
						);
					} else {
						$parsed_source_date = $this->parse_iso8601( $this->trim_unicode( $product['sourceUpdatedAtUtc'] ) );
						if ( null === $parsed_source_date ) {
							$errors[] = $this->error(
								$path . '.sourceUpdatedAtUtc',
								'invalid_date',
								'sourceUpdatedAtUtc must be a valid ISO 8601 timestamp with a time zone.'
							);
						} else {
							$source_updated_at = $parsed_source_date
								->setTimezone( new \DateTimeZone( 'UTC' ) )
								->format( 'Y-m-d H:i:s' );
						}
					}
				}

				if ( null !== $source_id ) {
					$source_id_key = function_exists( 'mb_strtolower' ) ? mb_strtolower( $source_id, 'UTF-8' ) : strtolower( $source_id );
					if ( isset( $seen_source_ids[ $source_id_key ] ) ) {
						$errors[] = $this->error(
							$path . '.sourceId',
							'duplicate_source_id',
							'sourceId must be unique within the payload.'
						);
					} else {
						$seen_source_ids[ $source_id_key ] = true;
					}
				}

				$normalized_products[] = array(
					'source_id'         => $source_id,
					'reference'         => $reference,
					'name'              => $name,
					'short_description' => $short_description,
					'family_code'       => $family_code,
					'family_label'      => $family_label,
					'brand'             => $brand,
					'source_updated_at' => $source_updated_at,
				);
			}
		}

		if ( ! empty( $errors ) ) {
			return $this->validation_error( $errors );
		}

		return array(
			'schema_version' => $schema_version,
			'run_id'          => $run_id,
			'sent_at_utc'      => $sent_at_utc,
			'products'         => $normalized_products,
		);
	}

	/**
	 * Rejects fields outside the explicit contract. This prevents accidental
	 * transmission of data such as prices or stock quantities.
	 *
	 * @param array $value    Object represented as an associative array.
	 * @param array $allowed  Allowed field names.
	 * @param string $path    JSON path used in error messages.
	 * @param array $errors   Error accumulator.
	 * @return void
	 */
	private function validate_unknown_fields( array $value, array $allowed, $path, array &$errors ) {
		foreach ( array_keys( $value ) as $field ) {
			if ( ! is_string( $field ) || ! in_array( $field, $allowed, true ) ) {
				$errors[] = $this->error(
					$path . '.' . (string) $field,
					'unknown_field',
					'The field is not part of schema version 1.'
				);
			}
		}
	}

	/**
	 * @param array $product Product input.
	 * @param string $field Field name.
	 * @param int $maximum_length Maximum allowed number of characters.
	 * @param string $path Product JSON path.
	 * @param bool $multiline Whether line breaks are accepted.
	 * @param array $errors Error accumulator.
	 * @return string|null
	 */
	private function required_text( array $product, $field, $maximum_length, $path, $multiline, array &$errors ) {
		$field_path = $path . '.' . $field;

		if ( ! array_key_exists( $field, $product ) ) {
			$errors[] = $this->error( $field_path, 'required', $field . ' is required.' );
			return null;
		}

		if ( ! is_string( $product[ $field ] ) ) {
			$errors[] = $this->error( $field_path, 'invalid_type', $field . ' must be a string.' );
			return null;
		}

		$value = $this->trim_unicode( $product[ $field ] );
		if ( '' === $value ) {
			$errors[] = $this->error( $field_path, 'empty_value', $field . ' must not be empty.' );
			return null;
		}

		if ( $this->text_length( $value ) > $maximum_length ) {
			$errors[] = $this->error(
				$field_path,
				'max_length',
				sprintf( '%s must not exceed %d characters.', $field, $maximum_length )
			);
		}

		$value = $multiline ? sanitize_textarea_field( $value ) : sanitize_text_field( $value );
		$value = $this->trim_unicode( $value );

		if ( '' === $value ) {
			$errors[] = $this->error( $field_path, 'empty_value', $field . ' must contain text.' );
			return null;
		}

		return $value;
	}

	/**
	 * @param array $product Product input.
	 * @param string $field Field name.
	 * @param int $maximum_length Maximum allowed number of characters.
	 * @param string $path Product JSON path.
	 * @param bool $multiline Whether line breaks are accepted.
	 * @param array $errors Error accumulator.
	 * @return string|null
	 */
	private function optional_text( array $product, $field, $maximum_length, $path, $multiline, array &$errors ) {
		if ( ! array_key_exists( $field, $product ) || null === $product[ $field ] ) {
			return null;
		}

		$field_path = $path . '.' . $field;
		if ( ! is_string( $product[ $field ] ) ) {
			$errors[] = $this->error( $field_path, 'invalid_type', $field . ' must be null or a string.' );
			return null;
		}

		$value = $this->trim_unicode( $product[ $field ] );
		if ( '' === $value ) {
			return null;
		}

		if ( $this->text_length( $value ) > $maximum_length ) {
			$errors[] = $this->error(
				$field_path,
				'max_length',
				sprintf( '%s must not exceed %d characters.', $field, $maximum_length )
			);
		}

		$value = $multiline ? sanitize_textarea_field( $value ) : sanitize_text_field( $value );

		return '' === $this->trim_unicode( $value ) ? null : $this->trim_unicode( $value );
	}

	/**
	 * Parses the timestamp only after a strict ISO 8601 shape and calendar check.
	 *
	 * @param string $value Timestamp to parse.
	 * @return \DateTimeImmutable|null
	 */
	private function parse_iso8601( $value ) {
		$pattern = '/\A(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,7}))?(Z|[+-](?:(?:0\d|1[0-3]):[0-5]\d|14:00))\z/i';
		if ( 1 !== preg_match( $pattern, $value, $matches ) ) {
			return null;
		}

		if (
			! checkdate( (int) $matches[2], (int) $matches[3], (int) $matches[1] ) ||
			(int) $matches[4] > 23 ||
			(int) $matches[5] > 59 ||
			(int) $matches[6] > 59
		) {
			return null;
		}

		// .NET's round-trip representation can contain seven fractional digits,
		// while PHP stores at most microseconds. Truncation is safe because the
		// database contract intentionally persists whole seconds.
		$php_parseable_value = preg_replace( '/(\.\d{6})\d(?=Z|[+-])/i', '$1', $value );
		if ( ! is_string( $php_parseable_value ) ) {
			return null;
		}

		try {
			$date = new \DateTimeImmutable( $php_parseable_value );
		} catch ( \Exception $exception ) {
			return null;
		}

		$date_errors = \DateTimeImmutable::getLastErrors();
		if ( is_array( $date_errors ) && ( $date_errors['warning_count'] > 0 || $date_errors['error_count'] > 0 ) ) {
			return null;
		}

		return $date;
	}

	/**
	 * @param string $value UUID candidate.
	 * @return bool
	 */
	private function is_uuid( $value ) {
		return 1 === preg_match(
			'/\A[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/i',
			$value
		);
	}

	/**
	 * @param string $value Input text.
	 * @return string
	 */
	private function trim_unicode( $value ) {
		$trimmed = trim( $value );
		$result  = preg_replace( '/\A[\p{Z}\s]+|[\p{Z}\s]+\z/u', '', $trimmed );

		return is_string( $result ) ? $result : $trimmed;
	}

	/**
	 * @param string $value Input text.
	 * @return int
	 */
	private function text_length( $value ) {
		if ( function_exists( 'mb_strlen' ) ) {
			return mb_strlen( $value, 'UTF-8' );
		}

		$length = preg_match_all( '/./us', $value, $characters );

		return false === $length ? strlen( $value ) : $length;
	}

	/**
	 * @param string $path JSON path.
	 * @param string $code Stable error code.
	 * @param string $message Human-readable error.
	 * @return array
	 */
	private function error( $path, $code, $message ) {
		return array(
			'path'    => $path,
			'code'    => $code,
			'message' => $message,
		);
	}

	/**
	 * @param array $errors Detailed validation errors.
	 * @return \WP_Error
	 */
	private function validation_error( array $errors ) {
		return new \WP_Error(
			'catalog_sync_invalid_payload',
			'The synchronization payload is invalid.',
			array(
				'status' => 400,
				'errors' => $errors,
			)
		);
	}
}
