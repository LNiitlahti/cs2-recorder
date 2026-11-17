'use strict';
(function () {
  var TOKEN = document.querySelector('meta[name=token]').content;
  var LAYERS = [
    { k: 'clean', n: 'Clean picture (no HUD)', d: 'The game image without killfeed or HUD. The main base for editing.' },
    { k: 'hud', n: 'HUD / killfeed only', d: 'Killfeed on a transparent background.' },
    { k: 'depth', n: 'Depth', d: 'Grey distance image for depth of field. It looks almost black: that is normal.' },
    { k: 'depthNoEnts', n: 'Depth without players', d: 'Same as Depth but players are left out.' },
    { k: 'players', n: 'Players cut-out (matte)', d: 'Only the players, with transparency.' },
    { k: 'viewModel', n: 'Weapon + hands cut-out', d: 'Only your weapon and hands. First-person only.' },
    { k: 'world', n: 'World only (no players)', d: 'The map without players.' },
    { k: 'particlesBlack', n: 'Particles on black', d: 'Muzzle flash, blood, smoke only, on black.' },
    { k: 'particlesWhite', n: 'Particles on white', d: 'Same particles on white.' }
  ];
  var DEF = {
    width: 1920, height: 1080, fps: 60, layers: ['clean', 'hud', 'depth', 'players', 'viewModel', 'particlesBlack'],
    camOn: true, camFps: 120, fov: 50, camDist: 110, camLayers: ['clean', 'players', 'depth', 'particlesBlack'],
    before: 4, after: 2, join: 8, outDir: '', accountId: '', accountKind: 'separate'
  };
  var S = { o: JSON.parse(JSON.stringify(DEF)), demoPath: '', players: [], player: null, kills: [], sel: {}, presets: [], preset: '', screen: 1, setupOk: false, pf: null, ack: false, polling: null, lastError: '' };

  // ---------- helpers
  function $(id) { return document.getElementById(id); }
  function h(tag, attrs, kids) {
    var e = document.createElement(tag);
    for (var k in (attrs || {})) {
      var v = attrs[k];
      if (k === 'class') e.className = v; else if (k === 'text') e.textContent = v;
      else if (k.slice(0, 2) === 'on') e.addEventListener(k.slice(2), v);
      else if (v === true) e.setAttribute(k, ''); else if (v !== false && v != null) e.setAttribute(k, v);
    }
    [].concat(kids || []).forEach(function (c) { if (c != null) e.appendChild(typeof c === 'string' ? document.createTextNode(c) : c); });
    return e;
  }
  function api(method, path, body) {
    var opt = { method: method, headers: { 'X-Token': TOKEN } };
    if (body !== undefined) { opt.body = JSON.stringify(body); opt.headers['Content-Type'] = 'application/json'; }
    return fetch(path, opt).then(function (r) { return r.json(); }).catch(function () {
      return { ok: false, error: 'Lost contact with the app. If the window was left open for long, close it and start the app again.' };
    });
  }
  function job(id, onTick) {
    return new Promise(function (res) {
      (function go() {
        api('GET', '/api/job?id=' + encodeURIComponent(id)).then(function (r) {
          if (r.done || r.ok === false) res(r); else { if (onTick) onTick(); setTimeout(go, 600); }
        });
      })();
    });
  }
  function showError(msg) {
    S.lastError = msg;
    var b = $('banner'); b.className = 'banner'; b.textContent = ''; b.hidden = false;
    b.appendChild(h('div', { text: msg }));
    b.appendChild(h('div', { class: 'row' }, [
      h('button', { type: 'button', text: 'Copy report', onclick: copyReport }),
      h('button', { type: 'button', text: 'Dismiss', onclick: function () { b.hidden = true; } })
    ]));
    b.scrollIntoView();
  }
  function note(msg) { var b = $('banner'); b.className = 'banner info'; b.textContent = msg; b.hidden = false; setTimeout(function () { b.hidden = true; }, 3500); }
  function clearError() { $('banner').hidden = true; }
  function copyReport() {
    api('GET', '/api/report?format=text').then(function (r) {
      var text = 'CS2 Recorder report\n' + (S.lastError ? 'Last problem: ' + S.lastError + '\n' : '') + (r.text || '');
      var done = function () { note('Report copied. Paste it in your message to the developer.'); };
      if (navigator.clipboard && navigator.clipboard.writeText) navigator.clipboard.writeText(text).then(done, function () { fallbackCopy(text); done(); });
      else { fallbackCopy(text); done(); }
    });
  }
  function fallbackCopy(t) { var a = h('textarea'); a.value = t; document.body.appendChild(a); a.select(); try { document.execCommand('copy'); } catch (e) {} a.remove(); }
  function saveReport() {
    fetch('/api/report', { headers: { 'X-Token': TOKEN } }).then(function (r) { return r.blob(); }).then(function (b) {
      var a = h('a', { href: URL.createObjectURL(b), download: 'cs2-recorder-report.zip' }); document.body.appendChild(a); a.click(); a.remove();
    });
  }
  function saveState() { api('POST', '/api/state', { state: S.o }); }
  function opts() {
    var o = S.o; return {
      width: +o.width, height: +o.height, fps: +o.fps, layers: o.layers, camOn: o.camOn, camFps: +o.camFps, fov: +o.fov, camDist: +o.camDist,
      camLayers: o.camLayers, before: +o.before, after: +o.after, join: +o.join, outDir: o.outDir, accountId: o.accountId, accountKind: o.accountKind
    };
  }
  function selTicks() { return S.kills.filter(function (k) { return S.sel[k.tick]; }).map(function (k) { return k.tick; }); }
  function payload() { var p = opts(); p.ticks = selTicks(); p.steamid = S.player ? S.player.steamid : ''; p.playerName = S.player ? S.player.name : ''; return p; }

  // ---------- navigation
  function go(n) {
    S.screen = n; clearError();
    for (var i = 1; i <= 4; i++) $('s' + i).hidden = (i !== n);
    [].forEach.call($('steps').children, function (li) {
      var s = +li.getAttribute('data-s'); li.className = s === n ? 'cur' : (s < n ? 'done' : '');
      if (s === n) li.setAttribute('aria-current', 'step'); else li.removeAttribute('aria-current');
    });
    if (S.polling) { clearInterval(S.polling); S.polling = null; }
    ({ 1: renderSetup, 2: renderPick, 3: renderRecord, 4: renderDone })[n]();
    $('main').focus();
  }

  // ---------- 1 Setup
  function renderSetup() {
    var el = $('s1'); el.textContent = '';
    el.appendChild(h('h1', { id: 'h1', text: 'Get ready' }));
    el.appendChild(h('p', { class: 'muted', text: 'One button installs what is missing. The first time takes about 20-30 minutes, mostly downloads.' }));
    var list = h('ul', { class: 'items', id: 'checkList' });
    var bar = h('div', { class: 'bar', role: 'progressbar', 'aria-valuemin': 0, 'aria-valuemax': 100 }, [h('i', { id: 'setupBar' })]);
    var msg = h('div', { class: 'mono muted', id: 'setupMsg', 'aria-live': 'polite' });
    bar.hidden = true;
    var btn = h('button', { class: 'primary big', id: 'setupBtn', type: 'button', text: 'Set up everything', onclick: function () { startSetup(''); } });
    var again = h('button', { type: 'button', text: 'Check again', onclick: loadChecks });
    var next = h('button', { class: 'primary big', id: 'setupNext', type: 'button', text: 'Continue', hidden: true, onclick: function () { go(2); } });
    el.appendChild(h('div', { class: 'panel' }, [list, bar, msg, h('div', { class: 'row' }, [btn, again, next])]));
    loadChecks();
  }
  function paintChecks(checks) {
    var list = $('checkList'); if (!list) return; list.textContent = '';
    var all = true, fixable = false;
    (checks || []).forEach(function (c) {
      if (c.status !== 'ok') all = false;
      if (c.status === 'fixable') fixable = true;
      var d = h('div', { class: 'd', text: c.detail || '' });
      var li = h('li', {}, [h('span', { class: 'dot ' + c.status, title: c.status }), h('div', { class: 'grow' }, [h('div', { class: 't', text: c.label || c.id }), d])]);
      if (c.fixId && c.status !== 'ok') li.appendChild(h('button', { type: 'button', text: 'Fix it', onclick: function () { startSetup(c.fixId); } }));
      list.appendChild(li);
    });
    S.setupOk = all && (checks || []).length > 0;
    $('setupNext').hidden = !S.setupOk; $('setupBtn').hidden = S.setupOk;
    $('setupBtn').textContent = fixable ? 'Set up everything' : 'Try setup';
  }
  function loadChecks() {
    api('GET', '/api/check').then(function (r) {
      if (!r.ok) { showError(r.error); paintChecks([]); return; }
      clearError(); paintChecks(r.checks);
    });
  }
  function startSetup(fixId) {
    $('setupBtn').disabled = true;
    api('POST', '/api/setup/start', { fixId: fixId }).then(function (r) {
      if (!r.ok) { $('setupBtn').disabled = false; showError(r.error); return; }
      var bar = document.querySelector('#s1 .bar'); bar.hidden = false;
      var t = setInterval(function () {
        api('GET', '/api/setup/status').then(function (s) {
          if (!s.ok) { clearInterval(t); showError(s.error); return; }
          $('setupBar').style.width = (s.pct || 0) + '%'; bar.setAttribute('aria-valuenow', s.pct || 0);
          $('setupMsg').textContent = s.msg || '';
          if (s.done && !s.running) {
            clearInterval(t); $('setupBtn').disabled = false; bar.hidden = true; $('setupMsg').textContent = '';
            if (s.error) showError(s.error);
            if (s.checks && s.checks.length) paintChecks(s.checks); else loadChecks();
          }
        });
      }, 700);
    });
  }

  // ---------- 2 Pick
  function renderPick() {
    var el = $('s2'); el.textContent = '';
    el.appendChild(h('h1', { id: 'h2', text: 'Pick your frags' }));
    // demo
    var path = h('input', { type: 'text', class: 'mono', id: 'demoPath', placeholder: 'Paste the full path to the demo, e.g. C:\\Users\\you\\Downloads\\match.dem', value: S.demoPath, 'aria-label': 'Demo file path' });
    var drop = h('div', { class: 'drop', id: 'drop', tabindex: 0, role: 'button', 'aria-label': 'Drop a demo file here or press Enter to browse' }, [h('div', { text: 'Drop your demo file here' }), h('div', { class: 'faint', text: 'or press Browse' })]);
    drop.addEventListener('dragover', function (e) { e.preventDefault(); drop.classList.add('over'); });
    drop.addEventListener('dragleave', function () { drop.classList.remove('over'); });
    drop.addEventListener('drop', function (e) {
      e.preventDefault(); drop.classList.remove('over');
      var f = e.dataTransfer.files && e.dataTransfer.files[0]; if (!f) return;
      api('POST', '/api/find', { name: f.name }).then(function (r) {
        if (r.paths && r.paths.length === 1) { path.value = r.paths[0]; loadDemo(); }
        else { showError('Browsers do not tell apps where a dropped file lives' + (r.paths && r.paths.length ? ' and I found several files named ' + f.name + '.' : ' and I could not find ' + f.name + ' in Downloads, Desktop or Documents.') + ' Press Browse and choose it, or paste its path below.'); }
      });
    });
    drop.addEventListener('keydown', function (e) { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); browseDemo(); } });
    var browse = h('button', { type: 'button', text: 'Browse...', onclick: browseDemo });
    var load = h('button', { class: 'primary', type: 'button', text: 'Read demo', onclick: loadDemo });
    path.addEventListener('keydown', function (e) { if (e.key === 'Enter') loadDemo(); });
    function browseDemo() { api('POST', '/api/browse', { kind: 'file' }).then(function (r) { if (!r.ok) return showError(r.error); if (r.path) { path.value = r.path; loadDemo(); } }); }
    function loadDemo() {
      var p = path.value.trim(); if (!p) return showError('Choose a demo first.');
      S.demoPath = p; clearError(); setBusy('demoMsg', 'Reading the demo. Big demos take up to a minute...');
      api('POST', '/api/demo', { path: p }).then(function (r) {
        if (!r.ok) { setBusy('demoMsg', ''); return showError(r.error); }
        job(r.job).then(function (d) {
          setBusy('demoMsg', '');
          if (!d.ok) return showError(d.error || 'That file could not be read as a CS2 demo.');
          S.players = d.players || []; S.player = null; S.kills = []; S.sel = {};
          $('demoMsg').textContent = 'Map ' + d.map + ', ' + S.players.length + ' players.';
          paintPlayers(); paintKills(); updateAll();
        });
      });
    }
    el.appendChild(h('div', { class: 'panel' }, [h('h2', {}, [h('span', { class: 'num', text: '1' }), 'Demo']), drop,
      h('div', { class: 'row', style: 'margin-top:10px' }, [h('div', { class: 'grow' }, [path]), browse, load]), h('div', { class: 'mono muted', id: 'demoMsg', 'aria-live': 'polite' })]));
    // player + kills
    el.appendChild(h('div', { class: 'panel', id: 'killPanel' }, [h('h2', {}, [h('span', { class: 'num', text: '2' }), 'Player and kills']),
      h('div', { id: 'playerBox' }), h('div', { id: 'chipBox', class: 'row', style: 'margin:10px 0' }), h('div', { id: 'killBox' })]));
    // options
    el.appendChild(optionsPanel());
    // summary
    el.appendChild(h('div', { class: 'panel' }, [h('h2', {}, [h('span', { class: 'num', text: '4' }), 'Result']),
      h('div', { id: 'clipInfo', class: 'muted' }), h('div', { id: 'estimate', class: 'est', 'aria-live': 'polite' }),
      h('div', { class: 'row', style: 'margin-top:12px' }, [h('button', { class: 'primary big', id: 'toRecord', type: 'button', text: 'Continue to recording', disabled: true, onclick: function () { go(3); } }), h('span', { class: 'muted', id: 'whyNot' })])]));
    paintPlayers(); paintKills(); loadAccounts(); updateAll();
  }
  function setBusy(id, t) { var e = $(id); if (e) e.textContent = t; }
  function paintPlayers() {
    var box = $('playerBox'); if (!box) return; box.textContent = '';
    if (!S.players.length) { box.appendChild(h('p', { class: 'muted', text: 'Read a demo first, then choose the player whose kills you want.' })); return; }
    var sel = h('select', { id: 'playerSel', 'aria-label': 'Player' }, [h('option', { value: '', text: 'Choose a player...' })].concat(S.players.map(function (p) {
      return h('option', { value: p.steamid, text: p.name + '  (' + p.kills + ' kills)', selected: S.player && S.player.steamid === p.steamid });
    })));
    sel.addEventListener('change', function () {
      S.player = S.players.filter(function (p) { return p.steamid === sel.value; })[0] || null; S.kills = []; S.sel = {}; S.presets = [];
      paintKills(); updateAll(); if (S.player) loadKills();
    });
    box.appendChild(sel);
  }
  function loadKills() {
    setBusy('killBox', 'Finding kills...');
    api('POST', '/api/kills', { steamid: S.player.steamid }).then(function (r) {
      if (!r.ok) { paintKills(); return showError(r.error); }
      job(r.job).then(function (k) {
        if (!k.ok) { paintKills(); return showError(k.error || 'Could not read kills.'); }
        S.kills = k.kills || []; S.sel = {}; S.presets = localPresets(); paintKills(); updateAll();
        api('POST', '/api/presets', { steamid: S.player.steamid }).then(function (p) {
          if (!p.ok) return; job(p.job).then(function (pp) { if (pp.ok && pp.presets && pp.presets.length) { S.presets = pp.presets; paintKills(); } });
        });
      });
    });
  }
  function localPresets() {
    var byRound = {}; S.kills.forEach(function (k) { (byRound[k.round] = byRound[k.round] || []).push(k); });
    function ticks(f) { var t = []; for (var r in byRound) if (f(byRound[r])) byRound[r].forEach(function (k) { t.push(k.tick); }); return t; }
    var best = null; for (var r in byRound) if (!best || byRound[r].length > byRound[best].length) best = r;
    var p = [{ id: 'all', label: 'All kills', kill_ticks: S.kills.map(function (k) { return k.tick; }) },
      { id: 'multikills', label: 'Multikills (3+)', kill_ticks: ticks(function (a) { return a.length >= 3; }) },
      { id: 'aces', label: 'Aces', kill_ticks: ticks(function (a) { return a.length >= 5; }) },
      { id: 'headshots', label: 'Headshots', kill_ticks: S.kills.filter(function (k) { return k.headshot; }).map(function (k) { return k.tick; }) }];
    if (best) p.splice(3, 0, { id: 'best_round', label: 'Best round', kill_ticks: byRound[best].map(function (k) { return k.tick; }) });
    return p;
  }
  function paintKills() {
    var chips = $('chipBox'), box = $('killBox'); if (!chips) return; chips.textContent = ''; box.textContent = '';
    if (!S.kills.length) { if (S.player) box.appendChild(h('p', { class: 'muted', text: 'No kills yet.' })); return; }
    S.presets.forEach(function (p) {
      var on = S.preset === p.id;
      chips.appendChild(h('button', { type: 'button', class: 'chip' + (on ? ' on' : ''), 'aria-pressed': on, text: p.label + ' (' + p.kill_ticks.length + ')', onclick: function () {
        S.sel = {}; if (S.preset !== p.id) { p.kill_ticks.forEach(function (t) { S.sel[t] = true; }); S.preset = p.id; } else S.preset = '';
        paintKills(); updateAll();
      } }));
    });
    chips.appendChild(h('button', { type: 'button', class: 'chip', text: 'Clear', onclick: function () { S.sel = {}; S.preset = ''; paintKills(); updateAll(); } }));
    var list = h('div', { class: 'kills', role: 'group', 'aria-label': 'Kills' });
    S.kills.forEach(function (k) {
      var cb = h('input', { type: 'checkbox', checked: !!S.sel[k.tick], 'aria-label': 'Round ' + k.round + ' ' + k.weapon + ' on ' + k.victim });
      var row = h('label', { class: 'kill' + (S.sel[k.tick] ? ' sel' : ''), style: 'margin:0;color:inherit' }, [cb, h('span', { class: 'r', text: 'Rd ' + k.round }), h('span', { class: 'w', text: k.weapon }), h('span', { text: k.victim }),
        h('span', { class: 'grow' })].concat(['headshot:HS', 'smoke:smoke', 'noscope:noscope', 'wallbang:wall', 'blind:blind'].filter(function (t) { return k[t.split(':')[0]]; }).map(function (t) { return h('span', { class: 'tag', text: t.split(':')[1] }); })));
      cb.addEventListener('change', function () { if (cb.checked) S.sel[k.tick] = true; else delete S.sel[k.tick]; S.preset = ''; row.classList.toggle('sel', cb.checked); updateAll(); });
      list.appendChild(row);
    });
    box.appendChild(list);
  }
  function optionsPanel() {
    var o = S.o;
    function num(id, label, key, min, max) { return h('div', {}, [h('label', { for: id, text: label }), h('input', { type: 'number', id: id, min: min, max: max, value: o[key], onchange: function (e) { o[key] = +e.target.value; saveState(); updateAll(); } })]); }
    var layerBox = h('div', {}, LAYERS.map(function (l) {
      var cb = h('input', { type: 'checkbox', id: 'ly_' + l.k, checked: o.layers.indexOf(l.k) >= 0 });
      cb.addEventListener('change', function () { o.layers = LAYERS.map(function (x) { return x.k; }).filter(function (k) { return $('ly_' + k).checked; }); saveState(); updateAll(); });
      return h('div', { class: 'layer' }, [cb, h('label', { for: 'ly_' + l.k, style: 'margin:0;color:var(--text)' }, [l.n, h('div', { class: 'd', text: l.d })])]);
    }));
    var accSel = h('select', { id: 'accSel', 'aria-label': 'Steam account to record on' });
    accSel.addEventListener('change', function () { o.accountId = accSel.value; saveState(); updateAll(); });
    var kind = h('select', { id: 'accKind', 'aria-label': 'Account type' }, [h('option', { value: 'separate', text: 'This is a separate account (safe to record on)' }), h('option', { value: 'main', text: 'This is my main account' })]);
    kind.value = o.accountKind;
    kind.addEventListener('change', function () { o.accountKind = kind.value; saveState(); updateAll(); });
    var out = h('input', { type: 'text', class: 'mono', id: 'outDir', value: o.outDir, 'aria-label': 'Output folder', onchange: function (e) { o.outDir = e.target.value.trim(); saveState(); updateAll(); } });
    var cam = h('input', { type: 'checkbox', id: 'camOn', checked: o.camOn, onchange: function (e) { o.camOn = e.target.checked; saveState(); updateAll(); } });
    return h('div', { class: 'panel' }, [h('h2', {}, [h('span', { class: 'num', text: '3' }), 'Settings']),
      h('div', { class: 'grid' }, [h('div', {}, [h('label', { for: 'accSel', text: 'Steam account to record on' }), accSel]), h('div', {}, [h('label', { for: 'accKind', text: 'Account type' }), kind])]),
      h('p', { class: 'faint', style: 'margin-top:8px', text: 'Recording on your main account is blocked, because CS2 is started with -insecure. Use a separate account.' }),
      h('div', { style: 'margin:12px 0' }, [h('label', { for: 'outDir', text: 'Where to save recordings' }), h('div', { class: 'row' }, [h('div', { class: 'grow' }, [out]),
        h('button', { type: 'button', text: 'Browse...', onclick: function () { api('POST', '/api/browse', { kind: 'folder', start: out.value }).then(function (r) { if (r.path) { out.value = r.path; o.outDir = r.path; saveState(); updateAll(); } }); } })])]),
      h('details', {}, [h('summary', { text: 'Layers, quality and timing' }),
        h('div', { class: 'grid' }, [num('width', 'Width', 'width', 320, 7680), num('height', 'Height', 'height', 240, 4320), num('fps', 'Frames per second', 'fps', 10, 480),
          num('before', 'Seconds before first kill', 'before', 0, 30), num('after', 'Seconds after last kill', 'after', 0, 30), num('join', 'Join kills closer than (s)', 'join', 0, 60)]),
        h('h3', { style: 'margin-top:14px', text: 'Layers' }), layerBox,
        h('div', { class: 'row', style: 'margin-top:10px' }, [cam, h('label', { for: 'camOn', style: 'margin:0;color:var(--text)', text: 'Also record a cinematic third-person camera shot' })])])]);
  }
  function loadAccounts() {
    api('GET', '/api/accounts').then(function (r) {
      var sel = $('accSel'); if (!sel) return; sel.textContent = '';
      var acc = (r.accounts || []);
      sel.appendChild(h('option', { value: '', text: acc.length ? 'Choose an account...' : 'No Steam accounts found (open Steam once and log in)' }));
      acc.forEach(function (a) { sel.appendChild(h('option', { value: a.id, text: (a.persona || a.account) + ' (' + a.account + ')' + (a.recent ? ' - last used' : '') })); });
      sel.value = S.o.accountId; if (sel.value !== S.o.accountId) { S.o.accountId = ''; }
      updateAll();
    });
  }
  var estTimer = null;
  function updateAll() {
    clearTimeout(estTimer); estTimer = setTimeout(doEstimate, 150);
    var n = selTicks().length, why = [];
    if (!S.demoPath || !S.players.length) why.push('read a demo'); else if (!S.player) why.push('choose a player'); else if (!n) why.push('pick at least one kill');
    if (!S.o.accountId) why.push('choose a Steam account'); else if (S.o.accountKind !== 'separate') why.push('use a separate (not main) account');
    if (!S.o.outDir) why.push('choose an output folder');
    if (!S.o.layers.length) why.push('pick a layer');
    var b = $('toRecord'); if (b) { b.disabled = why.length > 0; $('whyNot').textContent = why.length ? 'To continue: ' + why.join(', ') + '.' : ''; }
  }
  function doEstimate() {
    var est = $('estimate'); if (!est) return;
    var p = payload();
    if (!p.ticks.length) { $('clipInfo').textContent = 'Nothing selected yet.'; est.textContent = ''; return; }
    api('POST', '/api/clips', p).then(function (c) {
      if (c.ok) $('clipInfo').textContent = c.clips.length + ' clip' + (c.clips.length === 1 ? '' : 's') + ': ' + c.clips.map(function (x) { return 'round ' + x.round + ' (' + x.kills + 'k, ' + x.seconds + 's)'; }).join('; ');
    });
    api('POST', '/api/estimate', p).then(function (e) {
      if (!e.ok) { est.textContent = ''; return; }
      var t = e.seconds + ' s of footage, about ' + e.size_gb + ' GB, roughly ' + e.minutes + ' minutes to record.';
      if (e.free_gb != null) t += ' Free space: ' + e.free_gb + ' GB.';
      var bad = e.pathError || '';
      est.className = 'est' + (bad ? ' bad' : (e.free_gb != null && e.free_gb < e.size_gb * 1.2 ? ' warn' : ''));
      est.textContent = t + (bad ? ' ' + bad : '');
    });
  }

  // ---------- 3 Record
  function renderRecord() {
    var el = $('s3'); el.textContent = '';
    el.appendChild(h('h1', { id: 'h3', text: 'Safety checks and recording' }));
    var list = h('ul', { class: 'items', id: 'pfList' });
    var ack = h('input', { type: 'checkbox', id: 'ack', onchange: function (e) { S.ack = e.target.checked; paintPf(); } });
    el.appendChild(h('div', { class: 'panel', id: 'pfPanel' }, [h('h2', { text: 'Before we start' }), list,
      h('div', { class: 'row', id: 'ackRow', hidden: true }, [ack, h('label', { for: 'ack', style: 'margin:0;color:var(--text)', text: 'I have read the warnings and want to continue' })]),
      h('div', { class: 'row', style: 'margin-top:12px' }, [h('button', { type: 'button', text: 'Check again', onclick: runPreflight }),
        h('button', { class: 'primary big', id: 'recBtn', type: 'button', text: 'Start recording', disabled: true, onclick: startRecord }),
        h('button', { type: 'button', text: 'Back', onclick: function () { go(2); } })]),
      h('p', { class: 'muted', style: 'margin-top:12px', text: 'Once it starts, CS2 opens and records by itself. Do not touch the keyboard or mouse until it says Done.' })]));
    el.appendChild(h('div', { class: 'panel', id: 'runPanel', hidden: true }, [h('h2', { text: 'Recording' }), h('div', { class: 'bar', role: 'progressbar', 'aria-valuemin': 0, 'aria-valuemax': 100 }, [h('i', { id: 'runBar' })]),
      h('div', { id: 'runMsg', class: 'mono', 'aria-live': 'polite' }), h('div', { id: 'runSafe', class: 'mono muted' }),
      h('div', { class: 'row', style: 'margin-top:10px' }, [h('button', { class: 'danger', type: 'button', text: 'Stop', onclick: function () { if (confirm('Stop recording now? The clips done so far are kept.')) api('POST', '/api/record/stop', {}).then(function (r) { if (!r.ok) showError(r.error); }); } })])]));
    S.ack = false; runPreflight();
    api('GET', '/api/record/status').then(function (r) { if (r.ok && isRunning(r.status)) watchRun(); });
  }
  function runPreflight() {
    S.pf = null; paintPf();
    api('POST', '/api/preflight', payload()).then(function (r) {
      if (!r.ok) { showError(r.error); S.pf = { blocking: true, checks: [{ id: 'internal', status: 'block', label: 'Safety checks could not run', detail: r.error }] }; }
      else S.pf = r;
      paintPf();
    });
  }
  function paintPf() {
    var list = $('pfList'); if (!list) return; list.textContent = '';
    if (!S.pf) { list.appendChild(h('li', {}, [h('span', { class: 'dot' }), h('div', { class: 'muted', text: 'Checking...' })])); $('recBtn').disabled = true; return; }
    var warns = 0;
    S.pf.checks.forEach(function (c) { if (c.status === 'warn') warns++; list.appendChild(h('li', {}, [h('span', { class: 'dot ' + c.status, title: c.status }), h('div', {}, [h('div', { class: 't', text: c.label }), h('div', { class: 'd', text: c.detail || '' })])])); });
    $('ackRow').hidden = warns === 0;
    $('recBtn').disabled = !!S.pf.blocking || (warns > 0 && !S.ack);
  }
  function startRecord() {
    $('recBtn').disabled = true;
    api('POST', '/api/record/start', payload()).then(function (r) {
      if (!r.ok) { $('recBtn').disabled = false; return showError(r.error); }
      watchRun();
    });
  }
  function norm(s) {
    s = s || {}; var st = String(s.state || s.phase || s.status || '').toLowerCase();
    return {
      state: st, pct: +(s.pct != null ? s.pct : (s.percent != null ? s.percent : (s.progress != null ? s.progress : 0))) || 0,
      msg: s.message || s.msg || s.step || s.text || '', err: s.error || s.failed || '', safe: s.safety || s.insecure || (s.insecureOk === true ? 'Safety check: -insecure OK' : ''),
      done: s.done === true || s.finished === true || st === 'done' || st === 'finished' || st === 'complete' || st === 'completed',
      failed: st === 'failed' || st === 'error' || (!!s.error && st !== 'running')
    };
  }
  function isRunning(s) { var n = norm(s); return !n.done && !n.failed && (n.state === 'running' || n.state === 'starting' || n.state === 'recording' || s && s.running === true); }
  function watchRun() {
    $('pfPanel').hidden = true; $('runPanel').hidden = false;
    if (S.polling) clearInterval(S.polling);
    S.polling = setInterval(function () {
      api('GET', '/api/record/status').then(function (r) {
        if (!r.ok) { clearInterval(S.polling); S.polling = null; return showError(r.error); }
        var n = norm(r.status); S.outDir = r.outDir || S.o.outDir;
        $('runBar').style.width = Math.max(0, Math.min(100, n.pct)) + '%'; $('runMsg').textContent = n.msg || 'Working...';
        $('runSafe').textContent = typeof n.safe === 'string' ? n.safe : (n.safe ? 'Safety: -insecure check active' : '');
        if (n.failed) { clearInterval(S.polling); S.polling = null; $('pfPanel').hidden = false; $('runPanel').hidden = true; $('recBtn').disabled = false; showError(String(n.err || n.msg || 'Recording failed.')); }
        else if (n.done) { clearInterval(S.polling); S.polling = null; go(4); }
      });
    }, 1000);
  }

  // ---------- 4 Done
  function renderDone() {
    var el = $('s4'); el.textContent = '';
    el.appendChild(h('h1', { id: 'h4', text: 'Done' }));
    el.appendChild(h('div', { class: 'panel' }, [h('p', { text: 'Your clips are saved here:' }), h('p', { class: 'mono', text: S.outDir || S.o.outDir }),
      h('div', { class: 'row' }, [h('button', { class: 'primary big', type: 'button', text: 'Open folder', onclick: function () { api('POST', '/api/open', { what: 'folder' }).then(function (r) { if (!r.ok) showError(r.error); }); } }),
        h('button', { type: 'button', text: 'Open RESULT.txt', onclick: function () { api('POST', '/api/open', { what: 'result' }).then(function (r) { if (!r.ok) showError(r.error); }); } }),
        h('button', { type: 'button', text: 'Record more', onclick: function () { S.sel = {}; S.preset = ''; go(2); } })])]));
  }

  // ---------- boot
  $('copyReport').addEventListener('click', copyReport);
  $('saveReport').addEventListener('click', saveReport);
  setInterval(function () { api('GET', '/api/ping'); }, 5000);
  api('GET', '/api/state').then(function (r) {
    if (r.state) { for (var k in r.state) if (k in DEF) S.o[k] = r.state[k]; }
    if (!S.o.outDir) S.o.outDir = 'C:\\cs2-recorder\\recordings';
    go(1);
    api('GET', '/api/check').then(function (c) { if (c.ok && c.allOk) go(2); });
  });
})();
