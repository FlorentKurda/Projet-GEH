import { useEffect, useRef } from 'react';
import type { AssistantMessage } from '../../assistant/types';
import type { Product } from '../../types/catalog';
import { AssistantProductCard } from './AssistantProductCard';

interface AssistantMessageListProps {
  messages: readonly AssistantMessage[];
  loading: boolean;
  failedRequest: string | null;
  placeholderUrl: string;
  getProductHref: (product: Product) => string;
  onOpenProduct: (product: Product) => void;
  onRetry: () => void;
}

export function AssistantMessageList({
  messages,
  loading,
  failedRequest,
  placeholderUrl,
  getProductHref,
  onOpenProduct,
  onRetry,
}: AssistantMessageListProps) {
  const endRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    endRef.current?.scrollIntoView?.({ block: 'end' });
  }, [failedRequest, loading, messages]);

  return (
    <div
      className="geh-assistant-messages"
      role="log"
      aria-live="polite"
      aria-relevant="additions text"
      aria-label="Conversation avec l’assistant produits"
    >
      {messages.map((message) => (
        <div
          className={`geh-assistant-message geh-assistant-message--${message.role}`}
          key={message.id}
        >
          <span className="geh-assistant-sr-only">
            {message.role === 'user' ? 'Vous :' : 'Assistant produits :'}
          </span>
          <p>{message.text}</p>
          {message.products && message.products.length > 0 && (
            <ul className="geh-assistant-products" aria-label="Produits proposés">
              {message.products.map((product) => (
                <li key={product.id}>
                  <AssistantProductCard
                    product={product}
                    placeholderUrl={placeholderUrl}
                    href={getProductHref(product)}
                    onOpen={onOpenProduct}
                  />
                </li>
              ))}
            </ul>
          )}
        </div>
      ))}

      {loading && (
        <div className="geh-assistant-message geh-assistant-message--assistant" role="status">
          <p className="geh-assistant-loading">
            Recherche dans le catalogue
            <span aria-hidden="true">…</span>
          </p>
        </div>
      )}

      {failedRequest && !loading && (
        <div
          className="geh-assistant-message geh-assistant-message--assistant geh-assistant-message--error"
          role="alert"
        >
          <p>Le catalogue est momentanément indisponible.</p>
          <button type="button" onClick={onRetry}>Réessayer</button>
        </div>
      )}
      <div ref={endRef} />
    </div>
  );
}
