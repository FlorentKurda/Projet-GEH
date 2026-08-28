export function LoadingGrid() {
  return (
    <div className="geh-catalog-grid" aria-label="Chargement des produits" aria-busy="true">
      {Array.from({ length: 8 }, (_, index) => (
        <div className="geh-catalog-skeleton" key={index} aria-hidden="true">
          <div className="geh-catalog-skeleton__image" />
          <div className="geh-catalog-skeleton__line geh-catalog-skeleton__line--short" />
          <div className="geh-catalog-skeleton__line" />
          <div className="geh-catalog-skeleton__line geh-catalog-skeleton__line--medium" />
        </div>
      ))}
    </div>
  );
}
