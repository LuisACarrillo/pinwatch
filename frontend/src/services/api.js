const API_URL = import.meta.env.VITE_API_URL ?? "http://localhost:8000";

async function request(path) {
  let response;

  try {
    response = await fetch(`${API_URL}${path}`);
  } catch {
    throw new Error("No se pudo conectar con la API.");
  }

  if (!response.ok) {
    throw new Error(`La API respondió con estado ${response.status}`);
  }

  return response.json();
}

export function getHealth() {
  return request("/health");
}
