const API_URL = import.meta.env.VITE_API_URL ?? "http://localhost:8000";

async function request(path, options) {
  let response;

  try {
    response = await fetch(`${API_URL}${path}`, options);
  } catch {
    throw new Error("No se pudo conectar con la API.");
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
    throw new Error(detail);
  }

  return response.json();
}

export function getHealth() {
  return request("/health");
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
