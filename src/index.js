import { createApp } from './app.js';

const port = Number(process.env.PORT || 3000);
const server = createApp();
server.listen(port, '0.0.0.0', () => {
  console.log(`CargoFlow API listening on port ${port}`);
});

for (const signal of ['SIGINT', 'SIGTERM']) {
  process.on(signal, () => server.close(() => process.exit(0)));
}
