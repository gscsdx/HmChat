export type AppearanceMode = 'system' | 'light' | 'dark';

export function isAppearanceMode(value: string): value is AppearanceMode {
  return value === 'system' || value === 'light' || value === 'dark';
}

/** Migrate only the former appearance flag; never copy the old snapshot into new storage. */
export function migrateAppearanceMode(storedMode: string, legacySnapshot: string): AppearanceMode {
  if (isAppearanceMode(storedMode)) { return storedMode; }
  try {
    const legacy = JSON.parse(legacySnapshot) as { darkMode?: boolean } | null;
    if (legacy && !Array.isArray(legacy) && typeof legacy.darkMode === 'boolean') {
      return legacy.darkMode ? 'dark' : 'light';
    }
  } catch { /* Missing or damaged legacy data defaults to following the system. */ }
  return 'system';
}

/** Preference and effective color are separate; a system event never changes user intent. */
export class AppearanceState {
  private mode: AppearanceMode = 'system';
  private systemDark: boolean = false;
  private revision: number = 0;

  getMode(): AppearanceMode { return this.mode; }
  isDark(): boolean { return this.mode === 'dark' || (this.mode === 'system' && this.systemDark); }
  selectionRevision(): number { return this.revision; }
  select(mode: AppearanceMode): void { this.mode = mode; this.revision++; }
  restore(mode: AppearanceMode, startedRevision: number): void {
    if (this.revision === startedRevision) { this.mode = mode; }
  }
  updateSystemDark(dark: boolean): void { this.systemDark = dark; }
}
