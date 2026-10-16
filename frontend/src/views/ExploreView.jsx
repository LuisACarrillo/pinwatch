import PinGrid from "../components/PinGrid.jsx";
import SearchFilters from "../components/SearchFilters.jsx";

export default function ExploreView({
  pins,
  query,
  category,
  categories,
  onQuery,
  onCategory,
  fallingId,
  pinningId,
  onOpen,
  onFallen,
  onPinned,
  loading = false,
  error = "",
}) {
  const needle = query.trim().toLowerCase();
  const visible = pins.filter((pin) => {
    const matchesCategory = category === "Todas" || pin.category === category;
    const matchesQuery =
      needle.length === 0 ||
      pin.title.toLowerCase().includes(needle) ||
      pin.description.toLowerCase().includes(needle);
    return matchesCategory && matchesQuery;
  });

  return (
    <>
      <SearchFilters
        query={query}
        category={category}
        categories={categories}
        onQuery={onQuery}
        onCategory={onCategory}
      />
      {error ? <p className="form-error">{error}</p> : null}
      {loading ? <p className="empty">Cargando…</p> : null}
      {loading ? null : (
        <PinGrid
          pins={visible}
          fallingId={fallingId}
          pinningId={pinningId}
          onOpen={onOpen}
          onFallen={onFallen}
          onPinned={onPinned}
          empty={pins.length === 0 ? "Todavía no hay pines." : "Nada coincide con esa búsqueda."}
        />
      )}
    </>
  );
}
