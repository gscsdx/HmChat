/** Whether a compatible modern TDLib JSON shared library is packaged and loadable. */
export const getTdlibStatus: () => string;
/** Creates a real TDLib client; throws TDLIB_NOT_LINKED when unavailable. */
export const createClient: () => number;
/** Sends 1–1048576 UTF-8 bytes of JSON to a client created by this bridge. */
export const send: (clientId: number, request: string) => void;
/** Nonblocking poll of the process-wide update queue; an empty string means no update. */
export const receive: () => string;
