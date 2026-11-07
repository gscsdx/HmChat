import { describe, it, expect } from '@ohos/hypium';
import { ChatRepository } from '../main/ets/data/ChatRepository';

export default function localUnitTest() {
  describe('ChatRepository', () => {
    it('keeps_unsent_text_after_restore', 0, () => {
      const original = new ChatRepository();
      original.setDraft('saved', 'unfinished');
      const restored = new ChatRepository();
      expect(restored.restore(original.serialize())).assertTrue();
      expect(restored.getDraft('saved')).assertEqual('unfinished');
    });
    it('remote_messages_cannot_be_faked_by_local_repository', 0, () => {
      const repository = new ChatRepository();
      repository.useRemoteData();
      expect(repository.sendMessage('saved', 'not delivered')).assertFalse();
      expect(repository.getMessages('saved').length).assertEqual(0);
    });
  });
}
