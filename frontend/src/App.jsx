import { useEffect, useRef, useState } from "react";
import { useAuth } from "./auth/AuthContext.jsx";
import CreateBoardModal from "./components/CreateBoardModal.jsx";
import CreatePinModal from "./components/CreatePinModal.jsx";
import Masthead from "./components/Masthead.jsx";
import { categories, noteLook } from "./data/catalog.js";
import {
  addPinToBoard,
  createBoard as postBoard,
  getBoard,
  getBoards,
  getFeed,
  likePin,
  removePinFromBoard,
} from "./services/api.js";
import AuthView from "./views/AuthView.jsx";
import BoardView from "./views/BoardView.jsx";
import ExploreView from "./views/ExploreView.jsx";
import NotificationsView from "./views/NotificationsView.jsx";
import PinDetailView from "./views/PinDetailView.jsx";
import ProfileView from "./views/ProfileView.jsx";

function presentPin(pin, imageUrl) {
  return {
    ...noteLook(pin.id),
    id: pin.id,
    title: pin.title,
    description: pin.description ?? "",
    category: pin.category,
    likesCount: pin.likes_count ?? pin.likesCount ?? 0,
    objectKey: pin.object_key ?? pin.objectKey,
    imageUrl: imageUrl || pin.thumbnail_url || undefined,
  };
}

function keepPreview(previous, pin) {
  if (typeof previous?.imageUrl === "string" && previous.imageUrl.startsWith("blob:")) {
    return { ...pin, imageUrl: previous.imageUrl };
  }
  return previous?.imageUrl && !pin.imageUrl ? { ...pin, imageUrl: previous.imageUrl } : pin;
}

function presentBoard(detail) {
  const saved = detail.pins ?? [];
  return {
    id: detail.id,
    name: detail.name,
    description: detail.description ?? "",
    pinIds: saved.map((pin) => pin.id),
    pinsCount: Array.isArray(detail.pins) ? saved.length : (detail.pins_count ?? 0),
  };
}

