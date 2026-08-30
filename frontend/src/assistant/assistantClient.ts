import type { AssistantClient, AssistantEngine } from './types';

export const MAX_ASSISTANT_MESSAGE_LENGTH = 300;
const MAX_CONTEXT_MESSAGES = 8;

export class AssistantInputError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'AssistantInputError';
  }
}

export function createAssistantClient(engine: AssistantEngine): AssistantClient {
  return {
    sendMessage(text, history, signal) {
      const normalizedText = text.trim();
      if (!normalizedText) {
        throw new AssistantInputError('Le message ne peut pas être vide.');
      }
      if (normalizedText.length > MAX_ASSISTANT_MESSAGE_LENGTH) {
        throw new AssistantInputError(
          `Le message ne peut pas dépasser ${MAX_ASSISTANT_MESSAGE_LENGTH} caractères.`,
        );
      }

      return engine.respond({
        text: normalizedText,
        history: history.slice(-MAX_CONTEXT_MESSAGES).map(({ role, text: messageText }) => ({
          role,
          text: messageText,
        })),
        signal,
      });
    },
  };
}
