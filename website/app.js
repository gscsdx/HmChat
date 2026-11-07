/* Progressive enhancement only: the complete Chinese page works without JavaScript. */
const english = {
  'skip': 'Skip to content', 'navigation': 'Main navigation',
  'nav.home': 'Overview', 'nav.features': 'Features', 'nav.roadmap': 'Roadmap', 'nav.changelog': 'Changelog',
  'hero.title1': 'Telegram.', 'hero.title2': 'Native to HarmonyOS.',
  'hero.description': 'An open-source native third-party Telegram client for HarmonyOS NEXT. Familiar conversations in ArkUI, connected to Telegram through TDLib.',
  'hero.source': 'View source', 'hero.build': 'Build it yourself',
  'hero.note': 'In active development · Phone experience first',
  'hero.screenshot': 'HmChat single-column device capture, privacy-redacted and composited into an illustrative Pura X Max frame',
  'hero.caption': 'HarmonyOS NEXT · Privacy-redacted device capture',
  'foundation.label': 'Native, from interface to connection.',
  'features.title': 'Start with everyday conversations.',
  'features.intro': 'The core paths are connected. Each capability moves forward through real protocol behavior, native interactions, and device checks.',
  'feature.auth.title': 'Your account. Connected.',
  'feature.auth.text': 'Phone, verification code, two-step password, and email verification. Separate country selection and calling code, with session recovery.',
  'feature.auth.detail': 'Driven by TDLib authentication states',
  'feature.chats.title': 'A familiar rhythm',
  'feature.chats.text': 'Real avatars, unread counts, contacts, and Saved Messages. Search and filter loaded chats, pin conversations, and mute them.',
  'feature.chats.detail': 'Local filtering · Not global search',
  'feature.messages.title': 'Make messages work',
  'feature.messages.text': 'Send and receive text, reply, edit, forward a message, or delete it. Native context menus follow server-provided permissions.',
  'feature.messages.detail': 'Pending, sent, and failed stay distinct',
  'feature.photos.title': 'A closer look',
  'feature.photos.text': 'Pick up to 10 photos/videos, preview and exchange albums. Zoom photos; stream video, seek uncached positions, and use playback-speed gestures.',
  'feature.photos.detail': 'You confirm before a photo is sent',
  'feature.drafts.title': 'Keep your train of thought',
  'feature.drafts.text': 'Text drafts, paginated history, group sender names, and date separators. Replying and editing preserve your ordinary draft.',
  'feature.drafts.detail': 'Rich drafts and cross-device edge cases remain in progress',
  'feature.native.title': 'At home on HarmonyOS',
  'feature.native.text': 'Official navigation, menus, sheets, and a glass tab bar. Light, dark, or system appearance, with keyboard and safe-area handling.',
  'feature.native.detail': 'Native ArkUI · No WebView shell',
  'device.title': 'Unfold a little more room.',
  'device.text': 'A two-column layout captured on a real device. Only this static view has been captured; continued interaction while unfolding, rotating, and using multiple windows still needs validation.',
  'device.screenshot': 'HmChat two-column unfolded device capture, privacy-redacted and composited into an illustrative Pura X Max frame',
  'device.caption': 'Device captures are privacy-redacted and composited into illustrative device frames. Unfolded behavior remains under validation.',
  'progress.title': 'Open progress. Clear boundaries.', 'progress.status': 'Read the current status',
  'progress.one.title': 'Core paths tested',
  'progress.one.text': 'SDK 26 builds, real account sign-in, text and photo exchange, and cross-client checks for selected message actions.',
  'progress.two.title': 'Now: refine the phone experience',
  'progress.two.text': 'Make single-column conversations, drafts, media, and message actions work well. Telegram Web A on mobile is the functional reference.',
  'progress.three.title': 'Next: close the gaps, one by one',
  'progress.three.text': 'Server search, folders and archives, full media support, group management, background notifications, and calls—with separate acceptance checks.',
  'limits.badge': 'DEVELOPMENT PREVIEW', 'limits.title': 'Not a complete replacement yet.',
  'limits.search': 'Search covers loaded chats only. Server-wide search is not implemented.',
  'limits.media': 'Photos, albums, and video work; full voice, arbitrary file, sticker, and GIF interactions remain incomplete.',
  'limits.platform': 'Account switching works; inactive-account notifications, background push, calls, and full group management remain on the roadmap.',
  'limits.device': 'Single-column phones come first. Unfolded, tablet, and multi-window layouts have not completed acceptance testing.',
  'limits.link': 'Explore the feature-by-feature gaps',
  'engineering.title': 'Clear boundaries. Shared context.',
  'engineering.text': 'Interface, domain state, protocol, and platform adapters have separate responsibilities. Pure logic is tested independently; device behavior is checked with the real SDK and running app.',
  'engineering.link': 'Read the architecture', 'engineering.diagram': 'Architecture layers',
  'architecture.ui': 'Interface · Navigation · Native interactions',
  'architecture.domain': 'State · Drafts · Protocol · Testable logic',
  'architecture.platform': 'Lifecycle · Secure storage · Native bridge',
  'architecture.tdlib': 'Telegram connection · Encrypted sandbox database',
  'ai.title': 'AI-native describes how we build.',
  'ai.text': 'AGENTS.md, architecture docs, status notes, scripts, and tests give people and AI a shared, verifiable handoff. It does not mean uploading your chats to AI. The app currently has no AI chat-processing feature.',
  'ai.link': 'See the workflow',
  'develop.title': 'Start from source.',
  'develop.text': 'Prepare DevEco Studio and HarmonyOS SDK 26. Use the scripts to check your environment, build native dependencies, and build the app.',
  'develop.config': 'After setup, configure your own Telegram API ID / Hash and DevEco signing identity locally.',
  'develop.native': 'The first native build downloads and compiles TDLib / OpenSSL. Allow time for this step.',
  'develop.safety': 'Private configuration, signing files, and account data stay out of Git. End users do not need a developer API ID to sign in.',
  'develop.guide': 'Full development guide', 'develop.copy': 'Copy', 'develop.commands': 'Development commands',
  'develop.footer': 'Local build · Your API configuration · Your signing identity',
  'open.title': 'Build a better native experience.',
  'open.text': 'Read the code, report an issue, improve the docs, or take on a feature with a clear acceptance test.',
  'open.link': 'Contribute on GitHub',
  'footer.notices': 'Third-party notices', 'footer.issues': 'Report an issue',
  'footer.disclaimer': 'An independent open-source project, not an official Telegram client. Dependencies retain their respective licenses.',
  'footer.privacy': 'No analytics, external fonts, or third-party scripts on this site.'
};

