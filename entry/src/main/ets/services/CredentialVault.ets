import { asset } from '@kit.AssetStoreKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { isDatabaseNamespace, selectSessionStorage } from '../model/SessionStorage';

export interface TelegramCredentials {
  apiId: number;
  apiHash: string;
  encryptionKey: string;
  databaseNamespace?: string;
}

/** Only API application credentials and the database key are persisted, never login codes or passwords. */
export class CredentialVault {
  private static alias(accountId: string = 'primary'): Uint8Array {
    if (accountId !== 'primary' && !/^[a-f0-9]{32}$/.test(accountId)) { throw new Error('账户标识无效'); }
    return new util.TextEncoder().encodeInto(accountId === 'primary' ? 'harlgram.telegram.v1' : 'harlgram.telegram.v1.' + accountId);
  }
  static createAccountId(): string {
    const bytes = cryptoFramework.createRandom().generateRandomSync(16).data;
    let id = '';
    bytes.forEach((value: number) => { id += value.toString(16).padStart(2, '0'); });
    return id;
  }

  static async load(accountId: string = 'primary'): Promise<TelegramCredentials | undefined> {
    const query: asset.AssetMap = new Map();
    query.set(asset.Tag.ALIAS, CredentialVault.alias(accountId));
    query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
    try {
      const results = await asset.query(query);
      if (results.length === 0) { return undefined; }
      const bytes = results[0].get(asset.Tag.SECRET) as Uint8Array;
      const credentials = JSON.parse(new util.TextDecoder().decodeToString(bytes)) as TelegramCredentials;
      if (!credentials || !Number.isSafeInteger(credentials.apiId) || credentials.apiId <= 0 ||
        typeof credentials.apiHash !== 'string' || !/^[a-fA-F0-9]{32}$/.test(credentials.apiHash) ||
        typeof credentials.encryptionKey !== 'string' || credentials.encryptionKey.length === 0 ||
        (credentials.databaseNamespace !== undefined && !isDatabaseNamespace(credentials.databaseNamespace))) {
        throw new Error('安全存储中的账号配置无法读取');
      }
      return credentials;
    } catch (error) {
      if ((error as BusinessError).code === 24000002) { return undefined; }
      throw error as Error;
    }
  }

  static async save(apiId: number, apiHash: string, freshStorage: boolean = false, accountId: string = 'primary'): Promise<TelegramCredentials> {
    if (!Number.isSafeInteger(apiId) || apiId <= 0 || !/^[a-fA-F0-9]{32}$/.test(apiHash)) {
      throw new Error('API 配置格式不正确');
    }
    const previous = await CredentialVault.load(accountId);
    const random = cryptoFramework.createRandom();
    const storage = selectSessionStorage(previous, freshStorage,
      (): string => new util.Base64Helper().encodeToStringSync(random.generateRandomSync(32).data),
      (): string => {
        const bytes = random.generateRandomSync(16).data;
        let namespace = '';
        bytes.forEach((value: number) => { namespace += value.toString(16).padStart(2, '0'); });
        return namespace;
      });
    const credentials: TelegramCredentials = { apiId: apiId, apiHash: apiHash,
      encryptionKey: storage.encryptionKey, databaseNamespace: storage.databaseNamespace };
    const attributes: asset.AssetMap = new Map();
    attributes.set(asset.Tag.ALIAS, CredentialVault.alias(accountId));
    attributes.set(asset.Tag.SECRET, new util.TextEncoder().encodeInto(JSON.stringify(credentials)));
    attributes.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_FIRST_UNLOCKED);
    attributes.set(asset.Tag.CONFLICT_RESOLUTION, asset.ConflictResolution.OVERWRITE);
    await asset.add(attributes);
    return credentials;
  }
}
