import test, { after, before } from 'node:test';
import assert from 'node:assert/strict';
import { createApp } from '../src/app.js';

let server;
let baseUrl;

before(async () => {
  server = createApp({ version: 'test' });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  baseUrl = `http://127.0.0.1:${server.address().port}`;
});

after(async () => {
  await new Promise((resolve, reject) => server.close((err) => err ? reject(err) : resolve()));
});

test('le processus est vivant', async () => {
  const response = await fetch(`${baseUrl}/healthz`);
  assert.equal(response.status, 200);
});

test('la version est exposée', async () => {
  const response = await fetch(`${baseUrl}/api/version`);
  assert.equal(response.status, 200);
  assert.equal((await response.json()).version, 'test');
});

test('devis standard correct', async () => {
  const response = await fetch(`${baseUrl}/api/quote?distanceKm=20&weightKg=3`);
  const body = await response.json();
  assert.equal(response.status, 200);
  assert.equal(body.amountEUR, 13.6);
});

test('paramètres invalides rejetés', async () => {
  const response = await fetch(`${baseUrl}/api/quote?distanceKm=-1&weightKg=2`);
  assert.equal(response.status, 400);
});
