import { cp, mkdir, rm } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
const root = dirname(fileURLToPath(import.meta.url));
const output = join(root, 'dist');
await rm(output, { recursive: true, force: true });
await mkdir(output, { recursive: true });
for (const file of ['index.html', 'privacy.html', 'style.css', 'app.js', 'assets']) await cp(join(root, file), join(output, file), { recursive: true });
console.log(`Built static Swarmbell website: ${output}`);
