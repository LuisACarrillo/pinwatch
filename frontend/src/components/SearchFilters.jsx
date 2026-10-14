export default function SearchFilters({ query, category, categories, onQuery, onCategory }) {
  const options = ["Todas", ...categories];

  return (
    <div className="filters">
      <span className="tack" aria-hidden="true" />
      <label className="search-slip">
        <span className="search-caption">Buscar</span>
        <input
          type="search"
          value={query}
          placeholder="Silla, pasillo, taza"
          onChange={(event) => onQuery(event.target.value)}
        />
      </label>
      <div className="chips" role="group" aria-label="Categoría">
        {options.map((item) => (
          <button
            key={item}
            type="button"
            className={category === item ? "is-current" : ""}
            aria-pressed={category === item}
            onClick={() => onCategory(item)}
          >
            {item}
          </button>
        ))}
      </div>
    </div>
  );
}
