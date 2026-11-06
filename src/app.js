import { createServer } from 'node:http';
import { setTimeout as delay } from 'node:timers/promises';

function send(res, status, data) {
  res.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'cache-control': 'no-store',
  });
  res.end(JSON.stringify(data));
}

function calculateQuote(distanceKm, weightKg) {
  const cents = Math.round(500 + distanceKm * 40 + weightKg * 20);
  return cents / 100;
}

export function createApp({
  version = process.env.APP_VERSION || '1.2.0',
  startupDelayMs = 0,
  longQuoteDelayMs = 0,
} = {}) {
  for (const duration of [startupDelayMs, longQuoteDelayMs]) {
    if (!Number.isInteger(duration) || duration < 0 || duration > 2_147_483_647) {
      throw new RangeError('Invalid duration');
    }
  }

  let catalogReady = startupDelayMs === 0;
  const initialization = startupDelayMs > 0
    ? setTimeout(() => {
      catalogReady = true;
      console.log('catalog_ready');
    }, startupDelayMs).unref()
    : undefined;

  const server = createServer(async (req, res) => {
    try {
      const url = new URL(req.url, 'http://localhost');

      if (req.method !== 'GET') {
        return send(res, 405, { error: 'method_not_allowed' });
      }

      if (url.pathname === '/healthz') {
        return send(res, 200, { status: 'alive' });
      }

      if (url.pathname === '/readyz') {
        if (!catalogReady) {
          return send(res, 503, { status: 'starting' });
        }
        return send(res, 200, { status: 'ready' });
      }

      if (url.pathname === '/api/version') {
        return send(res, 200, { service: 'cargoflow-api', version });
      }

      if (url.pathname === '/api/quote') {
        if (!catalogReady) {
          return send(res, 503, { error: 'catalog_loading' });
        }

        const distanceKm = Number(url.searchParams.get('distanceKm'));
        const weightKg = Number(url.searchParams.get('weightKg'));
        if (
          !url.searchParams.has('distanceKm') ||
          !url.searchParams.has('weightKg') ||
          !Number.isFinite(distanceKm) ||
          !Number.isFinite(weightKg) ||
          distanceKm <= 0 ||
          weightKg <= 0 ||
          distanceKm > 2000 ||
          weightKg > 1000
        ) {
          return send(res, 400, { error: 'invalid_parameters' });
        }

        if (distanceKm > 100 && longQuoteDelayMs > 0) {
          console.log('quote_started', JSON.stringify({ distanceKm, weightKg, version }));
          await delay(longQuoteDelayMs);
        }

        return send(res, 200, {
          distanceKm,
          weightKg,
          amountEUR: calculateQuote(distanceKm, weightKg),
          currency: 'EUR',
          version,
        });
      }

      return send(res, 404, { error: 'not_found' });
    } catch (error) {
      console.error('request_failed', error);
      return send(res, 500, { error: 'internal_server_error' });
    }
  });

  server.once('close', () => clearTimeout(initialization));
  return server;
}
