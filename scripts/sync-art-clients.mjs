#!/usr/bin/env node

import { randomUUID } from 'node:crypto';

const email = process.env.XYNE_SYNC_ART_EMAIL;
const password = process.env.XYNE_SYNC_ART_PASSWORD;
const backend = (process.env.XYNE_SYNC_ART_BACKEND_URL ?? 'http://127.0.0.1:3001').replace(/\/$/, '');
const channelId = process.env.XYNE_SYNC_ART_CHANNEL_ID ?? 'sync-art-no-channel';
const groupId = process.env.XYNE_SYNC_ART_GROUP_ID ?? 'sync-art-no-group';
const timeoutMs = Number(process.env.XYNE_SYNC_ART_TIMEOUT_MS ?? 30000);

if (!email || !password) {
  console.error('Set XYNE_SYNC_ART_EMAIL and XYNE_SYNC_ART_PASSWORD to log in and run ART queries.');
  process.exit(2);
}

const queries = [
  { kind: 'Single table', name: 'getAllMerchants', args: [] },
  { kind: 'Single table', name: 'getAllUserGroups', args: [] },
  { kind: 'Single table', name: 'getAllResources', args: [] },
  { kind: 'Single table', name: 'getCurrentUserPreference', args: [{}] },
  { kind: 'Single table', name: 'userChannelSections', args: [{}] },
  { kind: 'Single join', name: 'getUsers', args: [{}] },
  { kind: 'Single join', name: 'userActiveCalls', args: [] },
  { kind: 'Single join', name: 'userScheduledCalls', args: [] },
  { kind: 'Single join', name: 'getUserGroupMembers', args: [{ userGroupId: groupId }] },
  { kind: 'Single join', name: 'getBoardComplexityScores', args: [{ userGroupId: groupId }] },
  { kind: 'Multi-column join', name: 'getSdlcFolderChildren', args: [{ channelId, parentType: 'TRACK', parentId: 'sync-art-no-parent' }] },
  { kind: 'Multi-column join', name: 'getSdlcTrackItems', args: [{ channelId, items: [] }] },
];

const loginResponse = await fetch(`${backend}/api/v2/auth/email/login`, {
  method: 'POST',
  headers: { 'content-type': 'application/json' },
  body: JSON.stringify({ email, password }),
});
if (!loginResponse.ok) {
  const detail = await loginResponse.text();
  throw new Error(`Login failed (${loginResponse.status}): ${detail}`);
}
const login = await loginResponse.json();
const workspaceId = login.autoLoginWorkspace ?? login.workspaces?.[0]?.id;
if (!workspaceId) throw new Error('Login did not select a workspace.');
const tokenCookie = loginResponse.headers.getSetCookie?.()
  .find((cookie) => cookie.startsWith(`xyne_ws_${workspaceId}_token=`));
if (!tokenCookie) throw new Error('Login succeeded but did not return a workspace token cookie.');
const authToken = decodeURIComponent(tokenCookie.split(';', 1)[0].split('=').slice(1).join('='));
const sessionCookies = loginResponse.headers.getSetCookie?.()
  .map((cookie) => cookie.split(';', 1)[0])
  .filter(Boolean)
  .join('; ');
const tokenPayload = JSON.parse(Buffer.from(authToken.split('.')[1], 'base64url').toString('utf8'));
const userId = tokenPayload.sub;
if (!userId) throw new Error('Workspace token is missing its user id.');
console.log(`Logged in as ${email} (${workspaceId}); running ${queries.length} query definitions from packages/shared/src/zero/queries.ts.`);

const endpoints = [
  { label: 'BASE', url: 'ws://127.0.0.1:4948/zero/art-base/sync/v51/connect' },
  { label: 'FEATURE', url: 'ws://127.0.0.1:4949/zero/art-feature/sync/v51/connect' },
];

function canonical(value) {
  if (Array.isArray(value)) return `[${value.map(canonical).join(',')}]`;
  if (value && typeof value === 'object') {
    return `{${Object.keys(value).sort().map((key) => `${JSON.stringify(key)}:${canonical(value[key])}`).join(',')}}`;
  }
  return JSON.stringify(value);
}

