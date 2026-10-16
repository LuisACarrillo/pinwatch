import { useState } from "react";
import PinGrid from "../components/PinGrid.jsx";

export default function BoardView({
  board,
  pins,
  loading = false,
  error = "",
  onBack,
  onEdit,
  onDelete,
  fallingId,
  onOpen,
  onFallen,
}) {
  const [confirmingDelete, setConfirmingDelete] = useState(false);

  if (!board) {
    return (
      <div className="page">
        <button type="button" className="text-action" onClick={onBack}>
          Volver al perfil
        </button>
        <p className="empty">Ese tablero ya no está.</p>
      </div>
    );
  }

  const saved = pins.filter((pin) => board.pinIds.includes(pin.id));

  return (
    <div className="page">
      <div className="page-head">
        <button type="button" className="text-action" onClick={onBack}>
          Volver al perfil
        </button>
        <h2>{board.name}</h2>
        {board.description ? <p className="quiet">{board.description}</p> : null}
        <div className="board-actions">
          <button type="button" className="text-action" onClick={onEdit}>
            Editar
          </button>
          {confirmingDelete ? (
            <>
              <p className="quiet">¿Borrar esta colección?</p>
              <button type="button" className="text-action" onClick={onDelete}>
                Borrar
              </button>
              <button type="button" className="text-action" onClick={() => setConfirmingDelete(false)}>
                Cancelar
              </button>
            </>
          ) : (
            <button type="button" className="text-action" onClick={() => setConfirmingDelete(true)}>
              Borrar
            </button>
          )}
        </div>
        {error ? <p className="form-error">{error}</p> : null}
      </div>
      {loading ? <p className="empty">Cargando…</p> : null}
      {loading ? null : (
        <PinGrid
          pins={saved}
          fallingId={fallingId}
          onOpen={onOpen}
          onFallen={onFallen}
          empty="Este tablero todavía no tiene pines."
        />
      )}
    </div>
  );
}
