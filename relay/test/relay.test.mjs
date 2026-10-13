import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID, createHash } from 'node:crypto';
import { setTimeout as delay } from 'node:timers/promises';
import WebSocket from 'ws';
import { createRelay } from '../server.mjs';

async function fixture(t, options = {}) {
  const relay = createRelay(options);
  const address = await relay.listen(0);
  t.after(() => relay.close());
  const url = `ws://127.0.0.1:${address.port}/ws`;
  return { relay, url, http: `http://127.0.0.1:${address.port}` };
}
async function peer(url, options = {}) {
  const ws = new WebSocket(url, options), messages = [], waiting = [];
  ws.on('error', () => {});
  ws.on('message', (data) => {
    const packet = JSON.parse(data.toString());
    const index = waiting.findIndex(({ type }) => type === packet.type);
    if (index < 0) messages.push(packet);
    else { const [{ resolve, timer }] = waiting.splice(index, 1); clearTimeout(timer); resolve(packet); }
  });
  await new Promise((resolve, reject) => { ws.once('open', resolve); ws.once('error', reject); });
  return {
    ws, messages,
    send(packet) { ws.send(JSON.stringify(packet)); },
    next(type) {
      const index = messages.findIndex((packet) => packet.type === type);
      if (index >= 0) return Promise.resolve(messages.splice(index, 1)[0]);
      return new Promise((resolve, reject) => {
        const entry = { type, resolve, timer: setTimeout(() => {
          waiting.splice(waiting.indexOf(entry), 1); reject(new Error(`Timed out waiting for ${type}`));
        }, 2000) }; waiting.push(entry);
      });
    },
    async hello(action, fields = {}) {
      this.send({ type: 'hello', version: 1, action, name: '测试朋友', ...fields });
      return this.next('welcome');
    },
    async close() { const closed = new Promise((resolve) => ws.once('close', resolve)); ws.close(); await closed; },
    closed() { return new Promise((resolve) => ws.once('close', (code) => resolve(code))); }
  };
}
const ping = (kind = 'generic', eventID = randomUUID()) => ({ type: 'ping', kind, eventID });
const onlyPings = (p) => p.messages.filter((message) => message.type === 'ping');

test('two-way delivery of all nine signals, authenticated sender and no sender echo', async (t) => {
  const { url } = await fixture(t);
  const a = await peer(url), aw = await a.hello('create', { name: '小明' });
  assert.match(aw.room, /^[A-HJ-NP-Z2-9]{12}$/);
  const b = await peer(url), bw = await b.hello('join', { room: aw.room, name: '小红' });
  assert.equal(bw.peers.length, 2);
  for (const kind of ['retreat', 'push', 'onMyWay', 'allIn', 'assist', 'needVision', 'missing', 'enemyVision', 'generic']) {
    a.send({ ...ping(kind), sender: { id: bw.memberID, name: '冒充' } });
    const received = await b.next('ping');
    assert.equal(received.kind, kind); assert.deepEqual(received.sender, { id: aw.memberID, name: '小明' });
  }
  b.send(ping('assist')); assert.equal((await a.next('ping')).sender.id, bw.memberID);
  assert.equal(onlyPings(a).length, 0); assert.equal(onlyPings(b).length, 0);
});

test('rooms are isolated and duplicate event IDs are not replayed', async (t) => {
  const { url } = await fixture(t);
  const a = await peer(url), aw = await a.hello('create');
  const b = await peer(url); await b.hello('join', { room: aw.room });
  const outsider = await peer(url); await outsider.hello('create');
  const packet = ping(); a.send(packet); await b.next('ping'); a.send(packet);
  await delay(80);
  assert.equal(onlyPings(b).length, 0); assert.equal(onlyPings(outsider).length, 0);
});

test('a third member and nonexistent rooms are rejected', async (t) => {
  const { url } = await fixture(t);
  const a = await peer(url), aw = await a.hello('create');
  const b = await peer(url); await b.hello('join', { room: aw.room });
  const third = await peer(url);
  third.send({ type: 'hello', version: 1, action: 'join', room: aw.room, name: '第三人' });
  assert.equal((await third.next('error')).code, 'room_full');
  const missing = await peer(url);
  missing.send({ type: 'hello', version: 1, action: 'join', room: 'AAAAAAAAAAAA', name: '朋友' });
  assert.equal((await missing.next('error')).code, 'room_missing');
});

