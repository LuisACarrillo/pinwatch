import PinGrid from "../components/PinGrid.jsx";

export default function BoardView({
  board,
  pins,
  loading = false,
  error = "",
  onBack,
  fallingId,
  onOpen,
  onFallen,
}) {
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
