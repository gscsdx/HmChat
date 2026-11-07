import { describe, it, expect } from '@ohos/hypium';
import nativeTdlib from 'libentry.so';

/** The device runner disables Previewer mocks. This checks real linking without starting authentication. */
export default function abilityTest() {
  describe('NativePackaging', () => {
    it('contains_a_loadable_ohos_tdlib', 0, () => {
      expect(nativeTdlib.getTdlibStatus()).assertEqual('available');
    });
  });
}
