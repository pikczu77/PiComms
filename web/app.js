import { CONFIG } from "./config.js";

// Dane na Google Drive (ten sam format co w wersji iOS):
//  - folder „PiComms” (properties: picomms=chat), udostępniony drugiej osobie,
//  - każda wiadomość to osobny plik JSON (properties: type=message, mid, sender),
//  - każda osoba ma jeden plik profilu (properties: type=profile, email).

const DRIVE_API = "https://www.googleapis.com/drive/v3";
const UPLOAD_API = "https://www.googleapis.com/upload/drive/v3";
const SCOPE = "https://www.googleapis.com/auth/drive";
const FILE_FIELDS = "id,name,createdTime,modifiedTime,properties";
const POLL_MS = 3000;
const REDIRECT_URI = location.origin + location.pathname.replace(/index\.html$/, "");

const $ = (selector) => document.querySelector(selector);

// ---------------------------------------------------------------------------
// Pamięć lokalna

const storage = {
  get(key) {
    try { return JSON.parse(localStorage.getItem(key)); } catch { return null; }
  },
  set(key, value) {
    try { localStorage.setItem(key, JSON.stringify(value)); } catch (error) { console.warn(error); }
  },
  remove(key) {
    try { localStorage.removeItem(key); } catch { /* brak dostępu do pamięci */ }
  },
};

// Daty bez milisekund – tak jak zapisuje je wersja iOS.
const isoNow = () => new Date().toISOString().replace(/\.\d{3}Z$/, "Z");

// ---------------------------------------------------------------------------
// Logowanie Google (OAuth 2.0 + PKCE, z refresh tokenem – bez wylogowywania)

class InvalidGrantError extends Error {
  constructor() { super("Połączenie z Google wygasło – połącz się ponownie."); }
}

const TOKENS_KEY = "picomms.tokens";
const PKCE_KEY = "picomms.pkce";

const auth = {
  tokens: storage.get(TOKENS_KEY),
  needsReauth: false,
  refreshing: null,

  get isConfigured() { return Boolean(CONFIG.googleClientId && CONFIG.googleClientSecret); },
  get isSignedIn() { return Boolean(this.tokens); },

  async signIn() {
    const verifier = randomString(32);
    const challenge = base64url(new Uint8Array(
      await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier))
    ));
    const state = randomString(16);
    storage.set(PKCE_KEY, { verifier, state });

    const url = new URL("https://accounts.google.com/o/oauth2/v2/auth");
    url.search = new URLSearchParams({
      client_id: CONFIG.googleClientId,
      redirect_uri: REDIRECT_URI,
      response_type: "code",
      scope: SCOPE,
      code_challenge: challenge,
      code_challenge_method: "S256",
      state,
      access_type: "offline",
      prompt: "consent",
    });
    location.assign(url);
  },

  /** Obsługuje powrót z ekranu logowania Google (?code=...). */
  async handleRedirect() {
    const params = new URLSearchParams(location.search);
    const code = params.get("code");
    const error = params.get("error");
    if (!code && !error) return;
    history.replaceState(null, "", REDIRECT_URI);

    const pkce = storage.get(PKCE_KEY);
    storage.remove(PKCE_KEY);
    if (error) throw new Error(error === "access_denied" ? "Logowanie anulowane." : `Błąd logowania: ${error}`);
    if (!pkce || pkce.state !== params.get("state")) throw new Error("Nieprawidłowa odpowiedź z logowania Google.");

    const response = await tokenRequest({
      code,
      client_id: CONFIG.googleClientId,
      client_secret: CONFIG.googleClientSecret,
      redirect_uri: REDIRECT_URI,
      grant_type: "authorization_code",
      code_verifier: pkce.verifier,
    });
    if (!response.refresh_token) throw new Error("Google nie zwrócił refresh tokena – spróbuj ponownie.");
    this.setTokens({
      accessToken: response.access_token,
      refreshToken: response.refresh_token,
      expiresAt: Date.now() + response.expires_in * 1000,
    });
  },

  async accessToken(forceRefresh = false) {
    if (!this.tokens) throw new Error("Nie jesteś zalogowany.");
    if (this.needsReauth) throw new InvalidGrantError();
    if (!forceRefresh && this.tokens.expiresAt > Date.now() + 60_000) return this.tokens.accessToken;

    if (!this.refreshing) {
      const refreshToken = this.tokens.refreshToken;
      this.refreshing = tokenRequest({
        client_id: CONFIG.googleClientId,
        client_secret: CONFIG.googleClientSecret,
        grant_type: "refresh_token",
        refresh_token: refreshToken,
      })
        .then((response) => {
          this.setTokens({
            accessToken: response.access_token,
            refreshToken: response.refresh_token || refreshToken,
            expiresAt: Date.now() + response.expires_in * 1000,
          });
          return this.tokens.accessToken;
        })
        .catch((error) => {
          // Nie wylogowujemy – czat zostaje, pojawia się tylko pasek „połącz ponownie”.
          if (error instanceof InvalidGrantError) {
            this.needsReauth = true;
            render();
          }
          throw error;
        })
        .finally(() => { this.refreshing = null; });
    }
    return this.refreshing;
  },

  setTokens(tokens) {
    this.tokens = tokens;
    this.needsReauth = false;
    if (tokens) storage.set(TOKENS_KEY, tokens);
    else storage.remove(TOKENS_KEY);
  },

  signOut() {
    this.setTokens(null);
    storage.remove(SESSION_KEY);
    chat.reset();
    render();
  },
};

