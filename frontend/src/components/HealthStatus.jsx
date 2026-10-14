import { useEffect, useState } from "react";
import { getHealth } from "../services/api.js";

export default function HealthStatus() {
  const [state, setState] = useState("loading");

  useEffect(() => {
    let active = true;

    getHealth()
      .then(() => {
        if (active) setState("ok");
      })
      .catch(() => {
        if (active) setState("error");
      });

    return () => {
      active = false;
    };
  }, []);

  const label =
    state === "loading" ? "Comprobando" : state === "ok" ? "En línea" : "Sin conexión";

  return (
    <p className={`link-state is-${state}`} role="status">
      {label}
    </p>
  );
}
