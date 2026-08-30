export interface AssistantConceptDefinition {
  id: string;
  aliases: readonly string[];
  matchTerms: readonly string[];
  retrievalTerms: readonly string[];
  importance: number;
  requiredWhenCombined?: boolean;
  clarificationWhenAlone?: string;
}

const conceptDefinitions: readonly AssistantConceptDefinition[] = [
  {
    id: 'cleaning',
    aliases: ['entretien', 'lavage', 'lavant', 'laver', 'menage', 'nettoyage', 'nettoyer'],
    matchTerms: ['entretien', 'lavage', 'lavant', 'laver', 'nettoyage', 'nettoyer'],
    retrievalTerms: ['entretien', 'nettoyage'],
    importance: 1.2,
    clarificationWhenAlone:
      'Pour quel usage ou quelle surface cherchez-vous un produit d’entretien ?',
  },
  {
    id: 'floor-surface',
    aliases: ['carrelage', 'sol', 'sols'],
    matchTerms: ['carrelage', 'sol', 'sols'],
    retrievalTerms: ['sol', 'carrelage'],
    importance: 1.15,
    requiredWhenCombined: true,
    clarificationWhenAlone: 'Que souhaitez-vous faire sur cette surface ?',
  },
  {
    id: 'degreasing',
    aliases: ['degraissage', 'degraissant', 'degraisser', 'graisse', 'gras'],
    matchTerms: ['degraissage', 'degraissant', 'degraisser', 'graisse', 'gras'],
    retrievalTerms: ['degraissant', 'graisse', 'entretien'],
    importance: 1.2,
  },
  {
    id: 'disinfection',
    aliases: ['desinfectant', 'desinfecter', 'desinfection'],
    matchTerms: ['desinfectant', 'desinfecter', 'desinfection'],
    retrievalTerms: ['desinfectant', 'desinfection', 'entretien'],
    importance: 1.2,
  },
  {
    id: 'storage',
    aliases: ['rangement', 'ranger', 'stockage'],
    matchTerms: ['rangement', 'ranger', 'stockage'],
    retrievalTerms: ['rangement', 'stockage'],
    importance: 1.2,
  },
  {
    id: 'tools',
    aliases: ['outil', 'outillage', 'outils'],
    matchTerms: ['outil', 'outillage', 'outils'],
    retrievalTerms: ['outil', 'outillage'],
    importance: 0.75,
  },
  {
    id: 'hands',
    aliases: ['gant', 'gants', 'main', 'mains'],
    matchTerms: ['gant', 'gants', 'main', 'mains'],
    retrievalTerms: ['gants', 'protection'],
    importance: 1.2,
    requiredWhenCombined: true,
  },
  {
    id: 'protection',
    aliases: ['protection', 'proteger'],
    matchTerms: ['casque', 'gant', 'gants', 'lunettes', 'protection', 'proteger'],
    retrievalTerms: ['protection', 'gants'],
    importance: 1,
    clarificationWhenAlone: 'Quelle partie ou quel usage souhaitez-vous protéger ?',
  },
  {
    id: 'measurement',
    aliases: [
      'distance',
      'mesure',
      'mesurer',
      'mesures',
      'metre',
      'metres',
      'telemetre',
      'telemetres',
    ],
    matchTerms: [
      'distance',
      'mesure',
      'mesurer',
      'mesures',
      'metre',
      'metres',
      'telemetre',
      'telemetres',
    ],
    retrievalTerms: ['mesure', 'metre', 'telemetre'],
    importance: 1.2,
  },
];

const conceptsByAlias = new Map<string, AssistantConceptDefinition>();
conceptDefinitions.forEach((definition) => {
  definition.aliases.forEach((alias) => conceptsByAlias.set(alias, definition));
});

export const assistantConceptClarificationTexts = conceptDefinitions
  .map(({ clarificationWhenAlone }) => clarificationWhenAlone)
  .filter((text): text is string => typeof text === 'string');

export function findAssistantConceptDefinition(
  token: string,
): AssistantConceptDefinition | undefined {
  return conceptsByAlias.get(token);
}
