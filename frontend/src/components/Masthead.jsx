import HealthStatus from "./HealthStatus.jsx";

export default function Masthead({ section, onExplore, onProfile, onCreate }) {
  return (
    <header className="mast">
      <span className="tack" aria-hidden="true" />
      <span className="tack tack-end" aria-hidden="true" />
      <h1>
        <button type="button" className="brand" onClick={onExplore}>
          PinWatch
        </button>
      </h1>
      <nav aria-label="Secciones">
        <button
          type="button"
          className={section === "explore" ? "is-current" : ""}
          onClick={onExplore}
        >
          Muro
        </button>
        <button
          type="button"
          className={section === "profile" ? "is-current" : ""}
          onClick={onProfile}
        >
          Perfil
        </button>
        <button type="button" onClick={onCreate}>
          Nuevo
        </button>
      </nav>
      <HealthStatus />
    </header>
  );
}
