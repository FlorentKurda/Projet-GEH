import type { Product } from '../types/catalog';

export function getProductMetadata(product: Product): string[] {
  return [product.brand, product.familyLabel].filter(
    (value): value is string => typeof value === 'string' && value.trim().length > 0,
  );
}
