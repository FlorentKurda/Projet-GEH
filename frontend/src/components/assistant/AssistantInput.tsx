import { useId, useState, type FormEvent, type RefObject } from 'react';
import { MAX_ASSISTANT_MESSAGE_LENGTH } from '../../assistant/assistantClient';

interface AssistantInputProps {
  inputRef: RefObject<HTMLInputElement | null>;
  disabled: boolean;
  onSubmit: (text: string) => void;
}

export function AssistantInput({ inputRef, disabled, onSubmit }: AssistantInputProps) {
  const inputId = useId();
  const hintId = useId();
  const [value, setValue] = useState('');

  const handleSubmit = (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    const text = value.trim();
    if (!text || disabled) return;
    onSubmit(text);
    setValue('');
  };

  return (
    <form className="geh-assistant-input" onSubmit={handleSubmit}>
      <label className="geh-assistant-sr-only" htmlFor={inputId}>
        Votre recherche produit
      </label>
      <div className="geh-assistant-input__row">
        <input
          ref={inputRef}
          id={inputId}
          type="text"
          value={value}
          maxLength={MAX_ASSISTANT_MESSAGE_LENGTH}
          placeholder="Ex. Je cherche une perceuse"
          autoComplete="off"
          aria-describedby={hintId}
          disabled={disabled}
          onChange={(event) => setValue(event.target.value)}
        />
        <button type="submit" disabled={disabled || value.trim().length === 0}>
          Envoyer
        </button>
      </div>
      <div className="geh-assistant-input__meta" id={hintId}>
        <span>Recherche dans le catalogue actuel</span>
        <span aria-label={`${value.length} caractères sur ${MAX_ASSISTANT_MESSAGE_LENGTH}`}>
          {value.length}/{MAX_ASSISTANT_MESSAGE_LENGTH}
        </span>
      </div>
    </form>
  );
}
