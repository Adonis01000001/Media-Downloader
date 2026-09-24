import { createHash, randomBytes, timingSafeEqual } from 'node:crypto';
import { OAuthError } from './oauth_error.mjs';

const ATTEMPT_ID = /^[A-Za-z0-9_-]{40,64}$/;
const HANDOFF_SECRET = /^[A-Za-z0-9_-]{43}$/;
const OAUTH_TTL_MS = 10 * 60 * 1000;
const REQUIRED_SCOPES = ['tweet.read', 'users.read', 'offline.access'];
const TOKEN_ENDPOINT = 'https://api.x.com/2/oauth2/token';

export function createXOAuth({
  clientId,
  clientSecret,
  redirectUri,
  fetchImpl = globalThis.fetch,
  now = () => Date.now(),
}) {
  const attempts = new Map();
  const callbackUri = safeRedirectUri(redirectUri);

  function configured() {
    return Boolean(clientId && clientSecret && callbackUri && fetchImpl);
  }

  function prune() {
    const current = now();
    for (const [id, attempt] of attempts) {
      if (attempt.expiresAt <= current) attempts.delete(id);
    }
  }

  function start(handoffSecret) {
    prune();
    if (!configured()) {
      throw new OAuthError('server_configuration', 'X OAuth is not configured on this server.', 503);
    }
    if (attempts.size >= 1000) {
      throw new OAuthError('server_busy', 'Too many sign-in attempts. Try again shortly.', 503);
    }
    if (typeof handoffSecret !== 'string' || !HANDOFF_SECRET.test(handoffSecret)) {
      throw new OAuthError('invalid_handoff', 'The X sign-in handoff is invalid.');
    }
    const attemptId = randomBytes(32).toString('base64url');
    const state = randomBytes(32).toString('base64url');
    const verifier = randomBytes(32).toString('base64url');
    const challenge = createHash('sha256').update(verifier).digest('base64url');
    const url = new URL('https://x.com/i/oauth2/authorize');
    url.searchParams.set('response_type', 'code');
    url.searchParams.set('client_id', clientId);
    url.searchParams.set('redirect_uri', callbackUri);
    url.searchParams.set('scope', REQUIRED_SCOPES.join(' '));
    url.searchParams.set('state', state);
    url.searchParams.set('code_challenge', challenge);
    url.searchParams.set('code_challenge_method', 'S256');
    attempts.set(attemptId, {
      state,
      verifier,
      handoffHash: hashSecret(handoffSecret),
      phase: 'pending',
      expiresAt: now() + OAUTH_TTL_MS,
      result: null,
    });
    return { attemptId, authorizationUrl: url.toString() };
  }

  async function callback(params) {
    prune();
    const state = params.get('state');
    const entry = [...attempts.entries()].find(([, attempt]) => attempt.state === state);
    if (!state || !entry || entry[1].phase !== 'pending') {
      throw new OAuthError('invalid_state', 'X returned an invalid or expired OAuth state.');
    }
    const [attemptId, attempt] = entry;
    attempt.phase = 'processing';
    if (params.has('error')) {
      attempt.phase = 'error';
      attempt.result = {
        code: params.get('error') === 'access_denied' ? 'access_denied' : 'authorization_failed',
      };
      return appCallback();
    }
    const code = params.get('code') ?? '';
    if (!code || code.length > 4096) {
      attempt.phase = 'error';
      attempt.result = { code: 'authorization_failed' };
      return appCallback();
    }
    try {
      const token = await exchangeAuthorizationCode(code, attempt.verifier);
      const profile = await fetchCurrentUser(token.access_token);
      const expiresIn = positiveSeconds(token.expires_in);
      const userId = typeof profile.id === 'string' ? profile.id : '';
      const username = typeof profile.username === 'string' ? profile.username : '';
      const name = typeof profile.name === 'string' ? profile.name : username;
      if (!userId || !username || !expiresIn || typeof token.refresh_token !== 'string') {
        throw new OAuthError('authorization_failed', 'X returned incomplete account details.');
      }
      attempt.phase = 'ready';
      attempt.result = {
        accessToken: token.access_token,
        refreshToken: token.refresh_token,
        expiresAt: new Date(now() + expiresIn * 1000).toISOString(),
        userId,
        username,
        name,
      };
      return appCallback();
    } catch {
      attempt.phase = 'error';
      attempt.result = { code: 'authorization_failed' };
      return appCallback();
    }
  }

  async function exchangeAuthorizationCode(code, verifier) {
    const form = new URLSearchParams({
      grant_type: 'authorization_code',
      code,
      redirect_uri: callbackUri,
      code_verifier: verifier,
      client_id: clientId,
      client_secret: clientSecret,
    });
    const body = await tokenRequest(form, 'authorization_failed');
    if (typeof body.access_token !== 'string' ||
        body.access_token.length > 10000 ||
        typeof body.refresh_token !== 'string' ||
        body.refresh_token.length > 10000) {
      throw new OAuthError('authorization_failed', 'X did not return valid account tokens.');
    }
    const grantedScopes = typeof body.scope === 'string'
      ? new Set(body.scope.trim().split(/\s+/).filter(Boolean))
      : new Set();
    if (!REQUIRED_SCOPES.every((scope) => grantedScopes.has(scope))) {
      throw new OAuthError('authorization_failed', 'X did not grant Gather the required read-only permissions.');
    }
    return body;
  }

  async function fetchCurrentUser(accessToken) {
    const url = new URL('https://api.x.com/2/users/me');
    url.searchParams.set('user.fields', 'id,name,username,protected');
    const body = await responseJson(url, {
      headers: { Accept: 'application/json', Authorization: `Bearer ${accessToken}` },
    }, 'identity_lookup_failed');
    if (!body.data || typeof body.data !== 'object') {
      throw new OAuthError('identity_lookup_failed', 'X did not verify the authorized account.');
    }
    return body.data;
  }

  function poll(attemptId, handoffSecret) {
    prune();
    if (typeof attemptId !== 'string' || !ATTEMPT_ID.test(attemptId)) {
      throw new OAuthError('invalid_attempt', 'The X sign-in attempt is invalid.');
    }
    const attempt = attempts.get(attemptId);
    if (!attempt) throw new OAuthError('attempt_expired', 'X sign-in expired. Connect again.', 410);
    if (typeof handoffSecret !== 'string' || !HANDOFF_SECRET.test(handoffSecret) ||
        !safeEqual(attempt.handoffHash, hashSecret(handoffSecret))) {
      throw new OAuthError('invalid_handoff', 'The X sign-in handoff is invalid.', 403);
    }
    if (attempt.phase === 'pending' || attempt.phase === 'processing') return { status: 'pending' };
    const result = attempt.result;
    attempts.delete(attemptId);
    if (attempt.phase === 'error') return { status: 'error', code: result?.code ?? 'authorization_failed' };
    return { status: 'ready', session: result };
  }

  async function refresh(refreshToken) {
    if (!configured()) throw new OAuthError('server_configuration', 'X OAuth is not configured on this server.', 503);
    if (typeof refreshToken !== 'string' || refreshToken.length < 10 || refreshToken.length > 10000) {
      throw new OAuthError('invalid_token', 'The X session is invalid. Connect again.', 401);
    }
    const form = new URLSearchParams({
      grant_type: 'refresh_token',
      refresh_token: refreshToken,
      client_id: clientId,
      client_secret: clientSecret,
    });
    let body;
    try {
      body = await tokenRequest(form, 'reauthentication_required');
    } catch (error) {
      if (error.code === 'reauthentication_required') {
        throw new OAuthError('reauthentication_required', 'X authorization expired or was revoked.', 401);
      }
      throw error;
    }
    const expiresIn = positiveSeconds(body.expires_in);
    if (typeof body.access_token !== 'string' || !expiresIn) {
      throw new OAuthError('provider_error', 'X returned an invalid refresh response.', 502);
    }
    return {
      accessToken: body.access_token,
      ...(typeof body.refresh_token === 'string' ? { refreshToken: body.refresh_token } : {}),
      expiresIn,
    };
  }

  async function revoke(token) {
    if (!configured()) throw new OAuthError('server_configuration', 'X OAuth is not configured on this server.', 503);
    if (typeof token !== 'string' || token.length < 10 || token.length > 10000) {
      throw new OAuthError('invalid_token', 'The X session is invalid.', 400);
    }
    const form = new URLSearchParams({ token, client_id: clientId, client_secret: clientSecret });
    let response;
    try {
      response = await fetchImpl('https://api.x.com/2/oauth2/revoke', {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded', Accept: 'application/json' },
        body: form.toString(),
        redirect: 'error',
      });
    } catch {
      throw new OAuthError('provider_unavailable', 'X could not confirm token revocation.', 502);
    }
    if (!response.ok) throw new OAuthError('provider_unavailable', 'X could not confirm token revocation.', 502);
    return { revoked: true };
  }

  async function tokenRequest(form, errorCode) {
    return responseJson(TOKEN_ENDPOINT, {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded', Accept: 'application/json' },
      body: form.toString(),
    }, errorCode);
  }

  async function responseJson(url, init, errorCode) {
    let response;
    try {
      response = await fetchImpl(url, { ...init, redirect: 'error' });
    } catch {
      throw new OAuthError('provider_unavailable', 'X authorization service is unavailable.', 502);
    }
    let body;
    try {
      body = await response.json();
    } catch {
      throw new OAuthError('provider_error', 'X returned an invalid authorization response.', 502);
    }
    if (response.status === 429) throw new OAuthError('rate_limited', 'X is rate limiting authorization requests.', 429);
    if (!response.ok || body.error) {
      throw new OAuthError(errorCode, 'X could not complete this authorization request.', response.status === 401 ? 401 : 502);
    }
    return body;
  }

  return { start, callback, poll, refresh, revoke, configured };

  function appCallback() {
    // This is only a wake-up signal; no OAuth code, state, or token enters the app URI.
    return 'gather://x-auth';
  }
}

function hashSecret(value) {
  return createHash('sha256').update(value).digest('base64url');
}

function safeEqual(expected, actual) {
  const left = Buffer.from(expected);
  const right = Buffer.from(actual);
  return left.length === right.length && timingSafeEqual(left, right);
}

function safeRedirectUri(value) {
  try {
    const uri = new URL(value);
    if (uri.protocol !== 'https:' || !uri.hostname || uri.username || uri.password || uri.hash || uri.search) return null;
    return uri.toString();
  } catch {
    return null;
  }
}

function positiveSeconds(value) {
  const seconds = typeof value === 'number' ? value : Number.parseInt(String(value), 10);
  return Number.isSafeInteger(seconds) && seconds > 0 && seconds <= 31_536_000 ? seconds : null;
}
