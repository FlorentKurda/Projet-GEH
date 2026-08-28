import type { Product } from '../types/catalog';
import { ProductImage } from './ProductImage';

interface ProductDetailProps {
  product: Product;
  placeholderUrl: string;
  onBack: () => void;
}

export function ProductDetail({ product, placeholderUrl, onBack }: ProductDetailProps) {
  return (
    <article className="geh-catalog-detail">
      <button className="geh-catalog-back" type="button" onClick={onBack}>
        <span aria-hidden="true">← </span>
        Retour aux produits
      </button>
      <div className="geh-catalog-detail__layout">
        <ProductImage
          imageUrl={product.imageUrl}
          placeholderUrl={placeholderUrl}
          alt={`Illustration de ${product.name}`}
          variant="detail"
        />
        <div className="geh-catalog-detail__content">
          <p className="geh-catalog-reference">Réf. {product.reference}</p>
          <h1>{product.name}</h1>
          {(product.brand || product.familyLabel) && (
            <dl className="geh-catalog-detail__facts">
              {product.brand && (
                <div>
                  <dt>Marque</dt>
                  <dd>{product.brand}</dd>
                </div>
              )}
              {product.familyLabel && (
                <div>
                  <dt>Famille</dt>
                  <dd>{product.familyLabel}</dd>
                </div>
              )}
            </dl>
          )}
          {product.shortDescription ? (
            <div className="geh-catalog-detail__description">
              <h2>Description</h2>
              <p>{product.shortDescription}</p>
            </div>
          ) : (
            <p className="geh-catalog-muted">Aucune description disponible pour ce produit.</p>
          )}
        </div>
      </div>
    </article>
  );
}
