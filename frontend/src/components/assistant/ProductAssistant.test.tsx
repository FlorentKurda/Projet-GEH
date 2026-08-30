/** @vitest-environment jsdom */

import { act } from 'react';
import { createRoot, type Root } from 'react-dom/client';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { ASSISTANT_SESSION_STORAGE_KEY } from '../../assistant/assistantSessionStorage';
import type { AssistantClient } from '../../assistant/types';
import type { Product } from '../../types/catalog';
import { ProductAssistant } from './ProductAssistant';

(globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

const product: Product = {
  id: 51,
  sourceId: 'MOCK-0051',
  reference: 'REF-0051',
  name: 'Perceuse sans fil',
  shortDescription: 'Perceuse compacte avec réglage du couple.',
  familyCode: 'FAM-ELE',
  familyLabel: 'Outillage électroportatif',
  brand: 'Novatool',
  imageUrl: null,
  sourceUpdatedAtUtc: '2026-08-13T08:00:00Z',
};

let container: HTMLDivElement;
let root: Root;

beforeEach(() => {
  window.sessionStorage.clear();
  container = document.createElement('div');
  document.body.append(container);
  root = createRoot(container);
});

afterEach(async () => {
  await act(async () => root.unmount());
  container.remove();
  vi.restoreAllMocks();
});

describe('product assistant UI', () => {
  it('opens, focuses the input and closes with Escape', async () => {
    await renderAssistant(createSuccessfulClient());

    expect(container.querySelector('[role="dialog"]')).toBeNull();
    await click(buttonNamed('Assistant produits'));

    const input = container.querySelector<HTMLInputElement>('input');
    expect(container.querySelector('[role="dialog"]')).not.toBeNull();
    expect(document.activeElement).toBe(input);

    await act(async () => {
      document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }));
    });

    expect(container.querySelector('[role="dialog"]')).toBeNull();
    expect(document.activeElement).toBe(buttonNamed('Assistant produits'));
  });

  it('shows the user message, demo response and linked product card, then persists them', async () => {
    const client = createSuccessfulClient();
    const onOpenProduct = vi.fn();
    await renderAssistant(client, onOpenProduct);
    await click(buttonNamed('Assistant produits'));

    const input = requiredElement(container.querySelector<HTMLInputElement>('input'));
    await changeInput(input, 'Je cherche une perceuse');
    await click(buttonNamed('Envoyer'));

    expect(client.sendMessage).toHaveBeenCalled();
    expect(container.textContent).toContain('Je cherche une perceuse');
    expect(container.textContent).toContain('Perceuse sans fil');
    expect(container.textContent).toContain('REF-0051');
    expect(container.textContent).toContain('Novatool · Outillage électroportatif');

    const productLink = requiredElement(
      container.querySelector<HTMLAnchorElement>('a[aria-label^="Voir le produit"]'),
    );
    expect(productLink.getAttribute('href')).toBe('?product=51');
    await click(productLink);

    expect(onOpenProduct).toHaveBeenCalledWith(product);
    expect(container.querySelector('[role="dialog"]')).toBeNull();

    const stored = window.sessionStorage.getItem(ASSISTANT_SESSION_STORAGE_KEY) ?? '';
    expect(stored).toContain('Je cherche une perceuse');
    expect(stored).toContain('REF-0051');
  });

  it('restores a conversation and starts a new one on request', async () => {
    window.sessionStorage.setItem(
      ASSISTANT_SESSION_STORAGE_KEY,
      JSON.stringify([
        {
          id: 'saved-user-message',
          role: 'user',
          text: 'Je cherche des gants',
          createdAt: '2026-08-29T10:00:00.000Z',
        },
      ]),
    );
    const client = createSuccessfulClient();
    await renderAssistant(client);
    await click(buttonNamed('Assistant produits'));

    expect(container.textContent).toContain('Je cherche des gants');
    await click(buttonNamed('Nouvelle conversation'));

    expect(container.textContent).not.toContain('Je cherche des gants');
    expect(container.textContent).toContain('Que recherchez-vous ?');

    const input = requiredElement(container.querySelector<HTMLInputElement>('input'));
    await changeInput(input, 'Je cherche une perceuse');
    await click(buttonNamed('Envoyer'));
    const sentHistory = vi.mocked(client.sendMessage).mock.calls.at(-1)?.[1] ?? [];
    expect(sentHistory.some(({ text }) => text.includes('gants'))).toBe(false);
    expect(sentHistory.some(({ text }) => text.includes('perceuse'))).toBe(true);
  });
});

function createSuccessfulClient(): AssistantClient {
  return {
    sendMessage: vi.fn(async () => ({
      kind: 'results' as const,
      text: 'J’ai trouvé un produit correspondant dans le catalogue actuel.',
      products: [product],
    })),
  };
}

async function renderAssistant(client: AssistantClient, onOpenProduct = vi.fn()) {
  await act(async () => {
    root.render(
      <ProductAssistant
        client={client}
        placeholderUrl="/placeholder.svg"
        getProductHref={(candidate) => `?product=${candidate.id}`}
        onOpenProduct={onOpenProduct}
      />,
    );
  });
}

async function click(element: Element) {
  await act(async () => {
    element.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true }));
    await Promise.resolve();
  });
}

async function changeInput(input: HTMLInputElement, value: string) {
  const valueSetter = Object.getOwnPropertyDescriptor(
    HTMLInputElement.prototype,
    'value',
  )?.set;
  await act(async () => {
    valueSetter?.call(input, value);
    input.dispatchEvent(new Event('input', { bubbles: true }));
  });
}

function buttonNamed(name: string): HTMLButtonElement {
  const button = [...container.querySelectorAll<HTMLButtonElement>('button')].find(
    (candidate) =>
      candidate.textContent?.includes(name) || candidate.getAttribute('aria-label') === name,
  );
  return requiredElement(button ?? null);
}

function requiredElement<T extends Element>(element: T | null): T {
  if (!element) throw new Error('Expected element was not rendered.');
  return element;
}