export default function App() {
  const { user, status, loginRequired, acknowledgeLogin, logout } = useAuth();
  const [pins, setPins] = useState([]);
  const [boards, setBoards] = useState([]);
  const [screen, setScreen] = useState({ name: "explore" });
  const [query, setQuery] = useState("");
  const [category, setCategory] = useState("Todas");
  const [modal, setModal] = useState(null);
  const [openingId, setOpeningId] = useState(null);
  const [pinningId, setPinningId] = useState(null);
  const [arriving, setArriving] = useState(false);
  const [likedIds, setLikedIds] = useState([]);
  const [feedLoading, setFeedLoading] = useState(true);
  const [feedError, setFeedError] = useState("");
  const [boardsLoading, setBoardsLoading] = useState(false);
  const [boardsError, setBoardsError] = useState("");
  const [boardLoading, setBoardLoading] = useState(false);
  const [actionError, setActionError] = useState("");
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
    setActionError("");
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
    if (!requireUser()) return;
    openingRef.current = null;
    pinningRef.current = null;
    setOpeningId(null);
    setPinningId(null);
    setArriving(false);
    setActionError("");
    setScreen({ name: "profile" });
  }

  function openNotifications() {
    if (!requireUser()) return;
    openingRef.current = null;
    pinningRef.current = null;
    setOpeningId(null);
    setPinningId(null);
    setArriving(false);
    setActionError("");
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
    let active = true;
    getFeed()
      .then((page) => {
        if (!active) return;
        setPins((current) =>
          page.items.map((item) => {
            const pin = presentPin(item);
            const previous = current.find((entry) => entry.id === pin.id);
            return keepPreview(previous, pin);
          }),
        );
        setFeedError("");
      })
      .catch((error) => {
        if (!active || error.status === 401) return;
        setFeedError(error.message);
      })
      .finally(() => {
        if (active) setFeedLoading(false);
      });
    return () => {
      active = false;
    };
  }, []);

  useEffect(() => {
    if (!user) {
      setBoards([]);
      setBoardsLoading(false);
      return undefined;
    }
    let active = true;
    setBoardsLoading(true);
    getBoards(user.id)
      .then((rows) => Promise.all(rows.map((board) => getBoard(board.id))))
      .then((details) => {
        if (!active) return;
        const savedPins = details.flatMap((detail) => detail.pins ?? []);
        setPins((current) => {
          const next = [...current];
          for (const item of savedPins) {
            const pin = presentPin(item);
            const index = next.findIndex((entry) => entry.id === pin.id);
            if (index === -1) next.push(pin);
            else next[index] = keepPreview(next[index], pin);
          }
          return next;
        });
        setBoards(details.map(presentBoard));
        setBoardsError("");
      })
      .catch((error) => {
        if (!active || error.status === 401) return;
        setBoardsError(error.message);
      })
      .finally(() => {
        if (active) setBoardsLoading(false);
      });
    return () => {
      active = false;
    };
  }, [user]);

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

  async function openBoard(id) {
    openingRef.current = null;
    pinningRef.current = null;
    setOpeningId(null);
    setPinningId(null);
    setArriving(false);
    setActionError("");
    setScreen({ name: "board", id });
    setBoardLoading(true);
    try {
      const detail = await getBoard(id);
      const saved = (detail.pins ?? []).map((item) => presentPin(item));
      setPins((current) => {
        const next = [...current];
        for (const pin of saved) {
          const index = next.findIndex((entry) => entry.id === pin.id);
          if (index === -1) next.push(pin);
          else next[index] = keepPreview(next[index], pin);
        }
        return next;
      });
      setBoards((current) => {
        const updated = presentBoard(detail);
        return current.some((board) => board.id === id)
          ? current.map((board) => (board.id === id ? updated : board))
          : [...current, updated];
      });
    } catch (error) {
      if (error.status !== 401) setActionError(error.message);
    } finally {
      setBoardLoading(false);
    }
  }

  async function toggleLike(pinId) {
    if (likedIds.includes(pinId)) return;
    if (!requireUser()) return;
    setLikedIds((current) => [...current, pinId]);
    setActionError("");
    try {
      const result = await likePin(pinId);
      setPins((current) =>
        current.map((pin) => (pin.id === pinId ? { ...pin, likesCount: result.likes_count } : pin)),
      );
    } catch (error) {
      setLikedIds((current) => current.filter((id) => id !== pinId));
      if (error.status !== 401) setActionError(error.message);
    }
  }

  async function togglePinOnBoard(boardId, pinId) {
    if (!requireUser()) return;
    const board = boards.find((item) => item.id === boardId);
    if (!board) return;
    const saved = board.pinIds.includes(pinId);
    setActionError("");
    try {
      if (saved) await removePinFromBoard(boardId, pinId);
      else await addPinToBoard(boardId, pinId);
      setBoards((current) =>
        current.map((item) => {
          if (item.id !== boardId) return item;
          const pinIds = saved
            ? item.pinIds.filter((id) => id !== pinId)
            : [...item.pinIds, pinId];
          return { ...item, pinIds, pinsCount: pinIds.length };
        }),
      );
    } catch (error) {
      if (error.status !== 401) setActionError(error.message);
    }
  }

  function createPin({ id, title, description, category: pinCategory, file, objectKey }) {
    const pin = presentPin(
      {
        id: id ?? crypto.randomUUID(),
        title,
        description,
        category: pinCategory,
        object_key: objectKey,
        likes_count: 0,
      },
      file ? URL.createObjectURL(file) : undefined,
    );
    setPins((current) => [pin, ...current.filter((item) => item.id !== pin.id)]);
    setModal(null);
    setArriving(false);
    setScreen({ name: "pin", id: pin.id });
  }

  async function createBoard({ name, description }) {
    const created = await postBoard({ name, description });
    const board = presentBoard(created);
    setBoards((current) => [...current, board]);
    setModal(null);
    setScreen({ name: "board", id: board.id });
  }

  function signOut() {
    logout();
    setBoards([]);
    if (screen.name === "notifications" || screen.name === "auth" || screen.name === "profile" || screen.name === "board") {
      openExplore();
    }
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
          loading={feedLoading}
          error={feedError}
        />
      ) : null}
      {screen.name === "pin" ? (
        <PinDetailView
          pin={selectedPin}
          boards={boards}
          arriving={arriving}
          liked={selectedPin ? likedIds.includes(selectedPin.id) : false}
          error={actionError}
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
          loading={boardsLoading}
          error={boardsError}
          onOpen={openBoard}
          onCreate={() => {
            if (requireUser()) setModal("board");
          }}
        />
      ) : null}
      {screen.name === "board" ? (
        <BoardView
          board={selectedBoard}
          pins={pins}
          loading={boardLoading}
          error={actionError}
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
