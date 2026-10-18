// BrowserDrop's bundled upload page. It speaks the protocol documented in the package README:
// GET /config.json for settings, then POST /upload?path=<relative path> with the raw file as the body.

const DEFAULT_STRINGS = {
  title: 'Upload files',
  subtitle: 'Send files from this computer to your device.',
  dropTitle: 'Drop files or folders here',
  dropHint: 'Folders keep their structure.',
  chooseFiles: 'Choose files',
  chooseFolder: 'Choose folder',
  summaryEmpty: 'No files yet.',
  summary: '{done} of {total} uploaded',
  queued: 'Waiting',
  uploading: 'Uploading',
  uploaded: 'Uploaded',
  failed: 'Failed',
  waitingForDevice: 'Waiting for the device…',
  deviceUnreachable: "Can't reach the device. Keep the upload screen open on it; uploads resume on their own.",
  notEnoughSpace: 'Not enough space on the device',
  tooLarge: 'Too large',
  unsupported: 'File type not supported',
  skipped: 'Skipped because the type isn’t supported: {count}',
  retry: 'Retry failed',
  doneHint: 'When you’re done, confirm on your device to import the files.',
  loadError: "Can't reach the device. Check that its upload screen is still open.",
};

const STATUS_TEXT = {
  queued: 'queued',
  uploading: 'uploading',
  done: 'uploaded',
  failed: 'failed',
  waiting: 'waitingForDevice',
};

/** Network failures are retried on their own this many times per file once the device answers again. */
const MAX_AUTOMATIC_RETRIES = 3;
const RECONNECT_INTERVAL = 3000;

const $ = (id) => document.getElementById(id);

const state = {
  config: null,
  strings: DEFAULT_STRINGS,
  /** @type {{path: string, file: File, status: string, retries: number, row: object}[]} */
  items: [],
  active: 0,
  reconnectTimer: null,
};

function t(key, values = {}) {
  let text = state.strings[key] ?? DEFAULT_STRINGS[key] ?? key;
  for (const [name, value] of Object.entries(values)) {
    text = text.replaceAll(`{${name}}`, String(value));
  }
  return text;
}

async function fetchConfig() {
  const response = await fetch('/config.json', { cache: 'no-store' });
  if (!response.ok) throw new Error(`config.json answered ${response.status}`);
  return response.json();
}

function applyConfig(config) {
  state.config = config;
  state.strings = { ...DEFAULT_STRINGS, ...(config.strings || {}) };
  if (config.language) document.documentElement.lang = config.language;
  if (config.accentColor) document.documentElement.style.setProperty('--accent', config.accentColor);

  const title = config.title || t('title');
  document.title = title;
  $('title').textContent = title;
  $('subtitle').textContent = t('subtitle');
  $('drop-title').textContent = t('dropTitle');
  $('drop-hint').textContent = t('dropHint');
  $('pick-files').textContent = t('chooseFiles');
  $('pick-folder').textContent = t('chooseFolder');
  $('retry').textContent = t('retry');
  $('done-hint').textContent = t('doneHint');
  if (config.allowedExtensions) {
    $('file-input').accept = config.allowedExtensions.map((extension) => `.${extension}`).join(',');
  }
  $('pick-files').disabled = false;
  $('pick-folder').disabled = false;
  updateSummary();
}

// MARK: - Adding files

function isAccepted(path) {
  const segments = path.split('/');
  if (segments.some((segment) => segment === '' || segment.startsWith('.'))) return false;
  const allowed = state.config.allowedExtensions;
  if (!allowed) return true;
  const name = segments[segments.length - 1];
  const dot = name.lastIndexOf('.');
  return dot > 0 && allowed.includes(name.slice(dot + 1).toLowerCase());
}

/** @param {{path: string, file: File}[]} entries */
function addFiles(entries) {
  let skipped = 0;
  for (const { path, file } of entries) {
    const cleanPath = path.replace(/^\/+/, '');
    if (!isAccepted(cleanPath)) {
      skipped += 1;
      continue;
    }
    // The device replaces a file uploaded again at the same path, so reuse its row.
    let item = state.items.find((existing) => existing.path === cleanPath);
    if (item) {
      if (item.status !== 'done' && item.status !== 'failed') continue;
      item.file = file;
      item.retries = 0;
    } else {
      item = { path: cleanPath, file, status: 'queued', retries: 0, row: null };
      item.row = createRow(item);
      state.items.push(item);
    }
    if (file.size > state.config.maximumFileSize) {
      setStatus(item, 'failed', t('tooLarge'));
    } else {
      setStatus(item, 'queued');
    }
  }
  if (skipped) showNotice(t('skipped', { count: skipped }));
  pump();
}

async function walk(entry, prefix, out) {
  const path = prefix ? `${prefix}/${entry.name}` : entry.name;
  if (entry.isFile) {
    try {
      out.push({ path, file: await new Promise((resolve, reject) => entry.file(resolve, reject)) });
    } catch {
      // Unreadable (permissions, vanished): skip it.
    }
    return;
  }
  if (!entry.isDirectory || entry.name.startsWith('.')) return;
  const reader = entry.createReader();
  for (;;) {
    // readEntries returns at most ~100 entries per call; keep reading until it returns none.
    const batch = await new Promise((resolve, reject) => reader.readEntries(resolve, reject));
    if (!batch.length) break;
    for (const child of batch) await walk(child, path, out);
  }
}

async function collectDropped(roots, files) {
  if (!roots.length) {
    return files.map((file) => ({ path: file.webkitRelativePath || file.name, file }));
  }
  const out = [];
  for (const root of roots) await walk(root, '', out);
  return out;
}

