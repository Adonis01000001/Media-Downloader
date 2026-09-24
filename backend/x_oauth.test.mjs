import assert from 'node:assert/strict';
import test from 'node:test';
import { createXOAuth } from './x_oauth.mjs';

const handoffSecret = 'h'.repeat(43);

function response(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json' },
  });
}

function setup({ now = () => Date.now() } = {}) {
  const calls = [];
  const oauth = createXOAuth({
    clientId: 'x-client-id',
    clientSecret: 'TEST_CLIENT_SECRET',
    redirectUri: 'https://oauth.example.test/v1/x/oauth/callback',
    now,
    fetchImpl: async (input, init = {}) => {
      const url = new URL(input);
      calls.push({ url, init });
      if (url.pathname === '/2/oauth2/token') {
        const form = new URLSearchParams(init.body);
        if (form.get('grant_type') === 'refresh_token') {
          return response({
            token_type: 'bearer',
            access_token: 'TEST_ACCESS_TOKEN',
            refresh_token: 'TEST_REFRESH_TOKEN',
            expires_in: 7200,
          });
        }
        return response({
          token_type: 'bearer',
          access_token: 'TEST_ACCESS_TOKEN',
          refresh_token: 'TEST_REFRESH_TOKEN',
          expires_in: 7200,
          scope: 'tweet.read users.read offline.access',
        });
      }
      if (url.pathname === '/2/users/me') {
        return response({ data: { id: '42', name: 'Gather User', username: 'gather_user', protected: true } });
      }
      if (url.pathname === '/2/oauth2/revoke') return response({ revoked: true });
      throw new Error(`Unexpected URL ${url}`);
    },
  });
  return { oauth, calls };
}

test('X OAuth uses state, PKCE S256, minimum read scopes, and verified identity', async () => {
  const { oauth, calls } = setup();
  const attempt = oauth.start(handoffSecret);
  const authorize = new URL(attempt.authorizationUrl);
  assert.equal(authorize.origin, 'https://x.com');
  assert.equal(authorize.pathname, '/i/oauth2/authorize');
  assert.equal(authorize.searchParams.get('code_challenge_method'), 'S256');
  assert.equal(authorize.searchParams.get('scope'), 'tweet.read users.read offline.access');
  assert.equal(authorize.searchParams.has('client_secret'), false);

  assert.throws(() => oauth.poll(attempt.attemptId, 'x'.repeat(43)), { code: 'invalid_handoff' });
  assert.equal(oauth.poll(attempt.attemptId, handoffSecret).status, 'pending');
  await assert.rejects(
    () => oauth.callback(new URLSearchParams({ state: 'wrong-state', code: 'code' })),
    { code: 'invalid_state' },
  );
  assert.equal(calls.length, 0);

  const callbackUrl = await oauth.callback(new URLSearchParams({
    state: authorize.searchParams.get('state'),
    code: 'authorization-code',
  }));
  assert.equal(callbackUrl, 'gather://x-auth');
  assert.equal(calls[0].url.toString(), 'https://api.x.com/2/oauth2/token');
  const tokenForm = new URLSearchParams(calls[0].init.body);
  assert.ok(tokenForm.get('code_verifier'));
  assert.equal(tokenForm.get('client_secret'), 'TEST_CLIENT_SECRET');
  assert.equal(calls[1].url.origin, 'https://api.x.com');
  assert.equal(calls[1].url.pathname, '/2/users/me');
  assert.equal(calls[1].init.headers.Authorization, 'Bearer TEST_ACCESS_TOKEN');

  const result = oauth.poll(attempt.attemptId, handoffSecret);
  assert.equal(result.status, 'ready');
  assert.equal(result.session.userId, '42');
  assert.equal(result.session.username, 'gather_user');
  assert.equal(result.session.refreshToken, 'TEST_REFRESH_TOKEN');
  assert.throws(() => oauth.poll(attempt.attemptId, handoffSecret), { code: 'attempt_expired' });
});

test('X OAuth refresh rotates tokens and disconnect revokes through the official endpoint', async () => {
  const { oauth, calls } = setup();
  assert.deepEqual(await oauth.refresh('TEST_REFRESH_TOKEN'), {
    accessToken: 'TEST_ACCESS_TOKEN',
    refreshToken: 'TEST_REFRESH_TOKEN',
    expiresIn: 7200,
  });
  assert.deepEqual(await oauth.revoke('TEST_REFRESH_TOKEN'), { revoked: true });
  assert.equal(new URL(calls[1].url).pathname, '/2/oauth2/revoke');
  assert.equal(new URLSearchParams(calls[1].init.body).get('token'), 'TEST_REFRESH_TOKEN');
});

test('X OAuth rejects insecure callbacks, invalid handoffs, and expired state', async () => {
  const insecure = createXOAuth({
    clientId: 'id',
    clientSecret: 'TEST_CLIENT_SECRET',
    redirectUri: 'http://oauth.example.test/callback',
  });
  assert.throws(() => insecure.start(handoffSecret), { code: 'server_configuration' });

  let currentTime = 0;
  const { oauth } = setup({ now: () => currentTime });
  assert.throws(() => oauth.start('short'), { code: 'invalid_handoff' });
  const attempt = oauth.start(handoffSecret);
  currentTime = 600_001;
  await assert.rejects(() => oauth.callback(new URLSearchParams({
    state: new URL(attempt.authorizationUrl).searchParams.get('state'),
    code: 'code',
  })), { code: 'invalid_state' });
});
