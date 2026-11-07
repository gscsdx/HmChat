import { common, wantAgent } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { notificationManager } from '@kit.NotificationKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';

const DOMAIN: number = 0x0000;
const TAG: string = 'HarlgramClashKeepAlive';
/** Cadence of the live-view progress ping that keeps the DATA_TRANSFER task alive. */
const PROGRESS_INTERVAL_MS: number = 60 * 1000;
/** Brand-only copy: never include node names, domains, URLs or credentials. */
const NOTIFICATION_TITLE: string = 'HmChat 网络代理';
const NOTIFICATION_TEXT: string = '代理运行中';
const NOTIFICATION_FILE_NAME: string = 'HmChat 网络代理';
const TEMPLATE_NAME: string = 'downloadTemplate';
/** typeCode 8 is the upload/download live-view style. */
const LIVE_VIEW_TYPE_CODE: number = 8;
const PROGRESS_MAX: number = 100;

/**
 * UI-process continuous-task holder for the Clash proxy.
 *
 * `startBackgroundRunning()` is accepted only from a UIAbility context in the
 * stage model; extension contexts are rejected with 201 (Permission denied).
 * The proxy core and the VPN extension therefore never call this class: it is
 * owned by the UI process (ClashService) and only activated after the session
 * reaches `connected`.
 *
 * A DATA_TRANSFER continuous task is reaped by the system after roughly ten
 * minutes unless it observes both live progress updates and real traffic.
 * Publishing a `downloadTemplate` system live view every minute is the
 * documented countermeasure for VPN apps. The notification ID returned by
 * `startBackgroundRunning()` belongs to the system-created continuous-task
 * notification; publishing with the same ID updates its live view instead of
 * creating a separate third-party live view.
 *
 * Failure policy: notification and release failures are counted and logged
 * only. They never reject the caller and never change the proxy state.
 */
export class ClashKeepAlive {
  private static instance: ClashKeepAlive | null = null;

  static get(): ClashKeepAlive {
    if (ClashKeepAlive.instance === null) {
      ClashKeepAlive.instance = new ClashKeepAlive();
    }
    return ClashKeepAlive.instance;
  }

  /** UIAbilityContext retained only for `stopBackgroundRunning()` in `disable()`. */
  private context: common.UIAbilityContext | undefined = undefined;
  private running: boolean = false;
  private starting: boolean = false;
  /**
   * Generation counter: a `disable()` or a newer `enable()` invalidates an
   * in-flight request so its late success is stopped immediately.
   */
  private epoch: number = 0;
  private notificationId: number = 0;
  private progressTimer: number = -1;
  private progressValue: number = 0;
  /** Brand-only display title; never a node name, URL, domain or credential. */
  private title: string = NOTIFICATION_TITLE;
  /** Caller supplied progress (real traffic); when true the timer stops faking it. */
  private externalProgress: boolean = false;
  private revokedHandler: (() => void) | undefined = undefined;
  private revokeCallback: ((info: backgroundTaskManager.ContinuousTaskCancelInfo) => void) | undefined =
    undefined;
  private revokeListening: boolean = false;
  private failureCount: number = 0;

  /** True after `startBackgroundRunning()` succeeded and before `disable()`. */
  isRunning(): boolean {
    return this.running;
  }

  /** Number of non-fatal notification / release failures, for diagnostics only. */
  getFailureCount(): number {
    return this.failureCount;
  }

  /**
   * Optional brand title override. Callers must pass brand copy only: never a
   * node name, subscription URL, domain, server address or credential.
   */
  setTitle(title: string): void {
    if (title.trim() !== '') {
      this.title = title;
    }
  }

  /**
   * Registers the callback invoked when the system cancels the continuous task
   * (for example after a policy violation or a manual notification swipe).
   * The callback runs on the UI thread; ClashService re-checks `hello` /
   * `getRunTime` inside it instead of trusting a stale `connected` state.
   */
  onRevoked(callback: () => void): void {
    this.revokedHandler = callback;
  }

