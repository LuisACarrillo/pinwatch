export const categories = ["Foto", "Objeto", "Lugar"];

export const initialPins = [
  {
    id: "silla",
    title: "Silla de madera",
    description: "Asiento bajo, patas torneadas y un respaldo que deja pasar la luz.",
    category: "Objeto",
    paper: "#fff8e8",
    rot: "-0.5deg",
    sky: "#3d342c",
    ground: "#c4845a",
    split: "34%",
    tall: false,
  },
  {
    id: "pasillo",
    title: "Pasillo",
    description: "Corredor estrecho con el piso más oscuro que la pared.",
    category: "Lugar",
    paper: "#fff3c4",
    rot: "0.7deg",
    sky: "#f3d7a4",
    ground: "#c4623a",
    split: "52%",
    tall: true,
  },
  {
    id: "taza",
    title: "Taza",
    description: "Cerámica roja, borde claro, usada en la mesa del estudio.",
    category: "Objeto",
    paper: "#fff6ee",
    rot: "-0.4deg",
    sky: "#f7e7d4",
    ground: "#a33b32",
    split: "70%",
    tall: false,
  },
  {
    id: "estudio",
    title: "Estudio",
    description: "Mesa de trabajo contra una pared lisa, casi sin objetos.",
    category: "Lugar",
    paper: "#fff8e8",
    rot: "0.6deg",
    sky: "#d8b48a",
    ground: "#f6efe2",
    split: "28%",
    tall: false,
  },
  {
    id: "ventana",
    title: "Ventana",
    description: "Marco de madera y un rectángulo de luz al fondo del cuarto.",
    category: "Foto",
    paper: "#fff1d0",
    rot: "-0.8deg",
    sky: "#f8ead4",
    ground: "#8d5a3c",
    split: "58%",
    tall: true,
  },
  {
    id: "mesa",
    title: "Mesa",
    description: "Superficie oscura con una franja de luz cálida en el borde.",
    category: "Objeto",
    paper: "#fffaf2",
    rot: "0.4deg",
    sky: "#4a3428",
    ground: "#e2b56a",
    split: "42%",
    tall: false,
  },
  {
    id: "patio",
    title: "Patio",
    description: "Suelo de barro y una pared que corta el sol a media tarde.",
    category: "Lugar",
    paper: "#fff6d8",
    rot: "0.5deg",
    sky: "#f2c9a0",
    ground: "#8a4b32",
    split: "46%",
    tall: false,
  },
  {
    id: "lampara",
    title: "Lámpara",
    description: "Pantalla clara sobre un pie delgado, vista de cerca.",
    category: "Foto",
    paper: "#fffaf2",
    rot: "-0.3deg",
    sky: "#f6efe4",
    ground: "#6b5344",
    split: "62%",
    tall: true,
  },
];

export const initialBoards = [
  {
    id: "casa",
    name: "Casa",
    description: "Objetos que viven en el estudio.",
    pinIds: ["silla", "taza", "mesa"],
  },
  {
    id: "recorrido",
    name: "Recorrido",
    description: "Lugares para volver a mirar.",
    pinIds: ["pasillo", "ventana", "patio"],
  },
];

export function noteLook(id) {
  let hash = 0;
  for (let index = 0; index < id.length; index += 1) {
    hash = (hash + id.charCodeAt(index)) >>> 0;
  }
  return noteLooks[hash % noteLooks.length];
}

export const noteLooks = [
  { paper: "#fff8e8", sky: "#3d342c", ground: "#c4845a", split: "40%", tall: false, rot: "-0.6deg" },
  { paper: "#fff3c4", sky: "#f3d7a4", ground: "#c4623a", split: "55%", tall: true, rot: "0.5deg" },
  { paper: "#fff6ee", sky: "#f7e7d4", ground: "#a33b32", split: "68%", tall: false, rot: "-0.4deg" },
  { paper: "#fff1d0", sky: "#f8ead4", ground: "#8d5a3c", split: "48%", tall: false, rot: "0.7deg" },
];
