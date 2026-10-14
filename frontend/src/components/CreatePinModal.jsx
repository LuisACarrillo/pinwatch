import { useEffect, useRef, useState } from "react";
import { requestPresignedUpload, uploadOriginal } from "../services/api.js";

export default function CreatePinModal({ categories, onClose, onCreate }) {
  const [title, setTitle] = useState("");
  const [description, setDescription] = useState("");
  const [category, setCategory] = useState(categories[0]);
  const [file, setFile] = useState(null);
  const [preview, setPreview] = useState("");
  const [error, setError] = useState("");
  const [submitting, setSubmitting] = useState(false);
  const alive = useRef(true);

  useEffect(() => {
    alive.current = true;
    return () => {
      alive.current = false;
    };
  }, []);

  useEffect(() => {
    function onKey(event) {
      if (event.key === "Escape" && !submitting) onClose();
    }
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onClose, submitting]);

  useEffect(() => {
    return () => {
      if (preview) URL.revokeObjectURL(preview);
    };
  }, [preview]);

  function onFile(event) {
    const next = event.target.files?.[0] ?? null;
    setFile(next);
    setPreview((current) => {
      if (current) URL.revokeObjectURL(current);
      return next ? URL.createObjectURL(next) : "";
    });
  }

  async function onSubmit(event) {
    event.preventDefault();
    const trimmed = title.trim();
    if (!trimmed) {
      setError("Escribe un título.");
      return;
    }
    if (!file) {
      setError("Selecciona una imagen.");
      return;
    }
    const contentType = file.type || "application/octet-stream";
    setSubmitting(true);
    setError("");
    try {
      const presign = await requestPresignedUpload({
        title: trimmed,
        description: description.trim(),
        category,
        filename: file.name,
        contentType,
      });
      await uploadOriginal(presign.url, file, presign.content_type);
      if (!alive.current) return;
      onCreate({
        title: trimmed,
        description: description.trim(),
        category,
        file,
        objectKey: presign.key,
      });
    } catch (uploadError) {
      if (!alive.current) return;
      setError(uploadError.message);
      setSubmitting(false);
    }
  }

  return (
    <div className="modal-back" onClick={submitting ? undefined : onClose}>
      <form
        className="sheet"
        role="dialog"
        aria-modal="true"
        aria-labelledby="create-pin-title"
        onClick={(event) => event.stopPropagation()}
        onSubmit={onSubmit}
      >
        <h2 id="create-pin-title">Nuevo pin</h2>
        <label className="field">
          Título
          <input
            autoFocus
            value={title}
            onChange={(event) => {
              setTitle(event.target.value);
              setError("");
            }}
          />
        </label>
        <label className="field">
          Descripción
          <textarea
            rows={3}
            value={description}
            onChange={(event) => setDescription(event.target.value)}
          />
        </label>
        <label className="field">
          Categoría
          <select value={category} onChange={(event) => setCategory(event.target.value)}>
            {categories.map((item) => (
              <option key={item} value={item}>
                {item}
              </option>
            ))}
          </select>
        </label>
        <label className="field">
          Imagen
          <input type="file" accept="image/*" onChange={onFile} disabled={submitting} />
        </label>
        {preview ? <img className="preview" src={preview} alt="" /> : null}
        {error ? <p className="form-error">{error}</p> : null}
        <div className="form-actions">
          <button type="button" className="text-action" onClick={onClose} disabled={submitting}>
            Cancelar
          </button>
          <button type="submit" className="is-current" disabled={submitting}>
            {submitting ? "Subiendo…" : "Agregar"}
          </button>
        </div>
      </form>
    </div>
  );
}
