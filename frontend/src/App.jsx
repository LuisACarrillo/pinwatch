import { useEffect, useRef, useState } from "react";
import CreateBoardModal from "./components/CreateBoardModal.jsx";
import CreatePinModal from "./components/CreatePinModal.jsx";
import Masthead from "./components/Masthead.jsx";
import { categories, initialBoards, initialPins, noteLooks } from "./data/catalog.js";
import BoardView from "./views/BoardView.jsx";
import ExploreView from "./views/ExploreView.jsx";
import PinDetailView from "./views/PinDetailView.jsx";
import ProfileView from "./views/ProfileView.jsx";

export default function App() {
  const [pins, setPins] = useState(initialPins);
  const [boards, setBoards] = useState(initialBoards);
  const [screen, setScreen] = useState({ name: "explore" });
  const [query, setQuery] = useState("");
  const [category, setCategory] = useState("Todas");
  const [modal, setModal] = useState(null);
  const [openingId, setOpeningId] = useState(null);
  const [pinningId, setPinningId] = useState(null);
  const [arriving, setArriving] = useState(false);
  const openingRef = useRef(null);
  const pinningRef = useRef(null);

  const section = screen.name === "profile" || screen.name === "board" ? "profile" : "explore";
  const selectedPin = pins.find((pin) => pin.id === screen.id);
  const selectedBoard = boards.find((board) => board.id === screen.id);

  function finishPin(id) {
    if (pinningRef.current !== id) return;
    pinningRef.current = null;
    setPinningId(null);
  }

  function openExplore() {
    const returningId = screen.name === "pin" ? screen.id : null;
    const reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    openingRef.current = null;
    setOpeningId(null);
    setArriving(false);
    setScreen({ name: "explore" });
    if (returningId && !reduce) {
      pinningRef.current = returningId;
      setPinningId(returningId);
    } else {
      pinningRef.current = null;
      setPinningId(null);
    }
  }

  function openProfile() {
    openingRef.current = null;
    pinningRef.current = null;
    setOpeningId(null);
    setPinningId(null);
    setArriving(false);
    setScreen({ name: "profile" });
  }

  function beginOpen(id) {
    if (openingRef.current || pinningRef.current) return;
    const reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    if (reduce) {
      setArriving(false);
      setScreen({ name: "pin", id });
      return;
    }
    openingRef.current = id;
    setArriving(false);
    setOpeningId(id);
  }

  function finishOpen(id) {
    if (openingRef.current !== id) return;
    openingRef.current = null;
    setOpeningId(null);
    setArriving(true);
    setScreen({ name: "pin", id });
  }

  useEffect(() => {
    if (!openingId) return undefined;
    const timer = window.setTimeout(() => finishOpen(openingId), 1800);
    return () => window.clearTimeout(timer);
  }, [openingId]);

  useEffect(() => {
    if (!pinningId) return undefined;
    const timer = window.setTimeout(() => finishPin(pinningId), 1600);
    return () => window.clearTimeout(timer);
  }, [pinningId]);

  function togglePinOnBoard(boardId, pinId) {
    setBoards((current) =>
      current.map((board) => {
        if (board.id !== boardId) return board;
        const saved = board.pinIds.includes(pinId);
        return {
          ...board,
          pinIds: saved
            ? board.pinIds.filter((id) => id !== pinId)
            : [...board.pinIds, pinId],
        };
      }),
    );
  }

  function createPin({ title, description, category: pinCategory, file }) {
    const look = noteLooks[pins.length % noteLooks.length];
    const pin = {
      id: crypto.randomUUID(),
      title,
      description,
      category: pinCategory,
      imageUrl: file ? URL.createObjectURL(file) : undefined,
      ...look,
    };
    setPins((current) => [pin, ...current]);
    setModal(null);
    setArriving(false);
    setScreen({ name: "pin", id: pin.id });
  }

  function createBoard({ name, description }) {
    const board = {
      id: crypto.randomUUID(),
      name,
      description,
      pinIds: [],
    };
    setBoards((current) => [...current, board]);
    setModal(null);
    setScreen({ name: "board", id: board.id });
  }

  return (
    <div className="cork">
      <Masthead
        section={section}
        onExplore={openExplore}
        onProfile={openProfile}
        onCreate={() => setModal("pin")}
      />
      {screen.name === "explore" ? (
        <ExploreView
          pins={pins}
          query={query}
          category={category}
          categories={categories}
          onQuery={setQuery}
          onCategory={setCategory}
          fallingId={openingId}
          pinningId={pinningId}
          onOpen={beginOpen}
          onFallen={finishOpen}
          onPinned={finishPin}
        />
      ) : null}
      {screen.name === "pin" ? (
        <PinDetailView
          pin={selectedPin}
          boards={boards}
          arriving={arriving}
          onBack={openExplore}
          onToggle={togglePinOnBoard}
          onCreateBoard={() => setModal("board")}
        />
      ) : null}
      {screen.name === "profile" ? (
        <ProfileView
          boards={boards}
          onOpen={(id) => setScreen({ name: "board", id })}
          onCreate={() => setModal("board")}
        />
      ) : null}
      {screen.name === "board" ? (
        <BoardView
          board={selectedBoard}
          pins={pins}
          onBack={openProfile}
          fallingId={openingId}
          onOpen={beginOpen}
          onFallen={finishOpen}
        />
      ) : null}
      {modal === "pin" ? (
        <CreatePinModal
          categories={categories}
          onClose={() => setModal(null)}
          onCreate={createPin}
        />
      ) : null}
      {modal === "board" ? (
        <CreateBoardModal onClose={() => setModal(null)} onCreate={createBoard} />
      ) : null}
    </div>
  );
}
