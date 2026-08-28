import type { CatalogFiltersResponse } from '../types/catalog';

interface FilterBarProps {
  searchInput: string;
  family: string;
  brand: string;
  filters: CatalogFiltersResponse;
  filtersLoading: boolean;
  onSearchChange: (value: string) => void;
  onFamilyChange: (value: string) => void;
  onBrandChange: (value: string) => void;
  onReset: () => void;
}

export function FilterBar({
  searchInput,
  family,
  brand,
  filters,
  filtersLoading,
  onSearchChange,
  onFamilyChange,
  onBrandChange,
  onReset,
}: FilterBarProps) {
  const hasCriteria = Boolean(searchInput || family || brand);

  return (
    <form className="geh-catalog-filters" role="search" onSubmit={(event) => event.preventDefault()}>
      <div className="geh-catalog-field geh-catalog-field--search">
        <label htmlFor="geh-catalog-search">Rechercher</label>
        <input
          id="geh-catalog-search"
          type="search"
          value={searchInput}
          maxLength={100}
          placeholder="Nom, référence, marque…"
          autoComplete="off"
          onChange={(event) => onSearchChange(event.target.value)}
        />
      </div>
      <div className="geh-catalog-field">
        <label htmlFor="geh-catalog-family">Famille</label>
        <select
          id="geh-catalog-family"
          value={family}
          disabled={filtersLoading}
          onChange={(event) => onFamilyChange(event.target.value)}
        >
          <option value="">Toutes les familles</option>
          {filters.families.map((item) => (
            <option key={item.code} value={item.code}>
              {item.label}
            </option>
          ))}
        </select>
      </div>
      <div className="geh-catalog-field">
        <label htmlFor="geh-catalog-brand">Marque</label>
        <select
          id="geh-catalog-brand"
          value={brand}
          disabled={filtersLoading}
          onChange={(event) => onBrandChange(event.target.value)}
        >
          <option value="">Toutes les marques</option>
          {filters.brands.map((item) => (
            <option key={item} value={item}>
              {item}
            </option>
          ))}
        </select>
      </div>
      {hasCriteria && (
        <button className="geh-catalog-reset" type="button" onClick={onReset}>
          Réinitialiser
        </button>
      )}
    </form>
  );
}
