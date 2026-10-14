import PinShot from "../components/PinShot.jsx";
import SaveToBoard from "../components/SaveToBoard.jsx";

export default function PinDetailView({
  pin,
  boards,
  arriving = false,
  onBack,
  onToggle,
  onCreateBoard,
}) {
  if (!pin) {
    return (
      <div className="page">
        <button type="button" className="text-action" onClick={onBack}>
          Volver al muro
        </button>
        <p className="empty">Ese pin ya no está.</p>
      </div>
    );
  }

  return (
    <div className={arriving ? "page is-arriving" : "page"}>
      <button type="button" className="text-action" onClick={onBack}>
        Volver al muro
      </button>
      <article className={arriving ? "sheet detail is-arriving" : "sheet detail"} style={{ background: pin.paper }}>
        <PinShot pin={{ ...pin, tall: true }} hero />
        <p className="kicker">{pin.category}</p>
        <h2>{pin.title}</h2>
        <p className="quiet">{pin.description}</p>
        <SaveToBoard
          boards={boards}
          pinId={pin.id}
          onToggle={onToggle}
          onCreateBoard={onCreateBoard}
        />
      </article>
    </div>
  );
}
