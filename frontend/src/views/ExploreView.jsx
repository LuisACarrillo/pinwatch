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
      <PinGrid
        pins={visible}
        fallingId={fallingId}
        pinningId={pinningId}
        onOpen={onOpen}
        onFallen={onFallen}
        onPinned={onPinned}
        empty="Nada coincide con esa búsqueda."
      />
    </>
  );
}
