import { InMemoryWebStorage, UserManager, WebStorageStateStore } from 'oidc-client-ts';

export type Config = { localAuth: boolean; mockClaude: boolean; authority: string; clientId: string; domain: string };
export type Message = { role: 'user' | 'assistant'; content: string; request_id: string; stop_reason?: string };
export type Conversation = { id: string; title: string; created_at: number; updated_at: number; messages?: Message[] };
let manager: UserManager | undefined;
let configuration: Config;

export async function initialize(): Promise<{ config: Config; signedIn: boolean }> {
  const response = await fetch('/api/config', { cache: 'no-store' });
  if (!response.ok) throw new Error('Unable to load the workspace. Please try again.');
  configuration = await response.json();
  if (configuration.localAuth) return { config: configuration, signedIn: true };
  manager = new UserManager({
    authority: configuration.authority, client_id: configuration.clientId,
    redirect_uri: `${location.origin}/`, response_type: 'code', scope: 'openid email profile',
    metadata: {
      issuer: configuration.authority,
      authorization_endpoint: `${configuration.domain}/oauth2/authorize`,
      token_endpoint: `${configuration.domain}/oauth2/token`,
      userinfo_endpoint: `${configuration.domain}/oauth2/userInfo`,
      jwks_uri: `${configuration.authority}/.well-known/jwks.json`,
    },
    // Only short-lived PKCE transaction state goes to sessionStorage. Tokens stay in memory.
    stateStore: new WebStorageStateStore({ store: sessionStorage }),
    userStore: new WebStorageStateStore({ store: new InMemoryWebStorage() }),
    automaticSilentRenew: true, loadUserInfo: false,
  });
  const query = new URLSearchParams(location.search);
  if (query.has('code') || query.has('error')) {
    try { await manager.signinRedirectCallback(); }
    finally { history.replaceState({}, '', '/'); }
  }
  await manager.clearStaleState();
  const user = await manager.getUser();
  return { config: configuration, signedIn: !!user && !user.expired };
}

export async function signIn() { await manager?.signinRedirect(); }
export async function signOut() {
  await manager?.removeUser();
  const target = new URL(`${configuration.domain}/logout`);
  target.searchParams.set('client_id', configuration.clientId);
  target.searchParams.set('logout_uri', `${location.origin}/`);
  location.assign(target.toString());
}

async function headers(): Promise<Record<string, string>> {
  if (configuration.localAuth) return { 'Content-Type': 'application/json' };
  const user = await manager?.getUser();
  if (!user || user.expired) throw new Error('Your session has expired. Sign in again.');
  return { 'Content-Type': 'application/json', Authorization: `Bearer ${user.access_token}` };
}

export async function api<T>(path: string, method = 'GET'): Promise<T> {
  const response = await fetch(`/api${path}`, { method, headers: await headers(), cache: 'no-store' });
  if (!response.ok) {
    const body = await response.json().catch(() => ({}));
    throw new Error(typeof body.detail === 'string' ? body.detail : `Request failed (${response.status}).`);
  }
  return response.status === 204 ? undefined as T : response.json();
}

export async function consumeStream(
  body: ReadableStream<Uint8Array>, onDelta: (text: string) => void,
): Promise<Message> {
  const reader = body.getReader();
  const decoder = new TextDecoder();
  let pending = '';
  try {
    while (true) {
      const { value, done } = await reader.read();
      pending += decoder.decode(value, { stream: !done });
      let match: RegExpExecArray | null;
      while ((match = /\r?\n\r?\n/.exec(pending))) {
        const block = pending.slice(0, match.index);
        pending = pending.slice(match.index + match[0].length);
        const lines = block.split(/\r?\n/);
        const event = lines.find(line => line.startsWith('event:'))?.slice(6).trim();
        const data = lines.filter(line => line.startsWith('data:')).map(line => line.slice(5).trimStart()).join('\n');
        if (!data) continue; // Heartbeat comment.
        const payload = JSON.parse(data);
        if (event === 'delta') onDelta(payload.text);
        if (event === 'error') throw new Error(payload.message);
        if (event === 'done') return payload as Message;
      }
      if (done) throw new Error('The connection ended before the reply was saved. Please retry.');
    }
  } finally {
    await reader.cancel().catch(() => {});
    reader.releaseLock();
  }
}

export async function chat(cid: string, message: string, requestId: string, signal: AbortSignal, onDelta: (text: string) => void) {
  const response = await fetch(`/api/conversations/${cid}/messages`, {
    method: 'POST', headers: await headers(), signal,
    body: JSON.stringify({ message, request_id: requestId, stream: true }),
  });
  if (!response.ok || !response.body) {
    const body = await response.json().catch(() => ({}));
    throw new Error(typeof body.detail === 'string' ? body.detail : `Chat failed (${response.status}).`);
  }
  return consumeStream(response.body, onDelta);
}
