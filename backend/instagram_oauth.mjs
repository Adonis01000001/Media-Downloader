import { createHash, randomBytes, timingSafeEqual } from 'node:crypto';
import { OAuthError } from './oauth_error.mjs';

export { OAuthError } from './oauth_error.mjs';

const ATTEMPT_ID = /^[A-Za-z0-9_-]{40,64}$/;
const HANDOFF_SECRET = /^[A-Za-z0-9_-]{43}$/;
const OAUTH_TTL_MS = 10 * 60 * 1000;

export function createInstagramOAuth({
  clientId,
  clientSecret,
  redirectUri,
  apiVersion = 'v26.0',
  fetchImpl = globalThis.fetch,
  now = () => Date.now(),
}) {
  const attempts = new Map();
  const callbackUri = safeRedirectUri(redirectUri);
  const version = /^v\d+\.\d+$/.test(apiVersion) ? apiVersion : null;

  function configured() {
    return Boolean(clientId && clientSecret && callbackUri && version && fetchImpl);
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
      throw new OAuthError(
        'server_configuration',
        'Instagram OAuth is not configured on this server.',
        503,
      );
    }
    if (attempts.size >= 1000) {
      throw new OAuthError('server_busy', 'Too many sign-in attempts. Try again shortly.', 503);
    }
    if (typeof handoffSecret !== 'string' || !HANDOFF_SECRET.test(handoffSecret)) {
      throw new OAuthError('invalid_handoff', 'The Instagram sign-in handoff is invalid.');
    }
    const attemptId = randomBytes(32).toString('base64url');
    const state = randomBytes(32).toString('base64url');
    const url = new URL('https://www.instagram.com/oauth/authorize');
    url.searchParams.set('client_id', clientId);
    url.searchParams.set('redirect_uri', callbackUri);
    url.searchParams.set('response_type', 'code');
    url.searchParams.set('scope', 'instagram_business_basic');
    url.searchParams.set('state', state);
    url.searchParams.set('enable_fb_login', '0');
    attempts.set(attemptId, {
      state,
      handoffHash: hashSecret(handoffSecret),
      phase: 'pending',
      createdAt: now(),
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
      throw new OAuthError('invalid_state', 'Instagram returned an invalid or expired OAuth state.');
    }
    const [attemptId, attempt] = entry;
    attempt.phase = 'processing';

    if (params.has('error')) {
      attempt.phase = 'error';
      attempt.result = { code: params.get('error') === 'access_denied' ? 'access_denied' : 'authorization_failed' };
      return appCallback(attemptId, 'error');
    }

    const code = (params.get('code') ?? '').replace(/#_$/, '');
    if (!code || code.length > 4096) {
      attempt.phase = 'error';
      attempt.result = { code: 'authorization_failed' };
      return appCallback(attemptId, 'error');
    }

    try {
      const shortToken = await exchangeAuthorizationCode(code);
      const longToken = await exchangeLongLivedToken(shortToken.access_token);
      const profile = await fetchProfile(longToken.access_token);
      const userId = String(profile.user_id ?? profile.id ?? shortToken.user_id ?? '');
      const username = typeof profile.username === 'string' ? profile.username : '';
      const expiresIn = positiveSeconds(longToken.expires_in);
      if (!userId || !username || !expiresIn) {
        throw new OAuthError('authorization_failed', 'Instagram returned incomplete account details.');
      }
      attempt.phase = 'ready';
      attempt.result = {
        accessToken: longToken.access_token,
        expiresAt: now() + expiresIn * 1000,
        userId,
        username,
        apiVersion: version,
      };
      return appCallback(attemptId, 'ready');
    } catch {
      attempt.phase = 'error';
      attempt.result = { code: 'authorization_failed' };
      return appCallback(attemptId, 'error');
    }

    async function exchangeAuthorizationCode(authorizationCode) {
      const form = new URLSearchParams({
        client_id: clientId,
        client_secret: clientSecret,
        grant_type: 'authorization_code',
        redirect_uri: callbackUri,
        code: authorizationCode,
      });
      const body = await responseJson('https://api.instagram.com/oauth/access_token', {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded', Accept: 'application/json' },
        body: form.toString(),
      });
      if (typeof body.access_token !== 'string' || body.access_token.length > 10000) {
        throw new OAuthError('authorization_failed', 'Instagram did not return an access token.');
      }
      return body;
    }

    async function exchangeLongLivedToken(shortLivedToken) {
      const url = new URL('https://graph.instagram.com/access_token');
      url.searchParams.set('grant_type', 'ig_exchange_token');
      url.searchParams.set('client_secret', clientSecret);
      url.searchParams.set('access_token', shortLivedToken);
      const body = await responseJson(url, { headers: { Accept: 'application/json' } });
      if (typeof body.access_token !== 'string' || body.access_token.length > 10000) {
        throw new OAuthError('authorization_failed', 'Instagram did not return a long-lived token.');
      }
      return body;
    }

    async function fetchProfile(accessToken) {
      const url = new URL(`https://graph.instagram.com/${version}/me`);
      url.searchParams.set('fields', 'user_id,username');
      return responseJson(url, {
        headers: { Accept: 'application/json', Authorization: `Bearer ${accessToken}` },
      });
    }

    async function responseJson(url, init = {}) {
      const response = await fetchImpl(url, { ...init, redirect: 'error' });
      let body;
      try {
        body = await response.json();
      } catch {
        throw new OAuthError('provider_error', 'Instagram returned an invalid response.', 502);
      }
      if (!response.ok || body.error) {
        throw new OAuthError('provider_error', 'Instagram could not complete authorization.', 502);
      }
      return body;
    }
  }

  function poll(attemptId, handoffSecret) {
    prune();
    if (typeof attemptId !== 'string' || !ATTEMPT_ID.test(attemptId)) {
      throw new OAuthError('invalid_attempt', 'The Instagram sign-in attempt is invalid.');
    }
    const attempt = attempts.get(attemptId);
    if (!attempt) throw new OAuthError('attempt_expired', 'Instagram sign-in expired. Connect again.', 410);
    if (typeof handoffSecret !== 'string' || !HANDOFF_SECRET.test(handoffSecret) ||
        !safeEqual(attempt.handoffHash, hashSecret(handoffSecret))) {
      throw new OAuthError('invalid_handoff', 'The Instagram sign-in handoff is invalid.', 403);
    }
    if (attempt.phase === 'pending' || attempt.phase === 'processing') return { status: 'pending' };
    const result = attempt.result;
    attempts.delete(attemptId);
    if (attempt.phase === 'error') return { status: 'error', code: result?.code ?? 'authorization_failed' };
    return { status: 'ready', session: result };
  }

  async function refresh(accessToken) {
    if (!configured()) {
      throw new OAuthError('server_configuration', 'Instagram OAuth is not configured on this server.', 503);
    }
    if (typeof accessToken !== 'string' || accessToken.length < 10 || accessToken.length > 10000) {
      throw new OAuthError('invalid_token', 'The Instagram session is invalid. Connect again.', 401);
    }
    const url = new URL('https://graph.instagram.com/refresh_access_token');
    url.searchParams.set('grant_type', 'ig_refresh_token');
    url.searchParams.set('access_token', accessToken);
    let response;
    try {
      response = await fetchImpl(url, { headers: { Accept: 'application/json' }, redirect: 'error' });
    } catch {
      throw new OAuthError('provider_unavailable', 'Instagram could not refresh authorization.', 502);
    }
    let body;
    try {
      body = await response.json();
    } catch {
      throw new OAuthError('provider_error', 'Instagram returned an invalid refresh response.', 502);
    }
    if (response.status === 401 || response.status === 400 || body.error) {
      throw new OAuthError('reauthentication_required', 'Instagram authorization expired or was revoked.', 401);
    }
    if (response.status === 429) {
      throw new OAuthError('rate_limited', 'Instagram is receiving too many requests.', 429);
    }
    if (!response.ok) {
      throw new OAuthError('provider_unavailable', 'Instagram could not refresh authorization.', 502);
    }
    const expiresIn = positiveSeconds(body.expires_in);
    if (typeof body.access_token !== 'string' || !expiresIn) {
      throw new OAuthError('provider_error', 'Instagram returned an invalid refresh response.', 502);
    }
    return { accessToken: body.access_token, expiresIn };
  }

  return { start, callback, poll, refresh, configured };

  function appCallback() {
    // The Android URI is only a wake-up signal. It carries no attempt ID or token.
    return 'gather://instagram-auth';
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
    if (uri.protocol !== 'https:' || !uri.hostname || uri.username || uri.password || uri.hash) return null;
    return uri.toString();
  } catch {
    return null;
  }
}

function positiveSeconds(value) {
  return Number.isInteger(value) && value > 0 && value <= 90 * 24 * 60 * 60 ? value : null;
}
