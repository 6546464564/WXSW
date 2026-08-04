import {create} from 'zustand';
import {getObject, setObject} from '../utils/storage';

export type PageMode = 'cover' | 'slide' | 'simulate' | 'scroll' | 'none';

interface ReaderSettings {
  fontSize: number;
  lineHeight: number;
  backgroundColor: string;
  textColor: string;
  pageMode: PageMode;
}

interface ReaderState {
  settings: ReaderSettings;
  currentContent: string;
  currentChapterTitle: string;
  loading: boolean;
  updateSettings: (partial: Partial<ReaderSettings>) => void;
  setContent: (content: string, title: string) => void;
  setLoading: (loading: boolean) => void;
  loadSettingsFromDisk: () => Promise<void>;
}

const SETTINGS_KEY = 'wanxiang.reader.settings';

// 字号/行距钳制：防止 0 或超大值导致阅读布局崩溃
const MIN_FONT_SIZE = 12;
const MAX_FONT_SIZE = 32;
const MIN_LINE_HEIGHT = 1.2;
const MAX_LINE_HEIGHT = 2.5;

const clampSettings = (s: ReaderSettings): ReaderSettings => ({
  ...s,
  fontSize: Math.min(MAX_FONT_SIZE, Math.max(MIN_FONT_SIZE, s.fontSize)),
  lineHeight: Math.min(MAX_LINE_HEIGHT, Math.max(MIN_LINE_HEIGHT, s.lineHeight)),
});

const defaultSettings: ReaderSettings = {
  fontSize: 18,
  lineHeight: 1.8,
  backgroundColor: '#FFFFF2',
  textColor: '#333333',
  pageMode: 'scroll',
};

export const useReaderStore = create<ReaderState>((set, get) => ({
  settings: defaultSettings,
  currentContent: '',
  currentChapterTitle: '',
  loading: false,

  updateSettings: partial => {
    const next = clampSettings({...get().settings, ...partial});
    set({settings: next});
    setObject(SETTINGS_KEY, next).catch(() => {});
  },

  setContent: (content, title) => {
    set({currentContent: content, currentChapterTitle: title});
  },

  setLoading: loading => set({loading}),

  loadSettingsFromDisk: async () => {
    const saved = await getObject<ReaderSettings>(SETTINGS_KEY);
    if (saved) {
      set({settings: clampSettings({...defaultSettings, ...saved})});
    }
  },
}));

useReaderStore.getState().loadSettingsFromDisk();
