import { useEffect, useState } from 'react';

interface ProductImageProps {
  imageUrl: string | null;
  placeholderUrl: string;
  alt: string;
  variant: 'card' | 'detail' | 'assistant';
}

export function ProductImage({
  imageUrl,
  placeholderUrl,
  alt,
  variant,
}: ProductImageProps) {
  const initialSource = imageUrl || placeholderUrl;
  const [source, setSource] = useState(initialSource);

  useEffect(() => setSource(initialSource), [initialSource]);

  return (
    <div className={`geh-catalog-image geh-catalog-image--${variant}`}>
      <img
        src={source}
        alt={alt}
        loading={variant === 'detail' ? 'eager' : 'lazy'}
        onError={() => {
          if (source !== placeholderUrl) setSource(placeholderUrl);
        }}
      />
    </div>
  );
}
