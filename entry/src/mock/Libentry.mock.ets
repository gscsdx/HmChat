// Preview does not have a TDLib transport. Never simulate a successful account login.
const NativeMock: Record<string, Object> = {
  'getTdlibStatus': (): string => 'not-linked',
  'createClient': (): number => {
    throw new Error('TDLIB_NOT_LINKED: TDLib is unavailable in Previewer.');
  },
  'send': (_clientId: number, _request: string): void => {
    throw new Error('TDLIB_NOT_LINKED: TDLib is unavailable in Previewer.');
  },
  'receive': (): string => {
    throw new Error('TDLIB_NOT_LINKED: TDLib is unavailable in Previewer.');
  }
};

export default NativeMock;
