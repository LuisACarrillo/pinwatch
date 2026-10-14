import PinGrid from "../components/PinGrid.jsx";

export default function BoardView({ board, pins, onBack, fallingId, onOpen, onFallen }) {
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
      </div>
      <PinGrid
        pins={saved}
        fallingId={fallingId}
        onOpen={onOpen}
        onFallen={onFallen}
        empty="Este tablero todavía no tiene pines."
      />
    </div>
  );
}
