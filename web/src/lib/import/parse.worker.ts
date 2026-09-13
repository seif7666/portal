// Parses an export off the main thread so a 22 MB file doesn't freeze the page.
import { readFile } from './readFile';

self.onmessage = async (e: MessageEvent<ArrayBuffer>) => {
  try {
    const parsed = await readFile(new Uint8Array(e.data));
    self.postMessage({ ok: true, parsed });
  } catch (err) {
    self.postMessage({ ok: false, error: err instanceof Error ? err.message : String(err) });
  }
};
