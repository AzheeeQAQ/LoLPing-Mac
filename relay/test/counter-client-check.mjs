import { spawn } from 'node:child_process';
import path from 'node:path';
import { createRelay } from '../server.mjs';

// Runs the production Swift client's shared room counter against a temporary local relay.
const relay = createRelay();
try {
  const { port } = await relay.listen(0);
  const executable = path.resolve(process.argv[2] ?? '../dist/LoLPing.app/Contents/MacOS/LoLPing');
  const child = spawn(executable, ['--counter-relay-check', `ws://127.0.0.1:${port}/ws`], { stdio: 'inherit' });
  const code = await new Promise((resolve, reject) => { child.once('error', reject); child.once('exit', resolve); });
  process.exitCode = code === 0 ? 0 : 1;
} finally { await relay.close(); }
