import { useEffect, useRef } from "react";
import PinShot from "./PinShot.jsx";

const BEND_SLICES = 18;

function NoteFace({ pin }) {
  return (
    <span className="leaf-inner">
      <PinShot pin={pin} />
      <p>{pin.title}</p>
    </span>
  );
}

function Bend({ index, pin }) {
  return (
    <span className="seg" style={{ "--i": index }}>
      <span className="seg-clip">
        <NoteFace pin={pin} />
      </span>
      {index < BEND_SLICES - 1 ? <Bend index={index + 1} pin={pin} /> : null}
    </span>
  );
}

export default function PinCard({ pin, falling, pinning, onOpen, onFallen, onPinned }) {
  const buttonRef = useRef(null);

  useEffect(() => {
    if (!pinning) return;
    buttonRef.current?.scrollIntoView({ block: "center", inline: "nearest", behavior: "instant" });
  }, [pinning]);

  function handleAnimationEnd(event) {
    if (falling && event.animationName === "note-drop") onFallen(pin.id);
    if (pinning && event.animationName === "tack-stick") onPinned(pin.id);
  }

  const className = falling ? "note is-falling" : pinning ? "note is-pinning" : "note";

  return (
    <button
      ref={buttonRef}
      type="button"
      className={className}
      style={{ "--paper": pin.paper, "--rot": pin.rot }}
      aria-label={pin.title}
      onClick={() => onOpen(pin.id)}
      onAnimationEnd={handleAnimationEnd}
    >
      <span className="tack" aria-hidden="true" />
      <span className="note-leaf" style={{ "--n": BEND_SLICES }}>
        <span className="leaf-sizer" aria-hidden="true">
          <NoteFace pin={pin} />
        </span>
        <span className="leaf-cover" aria-hidden="true">
          <NoteFace pin={pin} />
        </span>
        <Bend index={0} pin={pin} />
      </span>
    </button>
  );
}
