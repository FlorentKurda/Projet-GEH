import { createRoot } from 'react-dom/client';
import { App } from './App';
import './styles.css';

const config = window.GEH_CATALOG_CONFIG;
const roots = document.querySelectorAll<HTMLElement>('.geh-catalog-root');

roots.forEach((element) => {
  if (!config) {
    element.textContent = 'Le catalogue est temporairement indisponible.';
    return;
  }
  createRoot(element).render(<App config={config} />);
});
