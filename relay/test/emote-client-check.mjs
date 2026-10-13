import { spawn } from 'node:child_process';
import path from 'node:path';
import { createRelay } from '../server.mjs';
const relay = createRelay();
try {
  const { port } = await relay.listen(0);
  const executable = path.resolve(process.argv[2] ?? '../dist/LoLPing.app/Contents/MacOS/LoLPing');
  const screenshots = path.resolve(process.argv[3] ?? '../.build/emote-check');
  for (const mode of ['--feature-check', '--emote-check']) {
    const child = spawn(executable, [mode, `ws://127.0.0.1:${port}/ws`, screenshots], { stdio: 'inherit' });
    const code = await new Promise((resolve, reject) => { child.once('error', reject); child.once('exit', resolve); });
    if (code !== 0) { process.exitCode = 1; break; }
  }
} finally { await relay.close(); }
