export default function ProfileView({ boards, onOpen, onCreate }) {
  return (
    <div className="page">
      <div className="page-head">
        <h2>Tus tableros</h2>
      </div>
      <div className="notes">
        {boards.map((board, index) => (
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
              {board.pinIds.length} {board.pinIds.length === 1 ? "pin" : "pines"}
            </p>
          </button>
        ))}
        <button type="button" className="board-card board-new" onClick={onCreate}>
          <span className="tack" aria-hidden="true" />
          Nueva colección
        </button>
      </div>
    </div>
  );
}
