import { useEffect, useRef, useState } from "react";
import { useAuth } from "./auth/AuthContext.jsx";
import CreateBoardModal from "./components/CreateBoardModal.jsx";
import CreatePinModal from "./components/CreatePinModal.jsx";
import Masthead from "./components/Masthead.jsx";
import { categories, initialBoards, initialPins, noteLooks } from "./data/catalog.js";
import { createBoard as postBoard } from "./services/api.js";
import AuthView from "./views/AuthView.jsx";
import BoardView from "./views/BoardView.jsx";
import ExploreView from "./views/ExploreView.jsx";
import NotificationsView from "./views/NotificationsView.jsx";
import PinDetailView from "./views/PinDetailView.jsx";
import ProfileView from "./views/ProfileView.jsx";

export default function App() {
  const { user, status, loginRequired, acknowledgeLogin, logout } = useAuth();
  const [pins, setPins] = useState(initialPins);
  const [boards, setBoards] = useState(initialBoards);
  const [screen, setScreen] = useState({ name: "explore" });
  const [query, setQuery] = useState("");
  const [category, setCategory] = useState("Todas");
  const [modal, setModal] = useState(null);
  const [openingId, setOpeningId] = useState(null);
  const [pinningId, setPinningId] = useState(null);
  const [arriving, setArriving] = useState(false);
  const [likedIds, setLikedIds] = useState([]);
  const openingRef = useRef(null);
  const pinningRef = useRef(null);

  const section =
    screen.name === "profile" || screen.name === "board"
      ? "profile"
      : screen.name === "notifications"
        ? "notifications"
        : screen.name === "auth"
          ? ""
          : "explore";
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

  function openNotifications() {
    if (!requireUser()) return;
    openingRef.current = null;
    pinningRef.current = null;
    setOpeningId(null);
    setPinningId(null);
    setArriving(false);
    setScreen({ name: "notifications" });
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
    if (!loginRequired) return;
    acknowledgeLogin();
    setModal(null);
    setScreen((current) => (current.name === "auth" ? current : { name: "auth", mode: "login" }));
  }, [loginRequired, acknowledgeLogin]);

  function openAuth(mode = "login") {
    openingRef.current = null;
    pinningRef.current = null;
    setOpeningId(null);
    setPinningId(null);
    setArriving(false);
    setModal(null);
    setScreen({ name: "auth", mode });
  }

  function requireUser() {
    if (status === "checking") return false;
    if (!user) {
      openAuth("login");
      return false;
    }
    return true;
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

  function toggleLike(pinId) {
    setLikedIds((current) =>
      current.includes(pinId) ? current.filter((id) => id !== pinId) : [...current, pinId],
    );
  }

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

  function createPin({ id, title, description, category: pinCategory, file, objectKey }) {
    const look = noteLooks[pins.length % noteLooks.length];
    const pin = {
      id: id ?? crypto.randomUUID(),
      title,
      description,
      category: pinCategory,
      imageUrl: file ? URL.createObjectURL(file) : undefined,
      objectKey,
      ...look,
    };
    setPins((current) => [pin, ...current]);
    setModal(null);
    setArriving(false);
    setScreen({ name: "pin", id: pin.id });
  }

  async function createBoard({ name, description }) {
    const created = await postBoard({ name, description });
    const board = {
      id: created.id,
      name: created.name,
      description: created.description,
      pinIds: [],
    };
    setBoards((current) => [...current, board]);
    setModal(null);
    setScreen({ name: "board", id: board.id });
  }

  function signOut() {
    logout();
    if (screen.name === "notifications" || screen.name === "auth") openExplore();
  }

  return (
    <div className="cork">
      <Masthead
        section={section}
        user={user}
        onExplore={openExplore}
        onProfile={openProfile}
        onNotifications={openNotifications}
        onCreate={() => {
          if (requireUser()) setModal("pin");
        }}
        onLogin={() => openAuth("login")}
        onLogout={signOut}
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
          liked={selectedPin ? likedIds.includes(selectedPin.id) : false}
          onBack={openExplore}
          onToggle={togglePinOnBoard}
          onLike={() => selectedPin && toggleLike(selectedPin.id)}
          onCreateBoard={() => {
            if (requireUser()) setModal("board");
          }}
        />
      ) : null}
      {screen.name === "notifications" ? <NotificationsView /> : null}
      {screen.name === "auth" ? (
        <AuthView
          mode={screen.mode === "register" ? "register" : "login"}
          onMode={(mode) => setScreen({ name: "auth", mode })}
          onDone={openExplore}
        />
      ) : null}
      {screen.name === "profile" ? (
        <ProfileView
          user={user}
          boards={boards}
          onOpen={(id) => setScreen({ name: "board", id })}
          onCreate={() => {
            if (requireUser()) setModal("board");
          }}
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
