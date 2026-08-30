import { forwardRef } from 'react';

interface AssistantLauncherProps {
  panelId: string;
  onOpen: () => void;
}

export const AssistantLauncher = forwardRef<HTMLButtonElement, AssistantLauncherProps>(
  function AssistantLauncher({ panelId, onOpen }, ref) {
    return (
      <button
        ref={ref}
        className="geh-assistant-launcher"
        type="button"
        aria-controls={panelId}
        aria-expanded="false"
        onClick={onOpen}
      >
        <span className="geh-assistant-launcher__icon" aria-hidden="true">?</span>
        <span>Assistant produits</span>
      </button>
    );
  },
);
