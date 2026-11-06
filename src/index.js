import { createApp } from './app.js';

const port = Number(process.env.PORT || 3000);
const server = createApp({ startupDelayMs: 20_000, longQuoteDelayMs: 12_000 });
server.listen(port, '0.0.0.0', () => {
  console.log(`CargoFlow API listening on port ${port}`);
});

let stopping = false;

function shutdown(signal) {
  if (stopping) return;
  stopping = true;
  console.log(`shutdown_started ${signal}`);

  const deadline = setTimeout(() => {
    console.error('shutdown_timeout');
    server.closeAllConnections();
    process.exit(1);
  }, 30_000).unref();

  server.close((error) => {
    clearTimeout(deadline);
    if (error) {
      console.error('shutdown_failed', error);
      process.exit(1);
    }
    console.log('shutdown_complete');
    process.exit(0);
  });
}

for (const signal of ['SIGINT', 'SIGTERM']) {
  process.on(signal, () => shutdown(signal));
}
