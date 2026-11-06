import { createServer } from 'node:http';

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

export function createApp({ version = process.env.APP_VERSION || 'dev' } = {}) {
  return createServer((req, res) => {
    try {
      const url = new URL(req.url, 'http://localhost');

      if (req.method !== 'GET') {
        return send(res, 405, { error: 'method_not_allowed' });
      }

      if (url.pathname === '/healthz') {
        return send(res, 200, { status: 'alive' });
      }

      if (url.pathname === '/readyz') {
        return send(res, 200, { status: 'ready' });
      }

      if (url.pathname === '/api/version') {
        return send(res, 200, { service: 'cargoflow-api', version });
      }

      if (url.pathname === '/api/quote') {
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
}
