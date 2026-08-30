import type { Product } from '../types/catalog';

export type AssistantMessageRole = 'user' | 'assistant';

export interface AssistantMessage {
  id: string;
  role: AssistantMessageRole;
  text: string;
  products?: Product[];
  createdAt: string;
}

export interface AssistantHistoryItem {
  role: AssistantMessageRole;
  text: string;
}

export type AssistantReplyKind = 'results' | 'no-results' | 'clarification';

export interface AssistantReply {
  text: string;
  kind: AssistantReplyKind;
  products?: Product[];
}

export interface AssistantEngineRequest {
  text: string;
  history: AssistantHistoryItem[];
  signal?: AbortSignal;
}

export interface AssistantEngine {
  respond(request: AssistantEngineRequest): Promise<AssistantReply>;
}

export interface AssistantClient {
  sendMessage(
    text: string,
    history: readonly AssistantMessage[],
    signal?: AbortSignal,
  ): Promise<AssistantReply>;
}

export type AssistantCatalogSearch = (
  queries: readonly string[],
  signal?: AbortSignal,
) => Promise<Product[]>;
