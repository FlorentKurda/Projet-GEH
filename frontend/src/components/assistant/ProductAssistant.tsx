import { useCallback, useEffect, useId, useRef, useState } from 'react';
import {
  clearAssistantMessages,
  createAssistantMessage,
  createInitialAssistantMessages,
  loadAssistantMessages,
  saveAssistantMessages,
} from '../../assistant/assistantSessionStorage';
import type { AssistantClient, AssistantMessage } from '../../assistant/types';
import type { Product } from '../../types/catalog';
import { AssistantLauncher } from './AssistantLauncher';
import { AssistantPanel } from './AssistantPanel';

interface ProductAssistantProps {
  client: AssistantClient;
  placeholderUrl: string;
  getProductHref: (product: Product) => string;
  onOpenProduct: (product: Product) => void;
  storage?: Storage;
}

export function ProductAssistant({
  client,
  placeholderUrl,
  getProductHref,
  onOpenProduct,
  storage: storageOverride,
}: ProductAssistantProps) {
  const panelId = useId();
  const titleId = useId();
  const modeId = useId();
  const storage = storageOverride ?? window.sessionStorage;
  const launcherRef = useRef<HTMLButtonElement>(null);
  const inputRef = useRef<HTMLInputElement>(null);
  const controllerRef = useRef<AbortController | null>(null);
  const requestIdRef = useRef(0);
  const wasOpenRef = useRef(false);
  const [open, setOpen] = useState(false);
  const [messages, setMessages] = useState<AssistantMessage[]>(() =>
    loadAssistantMessages(storage),
  );
  const [loading, setLoading] = useState(false);
  const [failedRequest, setFailedRequest] = useState<string | null>(null);

  useEffect(() => {
    saveAssistantMessages(storage, messages);
  }, [messages, storage]);

  useEffect(() => () => controllerRef.current?.abort(), []);

  const closePanel = useCallback(() => {
    setOpen(false);
  }, []);

  useEffect(() => {
    if (!open) {
      if (wasOpenRef.current) launcherRef.current?.focus();
      wasOpenRef.current = false;
      return;
    }

    wasOpenRef.current = true;
    inputRef.current?.focus();

    const handleKeyDown = (event: KeyboardEvent) => {
      if (event.key === 'Escape') closePanel();
    };
    document.addEventListener('keydown', handleKeyDown);
    return () => document.removeEventListener('keydown', handleKeyDown);
  }, [closePanel, open]);

  const runRequest = useCallback(
    async (text: string, history: readonly AssistantMessage[]) => {
      controllerRef.current?.abort();
      const controller = new AbortController();
      controllerRef.current = controller;
      const requestId = ++requestIdRef.current;
      setFailedRequest(null);
      setLoading(true);

      try {
        const reply = await client.sendMessage(text, history, controller.signal);
        if (controller.signal.aborted || requestId !== requestIdRef.current) return;
        setMessages((current) => [
          ...current,
          createAssistantMessage('assistant', reply.text, reply.products),
        ]);
      } catch (error) {
        if (controller.signal.aborted || requestId !== requestIdRef.current) return;
        console.error('Assistant catalog search could not be completed.', error);
        setFailedRequest(text);
      } finally {
        if (requestId === requestIdRef.current) setLoading(false);
      }
    },
    [client],
  );

  const handleSubmit = (text: string) => {
    const userMessage = createAssistantMessage('user', text);
    const nextMessages = [...messages, userMessage];
    setMessages(nextMessages);
    void runRequest(text, nextMessages);
  };

  const handleRetry = () => {
    if (failedRequest) void runRequest(failedRequest, messages);
  };

  const handleNewConversation = () => {
    requestIdRef.current += 1;
    controllerRef.current?.abort();
    clearAssistantMessages(storage);
    setMessages(createInitialAssistantMessages());
    setFailedRequest(null);
    setLoading(false);
    inputRef.current?.focus();
  };

  const handleOpenProduct = (product: Product) => {
    closePanel();
    onOpenProduct(product);
  };

  return (
    <aside className="geh-assistant" aria-label="Assistant de recherche produits">
      {!open && (
        <AssistantLauncher
          ref={launcherRef}
          panelId={panelId}
          onOpen={() => setOpen(true)}
        />
      )}
      {open && (
        <AssistantPanel
          panelId={panelId}
          titleId={titleId}
          modeId={modeId}
          inputRef={inputRef}
          messages={messages}
          loading={loading}
          failedRequest={failedRequest}
          placeholderUrl={placeholderUrl}
          getProductHref={getProductHref}
          onClose={closePanel}
          onNewConversation={handleNewConversation}
          onOpenProduct={handleOpenProduct}
          onRetry={handleRetry}
          onSubmit={handleSubmit}
        />
      )}
    </aside>
  );
}
