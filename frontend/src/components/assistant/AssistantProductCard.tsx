import type { Product } from '../../types/catalog';
import { getProductMetadata } from '../../utils/productPresentation';
import { CatalogProductLink } from '../CatalogProductLink';
import { ProductImage } from '../ProductImage';

interface AssistantProductCardProps {
  product: Product;
  placeholderUrl: string;
  href: string;
  onOpen: (product: Product) => void;
}

export function AssistantProductCard({
  product,
  placeholderUrl,
  href,
  onOpen,
}: AssistantProductCardProps) {
  const metadata = getProductMetadata(product);

  return (
    <CatalogProductLink
      className="geh-assistant-product"
      href={href}
      product={product}
      onOpen={onOpen}
      aria-label={`Voir le produit ${product.name}, référence ${product.reference}`}
    >
      <ProductImage
        imageUrl={product.imageUrl}
        placeholderUrl={placeholderUrl}
        alt=""
        variant="assistant"
      />
      <span className="geh-assistant-product__body">
        <strong>{product.name}</strong>
        <span className="geh-assistant-product__reference">Réf. {product.reference}</span>
        {metadata.length > 0 && (
          <span className="geh-assistant-product__meta">{metadata.join(' · ')}</span>
        )}
      </span>
      <span className="geh-assistant-product__arrow" aria-hidden="true">→</span>
    </CatalogProductLink>
  );
}