  /**
   * Optional real-traffic hook: feed a 0-100 progress value derived from the
   * proxy's counters. Without it the class publishes a monotonic 1..99 ping.
   */
  setProgress(progress: number): void {
    const normalized: number = Math.floor(progress);
    this.externalProgress = true;
    this.progressValue = normalized < 0 ? 0 : (normalized > PROGRESS_MAX ? PROGRESS_MAX : normalized);
  }

  /** Clears the real-traffic override and resumes timer-driven progress. */
  clearProgress(): void {
    this.externalProgress = false;
  }

  /**
   * Requests the dataTransfer continuous task. Idempotent while running or
   * while a request is in flight. Resolves even when the system rejects the
   * request; inspect `isRunning()` and `getFailureCount()` afterwards.
   */
  async enable(context: common.UIAbilityContext): Promise<void> {
    if (this.running || this.starting) {
      return;
    }
    if (!ClashKeepAlive.isUiAbilityContext(context)) {
      this.failureCount++;
      hilog.warn(DOMAIN, TAG, 'enable rejected: not a UIAbilityContext');
      return;
    }
    this.starting = true;
    const epoch: number = ++this.epoch;
    try {
      // actionType/actionFlags (not the deprecated operationType/wantAgentFlags
      // spellings): API 26 rejects agents built from the deprecated fields with
      // 16000151 "Invalid wantAgent object".
      const info: wantAgent.WantAgentInfo = {
        wants: [{
          bundleName: context.abilityInfo.bundleName,
          abilityName: context.abilityInfo.name
        }],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0,
        actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      };
      const agent = await wantAgent.getWantAgent(info);
      const result: backgroundTaskManager.ContinuousTaskNotification =
        await backgroundTaskManager.startBackgroundRunning(context, ['dataTransfer'], agent);
      if (epoch !== this.epoch) {
        // A disable() or a newer enable() won the race; release this request.
        backgroundTaskManager.stopBackgroundRunning(context).catch((error: BusinessError) => {
          this.reportFailure('stop after stale start', error);
        });
        return;
      }
      this.notificationId = result.notificationId;
      this.context = context;
      this.running = true;
      this.startRevokeListener();
      this.publishProgress();
      this.startTimer();
      hilog.info(DOMAIN, TAG, 'continuous task started id=%{public}d', this.notificationId);
    } catch (error) {
      this.failureCount++;
      const err: BusinessError = error as BusinessError;
      hilog.warn(DOMAIN, TAG, 'start continuous task failed: %{public}d %{public}s', err.code, err.message);
      if (this.running) {
        // The task was granted but a later step failed; release it so a failed
        // enable never leaves a background task or notification behind.
        backgroundTaskManager.stopBackgroundRunning(context).catch((stopError: BusinessError) => {
          this.reportFailure('stop after failed start', stopError);
        });
      }
      // Partial state must not look like a running task.
      this.running = false;
      this.context = undefined;
      this.notificationId = 0;
      this.clearTimer();
      this.stopRevokeListener();
    } finally {
      this.starting = false;
    }
  }

  /**
   * Releases the continuous task, its timer, live-view notification and
   * revocation listener. Safe to call at any time, including before `enable()`
   * and repeatedly. A failing release only increments the warning counter.
   */
  disable(): void {
    ++this.epoch;
    this.clearTimer();
    this.stopRevokeListener();
    const context: common.UIAbilityContext | undefined = this.context;
    this.context = undefined;
    this.notificationId = 0;
    this.running = false;
    this.starting = false;
    if (context === undefined) {
      return;
    }
    // Stopping the continuous task also removes its notification (the live
    // view shares the same system-owned ID); no separate cancel is needed.
    backgroundTaskManager.stopBackgroundRunning(context).catch((error: BusinessError) => {
      this.reportFailure('stop continuous task', error);
    });
  }

  private startTimer(): void {
    this.clearTimer();
    this.progressTimer = setInterval(() => {
      this.publishProgress();
    }, PROGRESS_INTERVAL_MS);
  }

  private clearTimer(): void {
    if (this.progressTimer !== -1) {
      clearInterval(this.progressTimer);
      this.progressTimer = -1;
    }
  }

