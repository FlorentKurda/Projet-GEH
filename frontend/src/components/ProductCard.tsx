import type { Product } from '../types/catalog';
import { getProductMetadata } from '../utils/productPresentation';
import { ProductImage } from './ProductImage';

interface ProductCardProps {
  product: Product;
  placeholderUrl: string;
  onOpen: (product: Product) => void;
}

export function ProductCard({ product, placeholderUrl, onOpen }: ProductCardProps) {
  const metadata = getProductMetadata(product);

  return (
    <article className="geh-catalog-card">
      <ProductImage
        imageUrl={product.imageUrl}
        placeholderUrl={placeholderUrl}
        alt={`Illustration de ${product.name}`}
        variant="card"
      />
      <div className="geh-catalog-card__body">
        <p className="geh-catalog-reference">Réf. {product.reference}</p>
        <h2 className="geh-catalog-card__title">{product.name}</h2>
        {metadata.length > 0 && (
          <p className="geh-catalog-card__meta">{metadata.join(' · ')}</p>
        )}
        <button
          className="geh-catalog-button geh-catalog-button--link"
          type="button"
          onClick={() => onOpen(product)}
          aria-label={`Voir le produit ${product.name}`}
        >
          Voir le produit
          <span aria-hidden="true"> →</span>
        </button>
      </div>
    </article>
  );
}
