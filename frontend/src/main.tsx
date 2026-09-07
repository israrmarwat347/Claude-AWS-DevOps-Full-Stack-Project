import { useEffect, useRef, useState, type FormEvent } from 'react';
import { createRoot } from 'react-dom/client';
import { api, chat, initialize, signIn, signOut, type Config, type Conversation, type Message } from './api';
import './styles.css';

function Workspace() {
  const [config, setConfig] = useState<Config>();
  const [signedIn, setSignedIn] = useState(false);
  const [ready, setReady] = useState(false);
  const [conversations, setConversations] = useState<Conversation[]>([]);
  const [cursor, setCursor] = useState<string | null>(null);
  const [active, setActive] = useState<Conversation>();
  const [messages, setMessages] = useState<Message[]>([]);
  const [draft, setDraft] = useState('');
  const [reply, setReply] = useState('');
  const [busy, setBusy] = useState(false);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState('');
  const controller = useRef<AbortController | undefined>(undefined);
  const retry = useRef<{ cid: string; text: string; id: string } | undefined>(undefined);
  const bottom = useRef<HTMLDivElement>(null);

  async function refresh(next?: string) {
    const page = await api<{ items: Conversation[]; cursor: string | null }>(`/conversations${next ? `?cursor=${encodeURIComponent(next)}` : ''}`);
    setConversations(previous => next ? [...previous, ...page.items] : page.items);
    setCursor(page.cursor);
  }
  async function select(c: Conversation) {
    setLoading(true); setError('');
    try {
      const record = await api<Conversation>(`/conversations/${c.id}`);
      setActive(record); setMessages(record.messages ?? []); setDraft(''); retry.current = undefined;
    } catch (e) { setError((e as Error).message); }
    finally { setLoading(false); }
  }
  useEffect(() => {
    initialize().then(async result => {
      setConfig(result.config); setSignedIn(result.signedIn);
      if (result.signedIn) await refresh();
    }).catch(e => setError(e.message)).finally(() => setReady(true));
    return () => controller.current?.abort();
  }, []);
  useEffect(() => { bottom.current?.scrollIntoView({ behavior: 'smooth', block: 'end' }); }, [reply, messages]);

  async function send(event: FormEvent) {
    event.preventDefault();
    if (!draft.trim() || busy || loading) return;
    setBusy(true); setError(''); setReply('');
    const text = draft;
    let conversation = active;
    const abort = new AbortController(); controller.current = abort;
    try {
      if (!conversation) {
        conversation = await api<Conversation>('/conversations', 'POST');
        setActive(conversation);
      }
      const requestId = retry.current?.cid === conversation.id && retry.current.text === text
        ? retry.current.id : crypto.randomUUID();
      retry.current = { cid: conversation.id, text, id: requestId };
      setMessages(current => [...current, { role: 'user', content: text, request_id: requestId }]);
      setDraft('');
      const result = await chat(conversation.id, text, requestId, abort.signal, delta => setReply(r => r + delta));
      retry.current = undefined;
      if (result.stop_reason === 'max_tokens') setError('Reply reached its length limit. Ask Claude to continue.');
    } catch (e) {
      setDraft(text);
      setError((e as Error).name === 'AbortError' ? 'Reply stopped. You can send your message again.' : (e as Error).message);
    } finally {
      // Read authoritative history: a disconnected reply might have completed just before cancellation.
      if (conversation) {
        try {
          const saved = await api<Conversation>(`/conversations/${conversation.id}`);
          setMessages(saved.messages ?? []); setActive(saved);
          if (retry.current && saved.messages?.some(m => m.role === 'assistant' && m.request_id === retry.current?.id)) {
            retry.current = undefined; setDraft('');
          }
          await refresh();
        } catch { setError('Unable to refresh history. Reopen the conversation before retrying.'); }
      }
      setReply(''); setBusy(false); controller.current = undefined;
    }
  }

  async function remove() {
    if (!active || !confirm('Delete this conversation?')) return;
    setLoading(true);
    try {
      await api(`/conversations/${active.id}`, 'DELETE');
      setActive(undefined); setMessages([]); setDraft(''); await refresh();
    } catch (e) { setError((e as Error).message); }
    finally { setLoading(false); }
  }

  if (!ready) return <main className="welcome"><p>Opening your workspace…</p></main>;
  if (!signedIn) return <main className="welcome"><div className="brand-mark">C</div><p className="eyebrow">CLAUDE WORKSPACE</p><h1>Space to think.<br />Help to build.</h1><p>Sign in to start a private conversation.</p>{error && <p role="alert" className="error">{error}</p>}<button className="primary" onClick={() => signIn().catch(e => setError(e.message))}>Sign in</button></main>;
  return <div className="workspace">
    <aside>
      <a className="brand" href="/" aria-label="Claude Workspace home"><span className="brand-mark">C</span><span>Claude<br /><b>Workspace</b></span></a>
      <button className="new-chat" disabled={busy || loading} onClick={() => { setActive(undefined); setMessages([]); setDraft(''); setError(''); retry.current = undefined; }}>＋ New conversation</button>
      <p className="eyebrow">YOUR CONVERSATIONS</p>
      <nav aria-label="Conversation history">{conversations.length === 0 && <p className="muted">Your conversations will appear here.</p>}{conversations.map(c => <button key={c.id} className={active?.id === c.id ? 'selected' : ''} disabled={busy || loading} onClick={() => select(c)}>{c.title}</button>)}</nav>
      {cursor && <button className="quiet" disabled={busy || loading} onClick={() => refresh(cursor).catch(e => setError(e.message))}>Load more</button>}
      <div className="account">{config?.localAuth ? <span>Local demo · history resets on restart</span> : <button className="quiet" disabled={busy} onClick={() => signOut().catch(e => setError(e.message))}>Sign out</button>}</div>
    </aside>
    <main className="chat">
      <header><div><p className="eyebrow">CONVERSATION</p><h1>{active?.title ?? 'A fresh start'}</h1></div>{active && <button className="quiet" disabled={busy || loading} onClick={remove}>Delete</button>}</header>
      <section className="transcript" aria-label="Messages" aria-busy={busy || loading}>
        {messages.length === 0 && !busy && <div className="empty"><span className="spark">✳</span><h2>What are we working on?</h2><p>Bring a question, a rough idea, or a problem.<br />We can work through it together.</p><div className="starters">{['Explain a concept simply', 'Help me debug a problem', 'Turn an idea into a plan'].map(s => <button key={s} onClick={() => setDraft(s)}>{s}</button>)}</div></div>}
        {messages.map((m, i) => <article className={`message ${m.role}`} key={`${m.request_id}-${i}`}><p className="speaker">{m.role === 'user' ? 'You' : 'Claude'}</p><div>{m.content}</div></article>)}
        {busy && <article className="message assistant"><p className="speaker">Claude</p><div>{reply || 'Thinking…'}</div></article>}
        <div ref={bottom} />
      </section>
      <div className="composer-wrap">{error && <p className="error" role="alert">{error}</p>}<form className="composer" onSubmit={send}><label className="sr-only" htmlFor="message">Your message</label><textarea id="message" rows={3} placeholder="Ask anything, or pick up where you left off…" value={draft} maxLength={8000} disabled={busy || loading} onChange={e => setDraft(e.target.value)} onKeyDown={e => { if (e.key === 'Enter' && !e.shiftKey && !e.nativeEvent.isComposing) { e.preventDefault(); e.currentTarget.form?.requestSubmit(); } }} /><div className="composer-bottom"><span>Shift + Enter for a new line</span>{busy ? <button type="button" className="primary" onClick={() => controller.current?.abort()}>Stop reply</button> : <button className="primary" type="submit" disabled={!draft.trim() || loading}>Send message ↗</button>}</div></form><p className="footnote">{config?.mockClaude ? 'Demo responses are simulated. No AI service is called.' : 'Claude can make mistakes. Check important information.'}</p></div>
    </main>
  </div>;
}

createRoot(document.getElementById('root')!).render(<Workspace />);