function openQuery(endpoint, query) {
  return new Promise((resolve, reject) => {
    const clientId = `art-${randomUUID()}`;
    const groupIdForClient = `art-${randomUUID()}`;
    const hash = `h-${randomUUID()}`;
    const queryArgs = query.args;
    const init = {
      desiredQueriesPatch: [{ op: 'put', hash, name: query.name, args: queryArgs, ttl: 300000 }],
    };
    const protocol = encodeURIComponent(Buffer.from(JSON.stringify({
      initConnectionMessage: ['initConnection', init],
      authToken,
    })).toString('base64'));
    const url = `${endpoint.url}?clientID=${encodeURIComponent(clientId)}&clientGroupID=${encodeURIComponent(groupIdForClient)}&userID=${encodeURIComponent(userId)}&baseCookie=&ts=1&lmid=0&wsid=${encodeURIComponent(clientId)}`;
    const ws = new WebSocket(url, [protocol]);
    const rows = new Map();
    let sawConnected = false;
    let sawQuery = false;
    let sawPokeEnd = false;
    let settled = false;
    const timeout = setTimeout(() => finish(new Error(`${endpoint.label} ${query.name}: timed out waiting for the initial response`)), timeoutMs);

    function finish(error) {
      if (settled) return;
      settled = true;
      clearTimeout(timeout);
      try { ws.close(); } catch {}
      resolve(error
        ? { rows: [], error: error.message }
        : { rows: [...rows.values()].sort((a, b) => canonical(a).localeCompare(canonical(b))) });
    }

    ws.addEventListener('error', () => finish(new Error(`${endpoint.label} ${query.name}: WebSocket connection failed`)));
    ws.addEventListener('close', () => {
      if (!settled) finish(new Error(`${endpoint.label} ${query.name}: socket closed before the query hydrated`));
    });
    ws.addEventListener('message', (event) => {
      let message;
      try { message = JSON.parse(event.data); } catch { return; }
      const [tag, body] = message;
      if (tag === 'connected') sawConnected = true;
      if (tag === 'error') {
        finish(new Error(`${endpoint.label} ${query.name}: server error ${body?.kind ?? ''} ${body?.message ?? JSON.stringify(body)}`));
        return;
      }
      if (tag === 'transformError') {
        finish(new Error(`${endpoint.label} ${query.name}: query transform error ${JSON.stringify(body)}`));
        return;
      }
      if (tag === 'pokePart') {
        for (const patch of body.rowsPatch ?? []) {
          if (patch.op === 'put') {
            const row = { table: patch.tableName, value: patch.value };
            rows.set(`${patch.tableName}:${canonical(patch.value)}`, row);
          } else if (patch.op === 'del') {
            const id = patch.id;
            const prefix = `${patch.tableName}:`;
            for (const [key, row] of rows) {
              if (key.startsWith(prefix) && Object.entries(id ?? {}).every(([field, value]) => row.value[field] === value)) rows.delete(key);
            }
          }
        }
        if ((body.gotQueriesPatch ?? []).some((patch) => patch.hash === hash && patch.op === 'put')) sawQuery = true;
      }
      if (tag === 'pokeEnd') sawPokeEnd = true;
      if (sawConnected && sawQuery && sawPokeEnd) finish();
    });
  });
}

const ansi = {
  reset: '\u001b[0m', green: '\u001b[32m', red: '\u001b[31m', cyan: '\u001b[36m', yellow: '\u001b[33m',
};
const colored = (color, value) => process.stdout.isTTY ? `${ansi[color]}${value}${ansi.reset}` : value;
let diffCount = 0;

try {
  for (const query of queries) {
    console.log(`\n${colored('cyan', `== ${query.kind}: ${query.name} ==`)}`);
    const [baseResult, featureResult] = await Promise.all(endpoints.map((endpoint) => openQuery(endpoint, query)));
    const base = baseResult.rows;
    const feature = featureResult.rows;
    const baseSet = new Set(base.map(canonical));
    const featureSet = new Set(feature.map(canonical));
    const removed = base.filter((row) => !featureSet.has(canonical(row)));
    const added = feature.filter((row) => !baseSet.has(canonical(row)));
    console.log(baseResult.error
      ? colored('red', `BASE response: ERROR\n${baseResult.error}`)
      : `BASE response (${base.length} rows):\n${JSON.stringify(base, null, 2)}`);
    console.log(featureResult.error
      ? colored('red', `FEATURE response: ERROR\n${featureResult.error}`)
      : `FEATURE response (${feature.length} rows):\n${JSON.stringify(feature, null, 2)}`);
    if (removed.length || added.length || baseResult.error !== featureResult.error) {
      diffCount += 1;
      console.log(colored('yellow', `DIFF: ${removed.length} base-only row(s), ${added.length} feature-only row(s)`));
      if (baseResult.error !== featureResult.error) {
        if (baseResult.error) console.log(colored('red', `- BASE error: ${baseResult.error}`));
        else console.log(colored('green', `+ BASE succeeded (${base.length} rows)`));
        if (featureResult.error) console.log(colored('red', `- FEATURE error: ${featureResult.error}`));
        else console.log(colored('green', `+ FEATURE succeeded (${feature.length} rows)`));
      }
      for (const row of removed) console.log(colored('red', `- ${JSON.stringify(row)}`));
      for (const row of added) console.log(colored('green', `+ ${JSON.stringify(row)}`));
    } else {
      console.log(colored('green', 'IDENTICAL responses'));
    }
  }
} finally {
  const logout = await fetch(`${backend}/api/v2/auth/logout`, {
    method: 'POST',
    headers: {
      accept: 'application/json',
      authorization: `Bearer ${authToken}`,
      cookie: sessionCookies,
      'x-workspace-id': workspaceId,
    },
  });
  console.log(logout.ok ? 'Login session revoked.' : `Login session cleanup returned HTTP ${logout.status}.`);
}

console.log(`\nFinished 5 single-table, 5 single-join, and 2 multi-column-join queries. ${diffCount} query response(s) differ.`);
