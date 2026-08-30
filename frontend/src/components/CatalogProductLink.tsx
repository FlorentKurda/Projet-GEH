import type { AnchorHTMLAttributes, MouseEvent } from 'react';
import type { Product } from '../types/catalog';

interface CatalogProductLinkProps
  extends Omit<AnchorHTMLAttributes<HTMLAnchorElement>, 'href' | 'onClick'> {
  product: Product;
  href: string;
  onOpen: (product: Product) => void;
}

export function CatalogProductLink({
  product,
  href,
  onOpen,
  ...anchorProps
}: CatalogProductLinkProps) {
  const handleClick = (event: MouseEvent<HTMLAnchorElement>) => {
    if (
      event.button !== 0 ||
      event.metaKey ||
      event.ctrlKey ||
      event.shiftKey ||
      event.altKey
    ) {
      return;
    }

    event.preventDefault();
    onOpen(product);
  };

  return <a {...anchorProps} href={href} onClick={handleClick} />;
}
