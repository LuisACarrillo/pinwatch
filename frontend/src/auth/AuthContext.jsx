import { createContext, useContext, useEffect, useMemo, useState } from "react";
import {
  getAccessToken,
  getMe,
  loginAccount,
  registerAccount,
  setAccessToken,
  setUnauthorizedHandler,
} from "../services/api.js";

const AuthContext = createContext(null);

export function AuthProvider({ children }) {
  const [user, setUser] = useState(null);
  const [status, setStatus] = useState(getAccessToken() ? "checking" : "anonymous");
  const [loginRequired, setLoginRequired] = useState(false);

  useEffect(() => {
    setUnauthorizedHandler(() => {
      setUser(null);
      setStatus("anonymous");
      setLoginRequired(true);
    });
  }, []);

  useEffect(() => {
    if (!getAccessToken()) return undefined;
    let active = true;

    getMe()
      .then((me) => {
        if (!active) return;
        setUser(me);
        setStatus("authenticated");
      })
      .catch(() => {
        if (!active) return;
        setUser(null);
        setStatus("anonymous");
      });

    return () => {
      active = false;
    };
  }, []);

  const value = useMemo(
    () => ({
      user,
      status,
      loginRequired,
      acknowledgeLogin() {
        setLoginRequired(false);
      },
      async register(payload) {
        const result = await registerAccount(payload);
        setAccessToken(result.access_token);
        setUser(result.user);
        setStatus("authenticated");
        setLoginRequired(false);
        return result.user;
      },
      async login(payload) {
        const result = await loginAccount(payload);
        setAccessToken(result.access_token);
        const me = await getMe();
        setUser(me);
        setStatus("authenticated");
        setLoginRequired(false);
        return me;
      },
      logout() {
        setAccessToken("");
        setUser(null);
        setStatus("anonymous");
      },
    }),
    [user, status, loginRequired],
  );

  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>;
}

export function useAuth() {
  const value = useContext(AuthContext);
  if (!value) throw new Error("useAuth debe usarse dentro de AuthProvider.");
  return value;
}
