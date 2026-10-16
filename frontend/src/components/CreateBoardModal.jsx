import { useEffect, useState } from "react";

export default function CreateBoardModal({ onClose, onCreate, board = null }) {
  const editing = Boolean(board);
  const [name, setName] = useState(board?.name ?? "");
  const [description, setDescription] = useState(board?.description ?? "");
  const [error, setError] = useState("");
  const [submitting, setSubmitting] = useState(false);

  useEffect(() => {
    function onKey(event) {
      if (event.key === "Escape" && !submitting) onClose();
    }
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onClose, submitting]);

  async function onSubmit(event) {
    event.preventDefault();
    const trimmed = name.trim();
    if (!trimmed) {
      setError("Escribe un nombre.");
      return;
    }
    setSubmitting(true);
    setError("");
    try {
      await onCreate({ name: trimmed, description: description.trim() });
    } catch (createError) {
      setError(createError.message);
      setSubmitting(false);
    }
  }

  return (
    <div className="modal-back" onClick={submitting ? undefined : onClose}>
      <form
        className="sheet"
        role="dialog"
        aria-modal="true"
        aria-labelledby="create-board-title"
        onClick={(event) => event.stopPropagation()}
        onSubmit={onSubmit}
      >
        <h2 id="create-board-title">{editing ? "Editar colección" : "Nueva colección"}</h2>
        <label className="field">
          Nombre
          <input
            autoFocus
            value={name}
            onChange={(event) => {
              setName(event.target.value);
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
        {error ? <p className="form-error">{error}</p> : null}
        <div className="form-actions">
          <button type="button" className="text-action" onClick={onClose} disabled={submitting}>
            Cancelar
          </button>
          <button type="submit" className="is-current" disabled={submitting}>
            {editing ? (submitting ? "Guardando…" : "Guardar") : submitting ? "Creando…" : "Crear"}
          </button>
        </div>
      </form>
    </div>
  );
}
