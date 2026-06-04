/**
 * 万象书屋 RN · 书源实体 (跟 iOS/Android 1:1)
 * 对应 iOS: BookSource.swift
 * 对应 Android: io.legado.app.data.entities.BookSource
 */

export enum BookSourceType {
  Text = 0,
  Audio = 1,
  Image = 2,
  File = 3,
}

export interface BookSource {
  // 基础信息
  bookSourceUrl: string;
  bookSourceName: string;
  bookSourceGroup?: string;
  bookSourceType?: number;
  bookUrlPattern?: string;
  customOrder?: number;
  enabled?: boolean;
  enabledExplore?: boolean;
  enabledCookieJar?: boolean;

  // 网络与脚本
  jsLib?: string;
  concurrentRate?: string;
  header?: string;
  loginUrl?: string;
  loginUi?: string;
  loginCheckJs?: string;
  coverDecodeJs?: string;

  // 注释和元数据
  bookSourceComment?: string;
  variableComment?: string;
  lastUpdateTime?: number;
  respondTime?: number;
  weight?: number;

  // 5 大规则
  exploreUrl?: string;
  exploreScreen?: string;
  ruleExplore?: ExploreRule;
  searchUrl?: string;
  ruleSearch?: SearchRule;
  ruleBookInfo?: BookInfoRule;
  ruleToc?: TocRule;
  ruleContent?: ContentRule;
  ruleReview?: ReviewRule;
}

export interface SearchRule {
  checkKeyWord?: string;
  bookList?: string;
  name?: string;
  author?: string;
  intro?: string;
  kind?: string;
  lastChapter?: string;
  updateTime?: string;
  bookUrl?: string;
  coverUrl?: string;
  wordCount?: string;
}

export interface ExploreRule {
  bookList?: string;
  name?: string;
  author?: string;
  intro?: string;
  kind?: string;
  lastChapter?: string;
  updateTime?: string;
  bookUrl?: string;
  coverUrl?: string;
  wordCount?: string;
}

export interface BookInfoRule {
  init?: string;
  name?: string;
  author?: string;
  intro?: string;
  kind?: string;
  lastChapter?: string;
  updateTime?: string;
  coverUrl?: string;
  tocUrl?: string;
  wordCount?: string;
  canReName?: string;
  downloadUrls?: string;
}

export interface TocRule {
  preUpdateJs?: string;
  chapterList?: string;
  chapterName?: string;
  chapterUrl?: string;
  formatJs?: string;
  isVolume?: string;
  isVip?: string;
  isPay?: string;
  updateTime?: string;
  nextTocUrl?: string;
}

export interface ContentRule {
  content?: string;
  title?: string;
  nextContentUrl?: string;
  webJs?: string;
  sourceRegex?: string;
  replaceRegex?: string;
  imageStyle?: string;
  imageDecode?: string;
  payAction?: string;
}

export interface ReviewRule {
  reviewUrl?: string;
  avatarRule?: string;
  contentRule?: string;
  postTimeRule?: string;
  reviewQuoteUrl?: string;
  voteUpUrl?: string;
  voteDownUrl?: string;
  postReviewUrl?: string;
  postQuoteUrl?: string;
  deleteUrl?: string;
}

// 引擎结果类型
export interface SearchResult {
  name: string;
  author: string;
  intro?: string;
  kind?: string;
  coverUrl?: string;
  bookUrl: string;
  lastChapter?: string;
  wordCount?: string;
  updateTime?: string;
  sourceUrl: string;
  sourceName: string;
  /** 跨源合并后的总源数 (对齐 iOS distinctOriginCount) */
  distinctOriginCount: number;
  /** 合并进来的其他源 URL */
  mergedSourceURLs: string[];
  mergedSourceNames: string[];
}

export interface BookInfo {
  name: string;
  author: string;
  intro?: string;
  kind?: string;
  coverUrl?: string;
  tocUrl?: string;
  lastChapter?: string;
  wordCount?: string;
}

export interface Chapter {
  title: string;
  url: string;
  index: number;
  isVolume?: boolean;
  isVip?: boolean;
}

// 规则引擎内部类型
export enum LegadoMode {
  CSS = 'css',
  XPath = 'xpath',
  JSON = 'json',
  JS = 'js',
  Regex = 'regex',
  Raw = 'raw',
}

export interface LegadoSourceRule {
  mode: LegadoMode;
  rule: string;
  replaceRegex: string;
  replacement: string;
  replaceFirst: boolean;
  isAllInOneRegex: boolean;
  hasPlaceholder: boolean;
}

export interface LegadoContext {
  baseUrl?: string;
  source: string;
  key?: string;
  page: number;
  book: Record<string, string>;
  chapter: Record<string, string>;
  nextChapterUrl?: string;
  bookSource?: BookSource;
}
