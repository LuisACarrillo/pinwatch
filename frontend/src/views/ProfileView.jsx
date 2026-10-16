export default function ProfileView({ user, boards, loading = false, error = "", onOpen, onCreate }) {
  return (
    <div className="page">
      <div className="page-head">
        <h2>{user ? `Tableros de ${user.username}` : "Tus tableros"}</h2>
      </div>
      {error ? <p className="form-error">{error}</p> : null}
      {loading ? <p className="empty">Cargando…</p> : null}
      <div className="notes">
        {boards.map((board, index) => {
          const count = board.pinsCount ?? board.pinIds.length;
          return (
          <button
            key={board.id}
            type="button"
            className="board-card"
            style={{ "--rot": index % 2 === 0 ? "-0.7deg" : "0.6deg" }}
            onClick={() => onOpen(board.id)}
          >
            <span className="tack" aria-hidden="true" />
            <p className="board-name">{board.name}</p>
            {board.description ? <p className="quiet">{board.description}</p> : null}
            <p className="count">
              {count} {count === 1 ? "pin" : "pines"}
            </p>
          </button>
          );
        })}
        <button type="button" className="board-card board-new" onClick={onCreate}>
          <span className="tack" aria-hidden="true" />
          Nueva colección
        </button>
      </div>
    </div>
  );
}
