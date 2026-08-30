import { findAssistantConceptDefinition } from './assistantSynonyms';

export const MIN_ASSISTANT_TOKEN_LENGTH = 3;

export interface AssistantConcept {
  id: string;
  sourceTokens: string[];
  matchTerms: readonly string[];
  retrievalTerms: readonly string[];
  importance: number;
  requiredWhenCombined: boolean;
  clarificationWhenAlone?: string;
}

export interface NormalizedAssistantText {
  normalizedText: string;
  significantTokens: string[];
  concepts: AssistantConcept[];
  brandRequested: boolean;
}

const stopWords = new Set([
  'aide',
  'aider',
  'aimerais',
  'article',
  'articles',
  'avoir',
  'avec',
  'besoin',
  'bonjour',
  'catalogue',
  'cherche',
  'cherchons',
  'chose',
  'comme',
  'dans',
  'des',
  'donc',
  'elle',
  'equipement',
  'equipements',
  'etc',
  'faire',
  'famille',
  'hello',
  'ils',
  'les',
  'marque',
  'materiel',
  'merci',
  'mes',
  'mon',
  'notre',
  'nous',
  'permet',
  'permettant',
  'permettre',
  'plait',
  'pour',
  'pouvoir',
  'produit',
  'produits',
  'que',
  'quel',
  'quelle',
  'quelles',
  'quels',
  'quelque',
  'qui',
  'recherche',
  'rechercher',
  'salut',
  'sans',
  'souhaite',
  'svp',
  'trouver',
  'une',
  'veut',
  'veux',
  'voudrais',
  'votre',
  'vous',
]);

export function normalizeAssistantText(text: string): NormalizedAssistantText {
  const normalizedText = normalizeForAssistantMatching(text);
  const allTokens = tokenizeNormalizedText(normalizedText);
  const significantTokens = [...new Set(allTokens.filter(isSignificantToken))];
  const concepts = new Map<string, AssistantConcept>();

  significantTokens.forEach((token) => {
    const definition = findAssistantConceptDefinition(token);
    if (definition) {
      const existing = concepts.get(definition.id);
      if (existing) {
        existing.sourceTokens.push(token);
        return;
      }
      concepts.set(definition.id, {
        id: definition.id,
        sourceTokens: [token],
        matchTerms: definition.matchTerms,
        retrievalTerms: definition.retrievalTerms,
        importance: definition.importance,
        requiredWhenCombined: definition.requiredWhenCombined ?? false,
        ...(definition.clarificationWhenAlone
          ? { clarificationWhenAlone: definition.clarificationWhenAlone }
          : {}),
      });
      return;
    }

    const terms = getLiteralTermVariants(token);
    concepts.set(`literal:${terms.join('|')}`, {
      id: `literal:${terms.join('|')}`,
      sourceTokens: [token],
      matchTerms: terms,
      retrievalTerms: terms,
      importance: 1,
      requiredWhenCombined: true,
    });
  });

  return {
    normalizedText,
    significantTokens,
    concepts: [...concepts.values()],
    brandRequested: allTokens.includes('marque'),
  };
}

export function normalizeForAssistantMatching(text: string): string {
  return text
    .trim()
    .normalize('NFKD')
    .replace(/[\u0300-\u036f]/g, '')
    .toLocaleLowerCase('fr')
    .replace(/[’']/g, ' ')
    .replace(/[^\p{L}\p{N}-]+/gu, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

export function tokenizeNormalizedText(normalizedText: string): string[] {
  return normalizedText.match(/[\p{L}\p{N}]+(?:-[\p{L}\p{N}]+)*/gu) ?? [];
}

export function buildAssistantRetrievalQueries(
  normalized: NormalizedAssistantText,
): string[] {
  return [
    ...new Set(
      normalized.concepts.flatMap((concept) => concept.retrievalTerms).filter(isSignificantToken),
    ),
  ];
}

function isSignificantToken(token: string): boolean {
  return token.length >= MIN_ASSISTANT_TOKEN_LENGTH && !stopWords.has(token);
}

function getLiteralTermVariants(token: string): string[] {
  if (token.length > 4 && token.endsWith('s')) {
    return [token, token.slice(0, -1)];
  }
  return [token];
}
