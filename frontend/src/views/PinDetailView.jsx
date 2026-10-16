import PinShot from "../components/PinShot.jsx";
import SaveToBoard from "../components/SaveToBoard.jsx";

function HeartIcon() {
  return (
    <svg className="icon" viewBox="0 0 24 24" aria-hidden="true">
      <path d="M12 19.5s-6.5-4-6.5-8.2a3.6 3.6 0 0 1 6.5-2 3.6 3.6 0 0 1 6.5 2c0 4.2-6.5 8.2-6.5 8.2z" />
    </svg>
  );
}

export default function PinDetailView({
  pin,
  boards,
  arriving = false,
  liked = false,
  onBack,
  onToggle,
  onLike,
  onCreateBoard,
  error = "",
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
        <div className="pin-actions">
          <button
            type="button"
            className={liked ? "like is-liked" : "like"}
            aria-pressed={liked}
            onClick={onLike}
          >
            <HeartIcon />
            <span>Me gusta {pin.likesCount ?? 0}</span>
          </button>
        </div>
        {error ? <p className="form-error">{error}</p> : null}
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
