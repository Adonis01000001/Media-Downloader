import http from 'node:http';
import { createInstagramOAuth } from './instagram_oauth.mjs';
import { OAuthError } from './oauth_error.mjs';
import { createXOAuth } from './x_oauth.mjs';

const oauth = createInstagramOAuth({
  clientId: process.env.INSTAGRAM_APP_ID,
  clientSecret: process.env.INSTAGRAM_APP_SECRET,
  redirectUri: process.env.INSTAGRAM_REDIRECT_URI,
  apiVersion: process.env.INSTAGRAM_API_VERSION ?? 'v26.0',
});
const limits = new Map();
const xOauth = createXOAuth({
  clientId: process.env.X_CLIENT_ID,
  clientSecret: process.env.X_CLIENT_SECRET,
  redirectUri: process.env.X_REDIRECT_URI,
});

const server = http.createServer(async (request, response) => {
  response.setHeader('Cache-Control', 'no-store');
  response.setHeader('Pragma', 'no-cache');
  response.setHeader('X-Content-Type-Options', 'nosniff');
  response.setHeader('Referrer-Policy', 'no-referrer');
  response.setHeader('Content-Security-Policy', "default-src 'none'; frame-ancestors 'none'");

  try {
    const url = new URL(request.url ?? '/', 'http://localhost');
    if (request.method === 'GET' && url.pathname === '/healthz') {
      return sendJson(response, 200, { status: 'ok' });
    }
    if (request.method === 'POST' && url.pathname === '/v1/instagram/oauth/start') {
      checkRate(request, 'start', 12, 60_000);
      const body = await readJson(request);
      return sendJson(response, 201, oauth.start(body.handoffSecret));
    }
    if (request.method === 'GET' && url.pathname === '/v1/instagram/oauth/callback') {
      checkRate(request, 'callback', 30, 60_000);
      const callbackUrl = await oauth.callback(url.searchParams);
      response.writeHead(303, { Location: callbackUrl });
      return response.end();
    }
    if (request.method === 'POST' && url.pathname === '/v1/instagram/oauth/poll') {
      checkRate(request, 'poll', 120, 60_000);
      const body = await readJson(request);
      const result = oauth.poll(body.attemptId, body.handoffSecret);
      return sendJson(response, result.status === 'pending' ? 202 : result.status === 'ready' ? 200 : 409, result);
    }
    if (request.method === 'POST' && url.pathname === '/v1/instagram/oauth/refresh') {
      checkRate(request, 'refresh', 20, 60_000);
      const body = await readJson(request);
      return sendJson(response, 200, await oauth.refresh(body.accessToken));
    }
    if (request.method === 'POST' && url.pathname === '/v1/x/oauth/start') {
      checkRate(request, 'x-start', 12, 60_000);
      const body = await readJson(request);
      return sendJson(response, 201, xOauth.start(body.handoffSecret));
    }
    if (request.method === 'GET' && url.pathname === '/v1/x/oauth/callback') {
      checkRate(request, 'x-callback', 30, 60_000);
      const callbackUrl = await xOauth.callback(url.searchParams);
      response.writeHead(303, { Location: callbackUrl });
      return response.end();
    }
    if (request.method === 'POST' && url.pathname === '/v1/x/oauth/poll') {
      checkRate(request, 'x-poll', 120, 60_000);
      const body = await readJson(request);
      const result = xOauth.poll(body.attemptId, body.handoffSecret);
      return sendJson(response, result.status === 'pending' ? 202 : result.status === 'ready' ? 200 : 409, result);
    }
    if (request.method === 'POST' && url.pathname === '/v1/x/oauth/refresh') {
      checkRate(request, 'x-refresh', 20, 60_000);
      const body = await readJson(request);
      return sendJson(response, 200, await xOauth.refresh(body.refreshToken));
    }
    if (request.method === 'POST' && url.pathname === '/v1/x/oauth/revoke') {
      checkRate(request, 'x-revoke', 20, 60_000);
      const body = await readJson(request);
      return sendJson(response, 200, await xOauth.revoke(body.token));
    }
    return sendJson(response, 404, { code: 'not_found', message: 'Endpoint not found.' });
  } catch (error) {
    const status = error instanceof OAuthError ? error.status : error?.statusCode ?? 500;
    const code = error instanceof OAuthError ? error.code : 'request_failed';
    const message = error instanceof OAuthError
      ? error.message
      : status === 413
        ? 'Request body is too large.'
        : status === 429
          ? 'Too many requests. Try again shortly.'
          : 'The platform authorization request could not be completed.';
    return sendJson(response, status, { code, message });
  }
});

function checkRate(request, route, maximum, windowMs) {
  const now = Date.now();
  for (const [key, entry] of limits) {
    if (now - entry.start >= windowMs * 2) limits.delete(key);
  }
  const ip = request.socket.remoteAddress ?? 'unknown';
  const key = `${route}:${ip}`;
  const old = limits.get(key);
  if (!old || now - old.start >= windowMs) {
    limits.set(key, { start: now, count: 1 });
    return;
  }
  old.count += 1;
  if (old.count > maximum) throw new OAuthError('rate_limited', 'Too many requests. Try again shortly.', 429);
}

async function readJson(request) {
  let text = '';
  for await (const chunk of request) {
    text += chunk;
    if (text.length > 16_384) {
      const error = new Error('Request body is too large');
      error.statusCode = 413;
      throw error;
    }
  }
  if (!text) return {};
  try {
    const body = JSON.parse(text);
    if (body === null || Array.isArray(body) || typeof body !== 'object') throw new Error('Expected object');
    return body;
  } catch {
    const error = new Error('Invalid JSON');
    error.statusCode = 400;
    throw error;
  }
}

function sendJson(response, status, value) {
  if (response.writableEnded) return;
  response.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8' });
  response.end(JSON.stringify(value));
}

const port = Number.parseInt(process.env.PORT ?? '8787', 10);
const host = process.env.HOST ?? '127.0.0.1';
if (!Number.isInteger(port) || port < 1 || port > 65535) {
  throw new Error('PORT must be an integer between 1 and 65535');
}
server.listen(port, host, () => {
  process.stdout.write(`Instagram OAuth service listening on ${host}:${port}\n`);
});

function close() {
  server.close(() => process.exit(0));
}
process.on('SIGINT', close);
process.on('SIGTERM', close);
