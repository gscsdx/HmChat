import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const ts = require(process.env.HARLGRAM_TYPESCRIPT);
const root = process.env.HARLGRAM_ROOT;
const source = path.join(root, 'entry/src/main/ets');
const output = path.join(root, 'artifacts/tests/js');
const files = [
  'model/ChatModels.ts',
  'model/MediaModels.ts',
  'model/StorageModels.ts',
  'model/VideoPlayback.ts',
  'model/MessagePresentation.ts',
  'model/PhoneNumber.ts',
  'model/PhotoTransform.ts',
  'data/PhoneCountries.ts',
  'data/DemoData.ts',
  'data/ChatRepository.ts',
  'telegram/TdTypes.ts',
  'telegram/RichMessage.ts',
  'telegram/TelegramClient.ts',
  'model/ClashModels.ts',
  'model/ClashError.ts',
  'model/ClashStateMachine.ts',
  'model/ClashProfileRules.ts',
  'model/ClashRedaction.ts',
  'model/ClashActionFactory.ts',
  'model/ClashSubscriptionParser.ts',
  'model/ClashGroupDeriver.ts',
  'model/ClashDelayMap.ts',
  'model/ClashConfigPatch.ts',
  'model/ClashVpnConfig.ts',
  'services/clash/ClashRpcProtocol.ts',
];
fs.mkdirSync(output, { recursive: true });
fs.writeFileSync(path.join(output, 'package.json'), '{"type":"commonjs"}\n');
for (const file of files) {
  const result = ts.transpileModule(fs.readFileSync(path.join(source, file), 'utf8'), {
    fileName: file,
    reportDiagnostics: true,
    compilerOptions: {
      target: ts.ScriptTarget.ES2020,
      module: ts.ModuleKind.CommonJS,
      strict: true,
      esModuleInterop: true,
    },
  });
  const errors = (result.diagnostics || []).filter(item => item.category === ts.DiagnosticCategory.Error);
  if (errors.length) {
    throw new Error(ts.formatDiagnosticsWithColorAndContext(errors, {
      getCanonicalFileName: value => value,
      getCurrentDirectory: () => root,
      getNewLine: () => '\n',
    }));
  }
  const target = path.join(output, file.replace(/\.ts$/, '.js'));
  fs.mkdirSync(path.dirname(target), { recursive: true });
  fs.writeFileSync(target, result.outputText);
}
console.log('已转译纯 TypeScript 领域层。设备 API 与 ArkUI 编译需另运行 scripts/build.sh。');
