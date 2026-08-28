import { getPaginationItems } from '../utils/pagination';

interface PaginationProps {
  page: number;
  totalPages: number;
  onChange: (page: number) => void;
}

export function Pagination({ page, totalPages, onChange }: PaginationProps) {
  if (totalPages <= 1) return null;

  return (
    <nav className="geh-catalog-pagination" aria-label="Pagination du catalogue">
      <button type="button" disabled={page <= 1} onClick={() => onChange(page - 1)}>
        Précédent
      </button>
      <div className="geh-catalog-pagination__pages">
        {getPaginationItems(page, totalPages).map((item) => {
          if (typeof item !== 'number') {
            return (
              <span key={item} className="geh-catalog-pagination__ellipsis" aria-hidden="true">
                …
              </span>
            );
          }

          return (
            <button
              key={item}
              type="button"
              className={item === page ? 'is-current' : undefined}
              aria-current={item === page ? 'page' : undefined}
              aria-label={`Page ${item}`}
              onClick={() => onChange(item)}
            >
              {item}
            </button>
          );
        })}
      </div>
      <button type="button" disabled={page >= totalPages} onClick={() => onChange(page + 1)}>
        Suivant
      </button>
    </nav>
  );
}
