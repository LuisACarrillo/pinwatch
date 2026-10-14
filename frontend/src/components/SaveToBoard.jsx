export default function SaveToBoard({ boards, pinId, onToggle, onCreateBoard }) {
  return (
    <section className="save-block">
      <h3>Guardar en un tablero</h3>
      {boards.length === 0 ? (
        <p className="quiet">Todavía no hay tableros.</p>
      ) : (
        <ul className="board-picks">
          {boards.map((board) => {
            const saved = board.pinIds.includes(pinId);
            return (
              <li key={board.id}>
                <button
                  type="button"
                  className={saved ? "pick is-saved" : "pick"}
                  aria-pressed={saved}
                  onClick={() => onToggle(board.id, pinId)}
                >
                  <span>{board.name}</span>
                  <span>{saved ? "Guardado" : "Guardar"}</span>
                </button>
              </li>
            );
          })}
        </ul>
      )}
      <button type="button" className="text-action" onClick={onCreateBoard}>
        Nueva colección
      </button>
    </section>
  );
}
