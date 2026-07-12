export function freezeEventDetail<T extends object>(detail: T): Readonly<T> {
  for (const value of Object.values(detail)) {
    if (value !== null && typeof value === "object" && !Object.isFrozen(value)) {
      Object.freeze(value);
    }
  }
  return Object.freeze(detail);
}
