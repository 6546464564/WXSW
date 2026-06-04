/**
 * 万象书屋 RN · 书库缓存 API
 * 对齐后端: /api/cache/*
 * 对齐 iOS: WanxiangAPI.searchLibrary / fetchLibraryChapters / fetchLibraryContent
 */

import {wanxiangClient} from './client';

export interface LibraryBook {
  id: number;
  qidianId?: string;
  title: string;
  author: string;
  category?: string;
  coverUrl?: string;
  intro?: string;
  totalChapters: number;
  cachedChapters: number;
}

export interface LibraryChapter {
  idx: number;
  title: string;
  wordCount: number;
  status: string;
}

export interface LibraryContent {
  bookId: number;
  idx: number;
  title: string;
  wordCount: number;
  content: string;
}

interface SearchResponse {
  ok: boolean;
  count: number;
  books: LibraryBook[];
}

interface ChaptersResponse {
  ok: boolean;
  bookId: number;
  title: string;
  chapters: LibraryChapter[];
}

/**
 * 搜索书库缓存
 */
export async function searchLibrary(keyword: string, limit = 20): Promise<LibraryBook[]> {
  const res = await wanxiangClient.instance.get<SearchResponse>(
    '/api/cache/search',
    {params: {keyword, limit}},
  );
  return res.data?.books || [];
}

/**
 * 获取缓存书籍的章节列表
 */
export async function fetchLibraryChapters(bookId: number): Promise<LibraryChapter[]> {
  const res = await wanxiangClient.instance.get<ChaptersResponse>(
    `/api/cache/books/${bookId}/chapters`,
  );
  return res.data?.chapters || [];
}

/**
 * 获取章节内容
 */
export async function fetchLibraryContent(
  bookId: number,
  chapterIdx: number,
): Promise<LibraryContent> {
  const res = await wanxiangClient.instance.get<LibraryContent>(
    `/api/cache/books/${bookId}/chapters/${chapterIdx}`,
  );
  return res.data;
}

/**
 * 列出所有缓存书籍
 */
export async function fetchLibraryBooks(status = 'done'): Promise<LibraryBook[]> {
  const res = await wanxiangClient.instance.get<SearchResponse>(
    '/api/cache/books',
    {params: {status}},
  );
  return res.data?.books || [];
}