function setUpInputs() {
  const zone = $('drop');
  const ready = () => state.config !== null;

  document.addEventListener('dragover', (event) => {
    event.preventDefault();
    if (!ready()) return;
    event.dataTransfer.dropEffect = 'copy';
    zone.classList.add('over');
  });
  document.addEventListener('dragleave', (event) => {
    if (event.relatedTarget === null) zone.classList.remove('over');
  });
  document.addEventListener('drop', (event) => {
    event.preventDefault();
    zone.classList.remove('over');
    if (!ready()) return;
    // Read the DataTransfer before awaiting anything: the browser empties it once this handler returns.
    const roots = [...(event.dataTransfer.items || [])]
      .map((item) => (typeof item.webkitGetAsEntry === 'function' ? item.webkitGetAsEntry() : null))
      .filter(Boolean);
    const files = [...(event.dataTransfer.files || [])];
    collectDropped(roots, files).then(addFiles);
  });

  $('pick-files').addEventListener('click', () => $('file-input').click());
  $('pick-folder').addEventListener('click', () => $('folder-input').click());
  $('file-input').addEventListener('change', (event) => {
    addFiles([...event.target.files].map((file) => ({ path: file.name, file })));
    event.target.value = '';
  });
  $('folder-input').addEventListener('change', (event) => {
    addFiles([...event.target.files].map((file) => ({ path: file.webkitRelativePath || file.name, file })));
    event.target.value = '';
  });
  $('retry').addEventListener('click', () => {
    for (const item of state.items) {
      if (item.status !== 'failed' || item.file.size > state.config.maximumFileSize) continue;
      item.retries = 0;
      setStatus(item, 'queued');
    }
    hideNotice();
    pump();
  });
}

// MARK: - Uploading

function pump() {
  // While the device is unreachable, wait for it instead of failing more files.
  if (!state.reconnectTimer) {
    const limit = Math.max(1, state.config.maximumConcurrentUploads || 3);
    while (state.active < limit) {
      const next = state.items.find((item) => item.status === 'queued');
      if (!next) break;
      upload(next);
    }
  }
  updateSummary();
}

function upload(item) {
  state.active += 1;
  setStatus(item, 'uploading');
  setProgress(item, 0);

  const request = new XMLHttpRequest();
  request.open('POST', `/upload?path=${encodeURIComponent(item.path)}`);
  request.upload.onprogress = (event) => {
    if (event.lengthComputable) setProgress(item, event.loaded / event.total);
  };
  request.onload = () => uploadEnded(item, request.status, request.responseText);
  request.onerror = () => uploadEnded(item, 0, '');
  request.onabort = () => uploadEnded(item, 0, '');
  request.send(item.file);
}

function uploadEnded(item, status, body) {
  state.active -= 1;
  if (status === 201) {
    setProgress(item, 1);
    setStatus(item, 'done');
  } else if (status === 0) {
    setStatus(item, 'waiting');
    startReconnecting();
  } else {
    setStatus(item, 'failed', failureText(status, body));
  }
  pump();
}

function failureText(status, body) {
  if (status === 507) return t('notEnoughSpace');
  if (status === 413) return t('tooLarge');
  try {
    if (JSON.parse(body).error === 'unsupported_type') return t('unsupported');
  } catch {
    // Not JSON: fall through.
  }
  return t('failed');
}

function startReconnecting() {
  if (state.reconnectTimer) return;
  showNotice(t('deviceUnreachable'));
  state.reconnectTimer = setTimeout(checkDevice, RECONNECT_INTERVAL);
}

async function checkDevice() {
  try {
    await fetchConfig();
  } catch {
    state.reconnectTimer = setTimeout(checkDevice, RECONNECT_INTERVAL);
    return;
  }
  state.reconnectTimer = null;
  hideNotice();
  for (const item of state.items) {
    if (item.status !== 'waiting') continue;
    // The device answers but keeps dropping this file: stop retrying it on our own.
    if (item.retries >= MAX_AUTOMATIC_RETRIES) {
      setStatus(item, 'failed', t('failed'));
      continue;
    }
    item.retries += 1;
    setStatus(item, 'queued');
  }
  pump();
}

// MARK: - Rendering

function createRow(item) {
  const li = document.createElement('li');
  li.className = 'item';
  const name = document.createElement('span');
  name.className = 'name';
  name.textContent = item.path;
  const status = document.createElement('span');
  status.className = 'state';
  const bar = document.createElement('div');
  bar.className = 'bar';
  const fill = document.createElement('div');
  fill.className = 'fill';
  bar.append(fill);
  li.append(name, status, bar);
  $('list').append(li);
  return { li, status, fill };
}

function setStatus(item, status, text) {
  item.status = status;
  item.row.li.dataset.state = status;
  item.row.status.textContent = text || t(STATUS_TEXT[status]);
}

function setProgress(item, fraction) {
  item.row.fill.style.width = `${Math.round(Math.max(0, Math.min(1, fraction)) * 100)}%`;
}

function updateSummary() {
  const total = state.items.length;
  const done = state.items.filter((item) => item.status === 'done').length;
  $('summary').textContent = total ? t('summary', { done, total }) : t('summaryEmpty');
  $('retry').hidden = !state.items.some((item) => item.status === 'failed');
}

function showNotice(text) {
  $('notice').textContent = text;
  $('notice').hidden = false;
}

function hideNotice() {
  $('notice').hidden = true;
}

// MARK: - Start

async function main() {
  setUpInputs();
  for (;;) {
    try {
      applyConfig(await fetchConfig());
      hideNotice();
      return;
    } catch {
      showNotice(t('loadError'));
      await new Promise((resolve) => setTimeout(resolve, RECONNECT_INTERVAL));
    }
  }
}

main();
