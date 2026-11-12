/**
 * Network by phases: the sandbox talks to the internet only while doing one known task,
 * and to nothing else, and it closes the door again as soon as that task ends.
 *
 * The reasoning, because this is the part that could quietly become a hole:
 *
 *  - A sandbox born with network is a sandbox that can exfiltrate whatever it holds.
 *  - A sandbox with no network at all cannot clone a repo or install a dependency, so it
 *    cannot do real work either.
 *
 * The way through is not a compromise, it is a schedule: the door opens for one named
 * destination during one named operation, and shuts afterwards. `github.com` is not
 * allowed while you edit files; the package registry is not allowed while you clone.
 *
 * How it is enforced: the container is *reconnected* to a Docker network per phase. The
 * phase "cerrada" means no network attachment at all, which is the same guarantee the
 * isolation tests already measure.
 */
import { DockerError } from "./docker.mjs";

/** Every destination the project is willing to open, with why. Anything else is refused. */
export const ALLOWED_HOSTS = Object.freeze({
  // Code hosting: cloning and pushing. The only destination for real repository work.
  "github.com": "traer y publicar repositorios",
  "codeload.github.com": "github entrega los tarballs de clonado desde aqui",
  "raw.githubusercontent.com": "archivos sueltos de un repo (seguimiento y checkouts)",
  "objects.githubusercontent.com": "objetos del repositorio durante el clonado",
  // Package registries: installing the dependencies a repo declares.
  "registry.npmjs.org": "dependencias de Node",
  "pypi.org": "dependencias de Python",
  "files.pythonhosted.org": "python entrega los paquetes desde aqui",
  "deb.debian.org": "paquetes del sistema base (Debian)",
  "security.debian.org": "parches de seguridad del sistema base",
  "dl-cdn.alpinelinux.org": "paquetes del sistema base (Alpine)",
});

export const PHASES = Object.freeze({
  /** No network attachment at all. The default, and where a sandbox returns after every task. */
  CLOSED: "cerrada",
  /** Fetch/push a repository from a code host. */
  REPO: "repo",
  /** Install declared dependencies from a package registry. */
  DEPS: "deps",
});

export class NetworkError extends Error {}

/** One Docker network per phase, so the allowed set is decided by the phase, not by the caller. */
function networkName(phase) {
  return `movilclaw-${phase}`;
}

/** Human-readable summary of what a phase allows. Used by the API and the UI. */
export function describePhase(phase) {
  switch (phase) {
    case PHASES.CLOSED:
      return { phase, hosts: [], explanation: "Cerrada: el sandbox no tiene red." };
    case PHASES.REPO:
      return {
        phase,
        hosts: ["github.com", "codeload.github.com", "raw.githubusercontent.com", "objects.githubusercontent.com"],
        explanation: "Abierta solo para traer o publicar un repositorio. Se cierra al terminar.",
      };
    case PHASES.DEPS:
      return {
        phase,
        hosts: ["registry.npmjs.org", "pypi.org", "files.pythonhosted.org", "deb.debian.org", "security.debian.org", "dl-cdn.alpinelinux.org"],
        explanation: "Abierta solo para instalar dependencias declaradas. Se cierra al terminar.",
      };
    default:
      throw new NetworkError(`fase de red desconocida: ${phase}`);
  }
}

/**
 * Change the network phase of one container.
 *
 * `closed` detaches every network (no route out). The other phases attach the container to
 * that phase's network. The caller must pass the phase explicitly: there is no "open
 * everything" value, by design.
 */
export function createNetwork(docker) {
  return {
    async setPhase(container, phase) {
      if (!Object.values(PHASES).includes(phase)) {
        throw new NetworkError(`fase de red desconocida: ${phase}`);
      }
      // Always detach first: a container left on two networks would keep the old permission.
      const attached = await docker.attachedNetworks(container).catch(() => []);
      for (const network of attached) {
        await docker.disconnectNetwork(container, network);
      }
      if (phase === PHASES.CLOSED) return { phase, attached: [] };

      const network = networkName(phase);
      await docker.ensureNetwork(network);
      await docker.connectNetwork(container, network);
      return { phase, attached: [network] };
    },
  };
}

/**
 * Assert that a host is reachable under the current phase *conceptually*.
 *
 * This does not talk to the network: it documents and enforces the intent, and the real
 * enforcement is the Docker attachment above. It is used by the API before starting a
 * fetch, so a caller asking for an unlisted host is refused with a reason instead of
 * silently getting a connection error.
 */
export function assertHostAllowed(phase, hostname) {
  const { hosts } = describePhase(phase);
  const clean = String(hostname).toLowerCase().replace(/\.$/, "");
  const ok = hosts.some((h) => clean === h || clean.endsWith(`.${h}`));
  if (!ok) {
    throw new NetworkError(`en la fase "${phase}" no se permite llegar a ${clean}`);
  }
}

export { DockerError };
