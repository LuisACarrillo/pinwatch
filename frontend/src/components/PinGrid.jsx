import PinCard from "./PinCard.jsx";

export default function PinGrid({ pins, fallingId, pinningId, onOpen, onFallen, onPinned, empty }) {
  if (pins.length === 0) {
    return <p className="empty">{empty}</p>;
  }

  return (
    <div className={fallingId || pinningId ? "notes is-releasing" : "notes"}>
      {pins.map((pin) => (
        <PinCard
          key={pin.id}
          pin={pin}
          falling={pin.id === fallingId}
          pinning={pin.id === pinningId}
          onOpen={onOpen}
          onFallen={onFallen}
          onPinned={onPinned}
        />
      ))}
    </div>
  );
}
