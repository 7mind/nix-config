import { createRoot } from 'react-dom/client';
import { App } from './App';
import { bindLifecycle, browserRuntime } from './connection';
import { DashboardClient } from './store';
import './style.css';

const root = document.getElementById('root');
if (root === null) throw new Error('Dashboard root is missing');
const url = new URL('/ws', window.location.href);
url.protocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
const client = new DashboardClient(browserRuntime(url.toString(), window, document));
const unbindLifecycle = bindLifecycle(client.connection, window, document, navigator);
createRoot(root).render(<App client={client} />);
client.start();
if (import.meta.hot) import.meta.hot.dispose(() => { unbindLifecycle(); client.destroy(); });
