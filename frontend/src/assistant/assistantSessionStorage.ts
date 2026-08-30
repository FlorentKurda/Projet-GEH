import type { Product } from '../types/catalog';
import type { AssistantMessage, AssistantMessageRole } from './types';

export const ASSISTANT_SESSION_STORAGE_KEY = 'geh-product-assistant:conversation:v1';
export const ASSISTANT_WELCOME_TEXT =
  'Bonjour\nJe peux vous aider à trouver un produit dans notre catalogue.\nQue recherchez-vous ?';

const MAX_STORED_MESSAGES = 50;
type AssistantStorage = Pick<Storage, 'getItem' | 'setItem' | 'removeItem'>;

export function createAssistantMessage(
  role: AssistantMessageRole,
  text: string,
  products?: Product[],
): AssistantMessage {
  return {
    id: createMessageId(),
    role,
    text,
    ...(products && products.length > 0 ? { products } : {}),
    createdAt: new Date().toISOString(),
  };
}

export function createInitialAssistantMessages(): AssistantMessage[] {
  return [createAssistantMessage('assistant', ASSISTANT_WELCOME_TEXT)];
}

export function loadAssistantMessages(storage: AssistantStorage): AssistantMessage[] {
  try {
    const serialized = storage.getItem(ASSISTANT_SESSION_STORAGE_KEY);
    if (!serialized) return createInitialAssistantMessages();

    const parsed: unknown = JSON.parse(serialized);
    if (!Array.isArray(parsed)) return createInitialAssistantMessages();

    const messages = parsed.filter(isAssistantMessage).slice(-MAX_STORED_MESSAGES);
    return messages.length > 0 ? messages : createInitialAssistantMessages();
  } catch {
    return createInitialAssistantMessages();
  }
}

export function saveAssistantMessages(
  storage: AssistantStorage,
  messages: readonly AssistantMessage[],
): void {
  try {
    storage.setItem(
      ASSISTANT_SESSION_STORAGE_KEY,
      JSON.stringify(messages.slice(-MAX_STORED_MESSAGES)),
    );
  } catch {
    // sessionStorage can be unavailable or full; the in-memory conversation still works.
  }
}

export function clearAssistantMessages(storage: AssistantStorage): void {
  try {
    storage.removeItem(ASSISTANT_SESSION_STORAGE_KEY);
  } catch {
    // Keep the reset local to the current render when storage is unavailable.
  }
}

function createMessageId(): string {
  if (typeof crypto !== 'undefined' && typeof crypto.randomUUID === 'function') {
    return crypto.randomUUID();
  }
  return `geh-assistant-${Date.now()}-${Math.random().toString(36).slice(2)}`;
}

function isAssistantMessage(value: unknown): value is AssistantMessage {
  if (!isRecord(value)) return false;
  if (value.role !== 'user' && value.role !== 'assistant') return false;
  if (typeof value.id !== 'string' || typeof value.text !== 'string') return false;
  if (typeof value.createdAt !== 'string') return false;
  if (value.products === undefined) return true;
  return Array.isArray(value.products) && value.products.every(isProduct);
}

function isProduct(value: unknown): value is Product {
  if (!isRecord(value)) return false;
  return (
    typeof value.id === 'number' &&
    typeof value.sourceId === 'string' &&
    typeof value.reference === 'string' &&
    typeof value.name === 'string' &&
    isNullableString(value.shortDescription) &&
    isNullableString(value.familyCode) &&
    isNullableString(value.familyLabel) &&
    isNullableString(value.brand) &&
    isNullableString(value.imageUrl) &&
    isNullableString(value.sourceUpdatedAtUtc)
  );
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null;
}

function isNullableString(value: unknown): value is string | null {
  return value === null || typeof value === 'string';
}
