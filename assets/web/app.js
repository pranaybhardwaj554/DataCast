/* DataCast web UI: device list, PIN, file browser and preview.
 * Plain JS, no build step. Talks to the phone's own HTTP server:
 *   GET  /api/info                -> {name, deviceId, platform, requiresPin, allowZip?}
 *   GET  /api/devices             -> [{name, deviceId, ip, port, platform, self?}]
 *   POST /api/auth {pin}          -> {token} (+ HttpOnly cookie dc_token)
 *                                   401 {error, attemptsLeft} | 429 {error, retryAfterSec}
 *   GET  /api/files?path=/x       -> {path, entries:[{name, path, isDir, size, modified, mime}]}
 *   GET  /api/download?path=      (attachment)
 *   GET  /api/raw?path=           (inline, Range)
 *   GET  /api/zip?path=           (folder as zip, when allowZip)
 */
(function () {
  'use strict';

  var TOKEN_KEY = 'dc_token';
  var VIEW_KEY = 'dc_view';
  var state = {
    info: null,
    path: '/',
    entries: [],
    query: '',
    layout: safeGet(VIEW_KEY) || 'list',
    previewList: [],
    previewIndex: -1,
    devicesTimer: null,
    lockedUntil: 0
  };

  var $ = function (id) { return document.getElementById(id); };

  // ---------- storage (may be unavailable in private modes) ----------
  function safeGet(k) { try { return sessionStorage.getItem(k) || localStorage.getItem(k); } catch (e) { return null; } }
  function safeSet(k, v) { try { if (k === TOKEN_KEY) sessionStorage.setItem(k, v); else localStorage.setItem(k, v); } catch (e) {} }
  function safeDel(k) { try { sessionStorage.removeItem(k); } catch (e) {} }

  // ---------- API ----------
  function api(url, opts) {
    opts = opts || {};
    var headers = opts.headers || {};
    var token = safeGet(TOKEN_KEY);
    if (token) headers['Authorization'] = 'Bearer ' + token;
    if (opts.json !== undefined) {
      headers['Content-Type'] = 'application/json';
      opts.body = JSON.stringify(opts.json);
    }
    return fetch(url, { method: opts.method || 'GET', headers: headers, body: opts.body, credentials: 'same-origin', cache: 'no-store' })
      .then(function (res) {
        return res.text().then(function (text) {
          var data = null;
          try { data = text ? JSON.parse(text) : null; } catch (e) { data = { raw: text }; }
          return { ok: res.ok, status: res.status, data: data || {} };
        });
      });
  }
  function q(path) { return encodeURIComponent(path); }

  // Automatic redirects replace the current history entry, so Back never
  // bounces into a page the app sent you to. Only user clicks push history.
  function redirect(hash) { location.replace(hash); }

  // Ends this browser's session on the phone so its "connected" count drops
  // straight away. Fire and forget; the cookie goes with the beacon, the
  // Bearer token with the keepalive fetch.
  function signOut() {
    var token = safeGet(TOKEN_KEY);
    safeDel(TOKEN_KEY);
    try {
      if (token && window.fetch) {
        fetch('/api/logout', { method: 'POST', keepalive: true, credentials: 'same-origin', headers: { Authorization: 'Bearer ' + token } }).catch(function () {});
      } else if (navigator.sendBeacon) {
        navigator.sendBeacon('/api/logout');
      }
    } catch (e) {}
  }
  function rawUrl(p) { return '/api/raw?path=' + q(p); }
  function downloadUrl(p) { return '/api/download?path=' + q(p); }
  function zipUrl(p) { return '/api/zip?path=' + q(p); }
  function canZip() { return !!(state.info && state.info.allowZip); }

  // ---------- helpers ----------
  function el(tag, attrs, children) {
    var n = document.createElement(tag);
    if (attrs) Object.keys(attrs).forEach(function (k) {
      var v = attrs[k];
      if (v == null || v === false) return;
      if (k === 'class') n.className = v;
      else if (k === 'text') n.textContent = v;
      else if (k.indexOf('on') === 0) n.addEventListener(k.slice(2), v);
      else n.setAttribute(k, v === true ? '' : v);
    });
    (children || []).forEach(function (c) { if (c != null) n.appendChild(typeof c === 'string' ? document.createTextNode(c) : c); });
    return n;
  }
  // Static, trusted icon markup only.
  var ICONS = {
    dir: '<path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/>',
    img: '<rect x="3" y="4" width="18" height="16" rx="2"/><circle cx="9" cy="10" r="1.6"/><path d="m21 16-5-5-9 9"/>',
    vid: '<rect x="3" y="5" width="13" height="14" rx="2"/><path d="m16 10 5-3v10l-5-3z"/>',
    aud: '<path d="M9 18V5l12-2v13"/><circle cx="6" cy="18" r="3"/><circle cx="18" cy="16" r="3"/>',
    doc: '<path d="M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8z"/><path d="M14 3v5h5"/>',
    download: '<path d="M12 3v12"/><path d="m7 10 5 5 5-5"/><path d="M5 21h14"/>',
    phone: '<rect x="6" y="2.5" width="12" height="19" rx="2.5"/><path d="M11 18.5h2"/>',
    tablet: '<rect x="4" y="2.5" width="16" height="19" rx="2.5"/><path d="M11 18.5h2"/>',
    lock: '<rect x="5" y="11" width="14" height="10" rx="2"/><path d="M8 11V8a4 4 0 0 1 8 0v3"/>'
  };
  function icon(name, size) {
    var s = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
    s.setAttribute('width', size || 18); s.setAttribute('height', size || 18);
    s.setAttribute('viewBox', '0 0 24 24'); s.setAttribute('fill', 'none');
    s.setAttribute('stroke', 'currentColor'); s.setAttribute('stroke-width', '1.8');
    s.setAttribute('stroke-linecap', 'round'); s.setAttribute('stroke-linejoin', 'round');
    s.setAttribute('aria-hidden', 'true');
    s.innerHTML = ICONS[name];
    return s;
  }
  function fmtSize(b) {
    if (b == null || b < 0) return '—';
    var u = ['B', 'KB', 'MB', 'GB', 'TB'], i = 0;
    while (b >= 1024 && i < u.length - 1) { b /= 1024; i++; }
    return (i === 0 ? b : b.toFixed(b < 10 ? 1 : 0)) + ' ' + u[i];
  }
  function fmtDate(v) {
    if (!v) return '—';
    var d = new Date(typeof v === 'number' && v < 1e12 ? v * 1000 : v);
    if (isNaN(d)) return '—';
    var now = new Date();
    var opts = { month: 'short', day: 'numeric' };
    if (d.getFullYear() !== now.getFullYear()) opts.year = 'numeric';
    else { opts.hour = '2-digit'; opts.minute = '2-digit'; }
    return d.toLocaleString(undefined, opts);
  }
  var EXT = {
    img: ['jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'svg', 'heic', 'avif'],
    vid: ['mp4', 'webm', 'mov', 'm4v', 'mkv', '3gp'],
    aud: ['mp3', 'm4a', 'aac', 'wav', 'ogg', 'flac', 'opus'],
    pdf: ['pdf'],
    txt: ['txt', 'md', 'csv', 'json', 'log', 'xml', 'yaml', 'yml', 'js', 'css', 'html', 'dart', 'py', 'srt']
  };
  function kindOf(e) {
    if (e.isDir) return 'dir';
    var m = e.mime || '';
    var ext = (e.name.split('.').pop() || '').toLowerCase();
    if (m.indexOf('image/') === 0 || EXT.img.indexOf(ext) >= 0) return 'img';
    if (m.indexOf('video/') === 0 || EXT.vid.indexOf(ext) >= 0) return 'vid';
    if (m.indexOf('audio/') === 0 || EXT.aud.indexOf(ext) >= 0) return 'aud';
    if (m === 'application/pdf' || ext === 'pdf') return 'pdf';
    if (m.indexOf('text/') === 0 || EXT.txt.indexOf(ext) >= 0) return 'txt';
    return 'other';
  }
  function iconKind(k) { return k === 'pdf' || k === 'txt' || k === 'other' ? 'doc' : k; }
  function joinPath(dir, name) { return (dir === '/' ? '' : dir) + '/' + name; }
  function entryPath(e) { return e.path || joinPath(state.path, e.name); }

  var reduceMotion = window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  // Hides an element after its CSS exit animation (class "leaving") ends.
  function hideAfterLeave(node, ms) {
    if (node.hidden) return;
    if (reduceMotion) { node.hidden = true; return; }
    node.classList.add('leaving');
    clearTimeout(node._leaveTimer);
    node._leaveTimer = setTimeout(function () { node.hidden = true; node.classList.remove('leaving'); }, ms || 180);
  }
  function unhide(node) {
    clearTimeout(node._leaveTimer);
    node.classList.remove('leaving');
    node.hidden = false;
  }

  var toastTimer;
  function toast(msg) {
    var t = $('toast'); t.textContent = msg; unhide(t);
    clearTimeout(toastTimer); toastTimer = setTimeout(function () { hideAfterLeave(t, 200); }, 3200);
  }

  // ---------- views ----------
  var VIEWS = ['view-devices', 'view-pin', 'view-files', 'view-message'];
  var currentView = null;
  // Page changes swap synchronously; the entrance is a plain CSS animation.
  // (The View Transitions API was dropped: Safari could leave the old page's
  // snapshot on screen, so links like "All devices" looked dead.)
  function show(id) { swapView(id); }
  function swapView(id) {
    currentView = id;
    VIEWS.forEach(function (v) { $(v).hidden = v !== id; });
    if (id !== 'view-devices' && state.devicesTimer) { clearInterval(state.devicesTimer); state.devicesTimer = null; }
    $('switch-device').hidden = id !== 'view-files';
    $('brand-status').hidden = id !== 'view-files';
    window.scrollTo(0, 0);
    // Focus can only land once the view is visible (the swap may run late
    // inside a view transition).
    if (id === 'view-pin') { var first = document.querySelector('.pin-inputs input'); if (first && !first.disabled) first.focus(); }
  }
  function message(title, body, retry) {
    $('msg-title').textContent = title;
    $('msg-body').textContent = body;
    $('msg-retry').onclick = retry || function () { location.reload(); };
    closePreview(true);
    show('view-message');
  }
  // ---------- connection watch ----------
  // Polls /api/info. When the phone goes away we show a "Reconnecting" bar
  // and keep the page as it is; if it comes back we carry on in place. After
  // GIVE_UP_MS without it we switch to the "Sharing stopped" page, and still
  // reload automatically if the phone reappears.
  var BEAT_MS = 5000, LOST_BEAT_MS = 2000, GIVE_UP_MS = 30000, PING_TIMEOUT_MS = 4000;
  var conn = { lostAt: 0, stopped: false, timer: null, deviceId: null };

  function ping() {
    var ctl = window.AbortController ? new AbortController() : null;
    var t = setTimeout(function () { if (ctl) ctl.abort(); }, PING_TIMEOUT_MS);
    return fetch('/api/info', { cache: 'no-store', credentials: 'same-origin', signal: ctl ? ctl.signal : undefined })
      .then(function (r) { clearTimeout(t); if (!r.ok) throw new Error('status ' + r.status); return r.json(); },
            function (e) { clearTimeout(t); throw e; });
  }
  function scheduleBeat() {
    clearTimeout(conn.timer);
    conn.timer = setTimeout(beat, conn.lostAt ? LOST_BEAT_MS : BEAT_MS);
  }
  function beat() {
    if (document.hidden) { scheduleBeat(); return; }
    ping().then(function (info) {
      // Same address now answered by a different phone: start over.
      if (conn.deviceId && info.deviceId && info.deviceId !== conn.deviceId) { location.reload(); return; }
      if (info.deviceId) conn.deviceId = info.deviceId;
      if (conn.stopped) { location.reload(); return; }
      if (conn.lostAt) {
        conn.lostAt = 0;
        setLost(false);
        toast('Back online');
        if ($('preview').hidden && !$('view-files').hidden) openFiles(state.path);
      }
    }, markLost).then(scheduleBeat);
  }
  function setLost(on) {
    if (on) unhide($('conn-bar')); else hideAfterLeave($('conn-bar'), 200);
    var st = $('brand-status');
    st.classList.toggle('warn', on);
    $('brand-status-text').textContent = on ? 'Reconnecting…' : 'Connected';
  }
  function markLost() {
    if (conn.stopped) return;
    if (!conn.lostAt) { conn.lostAt = Date.now(); setLost(true); }
    var left = GIVE_UP_MS - (Date.now() - conn.lostAt);
    if (left <= 0) { showStopped(); return; }
    $('conn-detail').textContent = 'Retrying · ' + Math.ceil(left / 1000) + 's';
  }
  function showStopped() {
    conn.stopped = true;
    setLost(false);
    message('Sharing stopped', 'The phone left the Wi-Fi, was locked, or stopped sharing. This page reloads when it is back.', function () {
      ping().then(function () { location.reload(); }, function () { toast("Still can't reach the phone"); });
    });
  }
  // A request failed outright (network error): treat it as the phone going away.
  function offline() {
    if (!conn.deviceId) { showStopped(); scheduleBeat(); return; } // never reached it at all
    markLost();
    scheduleBeat();
  }
  document.addEventListener('visibilitychange', function () { if (!document.hidden) beat(); });

  // ---------- devices ----------
  function renderDevices(list, animate) {
    var grid = $('device-grid');
    grid.textContent = '';
    grid.classList.toggle('stagger', !!animate); // only on first load, not every refresh
    if (!list.length) {
      $('devices-count').textContent = 'Searching…';
      return;
    }
    $('devices-count').textContent = list.length + ' found';
    list.sort(function (a, b) { return (b.self ? 1 : 0) - (a.self ? 1 : 0) || String(a.name).localeCompare(b.name); });
    list.forEach(function (d) {
      var isTablet = /ipad|tablet/i.test(d.platform || '') || /ipad/i.test(d.name || '');
      var card = el('button', { type: 'button', class: 'device' + (d.self ? ' self' : ''), onclick: function () { pickDevice(d); } }, [
        el('div', { class: 'device-top' }, [
          el('span', { class: 'device-icon' }, [icon(isTablet ? 'tablet' : 'phone', 22)]),
          el('span', { class: 'stack-6', style: 'gap:2px;min-width:0' }, [
            el('span', { class: 'device-name', text: d.name || 'DataCast device' }),
            el('span', { class: 'device-sub', text: [d.platform, d.ip].filter(Boolean).join(' · ') })
          ])
        ]),
        el('div', { class: 'device-foot' }, [
          el('span', { class: 'device-lock' }, [icon('lock', 14), 'PIN required']),
          el('span', { class: 'tag', text: d.self ? 'This one' : 'Open' })
        ])
      ]);
      card.style.setProperty('--i', Math.min(grid.children.length, 12));
      grid.appendChild(card);
    });
  }
  function loadDevices(first) {
    if (first) {
      var grid = $('device-grid'); grid.textContent = '';
      for (var i = 0; i < 3; i++) grid.appendChild(el('div', { class: 'skeleton', 'aria-hidden': 'true' }));
    }
    return api('/api/devices').then(function (r) {
      if (!r.ok) throw new Error('devices');
      renderDevices(Array.isArray(r.data) ? r.data : (r.data.devices || []), first);
    }).catch(function () {
      if (first) offline();
    });
  }
  function pickDevice(d) {
    if (d.self) { location.hash = '#/pin'; return; }
    var host = String(d.ip).indexOf(':') >= 0 ? '[' + d.ip + ']' : d.ip;
    signOut();
    location.href = 'http://' + host + ':' + (d.port || 8080) + '/#/pin';
  }
  function openDevices() {
    show('view-devices');
    loadDevices(true);
    state.devicesTimer = setInterval(function () { loadDevices(false); }, 5000);
  }

  // ---------- PIN ----------
  var pinInputs = Array.prototype.slice.call(document.querySelectorAll('.pin-inputs input'));
  function pinValue() { return pinInputs.map(function (i) { return i.value; }).join(''); }
  function clearPin() { pinInputs.forEach(function (i) { i.value = ''; }); pinInputs[0].focus(); }
  function setPinError(msg) {
    var e = $('pin-error'), box = document.querySelector('.pin-inputs');
    e.textContent = msg || ''; e.hidden = !msg;
    box.classList.toggle('bad', !!msg);
    if (msg) { box.classList.remove('shake'); void box.offsetWidth; box.classList.add('shake'); }
  }
  pinInputs.forEach(function (input, i) {
    input.addEventListener('input', function () {
      var digits = input.value.replace(/\D/g, '');
      if (digits.length > 1) { // paste or autofill into one box
        digits.split('').slice(0, 4 - i).forEach(function (c, j) { pinInputs[i + j].value = c; });
      } else input.value = digits;
      setPinError('');
      var next = pinInputs[Math.min(i + digits.length, 3)];
      if (digits && next) next.focus();
      if (pinValue().length === 4) submitPin();
    });
    input.addEventListener('keydown', function (ev) {
      if (ev.key === 'Backspace' && !input.value && i > 0) { pinInputs[i - 1].focus(); pinInputs[i - 1].value = ''; }
      if (ev.key === 'ArrowLeft' && i > 0) pinInputs[i - 1].focus();
      if (ev.key === 'ArrowRight' && i < 3) pinInputs[i + 1].focus();
    });
    input.addEventListener('focus', function () { input.select(); });
  });
  var submitting = false;
  function submitPin(ev) {
    if (ev) ev.preventDefault();
    var pin = pinValue();
    if (submitting) return;
    if (Date.now() < state.lockedUntil) return;
    if (pin.length !== 4) { setPinError('Enter all 4 digits.'); return; }
    submitting = true; $('pin-submit').disabled = true;
    api('/api/auth', { method: 'POST', json: { pin: pin } }).then(function (r) {
      if (r.ok) {
        if (r.data.token) safeSet(TOKEN_KEY, r.data.token);
        redirect('#/files/');
        return;
      }
      if (r.status === 429) {
        var sec = r.data.retryAfterSec || 60;
        lockPin(sec);
      } else if (r.status === 401) {
        var left = r.data.attemptsLeft;
        setPinError("That PIN didn't match." + (left != null ? ' ' + left + (left === 1 ? ' try' : ' tries') + ' left.' : ''));
        clearPin();
      } else setPinError(r.data.error || 'Could not check the PIN. Try again.');
    }).catch(offline).then(function () { submitting = false; if (Date.now() >= state.lockedUntil) $('pin-submit').disabled = false; });
  }
  function lockPin(sec) {
    state.lockedUntil = Date.now() + sec * 1000;
    pinInputs.forEach(function (i) { i.disabled = true; });
    $('pin-submit').disabled = true;
    (function tick() {
      var s = Math.ceil((state.lockedUntil - Date.now()) / 1000);
      if (s <= 0) {
        pinInputs.forEach(function (i) { i.disabled = false; });
        $('pin-submit').disabled = false; setPinError(''); clearPin(); return;
      }
      setPinError('Too many wrong tries. Try again in ' + s + 's.');
      document.querySelector('.pin-inputs').classList.remove('shake');
      setTimeout(tick, 1000);
    })();
  }
  $('pin-form').addEventListener('submit', submitPin);
  // "All devices" must always work, even if the address already says #/devices.
  document.querySelector('#view-pin .back').addEventListener('click', function (ev) {
    if (safeGet(TOKEN_KEY)) signOut();
    if (location.hash === '#/devices') { ev.preventDefault(); route(); }
  });
  // Leaving an unlocked session for the device list signs this browser out.
  $('switch-device').addEventListener('click', function () { signOut(); });
  function openPin() {
    show('view-pin');
    $('pin-device-name').textContent = (state.info && state.info.name) || 'This device';
    setPinError('');
    clearPin();
  }

  // ---------- files ----------
  function renderCrumbs(path) {
    var nav = $('crumbs'); nav.textContent = '';
    var parts = path.split('/').filter(Boolean);
    nav.hidden = parts.length === 0; // root: the title already says where we are
    var rootName = (state.info && state.info.folderName) || 'Shared folder';
    var acc = '';
    var items = [{ name: rootName, path: '/' }].concat(parts.map(function (p) { acc += '/' + p; return { name: p, path: acc }; }));
    items.forEach(function (it, i) {
      if (i) nav.appendChild(el('span', { class: 'sep', 'aria-hidden': 'true', text: '/' }));
      if (i === items.length - 1) nav.appendChild(el('span', { class: 'here', 'aria-current': 'page', text: it.name }));
      else nav.appendChild(el('a', { href: '#/files' + encodePath(it.path), text: it.name }));
    });
    $('folder-title').textContent = items[items.length - 1].name;
    document.title = items[items.length - 1].name + ' · DataCast';
  }
  function encodePath(p) { return p.split('/').map(encodeURIComponent).join('/'); }
  function visibleEntries() {
    var qy = state.query.trim().toLowerCase();
    var list = state.entries.slice().sort(function (a, b) {
      return (b.isDir ? 1 : 0) - (a.isDir ? 1 : 0) || a.name.localeCompare(b.name, undefined, { numeric: true, sensitivity: 'base' });
    });
    return qy ? list.filter(function (e) { return e.name.toLowerCase().indexOf(qy) >= 0; }) : list;
  }
  function activate(e, list) {
    if (e.isDir) { location.hash = '#/files' + encodePath(entryPath(e)); return; }
    var k = kindOf(e);
    if (k === 'other') { window.location.href = downloadUrl(entryPath(e)); return; }
    openPreview(e, list);
  }
  // Thumbnails: small resized JPEGs from /api/thumb when the phone offers
  // them, else the full image. Falls back to the file icon if neither loads.
  function thumbUrl(p, size) {
    return state.info && state.info.thumbs ? '/api/thumb?path=' + q(p) + '&size=' + size : rawUrl(p);
  }
  function fadeInOnLoad(img) {
    img.classList.add('fade-img');
    img.addEventListener('load', function () { img.classList.add('loaded'); });
    return img;
  }
  function thumbImg(p, size, fallback, noRaw) {
    var img = fadeInOnLoad(el('img', { src: thumbUrl(p, size), alt: '', loading: 'lazy', decoding: 'async' }));
    img.addEventListener('error', function () {
      if (!noRaw && img.dataset.triedRaw !== '1' && state.info && state.info.thumbs) {
        img.dataset.triedRaw = '1';
        img.src = rawUrl(p); // e.g. 415 for a format the phone can't shrink
      } else if (img.parentNode) {
        img.parentNode.replaceChild(fallback(), img);
      }
    });
    return img;
  }
  function listIcon(e, k, p) {
    var plain = function () { return el('span', { class: 'ficon ' + iconKind(k) }, [icon(iconKind(k))]); };
    // Only use real thumbnails in the list; full images would be too heavy.
    if (k !== 'img' || !(state.info && state.info.thumbs)) return plain();
    var box = el('span', { class: 'ficon img has-thumb' });
    var img = fadeInOnLoad(el('img', { src: thumbUrl(p, 128), alt: '', loading: 'lazy', decoding: 'async' }));
    img.addEventListener('error', function () { if (box.parentNode) box.parentNode.replaceChild(plain(), box); });
    box.appendChild(img);
    return box;
  }

  function renderFiles(animate) {
    var list = visibleEntries();
    var rows = $('file-rows'), grid = $('grid-box');
    rows.textContent = ''; grid.textContent = '';
    rows.classList.toggle('stagger', !!animate);
    grid.classList.toggle('stagger', !!animate);
    list.forEach(function (e, idx) {
      var k = kindOf(e), p = entryPath(e);
      var nameBtn = el('button', { type: 'button', class: 'fname', onclick: function (ev) { originFrom(ev.currentTarget); activate(e, list); } }, [
        listIcon(e, k, p),
        el('span', { class: 'fname-text' }, [
          el('span', { text: e.name }),
          el('span', { class: 'fmeta', text: e.isDir ? 'Folder' : fmtSize(e.size) + ' · ' + fmtDate(e.modified) })
        ])
      ]);
      var dl = e.isDir
        ? (canZip() ? el('a', { class: 'icon-btn', href: zipUrl(p), download: true, title: 'Download folder (.zip)', 'aria-label': 'Download ' + e.name + ' as zip' }, [icon('download', 16)]) : null)
        : el('a', { class: 'icon-btn', href: downloadUrl(p), download: e.name, 'aria-label': 'Download ' + e.name }, [icon('download', 16)]);
      rows.appendChild(el('tr', { style: '--i:' + Math.min(idx, 14) }, [
        el('td', null, [nameBtn]),
        el('td', { class: 'col-size', text: e.isDir ? '—' : fmtSize(e.size) }),
        el('td', { class: 'col-date', text: fmtDate(e.modified) }),
        el('td', null, [dl])
      ]));
      var thumb = el('span', { class: 'tile-thumb' });
      var bigIcon = function () { return el('span', { class: 'ficon ' + iconKind(k) }, [icon(iconKind(k), 26)]); };
      if (k === 'img') thumb.appendChild(thumbImg(p, window.devicePixelRatio > 1.5 ? 512 : 256, bigIcon));
      else if (k === 'vid' && state.info && state.info.thumbs) {
        // Poster frame from the phone (Android 10+); icon if it can't make one.
        thumb.appendChild(thumbImg(p, window.devicePixelRatio > 1.5 ? 512 : 256, bigIcon, true));
        thumb.appendChild(el('span', { class: 'play-badge', 'aria-hidden': 'true' }, [icon('vid', 14)]));
      }
      else thumb.appendChild(bigIcon());
      // The tile opens the item; folders also get a zip link in the corner
      // (a sibling, since a link can't sit inside a button).
      var tileDl = e.isDir && canZip()
        ? el('a', { class: 'tile-dl', href: zipUrl(p), download: true, title: 'Download folder (.zip)', 'aria-label': 'Download ' + e.name + ' as zip' }, [icon('download', 16)])
        : null;
      grid.appendChild(el('div', { class: 'tile-wrap', style: '--i:' + Math.min(idx, 18) }, [
        el('button', { type: 'button', class: 'tile', title: e.name, onclick: function (ev) { originFrom(ev.currentTarget); activate(e, list); } }, [
          thumb, el('span', { class: 'tile-label', text: e.name })
        ]),
        tileDl
      ]));
    });
    var isGrid = state.layout === 'grid';
    $('list-box').hidden = isGrid || !list.length;
    grid.hidden = !isGrid || !list.length;
    $('empty').hidden = !!list.length;
    $('empty').textContent = state.query ? 'Nothing here matches “' + state.query + '”.' : 'This folder is empty.';
    $('view-list').setAttribute('aria-pressed', String(!isGrid));
    $('view-grid').setAttribute('aria-pressed', String(isGrid));
    var dirs = state.entries.filter(function (e) { return e.isDir; }).length;
    var files = state.entries.length - dirs;
    var bytes = state.entries.reduce(function (s, e) { return s + (e.isDir ? 0 : (e.size || 0)); }, 0);
    $('folder-summary').textContent = dirs + (dirs === 1 ? ' folder' : ' folders') + ' · ' + files + (files === 1 ? ' file' : ' files') + (files ? ' · ' + fmtSize(bytes) : '');
  }
  function openFiles(path) {
    path = '/' + path.split('/').filter(Boolean).join('/');
    return api('/api/files?path=' + q(path)).then(function (r) {
      if (r.status === 401) { safeDel(TOKEN_KEY); redirect('#/pin'); return; }
      if (r.status === 404) { toast('That folder no longer exists.'); redirect('#/files/'); return; }
      if (!r.ok) { message('Could not open this folder', r.data.error || 'The device returned an error.', function () { route(); }); return; }
      state.path = r.data.path || path;
      state.entries = r.data.entries || [];
      show('view-files');
      $('brand-name').textContent = (state.info && state.info.name) || 'DataCast';
      var zip = $('zip-btn');
      // Whole-folder download. In files mode the root is the picked set.
      var label = state.info && state.info.mode === 'files' && state.path === '/' ? 'Download all (.zip)' : 'Download folder (.zip)';
      zip.hidden = !(canZip() && state.entries.length);
      zip.href = zipUrl(state.path);
      zip.setAttribute('download', '');
      zip.setAttribute('aria-label', label.replace(' (.zip)', ' as zip'));
      zip.title = label;
      zip.querySelector('.zip-label').textContent = label;
      renderCrumbs(state.path);
      renderFiles(true);
    }).catch(offline);
  }
  $('search').addEventListener('input', function (ev) { state.query = ev.target.value; renderFiles(); });
  $('view-list').addEventListener('click', function () { if (state.layout === 'list') return; state.layout = 'list'; safeSet(VIEW_KEY, 'list'); renderFiles(true); });
  $('view-grid').addEventListener('click', function () { if (state.layout === 'grid') return; state.layout = 'grid'; safeSet(VIEW_KEY, 'grid'); renderFiles(true); });

  // ---------- preview ----------
  var lastFocus = null;
  // The preview grows out of whatever was tapped.
  function originFrom(node) {
    var r = node.getBoundingClientRect();
    var pv = $('preview');
    pv.style.setProperty('--ox', Math.round(r.left + r.width / 2) + 'px');
    pv.style.setProperty('--oy', Math.round(r.top + r.height / 2) + 'px');
  }
  function openPreview(e, list) {
    state.previewList = list.filter(function (x) { return !x.isDir && kindOf(x) !== 'other'; });
    state.previewIndex = state.previewList.indexOf(e);
    lastFocus = document.activeElement;
    unhide($('preview'));
    document.body.style.overflow = 'hidden';
    renderPreview(0);
    $('pv-close').focus();
  }
  function renderPreview(dir) {
    var e = state.previewList[state.previewIndex];
    if (!e) return closePreview();
    var p = entryPath(e), k = kindOf(e), box = $('pv-content');
    box.textContent = '';
    box.style.transform = ''; box.style.opacity = '';
    box.classList.remove('from-left', 'from-right');
    if (dir) { void box.offsetWidth; box.classList.add(dir > 0 ? 'from-right' : 'from-left'); }
    $('pv-name').textContent = e.name;
    $('pv-sub').textContent = fmtSize(e.size) + ' · ' + (state.previewIndex + 1) + ' of ' + state.previewList.length;
    $('pv-download').href = downloadUrl(p);
    $('pv-download').setAttribute('download', e.name);
    $('pv-prev').disabled = state.previewIndex <= 0;
    $('pv-next').disabled = state.previewIndex >= state.previewList.length - 1;
    if (k === 'img') {
      var img = fadeInOnLoad(el('img', { src: rawUrl(p), alt: e.name }));
      img.addEventListener('error', function () { unsupported(box, e); });
      box.appendChild(img);
    } else if (k === 'vid') {
      var v = el('video', { src: rawUrl(p), controls: true, autoplay: true, playsinline: true, preload: 'metadata' });
      v.addEventListener('error', function () { unsupported(box, e); });
      box.appendChild(v);
    } else if (k === 'aud') {
      box.appendChild(el('audio', { src: rawUrl(p), controls: true, autoplay: true }));
    } else if (k === 'pdf') {
      box.appendChild(el('iframe', { src: rawUrl(p), title: e.name }));
    } else if (k === 'txt') {
      if ((e.size || 0) > 2 * 1024 * 1024) { unsupported(box, e, 'This file is too large to preview.'); return; }
      var pre = el('pre', { text: 'Loading…' });
      box.appendChild(pre);
      fetch(rawUrl(p), { credentials: 'same-origin' }).then(function (r) { return r.text(); })
        .then(function (t) { pre.textContent = t; }).catch(function () { unsupported(box, e); });
    }
  }
  function unsupported(box, e, msg) {
    box.textContent = '';
    box.appendChild(el('div', { class: 'pv-none' }, [
      el('p', { text: msg || "This browser can't preview this file." }),
      el('a', { class: 'btn btn-primary', href: downloadUrl(entryPath(e)), download: e.name }, [icon('download', 16), 'Download instead'])
    ]));
  }
  function closePreview(silent) {
    var pv = $('preview');
    if (pv.hidden || pv.classList.contains('leaving')) return;
    // Stop media now; let the overlay animate out, then clear it.
    var media = pv.querySelector('video, audio');
    if (media) media.pause();
    if (silent) { pv.hidden = true; $('pv-content').textContent = ''; }
    else {
      hideAfterLeave(pv, 200);
      setTimeout(function () { if (pv.hidden) $('pv-content').textContent = ''; }, 220);
    }
    document.body.style.overflow = '';
    if (!silent && lastFocus) lastFocus.focus();
  }
  function step(d) {
    var n = state.previewIndex + d;
    if (n < 0 || n >= state.previewList.length) return;
    state.previewIndex = n; renderPreview(d);
  }
  $('pv-close').addEventListener('click', function () { closePreview(); });
  $('pv-prev').addEventListener('click', function () { step(-1); });
  $('pv-next').addEventListener('click', function () { step(1); });
  document.addEventListener('keydown', function (ev) {
    if ($('preview').hidden) return;
    if (ev.key === 'Escape') closePreview();
    else if (ev.key === 'ArrowLeft') step(-1);
    else if (ev.key === 'ArrowRight') step(1);
  });
  // swipe on touch screens
  (function () {
    var x0 = null;
    var stage = document.querySelector('.pv-stage');
    // The file follows the finger, then either slides away to the next
    // one or springs back. Edges resist.
    var y0 = null, dragging = false, box = $('pv-content');
    stage.addEventListener('touchstart', function (e) {
      if (e.touches.length !== 1) { x0 = null; return; }
      x0 = e.touches[0].clientX; y0 = e.touches[0].clientY; dragging = false;
      box.style.transition = 'none';
    }, { passive: true });
    stage.addEventListener('touchmove', function (e) {
      if (x0 == null || reduceMotion) return;
      var dx = e.touches[0].clientX - x0, dy = e.touches[0].clientY - y0;
      if (!dragging && Math.abs(dx) < 8) return;
      if (!dragging && Math.abs(dy) > Math.abs(dx)) { x0 = null; return; } // vertical: let it scroll
      dragging = true;
      var atEdge = (dx > 0 && state.previewIndex <= 0) || (dx < 0 && state.previewIndex >= state.previewList.length - 1);
      var shift = atEdge ? dx / 3 : dx;
      box.style.transform = 'translateX(' + shift + 'px)';
      box.style.opacity = String(1 - Math.min(Math.abs(shift) / 600, 0.4));
    }, { passive: true });
    stage.addEventListener('touchend', function (e) {
      if (x0 == null) return;
      var dx = e.changedTouches[0].clientX - x0; x0 = null;
      var d = dx < 0 ? 1 : -1, n = state.previewIndex + d;
      box.style.transition = '';
      if (Math.abs(dx) > 60 && n >= 0 && n < state.previewList.length) {
        if (reduceMotion) { step(d); return; }
        box.style.transform = 'translateX(' + (d > 0 ? -40 : 40) + 'vw)';
        box.style.opacity = '0';
        setTimeout(function () { step(d); }, 160);
      } else {
        box.style.transform = ''; box.style.opacity = '';
      }
    });
  })();
  $('devices-refresh').addEventListener('click', function () { loadDevices(true); });

  // ---------- routing ----------
  function route() {
    closePreview(true);
    var h = decodeURIComponent(location.hash.replace(/^#/, '')) || '/';
    if (h.indexOf('/files') === 0) return openFiles(h.slice(6) || '/');
    if (h === '/pin') {
      if (state.info && state.info.requiresPin === false) { redirect('#/files/'); return; }
      return openPin();
    }
    if (h === '/devices') return openDevices();
    // Landing: straight to files if this browser is already unlocked.
    // Without a stored token we skip the probe to avoid a noisy 401.
    if (!safeGet(TOKEN_KEY)) return openDevices();
    return api('/api/files?path=%2F').then(function (r) {
      if (r.ok) redirect('#/files/');
      else openDevices();
    }).catch(offline);
  }

  window.addEventListener('hashchange', route);
  api('/api/info').then(function (r) {
    state.info = r.ok ? r.data : null;
    if (state.info && state.info.deviceId) conn.deviceId = state.info.deviceId;
    scheduleBeat();
    if (state.info && state.info.name) $('brand-name').textContent = state.info.name;
    route();
  }).catch(offline);
})();
