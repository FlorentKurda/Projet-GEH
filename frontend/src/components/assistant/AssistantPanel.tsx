import type { RefObject } from 'react';
import type { AssistantMessage } from '../../assistant/types';
import type { Product } from '../../types/catalog';
import { AssistantInput } from './AssistantInput';
import { AssistantMessageList } from './AssistantMessageList';

interface AssistantPanelProps {
  panelId: string;
  titleId: string;
  modeId: string;
  inputRef: RefObject<HTMLInputElement | null>;
  messages: readonly AssistantMessage[];
  loading: boolean;
  failedRequest: string | null;
  placeholderUrl: string;
  getProductHref: (product: Product) => string;
  onClose: () => void;
  onNewConversation: () => void;
  onOpenProduct: (product: Product) => void;
  onRetry: () => void;
  onSubmit: (text: string) => void;
}

export function AssistantPanel({
  panelId,
  titleId,
  modeId,
  inputRef,
  messages,
  loading,
  failedRequest,
  placeholderUrl,
  getProductHref,
  onClose,
  onNewConversation,
  onOpenProduct,
  onRetry,
  onSubmit,
}: AssistantPanelProps) {
  return (
    <section
      className="geh-assistant-panel"
      id={panelId}
      role="dialog"
      aria-modal="false"
      aria-labelledby={titleId}
      aria-describedby={modeId}
    >
      <header className="geh-assistant-header">
        <div>
          <h2 id={titleId}>Assistant produits</h2>
          <p id={modeId}>Recherche catalogue — mode démo</p>
        </div>
        <div className="geh-assistant-header__actions">
          <button type="button" onClick={onNewConversation}>
            Nouvelle conversation
          </button>
          <button
            className="geh-assistant-close"
            type="button"
            aria-label="Fermer l’assistant produits"
            onClick={onClose}
          >
            <span aria-hidden="true">×</span>
          </button>
        </div>
      </header>

      <AssistantMessageList
        messages={messages}
        loading={loading}
        failedRequest={failedRequest}
        placeholderUrl={placeholderUrl}
        getProductHref={getProductHref}
        onOpenProduct={onOpenProduct}
        onRetry={onRetry}
      />

      <AssistantInput inputRef={inputRef} disabled={loading} onSubmit={onSubmit} />
    </section>
  );
}
