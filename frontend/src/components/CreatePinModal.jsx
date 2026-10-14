import { useEffect, useState } from "react";

export default function CreatePinModal({ categories, onClose, onCreate }) {
  const [title, setTitle] = useState("");
  const [description, setDescription] = useState("");
  const [category, setCategory] = useState(categories[0]);
  const [file, setFile] = useState(null);
  const [preview, setPreview] = useState("");
  const [error, setError] = useState("");

  useEffect(() => {
    function onKey(event) {
      if (event.key === "Escape") onClose();
    }
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onClose]);

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

  function onSubmit(event) {
    event.preventDefault();
    const trimmed = title.trim();
    if (!trimmed) {
      setError("Escribe un título.");
      return;
    }
    onCreate({
      title: trimmed,
      description: description.trim(),
      category,
      file,
    });
  }

  return (
    <div className="modal-back" onClick={onClose}>
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
          <input type="file" accept="image/*" onChange={onFile} />
        </label>
        {preview ? <img className="preview" src={preview} alt="" /> : null}
        {error ? <p className="form-error">{error}</p> : null}
        <div className="form-actions">
          <button type="button" className="text-action" onClick={onClose}>
            Cancelar
          </button>
          <button type="submit" className="is-current">
            Agregar
          </button>
        </div>
      </form>
    </div>
  );
}
