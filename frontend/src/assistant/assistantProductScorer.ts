import type { Product } from '../types/catalog';
import {
  normalizeForAssistantMatching,
  tokenizeNormalizedText,
  type AssistantConcept,
  type NormalizedAssistantText,
} from './assistantTextNormalizer';

export const MIN_ASSISTANT_RELEVANCE_SCORE = 10;
const HIGH_CONFIDENCE_SCORE = 24;
const DEFAULT_PRODUCT_COUNT = 3;
const MAX_PRODUCT_COUNT = 5;

interface SearchableField {
  text: string;
  tokens: Set<string>;
}

export interface ScoredAssistantProduct {
  product: Product;
  score: number;
  matchedConceptIds: string[];
}

export function selectRelevantAssistantProducts(
  products: readonly Product[],
  query: NormalizedAssistantText,
): Product[] {
  const requiredConceptIds = new Set(
    query.concepts.length > 1
      ? query.concepts
          .filter((concept) => concept.requiredWhenCombined)
          .map((concept) => concept.id)
      : [],
  );

  const ranked = products
    .map((product) => scoreAssistantProduct(product, query))
    .filter(
      (result) =>
        result.score >= MIN_ASSISTANT_RELEVANCE_SCORE &&
        [...requiredConceptIds].every((conceptId) =>
          result.matchedConceptIds.includes(conceptId),
        ),
    )
    .sort(compareScoredProducts);

  const selected = ranked.slice(0, DEFAULT_PRODUCT_COUNT);
  const bestScore = ranked[0]?.score ?? 0;
  ranked.slice(DEFAULT_PRODUCT_COUNT, MAX_PRODUCT_COUNT).forEach((candidate) => {
    if (
      candidate.score >= HIGH_CONFIDENCE_SCORE &&
      candidate.score >= bestScore * 0.65
    ) {
      selected.push(candidate);
    }
  });

  return selected.map(({ product }) => product);
}

export function scoreAssistantProduct(
  product: Product,
  query: NormalizedAssistantText,
): ScoredAssistantProduct {
  const fields = {
    name: createSearchableField(product.name),
    reference: createSearchableField(product.reference),
    description: createSearchableField(product.shortDescription),
    familyLabel: createSearchableField(product.familyLabel),
    familyCode: createSearchableField(product.familyCode),
    brand: createSearchableField(product.brand),
  };
  const matchedConceptIds: string[] = [];
  let score = 0;

  query.concepts.forEach((concept) => {
    let conceptScore = 0;
    if (matchesConcept(fields.name, concept)) conceptScore += 15;
    if (matchesConcept(fields.reference, concept)) conceptScore += 14;
    if (matchesConcept(fields.familyLabel, concept)) conceptScore += 12;
    if (matchesConcept(fields.description, concept)) conceptScore += 7;
    if (matchesConcept(fields.familyCode, concept)) conceptScore += 5;
    if (matchesConcept(fields.brand, concept)) {
      conceptScore += query.brandRequested ? 12 : 3;
    }
    if (matchesSourceToken(fields.name, concept)) conceptScore += 3;

    if (conceptScore > 0) {
      matchedConceptIds.push(concept.id);
      score += conceptScore * concept.importance;
    }
  });

  if (matchedConceptIds.length > 1) {
    score += (matchedConceptIds.length - 1) * 8;
    if (matchedConceptIds.length === query.concepts.length) score += 4;
  }

  return {
    product,
    score: Math.round(score * 100) / 100,
    matchedConceptIds,
  };
}

function createSearchableField(value: string | null): SearchableField {
  const text = normalizeForAssistantMatching(value ?? '');
  return { text, tokens: new Set(tokenizeNormalizedText(text)) };
}

function matchesConcept(field: SearchableField, concept: AssistantConcept): boolean {
  return concept.matchTerms.some((term) => matchesTerm(field, term));
}

function matchesSourceToken(field: SearchableField, concept: AssistantConcept): boolean {
  return concept.sourceTokens.some((term) => matchesTerm(field, term));
}

function matchesTerm(field: SearchableField, term: string): boolean {
  const normalizedTerm = normalizeForAssistantMatching(term);
  if (!normalizedTerm) return false;
  return normalizedTerm.includes(' ')
    ? field.text.includes(normalizedTerm)
    : field.tokens.has(normalizedTerm);
}

function compareScoredProducts(
  left: ScoredAssistantProduct,
  right: ScoredAssistantProduct,
): number {
  return (
    right.score - left.score ||
    right.matchedConceptIds.length - left.matchedConceptIds.length ||
    left.product.name.localeCompare(right.product.name, 'fr') ||
    left.product.id - right.product.id
  );
}