  /**
   * Publishes the live-view progress ping. Uses the notification ID owned by
   * the continuous task: third-party apps cannot create a SYSTEM_LIVE_VIEW
   * directly, they can only update the system-proxy-created one.
   */
  private publishProgress(): void {
    if (!this.running || this.notificationId === 0) {
      return;
    }
    if (!this.externalProgress) {
      this.progressValue = (this.progressValue + 1) % PROGRESS_MAX;
    }
    const templateData: Record<string, Object> = {};
    templateData['title'] = this.title;
    templateData['fileName'] = NOTIFICATION_FILE_NAME;
    templateData['progressValue'] = this.progressValue;
    const request: notificationManager.NotificationRequest = {
      id: this.notificationId,
      content: {
        notificationContentType:
          notificationManager.ContentType.NOTIFICATION_CONTENT_SYSTEM_LIVE_VIEW,
        systemLiveView: {
          typeCode: LIVE_VIEW_TYPE_CODE,
          title: this.title,
          text: NOTIFICATION_TEXT,
          progress: {
            maxValue: PROGRESS_MAX,
            currentValue: this.progressValue,
            isPercentage: true
          }
        }
      },
      notificationSlotType: notificationManager.SlotType.LIVE_VIEW,
      template: {
        name: TEMPLATE_NAME,
        data: templateData
      }
    };
    notificationManager.publish(request).catch((error: BusinessError) => {
      this.reportFailure('publish live view', error);
    });
  }

  /**
   * API 26 does not expose `continuousTaskStateChange`; the equivalent event is
   * `continuousTaskCancel` (since API 15). It is registered after the task has
   * been granted, because the event itself needs KEEP_BACKGROUND_RUNNING.
   */
  private startRevokeListener(): void {
    if (this.revokeListening) {
      return;
    }
    const callback = (info: backgroundTaskManager.ContinuousTaskCancelInfo): void => {
      hilog.warn(DOMAIN, TAG, 'continuous task revoked id=%{public}d reason=%{public}d',
        info.id, info.reason);
      this.clearTimer();
      this.running = false;
      this.context = undefined;
      this.notificationId = 0;
      const handler: (() => void) | undefined = this.revokedHandler;
      if (handler !== undefined) {
        handler();
      }
    };
    try {
      backgroundTaskManager.on('continuousTaskCancel', callback);
      this.revokeCallback = callback;
      this.revokeListening = true;
    } catch (error) {
      this.failureCount++;
      const err: BusinessError = error as BusinessError;
      hilog.warn(DOMAIN, TAG, 'subscribe cancel event failed: %{public}d %{public}s', err.code, err.message);
    }
  }

  private stopRevokeListener(): void {
    const callback: ((info: backgroundTaskManager.ContinuousTaskCancelInfo) => void) | undefined =
      this.revokeCallback;
    this.revokeCallback = undefined;
    this.revokeListening = false;
    if (callback === undefined) {
      return;
    }
    try {
      backgroundTaskManager.off('continuousTaskCancel', callback);
    } catch (error) {
      this.failureCount++;
      const err: BusinessError = error as BusinessError;
      hilog.warn(DOMAIN, TAG, 'unsubscribe cancel event failed: %{public}d %{public}s', err.code, err.message);
    }
  }

  private reportFailure(action: string, error: BusinessError): void {
    this.failureCount++;
    hilog.warn(DOMAIN, TAG, '%{public}s failed: %{public}d %{public}s', action, error.code, error.message);
  }

  /**
   * Runtime guard for the UI-process-only contract. Extension contexts expose
   * `extensionAbilityInfo` instead of `abilityInfo`, so this also rejects a
   * cast extension context before it reaches `startBackgroundRunning()`.
   */
  private static isUiAbilityContext(context: common.UIAbilityContext): boolean {
    try {
      const abilityInfo = context.abilityInfo;
      return abilityInfo.name !== '' && abilityInfo.bundleName !== '';
    } catch (_) {
      // A cast extension context has no abilityInfo; reject it here.
      return false;
    }
  }
}