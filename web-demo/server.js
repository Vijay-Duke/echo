import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { WebSocketServer, WebSocket } from 'ws';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

for (const line of fs.readFileSync(path.join(__dirname, '.env'), 'utf8').split('\n')) {
  const m = line.match(/^([A-Z_]+)=(.*)$/);
  if (m) process.env[m[1]] ??= m[2];
}

const KEY = process.env.XAI_API_KEY;
const GEMINI_KEY = process.env.GEMINI_API_KEY;
const PORT = Number(process.env.PORT || 3000);
const XAI = 'https://api.x.ai/v1';
const GEMINI_WS = 'wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1alpha.GenerativeService.BidiGenerateContent';

const MIME = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css' };

function serveStatic(req, res) {
  const file = req.url === '/' ? '/index.html' : req.url;
  const fp = path.join(__dirname, 'public', file);
  if (!fp.startsWith(path.join(__dirname, 'public'))) return res.writeHead(403).end();
  fs.readFile(fp, (err, buf) => {
    if (err) return res.writeHead(404).end('not found');
    res.writeHead(200, { 'Content-Type': MIME[path.extname(fp)] || 'application/octet-stream' });
    res.end(buf);
  });
}

async function readBody(req) {
  const chunks = [];
  for await (const c of req) chunks.push(c);
  return Buffer.concat(chunks).toString('utf8');
}

// SSE: stream Grok chat reply, emit text deltas + sentence boundaries.
// Client requests TTS per sentence on its own (so audio Blobs stay binary).
const EMOTION_SYSTEM = `You are a voice assistant. Replies will be spoken via Grok TTS.
Use these inline tags to add emotion and pacing:
- [pause] — short pause
- [laugh] — natural laugh
- <whisper>text</whisper> — whispered phrase
Use them naturally where they fit the meaning. Do NOT overuse — at most 1–2 per sentence.
Keep replies short and conversational (2–4 sentences) since they will be spoken aloud.
Do not use markdown, code blocks, lists, or emoji. Plain spoken English only.`;

async function chatStream(req, res) {
  const { prompt, voice = 'eve' } = JSON.parse(await readBody(req));
  res.writeHead(200, {
    'Content-Type': 'text/event-stream',
    'Cache-Control': 'no-cache',
    'Connection': 'keep-alive',
  });
  const send = (event, data) => res.write(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`);

  const upstream = await fetch(`${XAI}/chat/completions`, {
    method: 'POST',
    headers: { 'Authorization': `Bearer ${KEY}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({
      model: 'grok-4-latest',
      stream: true,
      messages: [
        { role: 'system', content: EMOTION_SYSTEM },
        { role: 'user', content: prompt },
      ],
    }),
  });

  if (!upstream.ok || !upstream.body) {
    send('error', { status: upstream.status, body: await upstream.text() });
    return res.end();
  }

  const reader = upstream.body.getReader();
  const dec = new TextDecoder();
  let buf = '';
  let pending = '';

  // Find sentence boundary in pending. Skip boundaries inside <whisper>...</whisper>.
  // Returns index just past the boundary, or -1.
  function findBoundary(s) {
    let inWhisper = false;
    for (let i = 0; i < s.length; i++) {
      if (!inWhisper && s.startsWith('<whisper>', i)) { inWhisper = true; i += 8; continue; }
      if (inWhisper && s.startsWith('</whisper>', i)) { inWhisper = false; i += 9; continue; }
      if (inWhisper) continue;
      const c = s[i];
      if (c === '.' || c === '!' || c === '?' || c === '\n') {
        let j = i + 1;
        while (j < s.length && '.!?"\')]'.includes(s[j])) j++;
        if (j >= s.length) return -1; // need more chars to confirm boundary
        if (/\s/.test(s[j]) || c === '\n') return j;
      }
    }
    return -1;
  }

  while (true) {
    const { value, done } = await reader.read();
    if (done) break;
    buf += dec.decode(value, { stream: true });
    let nl;
    while ((nl = buf.indexOf('\n')) !== -1) {
      const line = buf.slice(0, nl).trim();
      buf = buf.slice(nl + 1);
      if (!line.startsWith('data:')) continue;
      const payload = line.slice(5).trim();
      if (payload === '[DONE]') continue;
      try {
        const j = JSON.parse(payload);
        const delta = j.choices?.[0]?.delta?.content || '';
        if (!delta) continue;
        send('text', { delta });
        pending += delta;
        let idx;
        while ((idx = findBoundary(pending)) !== -1) {
          const sentence = pending.slice(0, idx).trim();
          pending = pending.slice(idx);
          if (sentence) send('sentence', { text: sentence, voice });
        }
      } catch {}
    }
  }
  if (pending.trim()) send('sentence', { text: pending.trim(), voice });
  send('done', {});
  res.end();
}