async function tokenRequest(params) {
  const response = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams(params),
  });
  if (!response.ok) {
    const body = await response.text();
    if (body.includes("invalid_grant")) throw new InvalidGrantError();
    throw new Error(`Błąd logowania Google: ${body.slice(0, 200)}`);
  }
  return response.json();
}

function randomString(byteCount) {
  return base64url(crypto.getRandomValues(new Uint8Array(byteCount)));
}

function base64url(bytes) {
  return btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

// ---------------------------------------------------------------------------
// Google Drive API v3

const drive = {
  async request(method, url, { body, contentType } = {}, isRetry = false) {
    const headers = { Authorization: `Bearer ${await auth.accessToken(isRetry)}` };
    if (contentType) headers["Content-Type"] = contentType;
    const response = await fetch(url, { method, headers, body, cache: "no-store" });
    if (response.status === 401 && !isRetry) return this.request(method, url, { body, contentType }, true);
    if (!response.ok) {
      throw new Error(`Google Drive zwrócił błąd ${response.status}: ${(await response.text()).slice(0, 200)}`);
    }
    return response;
  },

  url(base, path, params = {}) {
    const url = new URL(`${base}/${path}`);
    url.search = new URLSearchParams(params);
    return url.toString();
  },

  async currentUser() {
    const response = await this.request("GET", this.url(DRIVE_API, "about", { fields: "user(displayName,emailAddress)" }));
    return (await response.json()).user;
  },

  async listFiles(q, orderBy) {
    const files = [];
    let pageToken;
    do {
      const params = { q, fields: `nextPageToken,files(${FILE_FIELDS})`, pageSize: "1000", spaces: "drive" };
      if (orderBy) params.orderBy = orderBy;
      if (pageToken) params.pageToken = pageToken;
      const page = await (await this.request("GET", this.url(DRIVE_API, "files", params))).json();
      files.push(...(page.files || []));
      pageToken = page.nextPageToken;
    } while (pageToken);
    return files;
  },

  async createFolder(name, properties) {
    const response = await this.request("POST", this.url(DRIVE_API, "files", { fields: FILE_FIELDS }), {
      body: JSON.stringify({ name, mimeType: "application/vnd.google-apps.folder", properties }),
      contentType: "application/json",
    });
    return response.json();
  },

  async share(fileId, email) {
    await this.request("POST", this.url(DRIVE_API, `files/${fileId}/permissions`, { sendNotificationEmail: "true" }), {
      body: JSON.stringify({ type: "user", role: "writer", emailAddress: email }),
      contentType: "application/json",
    });
  },

  async createJSONFile(name, parentId, properties, content) {
    const boundary = `picomms-${crypto.randomUUID()}`;
    const metadata = { name, parents: [parentId], properties, mimeType: "application/json" };
    const body =
      `--${boundary}\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n${JSON.stringify(metadata)}\r\n` +
      `--${boundary}\r\nContent-Type: application/json\r\n\r\n${JSON.stringify(content)}\r\n` +
      `--${boundary}--\r\n`;
    const response = await this.request(
      "POST",
      this.url(UPLOAD_API, "files", { uploadType: "multipart", fields: FILE_FIELDS }),
      { body, contentType: `multipart/related; boundary=${boundary}` }
    );
    return response.json();
  },

  async updateJSONFile(fileId, content) {
    const response = await this.request(
      "PATCH",
      this.url(UPLOAD_API, `files/${fileId}`, { uploadType: "media", fields: FILE_FIELDS }),
      { body: JSON.stringify(content), contentType: "application/json" }
    );
    return response.json();
  },

  async downloadJSON(fileId) {
    const response = await this.request("GET", this.url(DRIVE_API, `files/${fileId}`, { alt: "media" }));
    return response.json();
  },
};

// ---------------------------------------------------------------------------
// Stan czatu

const SESSION_KEY = "picomms.session";

const chat = {
  phase: "loading", // loading | needsChat | ready | failed
  failure: "",
  myEmail: "",
  googleName: null,
  folderId: null,
  messages: [],
  profiles: {},
  profileVersions: {},
  myProfileFileId: null,
  lastSeen: null,
  syncError: null,
  pollTimer: null,
  refreshing: false,

  reset() {
    this.stopPolling();
    Object.assign(this, {
      phase: "loading", failure: "", myEmail: "", googleName: null, folderId: null, messages: [],
      profiles: {}, profileVersions: {}, myProfileFileId: null, lastSeen: null, syncError: null,
    });
  },

  get myProfile() { return this.profiles[this.myEmail]; },
  get partnerProfile() {
    return Object.values(this.profiles)
      .filter((profile) => profile.email !== this.myEmail)
      .sort((a, b) => Date.parse(b.updatedAt) - Date.parse(a.updatedAt))[0];
  },

  async start() {
    // Znana rozmowa: od razu pokazujemy czat z pamięci, synchronizacja idzie w tle.
    const saved = storage.get(SESSION_KEY);
    if (saved) {
      this.myEmail = saved.email;
      if (this.phase !== "ready") await this.open(saved.folderId);
      return;
    }

    this.phase = "loading";
    render();
    try {
      const user = await drive.currentUser();
      this.myEmail = user.emailAddress.toLowerCase();
      this.googleName = user.displayName;
      const folder = await this.findChatFolder();
      if (folder) {
        await this.open(folder.id);
      } else {
        this.phase = "needsChat";
        render();
      }
    } catch (error) {
      this.phase = "failed";
      this.failure = error.message;
      render();
    }
  },

  async findChatFolder() {
    const q = "mimeType='application/vnd.google-apps.folder' and " +
      "properties has { key='picomms' and value='chat' } and trashed=false";
    return (await drive.listFiles(q, "createdTime"))[0];
  },

  async createChat(partnerEmail) {
    const folder = await drive.createFolder("PiComms", { picomms: "chat" });
    await drive.share(folder.id, partnerEmail.trim().toLowerCase());
    await this.open(folder.id);
  },

  async open(folderId) {
    this.folderId = folderId;
    storage.set(SESSION_KEY, { email: this.myEmail, folderId });
    this.loadCache();
    this.phase = "ready";
    render({ scrollToBottom: true });

    const synced = await this.refresh();
    if (synced && !this.myProfileFileId) {
      let name = this.googleName;
      if (!name) name = await drive.currentUser().then((user) => user.displayName, () => null);
      await this.saveProfile(name || this.myEmail, null).catch(() => {});
    }
    this.startPolling();
  },

  startPolling() {
    if (this.pollTimer || !this.folderId) return;
    this.pollTimer = setInterval(() => this.refresh(), POLL_MS);
  },

  stopPolling() {
    clearInterval(this.pollTimer);
    this.pollTimer = null;
  },

  async refresh() {
    if (this.refreshing || !this.folderId) return false;
    this.refreshing = true;
    try {
      const changedMessages = await this.refreshMessages();
      const changedProfiles = await this.refreshProfiles();
      const hadError = this.syncError !== null;
      this.syncError = null;
      if (changedMessages || changedProfiles || hadError) render();
      return true;
    } catch (error) {
      this.syncError = error.message;
      render();
      return false;
    } finally {
      this.refreshing = false;
    }
  },

  async refreshMessages() {
    let q = `'${this.folderId}' in parents and properties has { key='type' and value='message' } and trashed=false`;
    if (this.lastSeen) q += ` and createdTime >= '${this.lastSeen}'`;
    const files = await drive.listFiles(q, "createdTime");

    const known = new Set(this.messages.filter((m) => m.status === "sent").map((m) => m.id));
    const newFiles = files.filter((file) => file.properties?.mid && !known.has(file.properties.mid));
    const downloaded = await Promise.all(newFiles.map(async (file) => {
      try {
        const payload = await drive.downloadJSON(file.id);
        return {
          id: payload.id,
          sender: String(payload.sender).toLowerCase(),
          text: String(payload.text),
          date: file.createdTime || payload.sentAt,
          status: "sent",
        };
      } catch (error) {
        if (error instanceof SyntaxError) return null; // uszkodzony plik – pomijamy
        throw error;
      }
    }));
    for (const message of downloaded) if (message) this.upsert(message);
    if (newFiles.length) this.sortMessages();
    if (files.length) this.lastSeen = files[files.length - 1].createdTime;
    if (newFiles.length) this.saveCache();
    return newFiles.length > 0;
  },

  async refreshProfiles() {
    const q = `'${this.folderId}' in parents and properties has { key='type' and value='profile' } and trashed=false`;
    const files = await drive.listFiles(q, "modifiedTime desc");
    const seen = new Set();
    let changed = false;
    for (const file of files) {
      const email = file.properties?.email?.toLowerCase();
      if (!email || seen.has(email)) continue;
      seen.add(email);
      if (email === this.myEmail) this.myProfileFileId = file.id;
      if (this.profileVersions[file.id] === file.modifiedTime && this.profiles[email]) continue;

      const profile = await drive.downloadJSON(file.id).catch((error) => {
        if (error instanceof SyntaxError) return null;
        throw error;
      });
      if (profile) {
        this.profiles[email] = { ...profile, email };
        this.profileVersions[file.id] = file.modifiedTime;
        changed = true;
      }
    }
    if (changed) this.saveCache();
    return changed;
  },

  send(text) {
    const trimmed = text.trim();
    if (!trimmed) return;
    const message = { id: crypto.randomUUID(), sender: this.myEmail, text: trimmed, date: isoNow(), status: "sending" };
    this.messages.push(message);
    render({ scrollToBottom: true });
    this.upload(message);
  },

  retry(id) {
    const message = this.messages.find((m) => m.id === id);
    if (!message || message.status !== "failed") return;
    message.status = "sending";
    render();
    this.upload(message);
  },

  async upload(message) {
    try {
      const file = await drive.createJSONFile(
        `msg-${message.date}-${message.id}.json`,
        this.folderId,
        { type: "message", mid: message.id, sender: message.sender },
        { id: message.id, sender: message.sender, text: message.text, sentAt: message.date }
      );
      this.upsert({ ...message, status: "sent", date: file.createdTime || message.date });
      this.sortMessages();
    } catch {
      const current = this.messages.find((m) => m.id === message.id);
      if (current) current.status = "failed";
    }
    this.saveCache();
    render();
  },

  async saveProfile(displayName, avatar) {
    const name = displayName.trim();
    const profile = { email: this.myEmail, displayName: name || this.myEmail, updatedAt: isoNow() };
    if (avatar) profile.avatar = avatar;

    let file;
    if (this.myProfileFileId) {
      file = await drive.updateJSONFile(this.myProfileFileId, profile);
    } else {
      file = await drive.createJSONFile(
        `profile-${this.myEmail}.json`, this.folderId, { type: "profile", email: this.myEmail }, profile
      );
      this.myProfileFileId = file.id;
    }
    this.profileVersions[file.id] = file.modifiedTime;
    this.profiles[this.myEmail] = profile;
    this.saveCache();
    render();
  },

  upsert(message) {
    const index = this.messages.findIndex((m) => m.id === message.id);
    if (index >= 0) this.messages[index] = message;
    else this.messages.push(message);
  },

  sortMessages() {
    this.messages.sort((a, b) => Date.parse(a.date) - Date.parse(b.date));
  },

  cacheKey() { return `picomms.chat.${this.folderId}`; },

  loadCache() {
    const cache = storage.get(this.cacheKey());
    if (!cache) return;
    this.messages = (cache.messages || []).map((m) => (m.status === "sending" ? { ...m, status: "failed" } : m));
    this.profiles = cache.profiles || {};
    this.profileVersions = cache.profileVersions || {};
    this.lastSeen = cache.lastSeen || null;
  },

  saveCache() {
    storage.set(this.cacheKey(), {
      messages: this.messages,
      profiles: this.profiles,
      profileVersions: this.profileVersions,
      lastSeen: this.lastSeen,
    });
  },
};

// ---------------------------------------------------------------------------
// Widoki

const SCREENS = ["signin", "loading", "failed", "setup", "chat"];

function showScreen(name) {
  for (const screen of SCREENS) $(`#screen-${screen}`).hidden = screen !== name;
}

function render({ scrollToBottom = false } = {}) {
  if (!auth.isSignedIn) {
    showScreen("signin");
    $("#signin-not-configured").hidden = auth.isConfigured;
    $("#btn-signin").disabled = !auth.isConfigured;
    $("#install-hint").hidden = isStandalone();
    return;
  }
  switch (chat.phase) {
    case "loading":
      showScreen("loading");
      break;
    case "failed":
      showScreen("failed");
      $("#failed-message").textContent = chat.failure;
      break;
    case "needsChat":
      showScreen("setup");
      $("#setup-email").textContent = chat.myEmail;
      break;
    case "ready":
      showScreen("chat");
      renderChat(scrollToBottom);
      break;
  }
}

function renderChat(scrollToBottom) {
  const partner = chat.partnerProfile;
  $("#partner-avatar").replaceChildren(avatarElement(partner, 36));
  $("#partner-name").textContent = partner?.displayName || "Czekam na drugą osobę…";
  $("#sync-status").hidden = !chat.syncError || auth.needsReauth;
  $("#reauth-banner").hidden = !auth.needsReauth;
  $("#btn-open-profile").replaceChildren(avatarElement(chat.myProfile, 34));
  renderMessages(scrollToBottom);
}

let lastRenderedSignature = "";

function renderMessages(scrollToBottom) {
  const box = $("#messages");
  const signature = JSON.stringify([
    chat.messages.map((m) => [m.id, m.status, m.date]),
    Object.values(chat.profileVersions),
  ]);
  if (signature === lastRenderedSignature && !scrollToBottom) return;
  lastRenderedSignature = signature;

  const wasNearBottom = box.scrollHeight - box.scrollTop - box.clientHeight < 120;
  const fragment = document.createDocumentFragment();

  if (!chat.messages.length) {
    fragment.append(el("div", "empty", "Brak wiadomości. Napisz coś pierwszy! 💬"));
  }

  let previousDay = null;
  chat.messages.forEach((message, index) => {
    const date = new Date(message.date);
    const day = date.toDateString();
    if (day !== previousDay) {
      fragment.append(el("div", "day", date.toLocaleDateString("pl-PL", { weekday: "long", day: "numeric", month: "long" })));
      previousDay = day;
    }

    const mine = message.sender === chat.myEmail;
    const next = chat.messages[index + 1];
    const lastInGroup = !next || next.sender !== message.sender;
    const row = el("div", `row${mine ? " mine" : ""}${lastInGroup ? " last-in-group" : ""}`);

    if (!mine) {
      const avatar = avatarElement(chat.profiles[message.sender], 28);
      if (!lastInGroup) avatar.classList.add("hidden-avatar");
      row.append(avatar);
    }

    const wrap = el("div", "bubble-wrap");
    wrap.append(el("div", "bubble", message.text));
    const meta = el("div", "meta", date.toLocaleTimeString("pl-PL", { hour: "2-digit", minute: "2-digit" }));
    if (message.status === "sending") meta.append(" · wysyłanie…");
    if (message.status === "failed") {
      const retry = el("button", "", " · Nie wysłano – dotknij, aby ponowić");
      retry.type = "button";
      retry.addEventListener("click", () => chat.retry(message.id));
      meta.append(retry);
    }
    wrap.append(meta);
    row.append(wrap);
    if (!mine) row.append(el("div", "spacer"));
    fragment.append(row);
  });

  box.replaceChildren(fragment);
  if (scrollToBottom || wasNearBottom) box.scrollTop = box.scrollHeight;
}

function el(tag, className, text) {
  const element = document.createElement(tag);
  if (className) element.className = className;
  if (text !== undefined) element.textContent = text;
  return element;
}

function avatarElement(profile, size, avatarOverride) {
  const avatar = el("div", "avatar");
  avatar.style.width = avatar.style.height = `${size}px`;
  avatar.style.fontSize = `${Math.round(size * 0.4)}px`;
  const image = avatarOverride !== undefined ? avatarOverride : profile?.avatar;
  if (image) {
    const img = document.createElement("img");
    img.src = `data:image/jpeg;base64,${image}`;
    img.alt = "";
    avatar.append(img);
  } else {
    const initials = (profile?.displayName || "")
      .split(/\s+/).filter(Boolean).slice(0, 2).map((part) => part[0].toUpperCase()).join("");
    avatar.textContent = initials || "👤";
  }
  return avatar;
}

function isStandalone() {
  return window.matchMedia("(display-mode: standalone)").matches || navigator.standalone === true;
}

// ---------------------------------------------------------------------------
// Profil

let profileDraftAvatar = null;

function openProfile() {
  const profile = chat.myProfile;
  profileDraftAvatar = profile?.avatar || null;
  $("#profile-name").value = profile?.displayName || "";
  $("#profile-email").textContent = chat.myEmail;
  const partner = chat.partnerProfile;
  $("#profile-partner").hidden = !partner;
  $("#profile-partner").textContent = partner ? `Rozmawiasz z: ${partner.displayName}` : "";
  $("#profile-error").hidden = true;
  renderProfileAvatar();
  $("#profile-dialog").showModal();
}

function renderProfileAvatar() {
  const preview = { displayName: $("#profile-name").value };
  $("#profile-avatar-preview").replaceChildren(avatarElement(preview, 110, profileDraftAvatar));
  $("#profile-photo-label").textContent = profileDraftAvatar ? "Zmień zdjęcie" : "Dodaj zdjęcie";
  $("#btn-remove-photo").hidden = !profileDraftAvatar;
}

/** Przycina zdjęcie do kwadratu 256×256 i zwraca JPEG w base64 (ok. 20–40 KB). */
function avatarFromFile(file, side = 256) {
  return new Promise((resolve, reject) => {
    const url = URL.createObjectURL(file);
    const image = new Image();
    image.onload = () => {
      const scale = side / Math.min(image.naturalWidth, image.naturalHeight);
      const width = image.naturalWidth * scale;
      const height = image.naturalHeight * scale;
      const canvas = document.createElement("canvas");
      canvas.width = canvas.height = side;
      canvas.getContext("2d").drawImage(image, (side - width) / 2, (side - height) / 2, width, height);
      URL.revokeObjectURL(url);
      resolve(canvas.toDataURL("image/jpeg", 0.8).split(",")[1]);
    };
    image.onerror = () => {
      URL.revokeObjectURL(url);
      reject(new Error("Nie udało się wczytać zdjęcia."));
    };
    image.src = url;
  });
}

// ---------------------------------------------------------------------------
// Zdarzenia

function showError(selector, error) {
  const element = $(selector);
  element.textContent = error ? error.message || String(error) : "";
  element.hidden = !error;
}

async function withBusy(button, action) {
  button.disabled = true;
  try { await action(); } finally { button.disabled = false; }
}

function bindEvents() {
  $("#btn-signin").addEventListener("click", () => auth.signIn());
  $("#reauth-banner").addEventListener("click", () => auth.signIn());
  $("#btn-failed-retry").addEventListener("click", () => chat.start());
  for (const id of ["#btn-failed-signout", "#btn-setup-signout", "#btn-profile-signout"]) {
    $(id).addEventListener("click", () => {
      $("#profile-dialog").close();
      auth.signOut();
    });
  }

  const partnerInput = $("#setup-partner");
  const createButton = $("#btn-create-chat");
  const updateCreateButton = () => { createButton.disabled = !partnerInput.value.includes("@"); };
  partnerInput.addEventListener("input", updateCreateButton);
  updateCreateButton();
  createButton.addEventListener("click", () => withBusy(createButton, async () => {
    showError("#setup-error", null);
    try { await chat.createChat(partnerInput.value); } catch (error) { showError("#setup-error", error); }
  }));
  $("#btn-check-invite").addEventListener("click", (event) => withBusy(event.currentTarget, () => chat.start()));

  // Pisanie wiadomości
  const draft = $("#draft");
  const sendButton = $("#btn-send");
  const autosize = () => {
    draft.style.height = "auto";
    draft.style.height = `${Math.min(draft.scrollHeight, 140)}px`;
    sendButton.disabled = !draft.value.trim();
  };
  draft.addEventListener("input", autosize);
  $("#composer").addEventListener("submit", (event) => {
    event.preventDefault();
    chat.send(draft.value);
    draft.value = "";
    autosize();
    draft.focus();
  });
  draft.addEventListener("keydown", (event) => {
    // Na komputerze Enter wysyła, Shift+Enter to nowa linia. Na telefonie Enter to nowa linia.
    if (event.key === "Enter" && !event.shiftKey && !event.isComposing && matchMedia("(pointer: fine)").matches) {
      event.preventDefault();
      $("#composer").requestSubmit();
    }
  });

  // Profil
  $("#btn-open-profile").addEventListener("click", openProfile);
  $("#profile-name").addEventListener("input", renderProfileAvatar);
  $("#profile-photo").addEventListener("change", async (event) => {
    const file = event.target.files?.[0];
    event.target.value = "";
    if (!file) return;
    try {
      profileDraftAvatar = await avatarFromFile(file);
      renderProfileAvatar();
    } catch (error) {
      showError("#profile-error", error);
    }
  });
  $("#btn-remove-photo").addEventListener("click", () => {
    profileDraftAvatar = null;
    renderProfileAvatar();
  });
  $("#profile-form").addEventListener("submit", async (event) => {
    if (event.submitter?.value !== "save") return;
    event.preventDefault();
    const name = $("#profile-name").value.trim();
    if (!name) return showError("#profile-error", new Error("Wpisz nazwę użytkownika."));
    await withBusy($("#btn-profile-save"), async () => {
      try {
        await chat.saveProfile(name, profileDraftAvatar);
        $("#profile-dialog").close();
      } catch (error) {
        showError("#profile-error", error);
      }
    });
  });

  // Synchronizacja tylko wtedy, gdy aplikacja jest na ekranie.
  document.addEventListener("visibilitychange", () => {
    if (chat.phase !== "ready") return;
    if (document.visibilityState === "visible") {
      chat.startPolling();
      chat.refresh();
    } else {
      chat.stopPolling();
    }
  });
}

// ---------------------------------------------------------------------------
// Start

async function main() {
  bindEvents();
  if ("serviceWorker" in navigator) navigator.serviceWorker.register("sw.js").catch(() => {});

  try {
    await auth.handleRedirect();
  } catch (error) {
    render();
    showError("#signin-error", error);
    if (!auth.isSignedIn) return;
  }

  render();
  if (auth.isSignedIn) await chat.start();
}

main();
