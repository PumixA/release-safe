import test from 'node:test';
import assert from 'node:assert/strict';
import { once } from 'node:events';
import { setTimeout as delay } from 'node:timers/promises';
import { createApp } from '../src/app.js';

async function start(t, options) {
  const server = createApp({ version: 'test', ...options });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise((resolve, reject) => {
    if (!server.listening) return resolve();
    server.close((error) => error ? reject(error) : resolve());
  }));
  return { server, url: `http://127.0.0.1:${server.address().port}` };
}

test('le processus répond pendant l’initialisation du catalogue', async (t) => {
  const { url } = await start(t, { startupDelayMs: 60_000 });

  assert.equal((await fetch(`${url}/healthz`)).status, 200);
  const version = await fetch(`${url}/api/version`);
  assert.equal(version.status, 200);
  assert.equal((await version.json()).version, 'test');

  const readiness = await fetch(`${url}/readyz`);
  assert.equal(readiness.status, 503);
  assert.deepEqual(await readiness.json(), { status: 'starting' });

  const quote = await fetch(`${url}/api/quote?distanceKm=20&weightKg=3`);
  assert.equal(quote.status, 503);
  assert.deepEqual(await quote.json(), { error: 'catalog_loading' });
});

test('les devis sont disponibles une fois le catalogue prêt', async (t) => {
  const { url } = await start(t, { startupDelayMs: 50 });
  const deadline = Date.now() + 5_000;
  let response;
  do {
    response = await fetch(`${url}/readyz`);
    await response.arrayBuffer();
    if (response.status === 200) break;
    assert.equal(response.status, 503);
    await delay(10);
  } while (Date.now() < deadline);

  assert.equal(response.status, 200);
  const quote = await fetch(`${url}/api/quote?distanceKm=120&weightKg=3`);
  assert.equal(quote.status, 200);
  assert.equal((await quote.json()).amountEUR, 53.6);
});

test('le calcul long conserve le tarif et le format du devis', async (t) => {
  const { url } = await start(t, { longQuoteDelayMs: 100 });
  const started = performance.now();
  const response = await fetch(`${url}/api/quote?distanceKm=120&weightKg=3`);
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), {
    distanceKm: 120,
    weightKg: 3,
    amountEUR: 53.6,
    currency: 'EUR',
    version: 'test',
  });
  assert.ok(performance.now() - started >= 90);
});

test('un devis engagé se termine pendant l’arrêt du serveur', async (t) => {
  const { server, url } = await start(t, { longQuoteDelayMs: 100 });
  const received = once(server, 'request');
  const pending = fetch(`${url}/api/quote?distanceKm=120&weightKg=3`);
  await received;
  const closed = new Promise((resolve, reject) => {
    server.close((error) => error ? reject(error) : resolve());
  });

  const response = await pending;
  assert.equal(response.status, 200);
  assert.equal((await response.json()).amountEUR, 53.6);
  await closed;
});