async function realtimeSession(req, res) {
  const r = await fetch(`${XAI}/realtime/client_secrets`, {
    method: 'POST',
    headers: { 'Authorization': `Bearer ${KEY}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({}),
  });
  const body = await r.text();
  res.writeHead(r.status, { 'Content-Type': 'application/json' });
  res.end(body);
}

async function stt(req, res) {
  const chunks = [];
  for await (const c of req) chunks.push(c);
  const audio = Buffer.concat(chunks);
  const ct = req.headers['content-type'] || 'audio/webm';
  const ext = ct.includes('wav') ? 'wav' : ct.includes('mp3') ? 'mp3' : ct.includes('mp4') ? 'm4a' : 'webm';

  const form = new FormData();
  form.append('file', new Blob([audio], { type: ct }), `audio.${ext}`);
  form.append('model', 'grok-stt-1');

  const r = await fetch(`${XAI}/stt`, {
    method: 'POST',
    headers: { 'Authorization': `Bearer ${KEY}` },
    body: form,
  });
  const body = await r.text();
  res.writeHead(r.status, { 'Content-Type': 'application/json' });
  res.end(body);
}

async function tts(req, res) {
  const { text, voice = 'eve', language = 'en' } = JSON.parse(await readBody(req));
  const r = await fetch(`${XAI}/tts`, {
    method: 'POST',
    headers: { 'Authorization': `Bearer ${KEY}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ text, voice_id: voice, language }),
  });
  res.writeHead(r.status, { 'Content-Type': r.headers.get('content-type') || 'application/octet-stream' });
  if (!r.body) return res.end();
  const reader = r.body.getReader();
  while (true) {
    const { value, done } = await reader.read();
    if (done) break;
    res.write(Buffer.from(value));
  }
  res.end();
}

const server = http.createServer((req, res) => {
  if (req.method === 'POST' && req.url === '/chat') return chatStream(req, res);
  if (req.method === 'POST' && req.url === '/tts') return tts(req, res);
  if (req.method === 'POST' && req.url === '/stt') return stt(req, res);
  if (req.method === 'POST' && req.url === '/session') return realtimeSession(req, res);
  if (req.method === 'GET') return serveStatic(req, res);
  res.writeHead(405).end();
});

const wss = new WebSocketServer({ noServer: true });

server.on('upgrade', (req, socket, head) => {
  if (req.url !== '/gemini') return socket.destroy();
  wss.handleUpgrade(req, socket, head, (client) => {
    const upstream = new WebSocket(`${GEMINI_WS}?key=${GEMINI_KEY}`);
    let upstreamReady = false;
    const pending = [];

    upstream.on('open', () => {
      upstreamReady = true;
      for (const m of pending) upstream.send(m);
      pending.length = 0;
    });
    upstream.on('message', (data) => {
      if (client.readyState === client.OPEN) client.send(data.toString());
    });
    upstream.on('close', (code, reason) => {
      try { client.close(code >= 1000 && code <= 4999 ? code : 1011, reason?.toString().slice(0, 120)); } catch {}
    });
    upstream.on('error', (e) => {
      try { client.send(JSON.stringify({ proxyError: e.message })); } catch {}
    });

    client.on('message', (data) => {
      const buf = data.toString();
      if (upstreamReady) upstream.send(buf);
      else pending.push(buf);
    });
    client.on('close', () => { try { upstream.close(); } catch {} });
    client.on('error', () => { try { upstream.close(); } catch {} });
  });
});

server.listen(PORT, () => console.log(`http://localhost:${PORT}`));
