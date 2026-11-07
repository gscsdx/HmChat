export interface SessionStorageIdentity {
  encryptionKey: string;
  databaseNamespace?: string;
}

export function isDatabaseNamespace(value: string): boolean {
  return typeof value === 'string' && /^[a-fA-F0-9]{32}$/.test(value);
}

/** Select identity only. Filesystem creation and Asset persistence belong to the OS adapters. */
export function selectSessionStorage(previous: SessionStorageIdentity | undefined, freshStorage: boolean,
  createKey: () => string, createNamespace: () => string): SessionStorageIdentity {
  if (previous && (typeof previous.encryptionKey !== 'string' || previous.encryptionKey.length === 0 ||
    (previous.databaseNamespace !== undefined && !isDatabaseNamespace(previous.databaseNamespace)))) {
    throw new Error('安全存储中的会话标识无效');
  }
  if (previous && !freshStorage) {
    return { encryptionKey: previous.encryptionKey, databaseNamespace: previous.databaseNamespace };
  }
  const key = previous ? previous.encryptionKey : createKey();
  if (typeof key !== 'string' || key.length === 0) { throw new Error('无法创建数据库密钥'); }
  // A recovery cannot accidentally select the directory that just failed to open.
  for (let attempt = 0; attempt < 4; attempt++) {
    const namespace = createNamespace();
    if (!isDatabaseNamespace(namespace)) { throw new Error('无法创建会话存储标识'); }
    if (!previous || namespace !== previous.databaseNamespace) {
      return { encryptionKey: key, databaseNamespace: namespace };
    }
  }
  throw new Error('无法分配新的会话存储目录');
}

export function sessionStorageDirectory(filesDir: string, namespace?: string): string {
  if (!filesDir.startsWith('/')) { throw new Error('应用存储目录无效'); }
  const legacy = filesDir.replace(/\/+$/, '') + '/telegram';
  if (namespace === undefined) { return legacy; }
  if (!isDatabaseNamespace(namespace)) { throw new Error('会话存储标识无效'); }
  return legacy + '/session-' + namespace;
}
