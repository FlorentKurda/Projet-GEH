import type { Product } from '../types/catalog';
import { getProductMetadata } from '../utils/productPresentation';
import { CatalogProductLink } from './CatalogProductLink';
import { ProductImage } from './ProductImage';

interface ProductCardProps {
  product: Product;
  placeholderUrl: string;
  href: string;
  onOpen: (product: Product) => void;
}

export function ProductCard({ product, placeholderUrl, href, onOpen }: ProductCardProps) {
  const metadata = getProductMetadata(product);

  return (
    <article className="geh-catalog-card">
      <CatalogProductLink
        className="geh-catalog-card__media-link"
        href={href}
        product={product}
        onOpen={onOpen}
      >
        <ProductImage
          imageUrl={product.imageUrl}
          placeholderUrl={placeholderUrl}
          alt={`Illustration de ${product.name}`}
          variant="card"
        />
      </CatalogProductLink>
      <div className="geh-catalog-card__body">
        <h2 className="geh-catalog-card__title">
          <CatalogProductLink
            className="geh-catalog-card__title-link"
            href={href}
            product={product}
            onOpen={onOpen}
          >
            {product.name}
          </CatalogProductLink>
        </h2>
        <p className="geh-catalog-reference">Réf. {product.reference}</p>
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