const translatable = [...document.querySelectorAll('[data-i18n], [data-i18n-aria], [data-i18n-alt]')];
const chinese = new Map();
for (const element of translatable) {
  const attribute = element.hasAttribute('data-i18n-aria') ? 'aria-label' : element.hasAttribute('data-i18n-alt') ? 'alt' : null;
  const key = element.dataset.i18n ?? element.dataset.i18nAria ?? element.dataset.i18nAlt;
  chinese.set(key, attribute ? element.getAttribute(attribute) : element.textContent);
}

let language = 'zh';
const titles = { zh: 'HmChat｜鸿蒙 HarmonyOS NEXT 原生 Telegram 客户端', en: 'HmChat | Native Telegram Client for HarmonyOS NEXT' };
const descriptions = {
  zh: 'HmChat 是开源的鸿蒙 HarmonyOS NEXT 原生 Telegram 第三方客户端，基于 ArkUI + TDLib，持续开发中。查看功能进度、界面预览和源码构建指南。',
  en: 'HmChat is an open-source native third-party Telegram client for HarmonyOS NEXT, built with ArkUI + TDLib and in active development. Explore features, previews, and source build guides.'
};

function setLanguage(next) {
  language = next === 'en' ? 'en' : 'zh';
  document.documentElement.lang = language === 'zh' ? 'zh-CN' : 'en';
  const page = document.body.dataset.page;
  const labels = { features: { zh: '现有功能', en: 'Features' }, roadmap: { zh: '路线图', en: 'Roadmap' }, changelog: { zh: '更新日志', en: 'Changelog' } };
  const pageTitle = labels[page] ? `${labels[page][language]} | HmChat` : titles[language];
  const pageDescription = labels[page] ? (language === 'zh' ? `HmChat ${labels[page].zh}：实现范围、验证与后续计划。` : `HmChat ${labels[page].en}: implementation scope, validation, and plans.`) : descriptions[language];
  document.title = pageTitle;
  for (const section of document.querySelectorAll('[data-doc-language]')) section.hidden = section.dataset.docLanguage !== language;
  document.querySelector('meta[name="description"]').content = pageDescription;
  document.querySelector('meta[property="og:title"]').content = pageTitle;
  document.querySelector('meta[property="og:description"]').content = pageDescription;
  for (const element of translatable) {
    const key = element.dataset.i18n ?? element.dataset.i18nAria ?? element.dataset.i18nAlt;
    const value = language === 'en' ? english[key] : chinese.get(key);
    if (value === undefined) continue;
    if (element.hasAttribute('data-i18n-aria')) element.setAttribute('aria-label', value);
    else if (element.hasAttribute('data-i18n-alt')) element.setAttribute('alt', value);
    else element.textContent = value;
  }
  for (const button of document.querySelectorAll('[data-language]')) {
    button.setAttribute('aria-pressed', String(button.dataset.language === language));
  }
  try { localStorage.setItem('harlgram.site.language', language); } catch { /* Storage is optional. */ }
}

