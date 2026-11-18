import { spawn } from 'node:child_process';
import path from 'node:path';
import { createRelay } from '../server.mjs';

// Runs the production Swift client's daily chart data against a temporary local relay.
// Right after the client creates its room, past days are written into it, as if the
// room had been used before: 4 yesterday, 2 three days ago, 9 at 95 days ago.
const relay = createRelay();
const day = (n) => new Date(Date.now() + 8*3600e3 - n*86_400_000).toISOString().slice(0, 10);
const seeded = new Set();
const seeding = setInterval(() => {
  for (const room of relay.rooms.values()) if (!seeded.has(room.code)) {
    seeded.add(room.code); room.counterHistory = { [day(1)]: 4, [day(3)]: 2, [day(95)]: 9 };
  }
}, 2);
try {
  const { port } = await relay.listen(0);
  const executable = path.resolve(process.argv[2] ?? '../dist/LoLPing.app/Contents/MacOS/LoLPing');
  const child = spawn(executable, ['--counter-history-check', `ws://127.0.0.1:${port}/ws`], { stdio: 'inherit' });
  const code = await new Promise((resolve, reject) => { child.once('error', reject); child.once('exit', resolve); });
  process.exitCode = code === 0 ? 0 : 1;
} finally { clearInterval(seeding); await relay.close(); }
