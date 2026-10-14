// Runs the production Swift receiver against legacy coordinate-free packets.
// The fixture binds loopback only and never contacts a user's room.
import assert from 'node:assert/strict';
import { randomUUID, createHash } from 'node:crypto';
import { spawn } from 'node:child_process';
import { WebSocketServer } from 'ws';

const app = process.argv[2];
assert(app, 'Pass the built LoLPing executable');
const server = new WebSocketServer({ host: '127.0.0.1', port: 0 });
await new Promise(resolve => server.once('listening', resolve));
const memberID = randomUUID(), sender = { id: randomUUID(), name: '坐标测试朋友' };
const png = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLttAAAAABJRU5ErkJggg==', 'base64');
const emote = { id: createHash('sha256').update(png).digest('hex'), name: '测试图片', png: png.toString('base64') };
server.on('connection', ws => {
  let phase = 0;
  const send = packet => ws.send(JSON.stringify(packet));
  ws.on('message', data => {
    const packet = JSON.parse(data);
    if (packet.type === 'hello') {
      assert(packet.capabilities.includes('relative-position-v1'));
      send({ type: 'welcome', version: 1, room: 'ABCDEFGHJK23', token: 'f'.repeat(64), memberID,
        peers: [{ id: memberID, name: packet.name }, sender], capabilities: ['relative-position-v1', 'emote-png-v1'] });
      send({ type: 'ping', eventID: randomUUID(), kind: 'assist', sender });
    } else if (packet.type === 'ping') {
      assert.deepEqual(packet.position, { nx: 0.1, ny: 0.2 });
      if (phase++ === 0) send({ type: 'emote', eventID: randomUUID(), emote, sender });
      else send({ type: 'ping', eventID: randomUUID(), kind: 'missing', sender, position: { nx: 0.23, ny: 0.71 } });
    }
  });
});
const child = spawn(app, ['--position-fixture-check', `ws://127.0.0.1:${server.address().port}/ws`], { stdio: 'inherit' });
const timeout = setTimeout(() => child.kill('SIGTERM'), 30_000);
const code = await new Promise(resolve => child.once('exit', resolve));
clearTimeout(timeout);
for (const ws of server.clients) ws.terminate();
await new Promise(resolve => server.close(resolve));
process.exit(code ?? 1);
