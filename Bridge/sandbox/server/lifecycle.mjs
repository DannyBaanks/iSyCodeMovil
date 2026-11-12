/**
 * The life of a sandbox: active → suspended → destroyed.
 *
 * The rule that shapes this whole file: **never destroy work that was not delivered
 * first**. A sandbox that goes idle is *suspended*, not deleted, and it only reaches
 * "destroyed" once its snapshot has been handed to whoever asked for it.
 *
 * Pure logic, no Docker and no HTTP here: the state machine is the part worth testing
 * exhaustively, so it is kept apart from the parts that touch the machine.
 */

/** What the caller may ask for when creating a sandbox. */
export const TTL_CHOICES = Object.freeze([30, 120, 720]); // minutes: 30 min, 2 h, 12 h

export const PHASES = Object.freeze({
  ACTIVE: "active",
  SUSPENDED: "suspended",
  DESTROYED: "destroyed",
});

export class LifecycleError extends Error {}

/**
 * Create the lifecycle record for a new sandbox.
 *
 * `ttlMinutes` must be one of TTL_CHOICES: an arbitrary value would let a caller ask for
 * a sandbox that outlives the host's own maintenance window, so it is a closed list.
 */
export function newLifecycle(id, ttlMinutes, now) {
  if (!TTL_CHOICES.includes(ttlMinutes)) {
    throw new LifecycleError(`ttl must be one of ${TTL_CHOICES.join(", ")} minutes`);
  }
  return {
    id,
    phase: PHASES.ACTIVE,
    ttlMs: ttlMinutes * 60_000,
    createdAt: now,
    lastUsedAt: now,
    /** Set when the phase changes, so the UI can explain what happened and when. */
    phaseChangedAt: now,
    /** True once the snapshot has been handed over; only then may we destroy. */
    snapshotDelivered: false,
    snapshotTakenAt: null,
    reason: "created",
  };
}

/** Real use resets the countdown: a sandbox nobody touched is the one that expires. */
export function touch(state, now) {
  if (state.phase === PHASES.DESTROYED) return { ...state };
  return { ...state, lastUsedAt: now, phaseChangedAt: now, phase: PHASES.ACTIVE, reason: "used" };
}

export function expiresAt(state) {
  return state.lastUsedAt + state.ttlMs;
}

export function remainingMs(state, now) {
  if (state.phase === PHASES.DESTROYED) return 0;
  return Math.max(0, expiresAt(state) - now);
}

/**
 * Take the snapshot. Marks it delivered so the sandbox becomes destroyable.
 * Called when the caller downloads it — not before.
 */
export function markSnapshotDelivered(state, now) {
  if (state.phase === PHASES.DESTROYED) {
    throw new LifecycleError("sandbox is already destroyed");
  }
  return { ...state, snapshotDelivered: true, snapshotTakenAt: now };
}

/**
 * Advance the state machine. Returns a new state, never mutates.
 *
 * `now` is injected so expiry can be tested with a fake clock instead of waiting.
 */
export function advance(state, now, { destroyWhenDelivered = true } = {}) {
  if (state.phase === PHASES.DESTROYED) return state;

  const idle = now >= expiresAt(state);
  if (!idle) return state;

  if (state.phase === PHASES.ACTIVE) {
    // First consequence of going idle: stop the compute, keep the data.
    return { ...state, phase: PHASES.SUSPENDED, phaseChangedAt: now, reason: "idle" };
  }

  // Already suspended: it may only be destroyed once the work is safe.
  if (state.phase === PHASES.SUSPENDED && state.snapshotDelivered && destroyWhenDelivered) {
    return { ...state, phase: PHASES.DESTROYED, phaseChangedAt: now, reason: "snapshot delivered" };
  }

  // Suspended with the snapshot not delivered: it stays, by design.
  return state;
}

/** Can this sandbox be destroyed right now, without losing anything? */
export function canDestroy(state) {
  return state.phase !== PHASES.DESTROYED && state.snapshotDelivered;
}

/** Why a suspended sandbox has not been destroyed yet, in words a person can read. */
export function describe(state, now) {
  const left = Math.ceil(remainingMs(state, now) / 60_000);
  switch (state.phase) {
    case PHASES.ACTIVE:
      return `Activo. Se suspende tras ${left} min sin usarse.`;
    case PHASES.SUSPENDED:
      return state.snapshotDelivered
        ? "Suspendido y guardado. Se puede destruir sin perder nada."
        : "Suspendido. No se destruye hasta que descargues el archivo.";
    case PHASES.DESTROYED:
      return "Destruido. Irreversible.";
    default:
      throw new LifecycleError(`unknown phase ${state.phase}`);
  }
}