test('resume keeps identity; offline events are discarded', async (t) => {
  const { url } = await fixture(t);
  const a = await peer(url), aw = await a.hello('create');
  const b = await peer(url), bw = await b.hello('join', { room: aw.room });
  await b.close(); await delay(30);
  a.send(ping('missing')); await delay(30);
  const resumed = await peer(url);
  const welcome = await resumed.hello('resume', { room: aw.room, token: bw.token });
  assert.equal(welcome.memberID, bw.memberID);
  assert.equal(welcome.token, bw.token);
  await delay(30); assert.equal(onlyPings(resumed).length, 0);
  a.send(ping('onMyWay')); assert.equal((await resumed.next('ping')).kind, 'onMyWay');
});

test('explicit leave releases a seat immediately; invalid resume tokens are rejected', async (t) => {
  const { url } = await fixture(t);
  const a = await peer(url), aw = await a.hello('create');
  const b = await peer(url); await b.hello('join', { room: aw.room });
  const closed = b.closed(); b.send({ type: 'leave' }); await closed;
  const replacement = await peer(url); await replacement.hello('join', { room: aw.room });
  const attacker = await peer(url);
  attacker.send({ type: 'hello', version: 1, action: 'resume', room: aw.room, name: '朋友', token: '0'.repeat(64) });
  assert.equal((await attacker.next('error')).code, 'resume_expired');
});

test('abandoned rooms expire after the reconnect grace period', async (t) => {
  const { url } = await fixture(t, { graceMs: 80 });
  const a = await peer(url), aw = await a.hello('create'); await a.close(); await delay(180);
  const b = await peer(url);
  b.send({ type: 'hello', version: 1, action: 'join', room: aw.room, name: '朋友' });
  assert.equal((await b.next('error')).code, 'room_missing');
});

test('malformed JSON, unauthenticated signals and oversized frames cannot crash the relay', async (t) => {
  const { url } = await fixture(t);
  const invalid = await peer(url); invalid.ws.send('{');
  assert.equal((await invalid.next('error')).code, 'invalid_message');
  const unauthenticated = await peer(url); unauthenticated.send(ping());
  assert.equal((await unauthenticated.next('error')).code, 'invalid_hello');
  const large = await peer(url), closed = large.closed(); large.ws.send('a'.repeat(50_000));
  assert.equal(await closed, 1009);
  const healthy = await peer(url); assert.ok((await healthy.hello('create')).room);
});

test('invalid signal kinds and unsupported protocol versions are rejected', async (t) => {
  const { url } = await fixture(t);
  const old = await peer(url);
  old.send({ type: 'hello', version: 99, action: 'create', name: '朋友' });
  assert.equal((await old.next('error')).code, 'invalid_hello');
  const a = await peer(url); await a.hello('create'); a.send(ping('invalid'));
  assert.equal((await a.next('error')).code, 'invalid_ping');
});

test('rate limits bound bursts without disconnecting normal users', async (t) => {
  const { url } = await fixture(t);
  const a = await peer(url), aw = await a.hello('create');
  const b = await peer(url); await b.hello('join', { room: aw.room });
  for (let index = 0; index < 50; index++) a.send(ping());
  assert.equal((await a.next('error')).code, 'rate_limited'); await delay(50);
  assert.ok(onlyPings(b).length <= 12); assert.equal(a.ws.readyState, WebSocket.OPEN);
});

test('session replacement does not let the old transport remove the resumed member', async (t) => {
  const { url } = await fixture(t);
  const a = await peer(url), aw = await a.hello('create');
  const b = await peer(url); await b.hello('join', { room: aw.room });
  const resumed = await peer(url); await resumed.hello('resume', { room: aw.room, token: aw.token });
  await delay(50); b.send(ping('push'));
  assert.equal((await resumed.next('ping')).kind, 'push');
});

test('health endpoint and configured room cap', async (t) => {
  const { url, http } = await fixture(t, { maxRooms: 1 });
  assert.deepEqual(await (await fetch(`${http}/health`)).json(), { status: 'ok', protocol: 1 });
  assert.equal((await fetch(`${http}/anything`)).status, 404);
  const a = await peer(url); await a.hello('create');
  const b = await peer(url); b.send({ type: 'hello', version: 1, action: 'create', name: '朋友' });
  assert.equal((await b.next('error')).code, 'server_full');
});

