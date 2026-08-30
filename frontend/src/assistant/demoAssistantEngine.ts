import { selectRelevantAssistantProducts } from './assistantProductScorer';
import { assistantConceptClarificationTexts } from './assistantSynonyms';
import {
  buildAssistantRetrievalQueries,
  normalizeAssistantText,
  type NormalizedAssistantText,
} from './assistantTextNormalizer';
import type {
  AssistantCatalogSearch,
  AssistantEngine,
  AssistantHistoryItem,
} from './types';

const GENERAL_CLARIFICATION_TEXT = 'Pour quel usage ou quelle famille de produit ?';
const NO_RELEVANT_RESULT_TEXT =
  'Je n’ai pas trouvé de produit suffisamment proche de ce besoin dans le catalogue actuel. Pouvez-vous préciser l’usage recherché ?';
const RESULT_TEXT =
  'Pour ce besoin, voici les produits qui semblent les plus proches des informations disponibles dans le catalogue.';
const contextualClarificationTexts = new Set([
  GENERAL_CLARIFICATION_TEXT,
  ...assistantConceptClarificationTexts,
]);

export function createDemoAssistantEngine(
  searchCatalog: AssistantCatalogSearch,
): AssistantEngine {
  return {
    async respond({ text, history, signal }) {
      const contextualText = addClarificationContext(text, history);
      const normalized = normalizeAssistantText(contextualText);
      const clarification = getClarification(normalized);
      if (clarification) {
        return {
          kind: 'clarification',
          text: clarification,
        };
      }

      const retrievalQueries = buildAssistantRetrievalQueries(normalized);
      if (retrievalQueries.length === 0) {
        return {
          kind: 'clarification',
          text: GENERAL_CLARIFICATION_TEXT,
        };
      }

      const candidates = await searchCatalog(retrievalQueries, signal);
      const products = selectRelevantAssistantProducts(candidates, normalized);
      if (products.length === 0) {
        return {
          kind: 'no-results',
          text: NO_RELEVANT_RESULT_TEXT,
        };
      }

      return {
        kind: 'results',
        text: RESULT_TEXT,
        products,
      };
    },
  };
}

function getClarification(normalized: NormalizedAssistantText): string | null {
  if (normalized.concepts.length === 0) return GENERAL_CLARIFICATION_TEXT;
  if (normalized.concepts.length === 1) {
    return normalized.concepts[0]?.clarificationWhenAlone ?? null;
  }
  return null;
}

function addClarificationContext(
  currentText: string,
  history: readonly AssistantHistoryItem[],
): string {
  let historyEnd = history.length;
  const lastMessage = history[historyEnd - 1];
  if (lastMessage?.role === 'user' && lastMessage.text.trim() === currentText.trim()) {
    historyEnd -= 1;
  }

  let lastAssistantIndex = -1;
  for (let index = historyEnd - 1; index >= 0; index -= 1) {
    if (history[index]?.role === 'assistant') {
      lastAssistantIndex = index;
      break;
    }
  }
  if (lastAssistantIndex < 0) return currentText;

  const assistantText = history[lastAssistantIndex]?.text;
  if (!assistantText || !contextualClarificationTexts.has(assistantText)) return currentText;

  for (let index = lastAssistantIndex - 1; index >= 0; index -= 1) {
    const message = history[index];
    if (message?.role === 'user') return `${message.text} ${currentText}`;
  }
  return currentText;
}
