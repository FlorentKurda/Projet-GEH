import { describe, expect, it, vi } from 'vitest';
import fixtureProducts from '../../../fixtures/products.json';
import type { Product } from '../types/catalog';
import { normalizeForAssistantMatching } from './assistantTextNormalizer';
import { createDemoAssistantEngine } from './demoAssistantEngine';
import type { AssistantCatalogSearch, AssistantReply } from './types';

const products: Product[] = fixtureProducts.map((fixture, index) => ({
  ...fixture,
  id: index + 1,
  imageUrl: null,
}));

describe('demo assistant relevance on the current fixture catalog', () => {
  it('A — ranks the drill without unrelated storage products', async () => {
    const reply = await ask('Je cherche une perceuse');

    expect(productNames(reply)[0]).toBe('Perceuse sans fil');
    expect(productNames(reply)).not.toContain('Armoire d’atelier');
  });

  it('B — returns gloves without unrelated tools', async () => {
    const reply = await ask('Je cherche des gants');

    expect(productNames(reply)).toEqual(['Gants anti-coupure']);
  });

  it('C — favors storage products for tools to put away', async () => {
    const reply = await ask('Je cherche quelque chose pour ranger mes outils');
    const names = productNames(reply);

    expect(
      names.some((name) => name === 'Armoire d’atelier' || name === 'Caisse pliable'),
    ).toBe(true);
    expect(names.some((name) => name.includes('rangement') || name.includes('outils'))).toBe(true);
    expect(reply.products?.every(({ familyLabel }) => familyLabel === 'Rangement')).toBe(true);
    expect(names.length).toBeLessThanOrEqual(3);
  });

  it('D — keeps a tile-cleaning request inside relevant floor-care products', async () => {
    const search = createFixtureSearch();
    const reply = await createDemoAssistantEngine(search).respond({
      text: "Je cherche un produit d'entretien permettant de laver du carrelage",
      history: [],
    });
    const names = productNames(reply);

    expect(search).toHaveBeenCalledWith(
      ['entretien', 'nettoyage', 'sol', 'carrelage'],
      undefined,
    );
    expect(names).toContain('Balai d’atelier');
    expect(names).toContain('Raclette de sol');
    expect(reply.products?.every(({ familyLabel }) => familyLabel === 'Entretien')).toBe(true);
    expect(names).not.toContain('Armoire d’atelier');
    expect(names).not.toContain('Agrafeuse manuelle');
  });

  it('E — requires a hand match when the user wants hand protection', async () => {
    const reply = await ask('Je cherche un produit pour protéger mes mains');

    expect(productNames(reply)).toEqual(['Gants anti-coupure']);
  });

  it('F — ranks distance-measurement products', async () => {
    const reply = await ask('Je veux mesurer une distance');
    const names = productNames(reply);

    expect(names[0]).toBe('Télémètre laser');
    expect(names).toContain('Mètre ruban 5 m');
  });

  it('G — returns no product for unknown concepts', async () => {
    const reply = await ask('abcdef xyz introuvable');

    expect(reply.kind).toBe('no-results');
    expect(reply.products).toBeUndefined();
    expect(reply.text).toContain('suffisamment proche');
  });

  it('H — clarifies a generic product request without searching', async () => {
    const search = createFixtureSearch();
    const reply = await createDemoAssistantEngine(search).respond({
      text: 'Je cherche un produit',
      history: [],
    });

    expect(reply.kind).toBe('clarification');
    expect(search).not.toHaveBeenCalled();
  });

  it('I — never searches a one-letter request', async () => {
    const search = createFixtureSearch();
    const reply = await createDemoAssistantEngine(search).respond({
      text: 'd',
      history: [],
    });

    expect(reply.kind).toBe('clarification');
    expect(reply.products).toBeUndefined();
    expect(search).not.toHaveBeenCalled();
  });

  it('uses only the previous clarification exchange for a short follow-up', async () => {
    const search = createFixtureSearch();
    const engine = createDemoAssistantEngine(search);
    const firstRequest = 'Je cherche un produit d’entretien';
    const firstReply = await engine.respond({ text: firstRequest, history: [] });

    expect(firstReply.kind).toBe('clarification');
    const followUp = await engine.respond({
      text: 'Du carrelage',
      history: [
        { role: 'user', text: firstRequest },
        { role: 'assistant', text: firstReply.text },
        { role: 'user', text: 'Du carrelage' },
      ],
    });

    expect(productNames(followUp)).toContain('Raclette de sol');
    expect(productNames(followUp)).toContain('Balai d’atelier');
  });
});

async function ask(text: string): Promise<AssistantReply> {
  return createDemoAssistantEngine(createFixtureSearch()).respond({ text, history: [] });
}

function productNames(reply: AssistantReply): string[] {
  return reply.products?.map(({ name }) => name) ?? [];
}

function createFixtureSearch() {
  const search: AssistantCatalogSearch = async (queries) => {
    const candidates = new Map<number, Product>();
    queries.forEach((query) => {
      const normalizedQuery = normalizeForAssistantMatching(query);
      products
        .filter((product) => getPublicSearchText(product).includes(normalizedQuery))
        .sort((left, right) => left.name.localeCompare(right.name, 'fr'))
        .slice(0, 12)
        .forEach((product) => candidates.set(product.id, product));
    });
    return [...candidates.values()];
  };
  return vi.fn(search);
}

function getPublicSearchText(product: Product): string {
  return normalizeForAssistantMatching(
    [product.reference, product.name, product.brand, product.familyLabel]
      .filter((value): value is string => typeof value === 'string')
      .join(' '),
  );
}
