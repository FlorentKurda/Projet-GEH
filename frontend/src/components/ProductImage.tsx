import { useEffect, useState } from 'react';

interface ProductImageProps {
  imageUrl: string | null;
  placeholderUrl: string;
  alt: string;
  variant: 'card' | 'detail';
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
        loading={variant === 'card' ? 'lazy' : 'eager'}
        onError={() => {
          if (source !== placeholderUrl) setSource(placeholderUrl);
        }}
      />
    </div>
  );
}
