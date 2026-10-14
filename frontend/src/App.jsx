import HealthStatus from "./components/HealthStatus.jsx";

const pines = [
  { title: "Silla de madera", paper: "#fff8e8", rot: "-0.5deg", sky: "#3d342c", ground: "#c4845a", split: "34%", tall: false },
  { title: "Pasillo", paper: "#fff3c4", rot: "0.7deg", sky: "#f3d7a4", ground: "#c4623a", split: "52%", tall: true },
  { title: "Taza", paper: "#fff6ee", rot: "-0.4deg", sky: "#f7e7d4", ground: "#a33b32", split: "70%", tall: false },
  { title: "Estudio", paper: "#fff8e8", rot: "0.6deg", sky: "#d8b48a", ground: "#f6efe2", split: "28%", tall: false },
  { title: "Ventana", paper: "#fff1d0", rot: "-0.8deg", sky: "#f8ead4", ground: "#8d5a3c", split: "58%", tall: true },
  { title: "Mesa", paper: "#fffaf2", rot: "0.4deg", sky: "#4a3428", ground: "#e2b56a", split: "42%", tall: false },
];

export default function App() {
  return (
    <div className="cork">
      <header className="mast">
        <span className="tack" aria-hidden="true" />
        <span className="tack tack-end" aria-hidden="true" />
        <h1>PinWatch</h1>
        <nav aria-label="Categorías">
          <span className="on">Foto</span>
          <span>Objeto</span>
          <span>Lugar</span>
        </nav>
        <HealthStatus />
      </header>
      <main className="notes">
        {pines.map((pin) => (
          <article
            className="note"
            key={pin.title}
            style={{ "--paper": pin.paper, "--rot": pin.rot }}
          >
            <span className="tack" aria-hidden="true" />
            <div className={pin.tall ? "shot tall" : "shot"} style={{ background: pin.sky }}>
              <span className="band" style={{ height: pin.split, background: pin.ground }} />
            </div>
            <p>{pin.title}</p>
          </article>
        ))}
      </main>
    </div>
  );
}
