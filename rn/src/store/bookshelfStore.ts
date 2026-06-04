import {create} from 'zustand';
import {getObject, setObject} from '../utils/storage';

const SHELF_KEY = 'wanxiang.bookshelf';
const GROUPS_KEY = 'wanxiang.bookshelf.groups';

export interface ShelfBook {
  id: string;
  name: string;
  author: string;
  coverUrl?: string;
  bookUrl: string;
  sourceUrl: string;
  lastChapterIndex: number;
  lastReadTime: number;
  totalChapters?: number;
  group?: string;
}

interface BookshelfState {
  books: ShelfBook[];
  groups: string[];
  hydrated: boolean;
  addBook: (book: Omit<ShelfBook, 'id' | 'lastReadTime'>) => void;
  removeBook: (id: string) => void;
  updateProgress: (id: string, chapterIndex: number) => void;
  moveToGroup: (bookId: string, group: string) => void;
  addGroup: (name: string) => void;
  removeGroup: (name: string) => void;
  renameGroup: (oldName: string, newName: string) => void;
  hydrate: () => Promise<void>;
}

function persist(books: ShelfBook[]) {
  setObject(SHELF_KEY, books).catch(() => {});
}

function persistGroups(groups: string[]) {
  setObject(GROUPS_KEY, groups).catch(() => {});
}

export const useBookshelfStore = create<BookshelfState>((set, get) => ({
  books: [],
  groups: [],
  hydrated: false,

  addBook: book => {
    const exists = get().books.find(b => b.bookUrl === book.bookUrl);
    if (exists) return;
    const newBook: ShelfBook = {
      ...book,
      id: Date.now().toString(36),
      lastReadTime: Date.now(),
    };
    const next = [newBook, ...get().books];
    set({books: next});
    persist(next);
  },

  removeBook: id => {
    const next = get().books.filter(b => b.id !== id);
    set({books: next});
    persist(next);
  },

  updateProgress: (id, chapterIndex) => {
    const next = get().books.map(b =>
      b.id === id
        ? {...b, lastChapterIndex: chapterIndex, lastReadTime: Date.now()}
        : b,
    );
    set({books: next});
    persist(next);
  },

  moveToGroup: (bookId, group) => {
    const next = get().books.map(b =>
      b.id === bookId ? {...b, group: group || undefined} : b,
    );
    set({books: next});
    persist(next);
  },

  addGroup: name => {
    const gs = get().groups;
    if (gs.includes(name)) return;
    const next = [...gs, name];
    set({groups: next});
    persistGroups(next);
  },

  removeGroup: name => {
    const nextGroups = get().groups.filter(g => g !== name);
    const nextBooks = get().books.map(b =>
      b.group === name ? {...b, group: undefined} : b,
    );
    set({groups: nextGroups, books: nextBooks});
    persistGroups(nextGroups);
    persist(nextBooks);
  },

  renameGroup: (oldName, newName) => {
    const nextGroups = get().groups.map(g => g === oldName ? newName : g);
    const nextBooks = get().books.map(b =>
      b.group === oldName ? {...b, group: newName} : b,
    );
    set({groups: nextGroups, books: nextBooks});
    persistGroups(nextGroups);
    persist(nextBooks);
  },

  hydrate: async () => {
    if (get().hydrated) return;
    const saved = await getObject<ShelfBook[]>(SHELF_KEY);
    const savedGroups = await getObject<string[]>(GROUPS_KEY);
    set({
      books: saved && saved.length > 0 ? saved : [],
      groups: savedGroups || [],
      hydrated: true,
    });
  },
}));

useBookshelfStore.getState().hydrate();
