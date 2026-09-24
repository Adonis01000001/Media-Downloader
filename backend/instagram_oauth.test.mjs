import assert from 'node:assert/strict';
import { test } from 'node:test';
import { createInstagramOAuth } from './instagram_oauth.mjs';

const secret = 's'.repeat(43);

function configuredOAuth(fetchImpl) {
  return createInstagramOAuth({
    clientId: 'meta-client-id',
    clientSecret: 'TEST_CLIENT_SECRET',
    redirectUri: 'https://auth.example.test/v1/instagram/oauth/callback',
    apiVersion: 'v26.0',
    fetchImpl,
  });
}

test('OAuth start requests only basic professional-account scope and protects session polling', async () => {
  const calls = [];
  const fetchImpl = async (input, init = {}) => {
    const url = new URL(input);
    calls.push({ url, init });
    if (url.hostname === 'api.instagram.com') {
      assert.match(init.body, /client_secret=TEST_CLIENT_SECRET/);
      assert.doesNotMatch(url.toString(), /TEST_CLIENT_SECRET/);
      return Response.json({ access_token: 'TEST_ACCESS_TOKEN', user_id: 'account-1' });
    }
    if (url.pathname === '/access_token') {
      assert.equal(url.searchParams.get('grant_type'), 'ig_exchange_token');
      assert.equal(url.searchParams.get('client_secret'), 'TEST_CLIENT_SECRET');
      return Response.json({ access_token: 'TEST_ACCESS_TOKEN', expires_in: 5184000 });
    }
    assert.equal(url.pathname, '/v26.0/me');
    assert.equal(url.searchParams.get('fields'), 'user_id,username');
    assert.equal(init.headers.Authorization, 'Bearer TEST_ACCESS_TOKEN');
    return Response.json({ user_id: 'account-1', username: 'professional_owner' });
  };

  const oauth = configuredOAuth(fetchImpl);
  const started = oauth.start(secret);
  const authUrl = new URL(started.authorizationUrl);
  assert.equal(authUrl.origin, 'https://www.instagram.com');
  assert.equal(authUrl.pathname, '/oauth/authorize');
  assert.equal(authUrl.searchParams.get('scope'), 'instagram_business_basic');
  assert.equal(authUrl.searchParams.get('state')?.length, 43);
  assert.equal(authUrl.searchParams.get('client_secret'), null);
  assert.match(started.attemptId, /^[A-Za-z0-9_-]{43}$/);

  assert.throws(
    () => oauth.poll(started.attemptId, 'x'.repeat(43)),
    { code: 'invalid_handoff' },
  );
  await assert.rejects(
    oauth.callback(new URLSearchParams({ state: 'wrong', code: 'authorization-code' })),
    { code: 'invalid_state' },
  );

  const callback = await oauth.callback(
    new URLSearchParams({ state: authUrl.searchParams.get('state'), code: 'authorization-code' }),
  );
  assert.equal(callback, 'gather://instagram-auth');
  assert.equal(calls.length, 3);

  const result = oauth.poll(started.attemptId, secret);
  assert.equal(result.status, 'ready');
  assert.deepEqual(
    { userId: result.session.userId, username: result.session.username, apiVersion: result.session.apiVersion },
    { userId: 'account-1', username: 'professional_owner', apiVersion: 'v26.0' },
  );
  assert.equal(result.session.accessToken, 'TEST_ACCESS_TOKEN');
  assert.throws(
    () => oauth.poll(started.attemptId, secret),
    { code: 'attempt_expired' },
  );
});

test('OAuth denial returns only a generic app wake-up and a one-time error', async () => {
  const oauth = configuredOAuth(async () => {
    throw new Error('Provider should not be called for a denial');
  });
  const started = oauth.start(secret);
  const state = new URL(started.authorizationUrl).searchParams.get('state');
  const callback = await oauth.callback(
    new URLSearchParams({ state, error: 'access_denied' }),
  );
  assert.equal(callback, 'gather://instagram-auth');
  assert.equal(new URL(callback).search, '');
  assert.deepEqual(oauth.poll(started.attemptId, secret), {
    status: 'error',
    code: 'access_denied',
  });
});

test('OAuth refuses malformed handoff secrets and missing provider configuration', () => {
  const oauth = configuredOAuth(async () => Response.json({}));
  assert.throws(() => oauth.start('short'), { code: 'invalid_handoff' });
  const unconfigured = createInstagramOAuth({
    clientId: '',
    clientSecret: '',
    redirectUri: 'http://localhost/callback',
  });
  assert.throws(() => unconfigured.start(secret), { code: 'server_configuration' });
});
