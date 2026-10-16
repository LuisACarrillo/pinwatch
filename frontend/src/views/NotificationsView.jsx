import { useEffect, useState } from "react";
import { getNotifications } from "../services/api.js";

export default function NotificationsView() {
  const [items, setItems] = useState(null);
  const [error, setError] = useState("");

  useEffect(() => {
    let active = true;
    getNotifications()
      .then((notifications) => {
        if (active) setItems(notifications);
      })
      .catch((loadError) => {
        if (!active || loadError.status === 401) return;
        setError(loadError.message);
        setItems([]);
      });
    return () => {
      active = false;
    };
  }, []);

  return (
    <div className="page">
      <div className="page-head">
        <h2>Notificaciones</h2>
        <p className="quiet">Avisos de tus pines y tableros.</p>
      </div>
      {error ? <p className="form-error">{error}</p> : null}
      {items === null ? <p className="empty">Cargando…</p> : null}
      {items?.length === 0 && !error ? <p className="empty">Todavía no hay notificaciones.</p> : null}
      {items?.length ? (
        <ul className="notice-list">
          {items.map((item) => (
            <li key={item.id} className="empty">
              <p>{item.message}</p>
              <p className="quiet">{new Date(item.created_at).toLocaleString()}</p>
            </li>
          ))}
        </ul>
      ) : null}
    </div>
  );
}
