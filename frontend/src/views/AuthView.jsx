import { useState } from "react";
import { useAuth } from "../auth/AuthContext.jsx";

export default function AuthView({ mode, onMode, onDone }) {
  const { login, register } = useAuth();
  const [username, setUsername] = useState("");
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [error, setError] = useState("");
  const [submitting, setSubmitting] = useState(false);
  const isRegister = mode === "register";

  async function onSubmit(event) {
    event.preventDefault();
    setError("");
    if (isRegister && !/^[A-Za-z0-9_.-]{3,50}$/.test(username.trim())) {
      setError("El usuario lleva de 3 a 50 caracteres: letras, números, punto, guion o guion bajo.");
      return;
    }
    if (password.length < 8) {
      setError("La contraseña necesita al menos 8 caracteres.");
      return;
    }
    setSubmitting(true);
    try {
      if (isRegister) {
        await register({ username: username.trim(), email: email.trim(), password });
      } else {
        await login({ email: email.trim(), password });
      }
      onDone();
    } catch (authError) {
      setError(authError.message);
      setSubmitting(false);
    }
  }

  return (
    <div className="page">
      <form className="sheet" onSubmit={onSubmit}>
        <h2>{isRegister ? "Crear cuenta" : "Entrar"}</h2>
        {isRegister ? (
          <label className="field">
            Usuario
            <input
              autoFocus
              autoComplete="username"
              value={username}
              onChange={(event) => setUsername(event.target.value)}
            />
          </label>
        ) : null}
        <label className="field">
          Email
          <input
            autoFocus={!isRegister}
            type="email"
            autoComplete="email"
            value={email}
            onChange={(event) => setEmail(event.target.value)}
            required
          />
        </label>
        <label className="field">
          Contraseña
          <input
            type="password"
            autoComplete={isRegister ? "new-password" : "current-password"}
            value={password}
            onChange={(event) => setPassword(event.target.value)}
            required
          />
        </label>
        {error ? <p className="form-error">{error}</p> : null}
        <div className="form-actions">
          <button type="submit" className="is-current" disabled={submitting}>
            {submitting ? "Un momento…" : isRegister ? "Crear cuenta" : "Entrar"}
          </button>
        </div>
        <p className="auth-switch">
          <button
            type="button"
            className="text-action"
            onClick={() => onMode(isRegister ? "login" : "register")}
            disabled={submitting}
          >
            {isRegister ? "Ya tengo cuenta" : "Crear cuenta"}
          </button>
        </p>
      </form>
    </div>
  );
}
