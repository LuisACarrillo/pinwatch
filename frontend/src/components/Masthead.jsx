import HealthStatus from "./HealthStatus.jsx";

function BellIcon() {
  return (
    <svg className="icon" viewBox="0 0 24 24" aria-hidden="true">
      <path d="M6 9a6 6 0 0 1 12 0c0 4.5.8 6.2 1.6 7.2.3.4.4.8.4 1.3H4c0-.5.1-.9.4-1.3C5.2 15.2 6 13.5 6 9z" />
      <path d="M10 19.5a2 2 0 0 0 4 0" />
    </svg>
  );
}

export default function Masthead({
  section,
  user,
  onExplore,
  onProfile,
  onNotifications,
  onCreate,
  onLogin,
  onLogout,
}) {
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
      <div className="mast-end">
        {user ? (
          <>
            <span className="mast-user">{user.username}</span>
            <button type="button" className="text-action" onClick={onLogout}>
              Salir
            </button>
          </>
        ) : (
          <button type="button" onClick={onLogin}>
            Entrar
          </button>
        )}
        <button
          type="button"
          className={section === "notifications" ? "mast-bell is-current" : "mast-bell"}
          aria-label="Notificaciones"
          onClick={onNotifications}
        >
          <BellIcon />
        </button>
        <HealthStatus />
      </div>
    </header>
  );
}
