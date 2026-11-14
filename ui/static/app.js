// The demo's web page. It shows what ../server.py sends: the events that
// demo.sh printed, the device's live state, and the session handshake as the
// NoPorts programs logged it. No libraries.
'use strict';

const $ = (id) => document.getElementById(id);
const el = (tag, cls, text) => {
  const e = document.createElement(tag);
  if (cls) e.className = cls;
  if (text !== undefined) e.textContent = text;
  return e;
};
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const api = (path, body) =>
  fetch(path, body === undefined ? {} : {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'X-NoPorts-Demo': '1' },
    body: JSON.stringify(body),
  }).then((r) => r.json());

// ---------------------------------------------------------------------------
// The story: demo.sh's events, as headings, prose, terminal blocks and prompts.
// ---------------------------------------------------------------------------
const story = $('story');
let act = null;        // the <article> being written
let block = null;      // the element new lines go into
let blockKind = '';
let looks = [];        // "look for yourself" commands waiting for the next pause
let caughtUp = false;  // false while replaying events that happened before the page loaded

function resetStory() {
  story.querySelectorAll('.act:not(#intro)').forEach((a) => a.remove());
  act = block = null; blockKind = ''; looks = [];
  showHandshake(null);
}

function ensureAct() {
  if (!act) { act = el('article', 'act'); story.append(act); }
  return act;
}

function ensure(kind, tag, cls) {
  if (blockKind !== kind || !block) {
    block = el(tag, cls); blockKind = kind; ensureAct().append(block);
  }
  return block;
}