for (const button of document.querySelectorAll('[data-language]')) {
  button.addEventListener('click', () => setLanguage(button.dataset.language));
}
try { if (localStorage.getItem('harlgram.site.language') === 'en') setLanguage('en'); } catch { /* Chinese is the default. */ }

const copyButton = document.getElementById('copy-command');
if (copyButton) {
copyButton.hidden = false;
copyButton.addEventListener('click', async () => {
  const code = document.getElementById('build-commands');
  const status = document.getElementById('copy-status');
  try {
    if (!navigator.clipboard) throw new Error('Clipboard unavailable');
    await navigator.clipboard.writeText(code.textContent);
    status.textContent = language === 'zh' ? '命令已复制。请先完成本机 API 与签名配置，再构建。' : 'Commands copied. Configure your API credentials and signing identity before building.';
    copyButton.querySelector('span').textContent = language === 'zh' ? '已复制' : 'Copied';
    window.setTimeout(() => { copyButton.querySelector('span').textContent = language === 'zh' ? '复制' : 'Copy'; }, 2000);
  } catch {
    const selection = window.getSelection();
    const range = document.createRange();
    range.selectNodeContents(code);
    selection?.removeAllRanges();
    selection?.addRange(range);
    code.parentElement.focus();
    status.textContent = language === 'zh' ? '浏览器未允许复制，命令已选中，可手动复制。' : 'Clipboard access was unavailable. The commands are selected for manual copying.';
  }
});

}

// Content stays visible if JavaScript or IntersectionObserver is unavailable.
const motionPreference = window.matchMedia('(prefers-reduced-motion: reduce)');
if ('IntersectionObserver' in window && !motionPreference.matches) {
  const observer = new IntersectionObserver(entries => {
    for (const entry of entries) {
      if (entry.isIntersecting) {
        entry.target.classList.add('reveal');
        observer.unobserve(entry.target);
      }
    }
  }, { threshold: 0.12 });
  document.querySelectorAll('.section-heading, .engineering-copy, .ai-card, .open-source-section').forEach(element => observer.observe(element));
}
