import { describe, expect, it } from 'vitest';
import { consumeStream } from './api';

function stream(text: string) {
  const bytes = new TextEncoder().encode(text);
  return new ReadableStream<Uint8Array>({ start(c) { for (const byte of bytes) c.enqueue(new Uint8Array([byte])); c.close(); } });
}
describe('SSE protocol', () => {
  it('handles split UTF-8, CRLF, and heartbeats', async () => {
    let text = '';
    const result = await consumeStream(stream(': heartbeat\r\n\r\nevent: delta\r\ndata: {"text":"héllo 🌍"}\r\n\r\nevent: done\ndata: {"content":"héllo 🌍","role":"assistant"}\n\n'), d => { text += d; });
    expect(text).toBe('héllo 🌍'); expect(result.content).toBe(text);
  });
  it('does not treat a truncated response as success', async () => {
    await expect(consumeStream(stream('event: delta\ndata: {"text":"partial"}\n\n'), () => {})).rejects.toThrow('before the reply was saved');
  });
  it('surfaces errors sent after the HTTP response started', async () => {
    await expect(consumeStream(stream('event: error\ndata: {"message":"Try again"}\n\n'), () => {})).rejects.toThrow('Try again');
  });
});
