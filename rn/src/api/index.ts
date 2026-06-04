/**
 * 万象书屋 RN · API 统一出口
 */

export {wanxiangClient, BASE_URL, PLATFORM} from './client';
export {fetchBookSources, reportSourceError} from './sources';
export {fetchBookStoreData, fetchMirrorRaw, clearMirrorCache, fetchYuepiaoTop50, fetchFinishLibrary, fetchRankBooks} from './bookstore';
export type {QidianBook, RankingGroup, BookStoreData, Channel} from './bookstore';
export {sendHeartbeat, checkVersion, fetchAnnouncements, submitFeedback} from './device';
export type {VersionCheckResult, Announcement} from './device';
export {fetchAdConfig, reportAdEvent, reportAdEvents} from './ad';
export type {AdConfig, AdSlot} from './ad';
export {fetchPromoCodes, attemptPromo, reportPromoUsage} from './promo';
export type {PromoCode} from './promo';
export {verifyReceipt, fetchEntitlements} from './iap';
export type {Entitlement} from './iap';
export {searchProxy, changeSourceSearch} from './search';
export type {ProxySearchBook} from './search';
export {searchLibrary, fetchLibraryChapters, fetchLibraryContent, fetchLibraryBooks} from './library';
export type {LibraryBook, LibraryChapter, LibraryContent} from './library';