test('private reverse proxy counts each real client separately', async (t) => {
  const { url } = await fixture(t, { trustProxy: true, maxConnectionsPerAddress: 1 });
  const a = await peer(url, { headers: { 'X-Forwarded-For': '192.0.2.1' } });
  const aw = await a.hello('create');
  const b = await peer(url, { headers: { 'X-Forwarded-For': '192.0.2.2' } });
  await b.hello('join', { room: aw.room });
  a.send(ping('missing')); assert.equal((await b.next('ping')).kind, 'missing');
  await assert.rejects(peer(url, { headers: { 'X-Forwarded-For': '192.0.2.1' } }), /503/);
  await a.close();
  const replacement = await peer(url, { headers: { 'X-Forwarded-For': '192.0.2.1' } });
  await replacement.hello('resume', { room: aw.room, token: aw.token });
});

test('forwarded headers cannot bypass default address limits', async (t) => {
  const { url } = await fixture(t, { maxConnectionsPerAddress: 1 });
  const a = await peer(url, { headers: { 'X-Forwarded-For': '192.0.2.1' } });
  await a.hello('create');
  await assert.rejects(peer(url, { headers: { 'X-Forwarded-For': '192.0.2.2' } }), /503/);
});

test('global connection limits still apply behind a trusted proxy', async (t) => {
  const { url } = await fixture(t, { trustProxy: true, maxConnections: 1 });
  const a = await peer(url, { headers: { 'X-Forwarded-For': '192.0.2.1' } });
  await a.hello('create');
  await assert.rejects(peer(url, { headers: { 'X-Forwarded-For': '192.0.2.2' } }), /503/);
});

const emoteFixture = () => {
  const png = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg==', 'base64');
  return { id: createHash('sha256').update(png).digest('hex'), name: '自己的表情', png: png.toString('base64') };
};
test('custom images cross the room with bound sender, deduplication and no offline storage', async (t) => {
  const { url } = await fixture(t);
  const a = await peer(url), aw = await a.hello('create', { capabilities: ['emote-png-v1'], name: '甲' });
  const b = await peer(url); await b.hello('join', { room: aw.room, capabilities: ['emote-png-v1'] });
  const outside = await peer(url); await outside.hello('create', { capabilities: ['emote-png-v1'] });
  const packet = { type: 'emote', eventID: randomUUID(), emote: emoteFixture(), sender: { id: 'forged', name: 'forged' } };
  a.send(packet); const got = await b.next('emote');
  assert.deepEqual(got.emote, packet.emote); assert.deepEqual(got.sender, { id: aw.memberID, name: '甲' });
  a.send(packet); await delay(100);
  assert.equal(b.messages.filter((p) => p.type === 'emote').length, 0);
  assert.equal(a.messages.filter((p) => p.type === 'emote').length, 0);
  assert.equal(outside.messages.filter((p) => p.type === 'emote').length, 0);
  a.send({ ...packet, eventID: randomUUID() }); assert.equal((await a.next('error')).code, 'rate_limited');
});
test('old clients retain ping compatibility and are never sent unknown image frames', async (t) => {
  const { url } = await fixture(t);
  const a = await peer(url), aw = await a.hello('create', { capabilities: ['emote-png-v1'] });
  const old = await peer(url); await old.hello('join', { room: aw.room });
  a.send({ type: 'emote', eventID: randomUUID(), emote: emoteFixture() });
  assert.equal((await a.next('error')).code, 'emote_unsupported');
  await delay(30); assert.equal(old.messages.filter((p) => p.type === 'emote').length, 0);
  a.send(ping()); assert.equal((await old.next('ping')).kind, 'generic');
});
test('image hash, dimensions, size and capabilities are checked', async (t) => {
  const { url } = await fixture(t);
  for (const mode of ['hash', 'dimensions', 'size', 'capability', 'base64']) {
    const a = await peer(url); await a.hello('create', { capabilities: mode === 'capability' ? [] : ['emote-png-v1'] });
    const emote = emoteFixture();
    if (mode === 'hash') emote.id = '0'.repeat(64);
    if (mode === 'base64') emote.png = 'garbage';
    if (mode === 'dimensions' || mode === 'size') {
      const png = mode === 'size' ? Buffer.alloc(32_769) : Buffer.from(emote.png, 'base64');
      if (mode === 'dimensions') png.writeUInt32BE(161, 16);
      emote.png = png.toString('base64'); emote.id = createHash('sha256').update(png).digest('hex');
    }
    a.send({ type: 'emote', eventID: randomUUID(), emote }); assert.equal((await a.next('error')).code, 'invalid_emote');
  }
});
