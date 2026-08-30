import { describe, expect, it, vi } from 'vitest';
import { createAssistantClient, MAX_ASSISTANT_MESSAGE_LENGTH } from './assistantClient';
import type { AssistantEngine, AssistantMessage } from './types';

describe('assistant client', () => {
  it('normalizes the input and sends only a bounded conversation context', async () => {
    const respond = vi.fn(async () => ({
      kind: 'no-results' as const,
      text: 'Aucun résultat.',
    }));
    const engine: AssistantEngine = { respond };
    const history: AssistantMessage[] = Array.from({ length: 10 }, (_, index) => ({
      id: String(index),
      role: index % 2 === 0 ? 'user' : 'assistant',
      text: `Message ${index}`,
      createdAt: '2026-08-29T10:00:00.000Z',
    }));

    await createAssistantClient(engine).sendMessage('  perceuse  ', history);

    expect(respond).toHaveBeenCalledWith({
      text: 'perceuse',
      history: history.slice(-8).map(({ role, text }) => ({ role, text })),
      signal: undefined,
    });
  });

  it('rejects empty and overlong messages before calling the engine', () => {
    const engine: AssistantEngine = { respond: vi.fn() };
    const client = createAssistantClient(engine);

    expect(() => client.sendMessage('   ', [])).toThrow('vide');
    expect(() =>
      client.sendMessage('x'.repeat(MAX_ASSISTANT_MESSAGE_LENGTH + 1), []),
    ).toThrow(`${MAX_ASSISTANT_MESSAGE_LENGTH}`);
    expect(engine.respond).not.toHaveBeenCalled();
  });
});
