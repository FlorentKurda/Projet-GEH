import { describe, expect, it } from 'vitest';
import type { Product } from '../types/catalog';
import {
  ASSISTANT_SESSION_STORAGE_KEY,
  ASSISTANT_WELCOME_TEXT,
  clearAssistantMessages,
  createAssistantMessage,
  loadAssistantMessages,
  saveAssistantMessages,
} from './assistantSessionStorage';

function createMemoryStorage() {
  const values = new Map<string, string>();
  return {
    getItem: (key: string) => values.get(key) ?? null,
    setItem: (key: string, value: string) => values.set(key, value),
    removeItem: (key: string) => values.delete(key),
  };
}

const product: Product = {
  id: 11,
  sourceId: 'MOCK-0011',
  reference: 'REF-0011',
  name: 'Gants anti-coupure',
  shortDescription: 'Gants souples destinés aux manipulations en atelier.',
  familyCode: 'FAM-SEC',
  familyLabel: 'Sécurité',
  brand: 'Boréal',
  imageUrl: null,
  sourceUpdatedAtUtc: '2026-08-03T08:00:00Z',
};

describe('assistant session storage', () => {
  it('persists and restores messages with their product cards', () => {
    const storage = createMemoryStorage();
    const messages = [
      createAssistantMessage('user', 'Je cherche des gants'),
      createAssistantMessage('assistant', 'Un produit trouvé.', [product]),
    ];

    saveAssistantMessages(storage, messages);

    expect(loadAssistantMessages(storage)).toEqual(messages);
  });

  it('falls back to the welcome message when storage is invalid', () => {
    const storage = createMemoryStorage();
    storage.setItem(ASSISTANT_SESSION_STORAGE_KEY, '<invalid>');

    const restored = loadAssistantMessages(storage);

    expect(restored).toHaveLength(1);
    expect(restored[0]?.text).toBe(ASSISTANT_WELCOME_TEXT);
  });

  it('clears the current tab conversation', () => {
    const storage = createMemoryStorage();
    storage.setItem(ASSISTANT_SESSION_STORAGE_KEY, '[]');

    clearAssistantMessages(storage);

    expect(storage.getItem(ASSISTANT_SESSION_STORAGE_KEY)).toBeNull();
  });
});
