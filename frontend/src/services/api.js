const API_URL = import.meta.env.VITE_API_URL ?? "http://localhost:8000";
const TOKEN_KEY = "pinwatch.access_token";

let accessToken = readStoredToken();
let onUnauthorized = () => {};

function readStoredToken() {
  try {
    return sessionStorage.getItem(TOKEN_KEY) ?? "";
  } catch {
    return "";
  }
}

export function getAccessToken() {
  return accessToken;
}

export function setAccessToken(token) {
  accessToken = token || "";
  try {
    if (accessToken) sessionStorage.setItem(TOKEN_KEY, accessToken);
    else sessionStorage.removeItem(TOKEN_KEY);
  } catch {
    // sessionStorage no está disponible.
  }
}

export function setUnauthorizedHandler(handler) {
  onUnauthorized = handler;
}

async function request(path, options = {}) {
  const headers = new Headers(options.headers ?? {});
  if (accessToken) headers.set("Authorization", `Bearer ${accessToken}`);

  let response;
  try {
    response = await fetch(`${API_URL}${path}`, { ...options, headers });
  } catch {
    throw new Error("No se pudo conectar con la API.");
  }

  if (response.status === 401 && path !== "/auth/login" && path !== "/auth/register") {
    setAccessToken("");
    onUnauthorized();
  }

  if (!response.ok) {
    let detail = `La API respondió con estado ${response.status}`;
    try {
      const body = await response.json();
      if (typeof body.detail === "string") {
        detail = body.detail;
      } else if (Array.isArray(body.detail) && body.detail[0]?.msg) {
        detail = String(body.detail[0].msg).replace(/^Value error,\s*/, "");
      }
    } catch {
      // La respuesta de error no trae JSON.
    }
    const error = new Error(detail);
    error.status = response.status;
    throw error;
  }

  if (response.status === 204) return null;
  return response.json();
}

export function getHealth() {
  return request("/health");
}

export function registerAccount({ username, email, password }) {
  return request("/auth/register", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ username, email, password }),
  });
}

export function loginAccount({ email, password }) {
  return request("/auth/login", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ email, password }),
  });
}

export function getMe() {
  return request("/auth/me");
}

export function requestPresignedUpload({ title, description, category, filename, contentType }) {
  return request("/pins/presign-url", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      title,
      description,
      category,
      filename,
      content_type: contentType,
    }),
  });
}

export async function uploadOriginal(url, file, contentType) {
  let response;

  try {
    response = await fetch(url, {
      method: "PUT",
      headers: { "Content-Type": contentType },
      body: file,
    });
  } catch {
    throw new Error("No se pudo subir la imagen al almacenamiento.");
  }

  if (!response.ok) {
    throw new Error("El almacenamiento rechazó la imagen.");
  }
}

export function createPin({ title, description, category, objectKey }) {
  return request("/pins", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      title,
      description,
      category,
      object_key: objectKey,
    }),
  });
}

export function createBoard({ name, description }) {
  return request("/boards", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ name, description }),
  });
}

export function getNotifications() {
  return request("/notifications");
}
