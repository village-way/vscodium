"use client";

import { createContext, useContext } from "react";

export type AuthUser = { id: string; username: string };
type AuthValue = { user: AuthUser; csrfToken: string };

const AuthContext = createContext<AuthValue | null>(null);

export function AuthProvider({ value, children }: { value: AuthValue; children: React.ReactNode }) {
  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>;
}

export function useAuth(): AuthValue {
  const value = useContext(AuthContext);
  if (!value) throw new Error("useAuth must be used inside AuthProvider");
  return value;
}
