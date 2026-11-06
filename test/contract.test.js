// Tests de contrat de l'équipe.
// Ils figent le barème et le comportement HTTP attendus par les clients,
// indépendamment des tests fournis avec chaque version.
// Barème : 5 € fixes + 0,40 €/km + 0,20 €/kg.
import test, { after, before } from 'node:test';
import assert from 'node:assert/strict';
import { createApp } from '../src/app.js';

let server;
let baseUrl;

before(async () => {
  server = createApp({ version: 'contract' });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  baseUrl = `http://127.0.0.1:${server.address().port}`;
});

after(async () => {
  await new Promise((resolve, reject) => server.close((err) => (err ? reject(err) : resolve())));
});

async function quote(distanceKm, weightKg) {
  const response = await fetch(`${baseUrl}/api/quote?distanceKm=${distanceKm}&weightKg=${weightKg}`);
  return { status: response.status, body: await response.json() };
}

const expectedQuotes = [
  // distanceKm, weightKg, amountEUR
  [20, 3, 13.6],
  [100, 3, 45.6],
  [101, 3, 46.0],
  [120, 3, 53.6],
  [500, 10, 207.0],
  [2000, 1000, 1005.0],
  [0.5, 0.1, 5.22],
];

for (const [distanceKm, weightKg, amountEUR] of expectedQuotes) {
  test(`barème : ${distanceKm} km / ${weightKg} kg = ${amountEUR} €`, async () => {
    const { status, body } = await quote(distanceKm, weightKg);
    assert.equal(status, 200);
    assert.equal(body.amountEUR, amountEUR);
  });
}

test('le format de réponse du devis est stable', async () => {
  const { status, body } = await quote(120, 3);
  assert.equal(status, 200);
  assert.deepEqual(Object.keys(body).sort(), ['amountEUR', 'currency', 'distanceKm', 'version', 'weightKg']);
  assert.equal(body.currency, 'EUR');
  assert.equal(body.version, 'contract');
});

for (const query of [
  'distanceKm=0&weightKg=3',
  'distanceKm=20&weightKg=0',
  'distanceKm=2001&weightKg=3',
  'distanceKm=20&weightKg=1001',
  'distanceKm=abc&weightKg=3',
  'weightKg=3',
  'distanceKm=20',
]) {
  test(`paramètres invalides rejetés : ${query}`, async () => {
    const response = await fetch(`${baseUrl}/api/quote?${query}`);
    assert.equal(response.status, 400);
    assert.deepEqual(await response.json(), { error: 'invalid_parameters' });
  });
}

test('route inconnue : 404', async () => {
  const response = await fetch(`${baseUrl}/inconnue`);
  assert.equal(response.status, 404);
});

test('méthode non autorisée : 405', async () => {
  const response = await fetch(`${baseUrl}/api/quote?distanceKm=20&weightKg=3`, { method: 'POST' });
  assert.equal(response.status, 405);
});

test('les réponses ne sont pas mises en cache', async () => {
  const response = await fetch(`${baseUrl}/api/version`);
  assert.equal(response.headers.get('cache-control'), 'no-store');
});