function render(e) {
  const t = e.t;
  switch (e.k) {
    case 'heading':
      act = el('article', 'act'); act.append(el('h2', '', t)); story.append(act);
      act.dataset.title = t; block = null; blockKind = '';
      break;
    case 'say':
      if (t === '') { block = null; blockKind = ''; }
      else if (t.startsWith('- ')) ensure('list', 'ul').append(el('li', '', t.slice(2)));
      else if (t.startsWith('  ') && blockKind === 'list') block.lastChild.textContent += ' ' + t.trim();
      else if (t.startsWith('  ')) ensure('term', 'pre', 'term').append(t + '\n');
      else { const p = ensure('p', 'p'); p.textContent += (p.textContent ? ' ' : '') + t; }
      break;
    case 'cmd': {
      block = el('pre', 'term'); blockKind = 'term'; ensureAct().append(block);
      const [command, note] = t.split(/\s{2,}#\s*/);
      block.append(el('span', 'cmd', '$ ' + command));
      if (note) block.append(el('span', 'note', '   # ' + note));
      block.append('\n');
      break;
    }
    case 'out':
      if (t.trim() === '' && blockKind !== 'term') break;
      ensure('term', 'pre', 'term').append(t + '\n');
      break;
    case 'big':
      ensureAct().append(el('div', 'big', t)); block = null; blockKind = '';
      break;
    case 'look':
      looks.push(t.split('|'));
      break;
    case 'pause':
      if (looks.length) ensureAct().append(lookBox(looks));
      looks = []; block = null; blockKind = '';
      if (/^[34]\./.test(act && act.dataset.title || '')) loadHandshake();
      if (caughtUp) act.scrollIntoView({ behavior: 'smooth', block: 'end' });
      break;
    case 'fail':
      ensureAct().append(el('div', 'fail', 'The demo stopped: ' + t)); block = null; blockKind = '';
      break;
  }
}

// The loud prompt: buttons that run a real command in a real box.
function lookBox(specs) {
  const box = el('div', 'look');
  box.append(el('h3', '', 'LOOK FOR YOURSELF'));
  box.append(el('p', '', "Don't take our word for it. Each button runs a real command inside the machine named on it, right now."));
  const presets = el('div', 'presets');
  const result = el('pre', 'term result'); result.hidden = true;
  const run = async (where, command) => {
    box.querySelectorAll('button').forEach((b) => { b.disabled = true; });
    result.hidden = false; result.textContent = '';
    result.append(el('span', 'cmd', '$ ' + command), el('span', 'note', '   # in the ' + where + ' box'), '\nRunning...');
    let r;
    try { r = await api('/api/exec', { box: where, command }); }
    catch (err) { r = { output: 'Could not reach the demo. Is it still running?', code: 1 }; }
    result.lastChild.remove();
    result.append('\n' + (r.output || '(no output)') + (r.code ? '\n(exit code ' + r.code + ')' : '') + '\n');
    box.querySelectorAll('button').forEach((b) => { b.disabled = false; });
  };
  for (const [where, command, what] of specs) {
    const b = el('button', 'preset');
    b.append(el('span', 'where', where), el('code', '', command), el('small', '', what));
    b.onclick = () => run(where, command);
    presets.append(b);
  }
  const form = el('form');
  const select = el('select');
  for (const name of ['device', 'scanner', 'client', 'relay']) select.append(el('option', '', name));
  const input = el('input'); input.placeholder = 'or type your own command, e.g. ss -tuln'; input.setAttribute('aria-label', 'Command');
  select.setAttribute('aria-label', 'Machine');
  form.append(select, input, el('button', '', 'Run'));
  form.onsubmit = (ev) => { ev.preventDefault(); if (input.value.trim()) run(select.value, input.value.trim()); };
  box.append(presets, form, result);
  return box;
}

// ---------------------------------------------------------------------------
// Run state and the one big button.
// ---------------------------------------------------------------------------
const go = $('go');
let state = 'idle';
const LABELS = {
  idle: ['Ready', 'Start the demo', ''],
  running: ['Working', 'Working...', 'Running real commands; a port scan takes a few seconds.'],
  paused: ['Your turn', 'Next step', 'Look around first, then carry on.'],
  done: ['Finished', 'Run it again', 'That was the whole demo.'],
  failed: ['Stopped', 'Try again', 'Something went wrong; the details are above.'],
};

function setState(s) {
  state = s;
  const [pill, button, hint] = LABELS[s] || LABELS.idle;
  $('status').textContent = pill; $('status').className = 'pill ' + s;
  go.textContent = button; go.disabled = s === 'running';
  $('go-hint').textContent = hint;
}

go.onclick = async () => {
  go.disabled = true;
  await api(state === 'paused' ? '/api/next' : '/api/start', {});
};

async function follow() {
  let run = -1, next = 0;
  for (;;) {
    try {
      const r = await api('/api/events?run=' + run + '&from=' + next);
      if (r.run !== run) { resetStory(); run = r.run; }
      r.events.forEach(render);
      next = r.next; setState(r.state); caughtUp = true;
    } catch (err) {
      $('status').textContent = 'Not connected'; $('status').className = 'pill failed';
      await sleep(2000);
    }
  }
}

// ---------------------------------------------------------------------------
// The device, right now.
// ---------------------------------------------------------------------------
async function watchDevice() {
  for (;;) {
    try {
      const d = await api('/api/live');
      $('live-listen').textContent = d.listeners || '(nothing)';
      $('live-conn').textContent = d.connections || '(none)';
      $('live-dot').className = 'dot ' + (d.up && d.loopback_only ? 'ok' : 'bad');
      $('live-summary').textContent = !d.up ? 'The device is not running.'
        : (d.loopback_only ? 'Nothing on the device listens on the network. ' : 'Something on the device is listening on the network! ')
          + (d.session ? 'An SSH session is open right now.' : 'No session is open.');
      $('live-published').textContent = d.published
        ? 'Docker publishes these device ports: ' + d.published
        : 'Docker publishes no ports for the device.';
    } catch (err) { $('live-dot').className = 'dot'; }
    await sleep(2000);
  }
}

// ---------------------------------------------------------------------------
// The diagram: five boxes, and one line per step of setting up a session.
// ---------------------------------------------------------------------------
const SVG = 'http://www.w3.org/2000/svg';
const svg = (tag, attrs, text) => {
  const e = document.createElementNS(SVG, tag);
  for (const k in attrs) e.setAttribute(k, attrs[k]);
  if (text !== undefined) e.textContent = text;
  return e;
};
// Each step's line. "msg" lines pass through the platform (the atServers).
const EDGES = {
  1: ['msg', 'M130,146 L200,54 M250,66 L250,235'],
  2: ['msg', 'M270,235 L270,66 M200,42 L130,134'],
  3: ['msg', 'M130,122 L200,30 M320,26 L420,108'],
  4: ['tcp', 'M420,142 L320,250'],
  5: ['msg', 'M436,108 L320,42 M200,18 L130,110'],
  6: ['tcp', 'M130,180 L200,255'],
  7: ['join', 'M200,278 L320,278'],
  8: ['local', 'M450,142 L450,180'],
  9: ['ssh', 'M130,188 L200,286 L320,286 L405,205'],
};

function drawDiagram() {
  const root = svg('svg', { viewBox: '0 0 520 326', role: 'img',
    'aria-label': 'Diagram: client, platform, relay, device and scanner, and the connections between them' });
  const defs = svg('defs', {});
  for (const kind of ['msg', 'tcp', 'join', 'local', 'ssh', 'scan']) {
    const m = svg('marker', { id: 'arrow-' + kind, viewBox: '0 0 10 10', refX: 9, refY: 5,
      markerWidth: 5, markerHeight: 5, orient: 'auto-start-reverse' });
    m.append(svg('path', { d: 'M0,0 L10,5 L0,10 z', class: 'head ' + kind }));
    defs.append(m);
  }
  root.append(defs);
  const node = (x, y, w, h, title, sub, cls) => {
    const g = svg('g', { class: 'node ' + (cls || '') });
    g.append(svg('rect', { x, y, width: w, height: h, rx: 7 }));
    g.append(svg('text', { x: x + w / 2, y: y + (sub ? h / 2 - 2 : h / 2 + 4) }, title));
    if (sub) g.append(svg('text', { x: x + w / 2, y: y + h / 2 + 13, class: 's' }, sub));
    root.append(g);
  };
  node(10, 100, 120, 96, 'client', 'sshnp + ssh');
  node(200, 10, 120, 56, 'platform', 'atServers');
  node(200, 235, 120, 56, 'relay', 'srvd');
  const d = svg('g', { class: 'node' });
  d.append(svg('rect', { x: 390, y: 76, width: 120, height: 154, rx: 7 }));
  d.append(svg('text', { x: 450, y: 96 }, 'device'));
  root.append(d);
  node(405, 108, 90, 34, 'sshnpd', '', 'inner');
  node(405, 180, 90, 40, 'sshd', '127.0.0.1:22', 'inner');
  node(390, 262, 120, 36, 'scanner (attacker)', '');
  root.append(svg('path', { d: 'M450,262 L450,233', class: 'edge scan', 'marker-end': 'url(#arrow-scan)' }));
  root.append(svg('text', { x: 510, y: 316, class: 'scan-label' }, '65,535 probes: nothing open'));
  for (const n in EDGES) {
    const [kind, path] = EDGES[n];
    const attrs = { d: path, class: 'edge ' + kind, id: 'edge-' + n };
    if (kind !== 'join') attrs['marker-end'] = 'url(#arrow-' + kind + ')';
    if (kind === 'ssh') attrs['marker-start'] = 'url(#arrow-ssh)';
    root.append(svg('path', attrs));
  }
  $('diagram').append(root);
}

let replaying = 0;

function select(n) {
  for (const k in EDGES) {
    const e = $('edge-' + k);
    e.classList.toggle('on', +k === n);
    e.classList.toggle('done', +k < n);
  }
  document.querySelectorAll('#steps li').forEach((li) => li.classList.toggle('on', +li.dataset.n === n));
}

async function replay() {
  const mine = ++replaying;
  for (let n = 1; n <= 9 && mine === replaying; n++) { select(n); await sleep(1600); }
}

function showHandshake(h) {
  const list = $('steps'); list.textContent = '';
  $('replay-bar').hidden = !h; $('steps-hint').hidden = !!h;
  replaying++;
  for (const k in EDGES) $('edge-' + k).classList.remove('on', 'done');
  if (!h) return;
  let longest = 0;
  for (const s of h.steps) {
    const li = el('li'); li.dataset.n = s.n;
    let title = s.title;
    if (s.n === 2 && h.ports.a) title += ' (A = ' + h.ports.a + ', B = ' + h.ports.b + ')';
    const name = el('span', '', title);
    name.append(el('span', 'tag' + (s.evidence ? ' seen' : ''), s.evidence ? 'in the logs' : 'stated, not shown'));
    const ms = s.evidence && s.evidence.ms !== null ? s.evidence.ms : null;
    if (ms !== null) longest = Math.max(longest, ms);
    const why = el('div', 'why');
    if (s.evidence) { why.append('The ' + s.evidence.box + ' logged:'); why.append(el('code', '', s.evidence.line)); }
    else why.append('No matching line was found in the logs, so this step is taken from the NoPorts design documents.');
    if (s.note) why.append(el('div', '', s.note));
    li.append(el('span', 'n', s.n), name, el('span', 'ms', ms === null ? '' : '+' + ms + ' ms'), why);
    li.onclick = () => { replaying++; select(s.n); };
    list.append(li);
  }
  $('took').textContent = longest >= 1000 ? (longest / 1000).toFixed(1) + ' seconds' : longest + ' ms';
}

let handshakeFor = '';
async function loadHandshake() {
  try {
    const h = await api('/api/handshake');
    if (!h.ready) return;
    const key = JSON.stringify(h.ports);
    showHandshake(h);
    if (key !== handshakeFor && caughtUp) replay(); else select(9);
    handshakeFor = key;
  } catch (err) { /* the diagram stays as it was */ }
}

$('replay').onclick = replay;
drawDiagram();
follow();
watchDevice();
