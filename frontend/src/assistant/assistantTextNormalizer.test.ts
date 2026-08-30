import { describe, expect, it } from 'vitest';
import {
  buildAssistantRetrievalQueries,
  normalizeAssistantText,
} from './assistantTextNormalizer';

describe('assistant text normalization', () => {
  it('normalizes apostrophes, accents, punctuation and French stop words', () => {
    const normalized = normalizeAssistantText(
      '  Je cherche un produit d’entretien permettant de laver du carrelage ! ',
    );

    expect(normalized.normalizedText).toBe(
      'je cherche un produit d entretien permettant de laver du carrelage',
    );
    expect(normalized.significantTokens).toEqual(['entretien', 'laver', 'carrelage']);
    expect(normalized.concepts.map(({ id }) => id)).toEqual(['cleaning', 'floor-surface']);
  });

  it('handles a simple apostrophe exactly like a typographic apostrophe', () => {
    expect(normalizeAssistantText("produit d'entretien").significantTokens).toEqual([
      'entretien',
    ]);
    expect(normalizeAssistantText('produit d’entretien').significantTokens).toEqual([
      'entretien',
    ]);
  });

  it('never keeps or retrieves one- and two-character tokens', () => {
    const normalized = normalizeAssistantText("d ' de du ab");

    expect(normalized.significantTokens).toEqual([]);
    expect(buildAssistantRetrievalQueries(normalized)).toEqual([]);
  });

  it('expands a small number of extensible business concepts', () => {
    const normalized = normalizeAssistantText('ranger outils protéger mains');

    expect(normalized.concepts.map(({ id }) => id)).toEqual([
      'storage',
      'tools',
      'protection',
      'hands',
    ]);
    expect(buildAssistantRetrievalQueries(normalized)).toEqual([
      'rangement',
      'stockage',
      'outil',
      'outillage',
      'protection',
      'gants',
    ]);
  });
});
